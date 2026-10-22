//! On-demand HTTP range server. `GET /stream/{id}` serves the media file that a
//! resolver registered, fetching ONLY the segments a byte-range touches — no
//! whole-file grab. The media is modeled as [`Extent`]s: one for a raw post, or
//! several for a RAR5 store-mode release (one per volume). A release verified
//! incomplete before playback is refused (502) so the app fails over.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use axum::Json;

use crate::archive::{self, Extent};
use crate::pool::Pool;
use crate::stream_errors::StreamError;

// std::sync::Mutex throughout: the guards are only ever held for brief synchronous
// sections (never across an `.await`), which keeps the async handlers `Send` and
// avoids tokio-mutex's higher-ranked-lifetime friction with axum.

/// A stream the resolver has registered (id → how to obtain it). The media layout
/// is learned lazily on first playback and cached.
struct StreamEntry {
    nzb_url: String,
    loaded: Mutex<Option<Loaded>>,
    unsupported_at: Mutex<Option<std::time::Instant>>,
    /// Single-flight for the heavy load (NZB download + volume-header fetches):
    /// a serve arriving while a warm is mid-load WAITS for it instead of doing
    /// the whole thing again in parallel (async mutex — held across awaits).
    load_lock: tokio::sync::Mutex<()>,
    verify_lock: tokio::sync::Mutex<()>,
    verification_attempt: Mutex<Option<std::time::Instant>>,
    recovery: Mutex<Recovery>,
}

impl StreamEntry {
    fn unsupported(&self) -> bool {
        let mut at = self.unsupported_at.lock().unwrap();
        if at.is_some_and(|when| when.elapsed() < std::time::Duration::from_secs(300)) { return true; }
        *at = None;
        false
    }
}

#[derive(Default)]
struct Recovery {
    candidates: Vec<String>,
    preparing: bool,
    attempted: bool,
    desired_fraction: f64,
    prepared: Option<PreparedRecovery>,
    last_attempt: Option<std::time::Instant>,
}

struct PreparedRecovery {
    sid: String,
    fraction: f64,
    /// Cache entries required by the head/seek warm. Readiness expires when
    /// any is evicted; a warm timestamp alone cannot guarantee fast playback.
    segments: Vec<String>,
    at: std::time::Instant,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryHealth {
    status: &'static str,
    stream_id: Option<String>,
    prepared_fraction: Option<f64>,
}

#[derive(Serialize)]
struct StreamHealth {
    status: &'static str,
    #[serde(rename = "errorCode", skip_serializing_if = "Option::is_none")]
    error_code: Option<&'static str>,
    recovery: RecoveryHealth,
}

/// The media file as a list of extents — one for a raw post, several for a RAR5
/// store-mode release (one per volume). The media is the concatenation of every
/// extent's data.
struct Loaded {
    extents: Arc<Vec<Extent>>,
    /// Media offset where each extent begins (prefix sums of data_len).
    ext_media_start: Arc<Vec<u64>>,
    total_size: u64,
    /// Async STAT verdict: None = not verified yet (serve optimistically — the
    /// old SYNCHRONOUS gate blocked byte 0 past the player's timeout), true =
    /// every segment confirmed present somewhere, false = confirmed holes. A
    /// false 502s every subsequent request, so the app fails over at a clean
    /// range-request boundary instead of the video parser choking on the
    /// zero-filled gap mid-scene.
    complete: Option<bool>,
}

/// Decoded-segment LRU, byte-capped. Warm jobs fill it ahead of playback; the
/// stream generator consults it before hitting NNTP, so a pre-warmed title's
/// first bytes leave the server with zero usenet round-trips.
pub struct SegCache {
    inner: Mutex<SegCacheInner>,
    max_bytes: usize,
}

struct SegCacheInner {
    map: HashMap<String, (Arc<Vec<u8>>, u64)>,
    order: std::collections::VecDeque<String>,
    bytes: usize,
}

impl SegCache {
    pub fn new(max_bytes: usize) -> Arc<SegCache> {
        Arc::new(SegCache {
            inner: Mutex::new(SegCacheInner {
                map: HashMap::new(),
                order: std::collections::VecDeque::new(),
                bytes: 0,
            }),
            max_bytes,
        })
    }

    pub fn get(&self, message_id: &str) -> Option<(Arc<Vec<u8>>, u64)> {
        self.inner.lock().unwrap().map.get(message_id).cloned()
    }

    pub fn put(&self, message_id: &str, data: Vec<u8>, start: u64) {
        let mut g = self.inner.lock().unwrap();
        if g.map.contains_key(message_id) {
            return;
        }
        g.bytes += data.len();
        g.map.insert(message_id.to_string(), (Arc::new(data), start));
        g.order.push_back(message_id.to_string());
        while g.bytes > self.max_bytes {
            let Some(old) = g.order.pop_front() else { break };
            if let Some((d, _)) = g.map.remove(&old) {
                g.bytes -= d.len();
            }
        }
    }
}

#[derive(Clone)]
pub struct StreamState {
    pub pool: Arc<Pool>,
    pub http: reqwest::Client,
    pub cache: Arc<SegCache>,
    /// For the bad-release ledger (verified-incomplete NZBs, kept forever so the
    /// resolver never offers them again).
    pub db: crate::db::Db,
    streams: Arc<Mutex<HashMap<String, Arc<StreamEntry>>>>,
    /// sid → when it was last warmed, so repeat resolves don't re-warm.
    warmed: Arc<Mutex<HashMap<String, std::time::Instant>>>,
    /// Bound candidate preparation across all viewers. Playback never acquires
    /// this semaphore and continues while alternate releases are prepared.
    recovery_slots: Arc<tokio::sync::Semaphore>,
}

impl StreamState {
    pub fn new(pool: Arc<Pool>, http: reqwest::Client, db: crate::db::Db) -> StreamState {
        StreamState {
            pool,
            http,
            // ~256MB of decoded segments ≈ 15 warmed titles at 24 segments each.
            cache: SegCache::new(256 * 1024 * 1024),
            db,
            streams: Arc::new(Mutex::new(HashMap::new())),
            warmed: Arc::new(Mutex::new(HashMap::new())),
            recovery_slots: Arc::new(tokio::sync::Semaphore::new(2)),
        }
    }

    /// True if this NZB was verified incomplete within the last 7 days. The
    /// verdict EXPIRES: a brand-new post can be condemned mid-propagation while
    /// its articles are still filling in, so an old verdict earns one re-check
    /// (still bad → re-condemned with a fresh timestamp, costing one failover).
    pub fn is_condemned(&self, nzb_url: &str) -> bool {
        if self.streams.lock().unwrap().get(&fnv_hex(nzb_url.as_bytes())).is_some_and(|entry| entry.unsupported()) { return true; }
        let sid = fnv_hex(nzb_url.as_bytes());
        let conn = self.db.lock().unwrap();
        conn.query_row(
            "SELECT 1 FROM bad_releases WHERE sid = ?1 \
             AND found_at > (strftime('%s','now') - 7*86400) * 1000",
            [&sid],
            |_| Ok(()),
        )
        .is_ok()
    }

    fn condemn(&self, sid: &str, nzb_url: &str, reason: &str) {
        let conn = self.db.lock().unwrap();
        let _ = conn.execute(
            "INSERT OR REPLACE INTO bad_releases (sid, nzb_url, reason, found_at) \
             VALUES (?1, ?2, ?3, strftime('%s','now')*1000)",
            rusqlite::params![sid, nzb_url, reason],
        );
    }

    /// Condemn by sid (used when a hole is discovered mid-stream): flips the
    /// in-memory verdict so every later request 502s, and records the ledger row.
    fn condemn_sid(&self, sid: &str, reason: &str) {
        let entry = self.lookup(sid);
        let Some(entry) = entry else { return };
        if let Some(l) = entry.loaded.lock().unwrap().as_mut() {
            l.complete = Some(false);
        }
        self.condemn(sid, &entry.nzb_url, reason);
    }

    /// Register the exact source privately so its public id survives a restart.
    /// Registrations never warm, resolve, or probe alternate releases.
    pub async fn register(&self, nzb_url: &str) -> String {
        let id = fnv_hex(nzb_url.as_bytes());
        {
            let conn = self.db.lock().unwrap();
            let result = conn.execute(
                "INSERT INTO stream_registrations (sid, nzb_url, touched_at) \
                 VALUES (?1, ?2, strftime('%s','now')*1000) \
                 ON CONFLICT(sid) DO UPDATE SET touched_at=excluded.touched_at \
                 WHERE stream_registrations.nzb_url=excluded.nzb_url",
                rusqlite::params![id, nzb_url],
            );
            if result.is_err() {
                // Never include a source URL or database bind values in logs.
                tracing::warn!("could not persist a stream registration");
            }
            // Keep private source credentials bounded on disk. Active in-memory
            // registrations still work; a later resolve refreshes their age.
            let _ = conn.execute(
                "DELETE FROM stream_registrations WHERE sid IN \
                 (SELECT sid FROM stream_registrations ORDER BY touched_at DESC, sid LIMIT -1 OFFSET 50000)",
                [],
            );
        }
        self.streams.lock().unwrap().entry(id.clone())
            .or_insert_with(|| Self::entry(nzb_url.to_owned()));
        id
    }

    fn entry(nzb_url: String) -> Arc<StreamEntry> {
        Arc::new(StreamEntry {
            nzb_url,
            loaded: Mutex::new(None),
            unsupported_at: Mutex::new(None),
            load_lock: tokio::sync::Mutex::new(()),
            verify_lock: tokio::sync::Mutex::new(()),
            verification_attempt: Mutex::new(None),
            recovery: Mutex::new(Recovery::default()),
        })
    }

    /// Local registry lookup only: no provider I/O or health gate. Restoring an
    /// id preserves the same NZB, never a similarly named replacement.
    fn lookup(&self, sid: &str) -> Option<Arc<StreamEntry>> {
        if !valid_stream_id(sid) { return None; }
        if let Some(entry) = self.streams.lock().unwrap().get(sid).cloned() {
            return Some(entry);
        }
        let nzb_url: String = {
            let conn = self.db.lock().unwrap();
            let url: String = conn.query_row(
                "SELECT nzb_url FROM stream_registrations WHERE sid=?1", [sid], |r| r.get(0),
            ).ok()?;
            // Reject corrupted or manually mismatched rows rather than serving
            // any source whose exact stable identity does not match this id.
            if fnv_hex(url.as_bytes()) != sid { return None; }
            let _ = conn.execute(
                "UPDATE stream_registrations SET touched_at=strftime('%s','now')*1000 WHERE sid=?1", [sid],
            );
            url
        };
        let mut map = self.streams.lock().unwrap();
        Some(map.entry(sid.to_owned()).or_insert_with(|| Self::entry(nzb_url)).clone())
    }

    pub fn is_registered(&self, sid: &str) -> bool { self.lookup(sid).is_some() }

    /// True if this sid was warmed recently (and mark it warmed now if not).
    fn claim_warm(&self, sid: &str, ttl: std::time::Duration) -> bool {
        let mut g = self.warmed.lock().unwrap();
        let now = std::time::Instant::now();
        if let Some(t) = g.get(sid) {
            if now.duration_since(*t) < ttl {
                return false;
            }
        }
        g.insert(sid.to_string(), now);
        true
    }

    /// Associate only candidates from the same resolver response (same title
    /// and episode). Never discover arbitrary sources from a client URL.
    pub fn set_recovery_candidates(&self, sids: &[String]) {
        let entries = self.streams.lock().unwrap();
        for sid in sids {
            if let Some(entry) = entries.get(sid) {
                entry.recovery.lock().unwrap().candidates = sids.iter()
                    .filter(|candidate| *candidate != sid)
                    .take(5).cloned().collect();
            }
        }
    }

    fn health(&self, sid: &str) -> Option<StreamHealth> {
        let entry = self.lookup(sid)?;
        let entries = self.streams.lock().unwrap();
        let complete = entry.loaded.lock().unwrap().as_ref().and_then(|l| l.complete);
        let status = if entry.unsupported() { "unsupported" } else { match complete {
            Some(true) => "complete",
            Some(false) => "incomplete",
            None if entry.verify_lock.try_lock().is_err() => "checking",
            None => "unverified",
        }};
        let recovery = entry.recovery.lock().unwrap();
        let ready = recovery.prepared.as_ref().filter(|prepared| {
            prepared.at.elapsed() < std::time::Duration::from_secs(90)
                && (prepared.fraction - recovery.desired_fraction).abs() < 0.002
                && entries.get(&prepared.sid).is_some_and(|candidate| {
                    candidate.loaded.lock().unwrap().as_ref().and_then(|l| l.complete) == Some(true)
                })
                && prepared.segments.iter().all(|id| self.cache.get(id).is_some())
        });
        Some(StreamHealth {
            error_code: match status { "unsupported" => Some("unsupported_archive"), "incomplete" => Some("missing_articles"), _ => None },
            status,
            recovery: RecoveryHealth {
                status: if ready.is_some() { "ready" } else if recovery.preparing {
                    "preparing"
                } else if recovery.attempted { "unavailable" } else { "idle" },
                stream_id: ready.map(|p| p.sid.clone()),
                prepared_fraction: ready.map(|p| p.fraction),
            },
        })
    }

    fn prepare_recovery(&self, sid: &str, fraction: f64) -> bool {
        let entry = self.lookup(sid);
        let Some(entry) = entry else { return false };
        {
            let mut recovery = entry.recovery.lock().unwrap();
            recovery.desired_fraction = fraction.clamp(0.0, 0.999);
            if recovery.preparing { return true; }
            if recovery.last_attempt.is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(20))
                && recovery.prepared.as_ref().is_none_or(|p| (p.fraction - fraction).abs() < 0.002)
            {
                return true;
            }
            recovery.preparing = true;
            recovery.attempted = true;
            recovery.last_attempt = Some(std::time::Instant::now());
        }
        let st = self.clone();
        let sid = sid.to_string();
        tokio::spawn(async move {
            let _slot = st.recovery_slots.acquire().await.expect("semaphore closed");
            prepare_recovery_inner(&st, &sid, &entry).await;
            entry.recovery.lock().unwrap().preparing = false;
        });
        true
    }
}

/// Segments per cached head/seek window (~17MB at 700KB/segment). Playback time
/// covered varies with bitrate; this reduces preparation latency, not all
/// buffering or container-restart time when changing releases.
const WARM_SEGS: usize = 24;

/// Async completeness verdict: STAT every segment (seconds, in the background —
/// never in front of byte 0) and record the result. An incomplete release is
/// condemned in the bad_releases ledger: the resolver stops offering
/// it, serve 502s it, and the warm chain moves to the next candidate — the
/// nzbdav lesson ("only ever play verified-complete files") without nzbdav's
/// blocking import step. Returns whether the release is complete.
pub async fn verify_stream(st: &StreamState, sid: &str) -> anyhow::Result<bool> {
    let entry = st.lookup(sid).ok_or_else(|| anyhow::anyhow!("unknown stream {sid}"))?;
    // Join an existing sweep rather than reporting a still-unverified source
    // as healthy to a concurrent warm. The guard also releases on cancellation.
    let _verification = entry.verify_lock.lock().await;
    if let Some(l) = entry.loaded.lock().unwrap().as_ref() {
        if let Some(v) = l.complete {
            return Ok(v);
        }
    }
    {
        let mut attempt = entry.verification_attempt.lock().unwrap();
        if attempt.is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(15)) {
            anyhow::bail!("verification waiting for provider retry");
        }
        *attempt = Some(std::time::Instant::now());
    }
    verify_stream_inner(st, sid, &entry).await
}

async fn verify_stream_inner(
    st: &StreamState,
    sid: &str,
    entry: &Arc<StreamEntry>,
) -> anyhow::Result<bool> {
    ensure_loaded(st.clone(), entry.clone()).await?;
    let ids = {
        let guard = entry.loaded.lock().unwrap();
        crate::archive::all_segment_ids(&guard.as_ref().unwrap().extents)
    };
    let health = st.pool.completeness(&ids).await;
    let ok = health.is_complete();
    if !ok && health.missing == 0 {
        anyhow::bail!("verification incomplete: providers temporarily unavailable");
    }
    if let Some(l) = entry.loaded.lock().unwrap().as_mut() {
        // A BODY failure discovered during the sweep is stronger evidence than
        // an earlier STAT success. Never erase an already-confirmed hole.
        if l.complete == Some(false) { return Ok(false); }
        l.complete = Some(ok);
    }
    if !ok {
        let reason = format!("{} of {} segments confirmed missing", health.missing, health.total);
        tracing::warn!("stream {sid} verified INCOMPLETE ({reason}) — condemned");
        st.condemn(sid, &entry.nzb_url, &reason);
    } else {
        tracing::info!("stream {sid} verified complete ({} segments)", health.total);
    }
    Ok(ok)
}

/// Pre-warm a registered stream: parse its NZB, build extents, and pull the
/// first WARM_SEGS segments into the cache — plus, if `fraction` is given, the
/// segments around that point of the file (so resuming mid-episode is instant
/// too). Quietly does nothing if warmed recently.
pub async fn warm_head(st: StreamState, sid: String, fraction: Option<f64>) -> anyhow::Result<()> {
    if !st.claim_warm(&sid, std::time::Duration::from_secs(30 * 60)) {
        return Ok(());
    }
    match warm_head_inner(&st, &sid, fraction).await {
        Ok(()) => Ok(()),
        Err(e) => {
            // Un-claim so the next trigger can retry — a claim must never outlive
            // a FAILED warm, or one bad moment blocks warming for the whole TTL.
            st.warmed.lock().unwrap().remove(&sid);
            Err(e)
        }
    }
}

async fn warm_head_inner(st: &StreamState, sid: &str, fraction: Option<f64>) -> anyhow::Result<()> {
    warm_region(st, sid, fraction).await.map(|_| ())
}

async fn warm_region(st: &StreamState, sid: &str, fraction: Option<f64>) -> anyhow::Result<Vec<String>> {
    let entry = st.lookup(sid).ok_or_else(|| anyhow::anyhow!("unknown stream {sid}"))?;
    ensure_loaded(st.clone(), entry.clone()).await?;
    // Verify BEFORE spending fetches on the head: an incomplete release errors
    // out here, so the warm chain moves to the next candidate and whatever ends
    // up cached is a release that will play through without a failover.
    if !verify_stream(st, sid).await? {
        anyhow::bail!("verified incomplete — condemned");
    }
    let (extents, ext_media_start, total) = {
        let guard = entry.loaded.lock().unwrap();
        let l = guard.as_ref().unwrap();
        (l.extents.clone(), l.ext_media_start.clone(), l.total_size)
    };

    let mut targets: Vec<u64> = vec![0, total.saturating_sub(2 * 1024 * 1024)];
    if let Some(f) = fraction {
        let f = f.clamp(0.0, 0.999);
        targets.push((total as f64 * f) as u64);
    }
    let mut warmed_ids = Vec::new();
    for media_off in targets {
        // Cross RAR extent boundaries: a window ending at the current volume
        // must keep warming into the next one, not silently stop after 1 part.
        let jobs = warm_targets(&extents, &ext_media_start, media_off, WARM_SEGS);
        // Fetch missing segments concurrently (bounded) straight into the cache.
        use futures::stream::StreamExt;
        let outcomes = futures::stream::iter(jobs)
            .map(|(ei, idx)| {
                let ext = &extents[ei];
                let pool = st.pool.clone();
                let cache = st.cache.clone();
                let group = ext.group.clone();
                let seg = ext.segments[idx].clone();
                let part_size = ext.part_size;
                async move {
                    let _background = pool.background_permit().await;
                    let (data, start) = fetch_streaming(&pool, &cache, &group, &seg, part_size, idx).await?;
                    cache.put(&seg.message_id, data, start);
                    Ok::<_, FetchFailure>(seg.message_id)
                }
            })
            .buffer_unordered((st.pool.total_capacity() / 8).clamp(1, 4))
            .collect::<Vec<_>>()
            .await;
        for outcome in outcomes {
            match outcome {
                Ok(id) => warmed_ids.push(id),
                Err(error) => {
                    if error.confirmed_bad() { st.condemn_sid(sid, error.reason()); }
                    anyhow::bail!("{}", error.reason());
                }
            }
        }
    }
    tracing::info!("warmed stream {sid} ({} extents, {:.2} GB)", extents.len(), total as f64 / 1e9);
    Ok(warmed_ids)
}

fn warm_targets(extents: &[Extent], starts: &[u64], media_off: u64, count: usize) -> Vec<(usize, usize)> {
    let Some(mut ei) = starts.iter().rposition(|&start| start <= media_off) else { return vec![] };
    let mut idx = ((extents[ei].data_start + media_off.saturating_sub(starts[ei]))
        / extents[ei].part_size.max(1)) as usize;
    // Include a little before the estimate for decoder keyframes and VBR drift.
    idx = idx.saturating_sub(2);
    let mut jobs = Vec::new();
    while ei < extents.len() && jobs.len() < count {
        let ext = &extents[ei];
        let last = ((ext.data_start + ext.data_len.saturating_sub(1)) / ext.part_size.max(1)) as usize;
        while idx < ext.segments.len() && idx <= last && jobs.len() < count {
            jobs.push((ei, idx));
            idx += 1;
        }
        ei += 1;
        if let Some(ext) = extents.get(ei) {
            idx = (ext.data_start / ext.part_size.max(1)) as usize;
        }
    }
    jobs
}

async fn prepare_recovery_inner(st: &StreamState, sid: &str, entry: &Arc<StreamEntry>) {
    let mut candidates = {
        let recovery = entry.recovery.lock().unwrap();
        let mut candidates = recovery.candidates.clone();
        if let Some(prepared) = &recovery.prepared {
            candidates.retain(|candidate| candidate != &prepared.sid);
            candidates.insert(0, prepared.sid.clone());
        }
        candidates
    };
    candidates.truncate(5);
    for candidate in candidates {
        let fraction = entry.recovery.lock().unwrap().desired_fraction;
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(180),
            warm_region(st, &candidate, Some(fraction)),
        ).await;
        match result {
            Ok(Ok(mut segments)) => {
                // Loading a large NZB can take long enough for playback to
                // move (or seek). Refresh the latest requested region before
                // declaring readiness, with the layout and STAT now cached.
                let latest = entry.recovery.lock().unwrap().desired_fraction;
                let mut fraction = fraction;
                if (latest - fraction).abs() >= 0.002 {
                    match tokio::time::timeout(std::time::Duration::from_secs(30), warm_region(st, &candidate, Some(latest))).await {
                        Ok(Ok(refreshed)) => { segments = refreshed; fraction = latest; }
                        _ => continue,
                    }
                }
                entry.recovery.lock().unwrap().prepared = Some(PreparedRecovery {
                    sid: candidate, fraction, segments, at: std::time::Instant::now(),
                });
                tracing::info!("stream {sid}: alternate prepared around {:.1}%", fraction * 100.0);
                return;
            }
            _ => tracing::debug!("stream {sid}: alternate {candidate} not ready; trying next"),
        }
    }
    entry.recovery.lock().unwrap().prepared = None;
}

#[derive(Deserialize)]
struct PrepareRequest {
    #[serde(default)]
    fraction: f64,
}

async fn prepare(State(st): State<StreamState>, Path(id): Path<String>, Json(req): Json<PrepareRequest>) -> Response {
    if !req.fraction.is_finite() || !(0.0..=1.0).contains(&req.fraction) {
        return (StatusCode::BAD_REQUEST, "fraction must be between 0 and 1").into_response();
    }
    if st.prepare_recovery(&id, req.fraction) {
        StatusCode::ACCEPTED.into_response()
    } else { StatusCode::NOT_FOUND.into_response() }
}

async fn health(State(st): State<StreamState>, Path(id): Path<String>) -> Response {
    match st.health(&id) {
        Some(health) => ([(header::CACHE_CONTROL, "no-store")], Json(health)).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

/// Router fragment for the range server.
pub fn router(state: StreamState) -> axum::Router {
    axum::Router::new()
        .route("/stream/:id", axum::routing::get(serve))
        .route("/stream/:id/prepare", axum::routing::post(prepare))
        .route("/stream/:id/health", axum::routing::get(health))
        .with_state(state)
}

async fn serve(
    State(st): State<StreamState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let Some(entry) = st.lookup(&id) else {
        return StreamError::UnknownStream.response();
    };

    // Ensure the segment map + sizes are loaded (parse NZB, learn part size once).
    // Owned args (not borrows) keep this future `Send` for the axum handler.
    if let Err(e) = ensure_loaded(st.clone(), entry.clone()).await {
        tracing::warn!("stream {id}: preparation failed ({})", StreamError::from_preparation(&e).code());
        return StreamError::from_preparation(&e).response();
    }

    // Read the cached load info into locals (brief lock, nothing held across await).
    let (total, extents, ext_media_start, complete) = {
        let guard = entry.loaded.lock().unwrap();
        let l = guard.as_ref().unwrap();
        (l.total_size, l.extents.clone(), l.ext_media_start.clone(), l.complete)
    };

    match complete {
        // Verified holes: refuse so the app fails over at a clean request
        // boundary — never let the parser hit a zero-filled gap mid-scene.
        Some(false) => {
            return StreamError::MissingArticles.response();
        }
        // Not verified yet: serve optimistically (never block byte 0) and let a
        // background verification land the verdict — subsequent range requests
        // honor it, so even a stream that started playing bails out cleanly
        // before the playhead reaches the hole.
        None => {
            let vst = st.clone();
            let vid = id.clone();
            tokio::spawn(async move {
                let _ = verify_stream(&vst, &vid).await;
            });
        }
        Some(true) => {}
    }

    // Parse a single Range: `bytes=start-end` (end optional).
    let (start, end) = match parse_range(&headers, total) {
        Some(r) => r,
        None => return StreamError::InvalidRange.response(),
    };

    let gen = StreamGen {
        pool: st.pool.clone(),
        extents,
        ext_media_start,
        media_pos: start,
        end: end + 1,
        ext_idx: 0,
        seg_idx: 0,
        positioned: false,
        inflight: std::collections::VecDeque::new(),
        cache: st.cache.clone(),
        state: st.clone(),
        sid: id.clone(),
    };
    let stream = futures::stream::unfold(gen, StreamGen::step);
    let body = Body::from_stream(stream);

    let mut resp = Response::builder().status(StatusCode::PARTIAL_CONTENT);
    let h = resp.headers_mut().unwrap();
    // Generic container type — players sniff the actual format from the bytes.
    h.insert(header::CONTENT_TYPE, "video/mp4".parse().unwrap());
    h.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());
    h.insert(header::CONTENT_LENGTH, (end - start + 1).to_string().parse().unwrap());
    h.insert(
        header::CONTENT_RANGE,
        format!("bytes {start}-{end}/{total}").parse().unwrap(),
    );
    resp.body(body).unwrap()
}

async fn ensure_loaded(st: StreamState, entry: Arc<StreamEntry>) -> anyhow::Result<()> {
    // Fast path: already loaded (brief lock, no await held).
    if entry.loaded.lock().unwrap().is_some() {
        return Ok(());
    }
    if entry.unsupported() { return Err(StreamError::UnsupportedArchive.into()); }
    // Single-flight: whoever holds the lock does the load; everyone else waits
    // and finds `loaded` populated on re-check.
    let _flight = entry.load_lock.lock().await;
    if entry.unsupported() { return Err(StreamError::UnsupportedArchive.into()); }
    if entry.loaded.lock().unwrap().is_some() {
        return Ok(());
    }
    // Download + parse the NZB. Per-request timeout override: a 100GB remux's
    // NZB is tens of MB and indexers serve it slowly — the client's default 60s
    // total-request timeout aborted exactly those, so the biggest releases were
    // the ones that could never load.
    let nzb_bytes = st
        .http
        .get(&entry.nzb_url)
        .timeout(std::time::Duration::from_secs(300))
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?;
    let parsed = crate::nzb::parse(&nzb_bytes)?;

    // Build the media as extents: a raw media file → one extent; otherwise try to
    // stream from inside a store-mode archive — RAR5 volumes (many extents) or a
    // single-file store-mode 7z (one extent). Anything else (compressed data,
    // LZMA-encoded 7z header, multi-volume 7z, nothing) errors → the app fails
    // over. 7z is <1% of releases and always co-listed with raw/rar, so we cover
    // only the cheap store-mode case and let the rest fail over fast.
    let (extents, total_size) = if let Some(file) = parsed.primary_file() {
        let group = file.groups.first().cloned().unwrap_or_default();
        let segments = file.segments.clone();
        let first = segments.first().ok_or_else(|| anyhow::anyhow!("no segments"))?;
        let (part_size, total) = match st.pool.fetch_checked(&group, &first.message_id).await {
            crate::pool::CheckedFetch::Found(raw) => {
                let dec = crate::yenc::decode(&raw)?;
                let part = dec.data.len() as u64;
                (part, dec.total_size.unwrap_or_else(|| part * segments.len() as u64))
            }
            crate::pool::CheckedFetch::Missing => return Err(StreamError::MissingArticles.into()),
                crate::pool::CheckedFetch::Unavailable => return Err(StreamError::UpstreamUnavailable.into()),
        };
        let extent = Extent {
            segments: Arc::new(segments),
            group,
            part_size,
            data_start: 0,
            data_len: total,
        };
        (vec![extent], total)
    } else {
        // Try store-mode RAR first, then a store-mode 7z. Both return quickly
        // when they don't apply (empty volume list / no .7z), so this adds no
        // cost to the common raw/rar path.
        let vols = archive::rar_volumes(&parsed.files);
        match archive::build_extents(&st.pool, &vols).await {
            Ok(res) => res,
            Err(rar_err) => match crate::sevenzip::build_extents(&st.pool, &parsed.files).await {
                Ok(res) => res,
                Err(sz_err) => {
                    tracing::warn!("stream {}: archive layout unavailable (rar: {rar_err}; 7z: {sz_err})", fnv_hex(entry.nzb_url.as_bytes()));
                    let error = crate::stream_errors::archive_failure(&rar_err, &sz_err, vols.is_empty());
                    if error == StreamError::UnsupportedArchive { *entry.unsupported_at.lock().unwrap() = Some(std::time::Instant::now()); }
                    return Err(error.into());
                }
            },
        }
    };

    // Prefix sums: media offset where each extent begins.
    let mut ext_media_start = Vec::with_capacity(extents.len());
    let mut acc = 0u64;
    for e in &extents {
        ext_media_start.push(acc);
        acc += e.data_len;
    }

    // NO full pre-play STAT here: verifying every segment before byte 0 blocked
    // the HTTP response past the player's read timeout. Verification instead
    // runs ASYNC (verify_stream) — during warms and right after a first serve —
    // and lands its verdict in `complete` for every later request to honor.

    // Store (a concurrent first-request may have loaded it meanwhile — first wins).
    let mut guard = entry.loaded.lock().unwrap();
    if guard.is_none() {
        *guard = Some(Loaded {
            extents: Arc::new(extents),
            ext_media_start: Arc::new(ext_media_start),
            total_size,
            complete: None,
        });
    }
    Ok(())
}

/// How many segments to keep in flight ahead of the emit position. At ~700KB
/// decoded per segment this is ~22MB of pipeline: throughput ≈ window / RTT, so
/// with ~1s effective per-segment RTT this sustains ~20MB/s — comfortable
/// headroom over a TrueHD DoVi remux's 12-15MB/s peaks (serial fetching capped a
/// stream at ~1MB/s; 16 segments measured 10-12MB/s, too tight for remux peaks).
/// Still a modest slice of the 170-connection budget, so several viewers coexist.
const LOOKAHEAD: usize = 32;

/// The streaming generator: walks the media file's extents (one for a raw post,
/// several for a RAR release), and within each extent fetches segments on demand.
/// It locates the exact segment for the current media position via each segment's
/// real =ypart offset, so both seeks and volume boundaries are byte-accurate.
///
/// After positioning, upcoming segments are fetched through a spawned LOOKAHEAD
/// pipeline (`inflight` always holds segments `[seg_idx, seg_idx+len)` of the
/// current extent, in order), so the server buffers AHEAD of the playhead and one
/// slow article no longer stalls the stream.
struct StreamGen {
    pool: Arc<Pool>,
    extents: Arc<Vec<Extent>>,
    ext_media_start: Arc<Vec<u64>>,
    /// Absolute media offset to emit next.
    media_pos: u64,
    /// Exclusive media offset to stop at.
    end: u64,
    ext_idx: usize,
    seg_idx: usize,
    /// Located the exact starting segment within the current extent.
    positioned: bool,
    /// Spawned fetches for segments `seg_idx..seg_idx+len` of the current extent.
    inflight: std::collections::VecDeque<tokio::task::JoinHandle<Result<(Vec<u8>, u64), FetchFailure>>>,
    /// Warm cache — consulted before NNTP so pre-warmed titles start instantly.
    cache: Arc<SegCache>,
    /// For condemning the release when a hole is discovered mid-stream.
    state: StreamState,
    sid: String,
}

/// Fetch one segment for STREAMING: warm cache, then all providers. Returns
/// An error when the article is missing everywhere — ABORT the
/// transfer instead of zero-filling (a 700KB run of zeros just crashes the
/// video parser mid-scene, which is worse than a clean cut the app can fail
/// over from). Corrupt articles also abort rather than injecting fake media.
#[derive(Debug)]
enum FetchFailure { Missing, Unavailable, Corrupt }

impl FetchFailure {
    fn confirmed_bad(&self) -> bool { !matches!(self, Self::Unavailable) }
    fn reason(&self) -> &'static str {
        match self {
            Self::Missing => "article missing on all providers",
            Self::Unavailable => "article temporarily unavailable",
            Self::Corrupt => "article could not be decoded",
        }
    }
}

async fn fetch_streaming(
    pool: &Arc<Pool>,
    cache: &Arc<SegCache>,
    group: &str,
    seg: &crate::nzb::Segment,
    part_size: u64,
    idx: usize,
) -> Result<(Vec<u8>, u64), FetchFailure> {
    if let Some((data, start)) = cache.get(&seg.message_id) {
        return Ok((data.as_ref().clone(), start));
    }
    match pool.fetch_checked(group, &seg.message_id).await {
        crate::pool::CheckedFetch::Found(raw) => match crate::yenc::decode(&raw) {
            Ok(d) if !d.data.is_empty() => {
                let start = d.part_begin.and_then(|b| b.checked_sub(1)).unwrap_or(idx as u64 * part_size);
                Ok((d.data, start))
            }
            _ => Err(FetchFailure::Corrupt),
        },
        crate::pool::CheckedFetch::Missing => Err(FetchFailure::Missing),
        crate::pool::CheckedFetch::Unavailable => Err(FetchFailure::Unavailable),
    }
}

impl Drop for StreamGen {
    fn drop(&mut self) {
        // Client gone (or extent change discarded the queue) — stop the fetches
        // instead of letting detached tasks keep pulling segments nobody wants.
        for h in &self.inflight {
            h.abort();
        }
    }
}

impl StreamGen {
    fn abort_inflight(&mut self) {
        for h in &self.inflight {
            h.abort();
        }
        self.inflight.clear();
    }

    /// Keep LOOKAHEAD segment fetches in flight, never past the last segment the
    /// requested range can touch (one slack segment for =ypart drift).
    fn top_up(&mut self, ext: &Extent, ext_start: u64, ext_end: u64) {
        let last_vol_off = ext.data_start + (self.end.min(ext_end) - ext_start).saturating_sub(1);
        let last_needed = ((last_vol_off / ext.part_size.max(1)) as usize + 1)
            .min(ext.segments.len().saturating_sub(1));
        while self.inflight.len() < LOOKAHEAD {
            let idx = self.seg_idx + self.inflight.len();
            if idx > last_needed {
                break;
            }
            let pool = self.pool.clone();
            let cache = self.cache.clone();
            let group = ext.group.clone();
            let seg = ext.segments[idx].clone();
            let part_size = ext.part_size;
            let state = self.state.clone();
            let sid = self.sid.clone();
            self.inflight.push_back(tokio::spawn(async move {
                let result = fetch_streaming(&pool, &cache, &group, &seg, part_size, idx).await;
                // Report as soon as a look-ahead task discovers a hole, before
                // ordered emission (and hence the viewer) reaches that article.
                if let Err(error) = &result {
                    if error.confirmed_bad() { state.condemn_sid(&sid, error.reason()); }
                }
                result
            }));
        }
    }

    fn invalid_position(mut self) -> Option<(Result<Bytes, std::io::Error>, StreamGen)> {
        tracing::warn!(
            "stream {}: article offsets do not cover media {}, aborting transfer",
            self.sid, self.media_pos,
        );
        self.abort_inflight();
        self.media_pos = self.end;
        Some((
            Err(std::io::Error::other("article offsets do not cover requested range")),
            self,
        ))
    }

    async fn step(mut self) -> Option<(Result<Bytes, std::io::Error>, StreamGen)> {
        // The initial part-size guess is only an estimate. Preserve a shrinking
        // search interval across retries; resetting the guess here used to loop
        // forever whenever real yEnc article lengths differed from that estimate.
        let mut search: Option<(usize, usize)> = None;
        loop {
            if self.media_pos >= self.end {
                self.abort_inflight();
                return None;
            }
            let Some(ext) = self.extents.get(self.ext_idx).cloned() else {
                return self.invalid_position();
            };
            let Some(&ext_start) = self.ext_media_start.get(self.ext_idx) else {
                return self.invalid_position();
            };
            let Some(ext_end) = ext_start.checked_add(ext.data_len) else {
                return self.invalid_position();
            };
            if ext.data_start.checked_add(ext.data_len).is_none() || self.media_pos < ext_start {
                return self.invalid_position();
            }
            if self.media_pos >= ext_end {
                // Extent boundary: queued fetches belong to the old extent.
                self.abort_inflight();
                self.ext_idx += 1;
                self.seg_idx = 0;
                self.positioned = false;
                search = None;
                continue;
            }

            // Volume-relative offset for the current media position.
            let vol_off = ext.data_start + (self.media_pos - ext_start);
            if !self.positioned && search.is_none() {
                search = Some((0, ext.segments.len()));
                self.seg_idx = (vol_off / ext.part_size.max(1))
                    .min(ext.segments.len().saturating_sub(1) as u64) as usize;
            }
            if self.seg_idx >= ext.segments.len() {
                // An extent may end only at its declared byte boundary. Running
                // out of articles earlier must not silently truncate a 206 body.
                return self.invalid_position();
            }

            let fetched = if self.positioned {
                // Pipelined path: front of the queue IS segment seg_idx.
                self.top_up(&ext, ext_start, ext_end);
                match self.inflight.pop_front() {
                    Some(handle) => match handle.await {
                        Ok(res) => res,
                        // Join failure (shouldn't happen) — fall back to a direct fetch.
                        Err(_) => {
                            fetch_streaming(&self.pool, &self.cache, &ext.group, &ext.segments[self.seg_idx], ext.part_size, self.seg_idx).await
                        }
                    },
                    None => {
                        fetch_streaming(&self.pool, &self.cache, &ext.group, &ext.segments[self.seg_idx], ext.part_size, self.seg_idx).await
                    }
                }
            } else {
                // Positioning: serial adaptive fetch until the exact segment for
                // media_pos is found (=ypart is ground truth, estimates can drift).
                fetch_streaming(&self.pool, &self.cache, &ext.group, &ext.segments[self.seg_idx], ext.part_size, self.seg_idx).await
            };
            let (decoded, seg_start) = match fetched {
                Ok(value) => value,
                Err(error) => {
                // Article missing on every provider: condemn the release and cut
                // the transfer cleanly. The app fails over at once (and this
                // release stops being offered), instead of the video parser
                // exploding on zero-filled garbage somewhere mid-scene.
                tracing::warn!(
                    "stream {}: {} at media {}, aborting transfer",
                    self.sid, error.reason(), self.media_pos,
                );
                if error.confirmed_bad() { self.state.condemn_sid(&self.sid, error.reason()); }
                self.abort_inflight();
                self.media_pos = self.end; // next step() ends the stream
                return Some((
                    Err(std::io::Error::other(error.reason())),
                    self,
                ));
                }
            };
            let Some(seg_end) = seg_start.checked_add(decoded.len() as u64) else {
                return self.invalid_position();
            };
            if decoded.is_empty() {
                return self.invalid_position();
            }

            if !self.positioned {
                let (lo, hi) = search.as_mut().expect("positioning search initialized");
                if vol_off < seg_start {
                    *hi = self.seg_idx;
                } else if vol_off >= seg_end {
                    *lo = self.seg_idx + 1;
                } else {
                    self.positioned = true;
                }
                if !self.positioned {
                    if *lo >= *hi {
                        // No article covers the requested offset: fail rather
                        // than oscillate across a hole or emit neighboring data.
                        return self.invalid_position();
                    }
                    self.seg_idx = *lo + (*hi - *lo) / 2;
                    continue;
                }
            } else if vol_off < seg_start {
                return self.invalid_position();
            } else if vol_off >= seg_end {
                // A duplicate/overlapping part can already be fully consumed.
                // Advancing is finite and preserves the queued segment order.
                self.seg_idx += 1;
                continue;
            }

            // Only emit after proving that the requested byte is in this part.
            let from = (vol_off - seg_start) as usize;
            // Cap the chunk at: end of segment, end of this extent, and the range end.
            let seg_avail = (seg_end - vol_off).min(ext_end - self.media_pos).min(self.end - self.media_pos);
            let take = (seg_avail as usize).min(decoded.len() - from);
            if take == 0 {
                return self.invalid_position();
            }
            let chunk = Bytes::copy_from_slice(&decoded[from..from + take]);
            self.media_pos += take as u64;
            self.seg_idx += 1;
            return Some((Ok(chunk), self));
        }
    }
}


/// Parse `Range: bytes=start-end`. Returns clamped (start, end) inclusive, or a
/// full-file range when there's no Range header.
fn parse_range(headers: &HeaderMap, total: u64) -> Option<(u64, u64)> {
    let Some(raw) = headers.get(header::RANGE).and_then(|v| v.to_str().ok()) else {
        return Some((0, total.saturating_sub(1)));
    };
    let spec = raw.strip_prefix("bytes=")?;
    let (s, e) = spec.split_once('-')?;
    let start: u64 = if s.is_empty() { 0 } else { s.parse().ok()? };
    let end: u64 = if e.is_empty() { total.saturating_sub(1) } else { e.parse().ok()? };
    if start > end || start >= total {
        return None;
    }
    Some((start, end.min(total.saturating_sub(1))))
}

pub fn valid_stream_id(id: &str) -> bool {
    id.len() == 16 && id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

/// FNV-1a → hex, for stable stream ids without a hashing dependency.
fn fnv_hex(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_state() -> StreamState {
        let db = crate::db::open(":memory:").unwrap();
        crate::sync::migrate(&db.lock().unwrap()).unwrap();
        StreamState::new(Pool::new(&[]), reqwest::Client::new(), db)
    }

    #[tokio::test]
    async fn registration_survives_restart_without_source_resolution_or_probe() {
        let first = test_state();
        let source = "https://unreachable.invalid/private-exact-release.nzb?key=fixture";
        let sid = first.register(source).await;
        let db = first.db.clone();
        drop(first);
        let restored = StreamState::new(Pool::new(&[]), reqwest::Client::new(), db);
        assert!(restored.is_registered(&sid));
        let entry = restored.lookup(&sid).unwrap();
        assert_eq!(entry.nzb_url, source);
        assert!(entry.loaded.lock().unwrap().is_none());
        assert!(entry.verification_attempt.lock().unwrap().is_none());
        assert!(entry.recovery.lock().unwrap().candidates.is_empty());
        // A different source, even with a similar display identity, is never
        // substituted for an unavailable id.
        let other = restored.register("https://unreachable.invalid/other-release.nzb").await;
        assert_ne!(sid, other);
        assert_eq!(restored.lookup(&sid).unwrap().nzb_url, source);
        assert!(!restored.is_registered("0000000000000000"));
    }

    #[test]
    fn corrupted_registration_and_noncanonical_ids_are_rejected() {
        let st = test_state();
        st.db.lock().unwrap().execute(
            "INSERT INTO stream_registrations VALUES (?1, ?2, 1)",
            rusqlite::params!["0123456789abcdef", "https://fixture.invalid/wrong.nzb"],
        ).unwrap();
        assert!(!st.is_registered("0123456789abcdef"));
        for sid in ["", "0123456789ABCDEF", "0123456789abcdeg", "../0123456789abc", "0123456789abcdef?token=x"] {
            assert!(!valid_stream_id(sid));
            assert!(!st.is_registered(sid));
        }
    }

    fn extent(prefix: &str, count: usize) -> Extent {
        Extent {
            segments: Arc::new((0..count).map(|idx| crate::nzb::Segment {
                number: idx as u32 + 1, bytes: 100, message_id: format!("{prefix}-{idx}"),
            }).collect()),
            group: "".into(), part_size: 100, data_start: 0, data_len: count as u64 * 100,
        }
    }

    async fn loaded_stream(st: &StreamState, name: &str, complete: Option<bool>) -> String {
        let sid = st.register(name).await;
        let entry = st.streams.lock().unwrap().get(&sid).cloned().unwrap();
        *entry.loaded.lock().unwrap() = Some(Loaded {
            extents: Arc::new(vec![extent(name, 5)]), ext_media_start: Arc::new(vec![0]),
            total_size: 500, complete,
        });
        sid
    }

    #[test]
    fn warm_window_continues_across_volume_boundaries() {
        let volumes = vec![extent("first", 5), extent("second", 5)];
        let jobs = warm_targets(&volumes, &[0, 500], 400, 6);
        assert_eq!(jobs, vec![(0, 2), (0, 3), (0, 4), (1, 0), (1, 1), (1, 2)]);
    }

    #[tokio::test]
    async fn recovery_readiness_requires_verified_source_and_live_cached_bytes() {
        let mut st = test_state();
        st.cache = SegCache::new(600);
        let current = loaded_stream(&st, "current", Some(false)).await;
        let backup = loaded_stream(&st, "backup", Some(true)).await;
        st.set_recovery_candidates(&[current.clone(), backup.clone()]);
        for idx in 0..5 { st.cache.put(&format!("backup-{idx}"), vec![1; 100], idx * 100); }
        let entry = st.streams.lock().unwrap().get(&current).cloned().unwrap();
        entry.recovery.lock().unwrap().desired_fraction = 0.5;
        prepare_recovery_inner(&st, &current, &entry).await;
        let health = st.health(&current).unwrap();
        assert_eq!(health.status, "incomplete");
        assert_eq!(health.recovery.status, "ready");
        assert_eq!(health.recovery.stream_id.as_deref(), Some(backup.as_str()));
        assert_eq!(health.recovery.prepared_fraction, Some(0.5));
        st.cache.put("evict", vec![2; 600], 0);
        assert_ne!(st.health(&current).unwrap().recovery.status, "ready");
    }

    #[tokio::test]
    async fn verification_outage_stays_unverified_and_does_not_poison_ledger() {
        let st = test_state();
        let sid = loaded_stream(&st, "offline", None).await;
        assert!(verify_stream(&st, &sid).await.is_err());
        assert_eq!(st.health(&sid).unwrap().status, "unverified");
        assert!(!st.is_condemned("offline"));
    }

    #[tokio::test]
    async fn prepare_rejects_invalid_fraction_and_unknown_stream() {
        let st = test_state();
        let invalid = prepare(State(st.clone()), Path("missing".into()), Json(PrepareRequest { fraction: 1.5 })).await;
        assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
        let missing = prepare(State(st), Path("missing".into()), Json(PrepareRequest { fraction: 0.5 })).await;
        assert_eq!(missing.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn startup_head_probe_does_not_queue_alternate_preparation() {
        let st = test_state();
        let current = loaded_stream(&st, "probe", Some(true)).await;
        let backup = loaded_stream(&st, "backup", Some(true)).await;
        st.set_recovery_candidates(&[current.clone(), backup]);
        let mut headers = HeaderMap::new();
        headers.insert(header::RANGE, "bytes=0-255".parse().unwrap());
        let response = serve(State(st.clone()), Path(current.clone()), headers).await;
        assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(st.health(&current).unwrap().recovery.status, "idle");
    }

    #[tokio::test]
    async fn corrupt_article_is_not_cached_as_zero_filled_media() {
        let (provider, server) = crate::pool::tests::fake_provider(223).await;
        let mut st = test_state();
        st.pool = Pool::new(&[provider]);
        let sid = loaded_stream(&st, "corrupt", Some(true)).await;
        assert!(warm_region(&st, &sid, Some(0.5)).await.is_err());
        assert!(st.cache.get("corrupt-0").is_none());
        assert_eq!(st.health(&sid).unwrap().status, "incomplete");
        server.abort();
    }

    #[tokio::test]
    async fn lookahead_reports_hole_before_waiting_for_ordered_emission() {
        let (provider, server) = crate::pool::tests::fake_provider(430).await;
        let mut st = test_state();
        st.pool = Pool::new(&[provider]);
        let sid = loaded_stream(&st, "lookahead", Some(true)).await;
        let ext = extent("lookahead", 5);
        let mut gen = StreamGen {
            pool: st.pool.clone(), extents: Arc::new(vec![ext.clone()]),
            ext_media_start: Arc::new(vec![0]), media_pos: 0, end: 500,
            ext_idx: 0, seg_idx: 0, positioned: true,
            inflight: std::collections::VecDeque::new(), cache: st.cache.clone(),
            state: st.clone(), sid: sid.clone(),
        };
        gen.top_up(&ext, 0, 500);
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while st.health(&sid).unwrap().status != "incomplete" { tokio::task::yield_now().await; }
        }).await.unwrap();
        assert_eq!(gen.media_pos, 0, "look-ahead must report before emission reaches the hole");
        assert!(st.is_condemned("lookahead"));
        server.abort();
    }

    #[test]
    fn range_parsing() {
        let mut h = HeaderMap::new();
        assert_eq!(parse_range(&h, 1000), Some((0, 999)));
        h.insert(header::RANGE, "bytes=100-199".parse().unwrap());
        assert_eq!(parse_range(&h, 1000), Some((100, 199)));
        h.insert(header::RANGE, "bytes=500-".parse().unwrap());
        assert_eq!(parse_range(&h, 1000), Some((500, 999)));
        h.insert(header::RANGE, "bytes=2000-3000".parse().unwrap());
        assert_eq!(parse_range(&h, 1000), None); // past EOF
    }

    #[test]
    fn fnv_is_stable() {
        assert_eq!(fnv_hex(b"https://x/a.nzb"), fnv_hex(b"https://x/a.nzb"));
        assert_ne!(fnv_hex(b"a"), fnv_hex(b"b"));
    }
}

#[cfg(test)]
#[path = "stream_error_tests.rs"]
mod stream_error_tests;

#[cfg(test)]
#[path = "stream_position_tests.rs"]
mod stream_position_tests;
