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
use axum::Json;
use bytes::Bytes;
use serde::{Deserialize, Serialize};

use crate::archive::{self, Extent};
use crate::pool::Pool;
use crate::stream_errors::StreamError;
use crate::recovery_metrics::{valid_session, Recorder, RecoveryEvent};

// std::sync::Mutex throughout: the guards are only ever held for brief synchronous
// sections (never across an `.await`), which keeps the async handlers `Send` and
// avoids tokio-mutex's higher-ranked-lifetime friction with axum.

/// Packet-indexed ahead buffer. Limits apply to one probe, independently of the
/// repair engine's disk/job limits. Seconds are reported only from actual packet
/// timestamps whose bytes are still resident in the verified segment cache.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct BufferConfig {
    pub enabled: bool,
    pub lookahead_seconds: u64,
    pub max_probe_bytes: u64,
    pub max_probe_seconds: u64,
    pub max_memory_bytes: usize,
    pub heartbeat_timeout_seconds: u64,
    pub ffprobe_binary: String,
}
impl Default for BufferConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            lookahead_seconds: 90,
            max_probe_bytes: 256 * 1024 * 1024,
            max_probe_seconds: 40,
            max_memory_bytes: 256 * 1024 * 1024,
            heartbeat_timeout_seconds: 15,
            ffprobe_binary: "ffprobe".into(),
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaybackRequest {
    session_id: String,
    generation: u64,
    position_ms: u64,
    #[serde(default)]
    duration_ms: u64,
    #[serde(default)]
    buffered_position_ms: u64,
    #[serde(default)]
    playing: bool,
    #[serde(default)]
    stopped: bool,
}
struct PlaybackPoint {
    request: PlaybackRequest,
    at: std::time::Instant,
}
#[derive(Default)]
struct VerifiedBuffer {
    sessions: HashMap<String, PlaybackPoint>,
    current_session: String,
    generation: u64,
    revision: u64,
    task: Option<tokio::task::JoinHandle<()>>,
    probe_token: String,
    probe_budget: Option<Arc<std::sync::atomic::AtomicU64>>,
    index_status: &'static str,
    verified: Option<VerifiedWindow>,
    updated: Option<std::time::Instant>,
    last_attempt: Option<std::time::Instant>,
}
struct VerifiedWindow {
    from: f64,
    through: f64,
    segments: Vec<String>,
    repaired_files: Vec<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExactRecoveryHealth {
    enabled: bool,
    status: &'static str,
    verified_ahead_seconds: Option<f64>,
    index_status: &'static str,
    hold_fallback: bool,
    lookahead_target_seconds: u64,
    updated_ago_seconds: Option<f64>,
}
impl StreamState {
    fn buffer_health(&self, entry: &StreamEntry) -> ExactRecoveryHealth {
        self.buffer_health_for(entry, None, &std::collections::HashSet::new())
    }
    fn buffer_health_for(
        &self,
        entry: &StreamEntry,
        session: Option<&str>,
        verified_files: &std::collections::HashSet<String>,
    ) -> ExactRecoveryHealth {
        let buffer = entry.buffer.lock().unwrap();
        let active = buffer.sessions.get(&buffer.current_session).filter(|p| {
            p.at.elapsed().as_secs() <= self.buffer_config.heartbeat_timeout_seconds
                && !p.request.stopped
                && session.is_none_or(|id| id == p.request.session_id)
        });
        let position = active.map(|p| p.request.position_ms as f64 / 1000.0);
        let seconds = buffer.verified.as_ref().and_then(|window| {
            let position = position?;
            if position + 0.002 < window.from || position > window.through {
                return None;
            }
            if !window
                .segments
                .iter()
                .all(|id| self.cache.get(id).is_some())
                || !window
                    .repaired_files
                    .iter()
                    .all(|id| verified_files.contains(id))
            {
                return None;
            }
            Some((window.through - position).max(0.0))
        });
        ExactRecoveryHealth {
            enabled: self.repair_enabled,
            status: if !self.repair_enabled {
                "disabled"
            } else if seconds.is_some() {
                "verified"
            } else if buffer.task.as_ref().is_some_and(|t| !t.is_finished()) {
                "checking"
            } else {
                "idle"
            },
            verified_ahead_seconds: seconds,
            index_status: if buffer.index_status.is_empty() {
                "idle"
            } else {
                buffer.index_status
            },
            // Readers wait for exact repair on the original resource. A real
            // read failure remains actionable; no indefinite client failover hold.
            hold_fallback: false,
            lookahead_target_seconds: self.buffer_config.lookahead_seconds,
            updated_ago_seconds: buffer.updated.map(|at| at.elapsed().as_secs_f64()),
        }
    }

    async fn playback_update(&self, sid: &str, request: PlaybackRequest) -> Result<(), StatusCode> {
        if request.session_id.is_empty()
            || request.session_id.len() > 80
            || !request
                .session_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
            || request.position_ms > 7 * 86400 * 1000
            || request.duration_ms > 7 * 86400 * 1000
            || request.buffered_position_ms > 7 * 86400 * 1000
        {
            return Err(StatusCode::BAD_REQUEST);
        }
        let entry = self.lookup(sid).ok_or(StatusCode::NOT_FOUND)?;
        if !self.repair_enabled || !self.buffer_config.enabled {
            return Ok(());
        }
        if !request.stopped {
            self.record_session(sid, &request.session_id);
        }
        let _lifecycle = entry.playback_lock.lock().await;
        if !request.stopped {
            let manifest = entry.manifest.lock().unwrap().clone();
            if let Some(manifest) = manifest {
                let _ = self.repair.register(sid, manifest).await;
            }
        }
        let mut cancel = false;
        let spawn = {
            let mut buffer = entry.buffer.lock().unwrap();
            let now = std::time::Instant::now();
            buffer.sessions.retain(|_, p| {
                p.at.elapsed().as_secs() <= self.buffer_config.heartbeat_timeout_seconds * 4
            });
            if buffer
                .sessions
                .get(&request.session_id)
                .is_some_and(|p| p.request.generation > request.generation)
            {
                return Ok(()); // Late stop/heartbeat from the old seek must not cancel a new one.
            }
            if buffer.sessions.len() >= 8 && !buffer.sessions.contains_key(&request.session_id) {
                return Err(StatusCode::TOO_MANY_REQUESTS);
            }
            let changed = buffer.current_session != request.session_id
                || buffer.generation != request.generation;
            buffer.sessions.insert(
                request.session_id.clone(),
                PlaybackPoint {
                    request: request.clone(),
                    at: now,
                },
            );
            if request.stopped {
                if buffer.current_session == request.session_id {
                    if let Some(task) = buffer.task.take() {
                        task.abort();
                    }
                    buffer.probe_budget = None;
                    buffer.probe_token.clear();
                    buffer.verified = None;
                    buffer.index_status = "stopped";
                    buffer.revision += 1;
                }
                cancel = !buffer.sessions.values().any(|p| {
                    !p.request.stopped
                        && p.at.elapsed().as_secs() <= self.buffer_config.heartbeat_timeout_seconds
                });
                None
            } else if buffer.current_session != request.session_id
                && buffer.task.as_ref().is_some_and(|task| !task.is_finished())
            {
                // Another viewer of the exact same source must not repeatedly
                // cancel a bounded probe that is already making progress.
                None
            } else {
                if changed {
                    if let Some(task) = buffer.task.take() {
                        task.abort();
                    }
                    buffer.verified = None;
                    buffer.current_session = request.session_id.clone();
                    buffer.generation = request.generation;
                    buffer.last_attempt = None;
                    buffer.revision += 1;
                }
                let running = buffer.task.as_ref().is_some_and(|t| !t.is_finished());
                let throttled = buffer.last_attempt.is_some_and(|at| {
                    at.elapsed().as_secs() < if request.playing { 8 } else { 30 }
                });
                let sufficient = buffer.verified.as_ref().is_some_and(|window| {
                    window.from <= request.position_ms as f64 / 1000.0 + 0.002
                        && window.through
                            > request.position_ms as f64 / 1000.0
                                + self.buffer_config.lookahead_seconds as f64 * 0.7
                        && window
                            .segments
                            .iter()
                            .all(|id| self.cache.get(id).is_some())
                });
                if running || throttled || sufficient {
                    None
                } else {
                    buffer.last_attempt = Some(now);
                    buffer.index_status = "indexing";
                    buffer.revision += 1;
                    Some(buffer.revision)
                }
            }
        };
        if cancel {
            self.repair.cancel(sid).await;
        }
        if let Some(revision) = spawn {
            let state = self.clone();
            let sid = sid.to_owned();
            let task_entry = entry.clone();
            let task = tokio::spawn(async move {
                state.index_ahead(&sid, task_entry, request, revision).await;
            });
            entry.buffer.lock().unwrap().task = Some(task);
        }
        Ok(())
    }

    async fn index_ahead(
        &self,
        sid: &str,
        entry: Arc<StreamEntry>,
        point: PlaybackRequest,
        revision: u64,
    ) {
        let timeout =
            std::time::Duration::from_secs(self.buffer_config.max_probe_seconds.clamp(1, 120));
        let result = tokio::time::timeout(
            timeout,
            self.index_ahead_inner(sid, &entry, &point, revision),
        )
        .await;
        let expired = matches!(&result, Ok(Err(reason)) if *reason == "heartbeat-expired");
        {
            let mut buffer = entry.buffer.lock().unwrap();
            if buffer.revision != revision {
                return;
            }
            buffer.probe_budget = None;
            buffer.probe_token.clear();
            buffer.updated = Some(std::time::Instant::now());
            match result {
                Ok(Ok(window)) => {
                    buffer.verified = Some(window);
                    buffer.index_status = "packet-indexed";
                }
                Ok(Err(reason)) => {
                    buffer.verified = None;
                    buffer.index_status = reason;
                }
                Err(_) => {
                    buffer.verified = None;
                    buffer.index_status = "probe-timeout";
                }
            }
        }
        if expired {
            // Serialize the last-viewer cleanup with a new session arriving, so
            // an old heartbeat expiry cannot remove newly registered repair data.
            let _lifecycle = entry.playback_lock.lock().await;
            let active = entry.buffer.lock().unwrap().sessions.values().any(|p| {
                !p.request.stopped
                    && p.at.elapsed().as_secs() <= self.buffer_config.heartbeat_timeout_seconds
            });
            if !active {
                self.repair.cancel(sid).await;
            }
        }
    }

    async fn index_ahead_inner(
        &self,
        sid: &str,
        entry: &Arc<StreamEntry>,
        point: &PlaybackRequest,
        revision: u64,
    ) -> Result<VerifiedWindow, &'static str> {
        use tokio::io::AsyncReadExt;
        let _slot = self
            .buffer_slots
            .acquire()
            .await
            .map_err(|_| "unavailable")?;
        let mut random = [0u8; 16];
        getrandom::getrandom(&mut random).map_err(|_| "unavailable")?;
        let token = random
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        {
            let mut buffer = entry.buffer.lock().unwrap();
            if buffer.revision != revision {
                return Err("cancelled");
            }
            buffer.probe_token = token.clone();
            buffer.probe_budget = Some(Arc::new(std::sync::atomic::AtomicU64::new(
                self.buffer_config.max_probe_bytes.min(1024 * 1024 * 1024),
            )));
        }
        let start = point.position_ms as f64 / 1000.0;
        let end = if point.duration_ms > point.position_ms {
            (start + self.buffer_config.lookahead_seconds.clamp(5, 300) as f64)
                .min(point.duration_ms as f64 / 1000.0)
        } else {
            start + self.buffer_config.lookahead_seconds.clamp(5, 300) as f64
        };
        let mut command = tokio::process::Command::new(&self.buffer_config.ffprobe_binary);
        command.args([
            "-v",
            "error",
            "-threads",
            "1",
            "-max_alloc",
            "16777216",
            "-protocol_whitelist",
            "http,tcp",
            "-format_whitelist",
            "matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,avi,mpegts,mpeg",
            "-rw_timeout",
            "15000000",
            "-headers",
            &format!("X-Velvet-Probe: {token}\r\n"),
            "-read_intervals",
            &format!("{start:.3}%{end:.3}"),
            "-show_packets",
            "-show_streams",
            "-show_entries",
            "packet=stream_index,pos,size,pts_time,dts_time,duration_time:stream=index,codec_type",
            "-of",
            "json",
            &format!("{}/stream/{sid}", self.local_origin),
        ]);
        command
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        let mut child = command.spawn().map_err(|_| "ffprobe-unavailable")?;
        let stdout = child.stdout.take().ok_or("ffprobe-unavailable")?;
        let read = async move {
            let mut bytes = Vec::new();
            stdout
                .take(16 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)
                .await
                .map_err(|_| "probe-failed")?;
            if bytes.len() > 16 * 1024 * 1024 {
                return Err("index-limit");
            }
            Ok(bytes)
        };
        let stale = async {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                let current = entry.buffer.lock().unwrap();
                if current.revision != revision
                    || current.sessions.get(&point.session_id).is_none_or(|p| {
                        p.at.elapsed().as_secs() > self.buffer_config.heartbeat_timeout_seconds
                    })
                {
                    return;
                }
            }
        };
        let bytes = tokio::select! {
            result = read => result?,
            _ = stale => { let _ = child.kill().await; return Err("heartbeat-expired"); }
        };
        if !child.wait().await.map_err(|_| "probe-failed")?.success() {
            return Err("unsupported-or-unavailable");
        }
        let value: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|_| "invalid-index")?;
        let file_ids = {
            let loaded = entry.loaded.lock().unwrap();
            loaded
                .as_ref()
                .map(|loaded| {
                    loaded
                        .extents
                        .iter()
                        .filter_map(|ext| {
                            ext.segments
                                .first()
                                .map(|segment| segment.message_id.clone())
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        };
        let mut verified_files = std::collections::HashSet::new();
        for id in file_ids {
            if self.repair.verified_file(sid, &id).await {
                verified_files.insert(id);
            }
        }
        self.verified_packet_window(entry, &value, start, end, &verified_files)
    }

    fn verified_packet_window(
        &self,
        entry: &StreamEntry,
        value: &serde_json::Value,
        start: f64,
        end: f64,
        verified_files: &std::collections::HashSet<String>,
    ) -> Result<VerifiedWindow, &'static str> {
        let loaded = entry.loaded.lock().unwrap();
        let loaded = loaded.as_ref().ok_or("not-loaded")?;
        let streams = value["streams"].as_array().ok_or("no-index")?;
        let mut tracks: HashMap<u64, Vec<(f64, f64)>> = streams
            .iter()
            .filter(|v| matches!(v["codec_type"].as_str(), Some("audio" | "video")))
            .filter_map(|v| v["index"].as_u64().map(|i| (i, Vec::new())))
            .collect();
        if tracks.is_empty() {
            return Err("no-media-tracks");
        }
        let mut spans = Vec::new();
        {
            let cache = self.cache.inner.lock().unwrap();
            for (ei, ext) in loaded.extents.iter().enumerate() {
                if let Some(id) = ext
                    .segments
                    .first()
                    .map(|segment| &segment.message_id)
                    .filter(|id| verified_files.contains(*id))
                {
                    // A PAR2-verified immutable original file proves every byte
                    // of this extent, including consecutive missing articles
                    // whose individual yEnc boundaries cannot be guessed.
                    spans.push((
                        loaded.ext_media_start[ei],
                        loaded.ext_media_start[ei] + ext.data_len,
                        id.clone(),
                        true,
                    ));
                    continue;
                }
                for segment in ext.segments.iter() {
                    if let Some((data, from)) = cache.map.get(&segment.message_id) {
                        let begin = (*from).max(ext.data_start);
                        let finish = (*from + data.len() as u64).min(ext.data_start + ext.data_len);
                        if begin < finish {
                            spans.push((
                                loaded.ext_media_start[ei] + begin - ext.data_start,
                                loaded.ext_media_start[ei] + finish - ext.data_start,
                                segment.message_id.clone(),
                                false,
                            ));
                        }
                    }
                }
            }
        }
        spans.sort_by_key(|span| span.0);
        let mut ids = std::collections::HashSet::new();
        let mut repaired_files = std::collections::HashSet::new();
        for packet in value["packets"].as_array().ok_or("no-packets")? {
            let Some(track) = packet["stream_index"]
                .as_u64()
                .and_then(|i| tracks.get_mut(&i))
            else {
                continue;
            };
            let time = packet["pts_time"]
                .as_str()
                .or_else(|| packet["dts_time"].as_str())
                .and_then(|v| v.parse::<f64>().ok())
                .filter(|v| v.is_finite())
                .ok_or("untimed-packets")?;
            let duration = packet["duration_time"]
                .as_str()
                .and_then(|v| v.parse::<f64>().ok())
                .filter(|v| v.is_finite() && *v >= 0.0)
                .unwrap_or(0.0);
            let pos = packet["pos"]
                .as_str()
                .and_then(|v| v.parse::<u64>().ok())
                .ok_or("no-byte-index")?;
            let size = packet["size"]
                .as_str()
                .and_then(|v| v.parse::<u64>().ok())
                .filter(|v| *v > 0)
                .ok_or("no-byte-index")?;
            let last = pos
                .checked_add(size)
                .filter(|last| *last <= loaded.total_size)
                .ok_or("invalid-byte-index")?;
            let mut offset = pos;
            while offset < last {
                let index = spans
                    .partition_point(|span| span.0 <= offset)
                    .checked_sub(1)
                    .ok_or("verified-bytes-evicted")?;
                let span = &spans[index];
                if span.1 <= offset {
                    return Err("verified-bytes-evicted");
                }
                if span.3 {
                    repaired_files.insert(span.2.clone());
                } else {
                    ids.insert(span.2.clone());
                }
                offset = span.1.min(last);
            }
            track.push((time, time + duration));
        }
        let mut from = f64::NEG_INFINITY;
        let mut through = end;
        for packets in tracks.values_mut() {
            packets.sort_by(|a, b| a.0.total_cmp(&b.0));
            let Some(first) = packets.first() else {
                return Err("incomplete-packet-index");
            };
            from = from.max(first.0);
            let mut covered = first.1;
            for packet in packets.iter().skip(1) {
                // Timestamp gaps are not treated as verified playback. Small
                // rounding differences in the container timebase are expected.
                if packet.0 > covered + 0.002 {
                    return Err("discontinuous-packet-index");
                }
                covered = covered.max(packet.1);
            }
            through = through.min(covered);
        }
        if !from.is_finite() || !through.is_finite() || from > start + 0.002 || through <= start {
            return Err("incomplete-packet-index");
        }
        Ok(VerifiedWindow {
            from,
            through,
            segments: ids.into_iter().collect(),
            repaired_files: repaired_files.into_iter().collect(),
        })
    }
}

async fn playback(
    State(st): State<StreamState>,
    Path(id): Path<String>,
    Json(request): Json<PlaybackRequest>,
) -> Response {
    match st.playback_update(&id, request).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(status) => status.into_response(),
    }
}

/// A stream the resolver has registered (id → how to obtain it). The media layout
/// is learned lazily on first playback and cached.
struct StreamEntry {
    nzb_url: String,
    loaded: Mutex<Option<Loaded>>,
    unsupported_at: Mutex<Option<std::time::Instant>>,
    manifest: Mutex<Option<Arc<crate::nzb::Nzb>>>,
    /// Single-flight for the heavy load (NZB download + volume-header fetches):
    /// a serve arriving while a warm is mid-load WAITS for it instead of doing
    /// the whole thing again in parallel (async mutex — held across awaits).
    load_lock: tokio::sync::Mutex<()>,
    verify_lock: tokio::sync::Mutex<()>,
    playback_lock: tokio::sync::Mutex<()>,
    verification_attempt: Mutex<Option<std::time::Instant>>,
    recovery: Mutex<Recovery>,
    buffer: Mutex<VerifiedBuffer>,
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
    /// A different release remains an explicit player restart fallback.
    seamless: bool,
}

#[derive(Serialize)]
struct StreamHealth {
    status: &'static str,
    #[serde(rename = "errorCode", skip_serializing_if = "Option::is_none")]
    error_code: Option<&'static str>,
    recovery: RecoveryHealth,
    #[serde(rename = "exactRecovery")]
    exact_recovery: ExactRecoveryHealth,
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
        g.map
            .insert(message_id.to_string(), (Arc::new(data), start));
        g.order.push_back(message_id.to_string());
        while g.bytes > self.max_bytes {
            let Some(old) = g.order.pop_front() else {
                break;
            };
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
    pub repair: crate::repair::RepairRegistry,
    pub recovery_recorder: Option<Recorder>,
    repair_enabled: bool,
    buffer_config: BufferConfig,
    local_origin: String,
    buffer_slots: Arc<tokio::sync::Semaphore>,
}

impl StreamState {
    pub fn new(pool: Arc<Pool>, http: reqwest::Client, db: crate::db::Db) -> StreamState {
        Self::with_recovery(
            pool,
            http,
            db,
            Default::default(),
            Default::default(),
            String::new(),
        )
    }

    pub fn with_recovery(
        pool: Arc<Pool>,
        http: reqwest::Client,
        db: crate::db::Db,
        repair_config: crate::repair::RepairConfig,
        buffer_config: BufferConfig,
        local_origin: String,
    ) -> StreamState {
        StreamState {
            repair: crate::repair::RepairRegistry::new(repair_config.clone(), pool.clone()),
            recovery_recorder: None,
            repair_enabled: repair_config.enabled,
            buffer_config: buffer_config.clone(),
            local_origin,
            buffer_slots: Arc::new(tokio::sync::Semaphore::new(2)),
            pool,
            http,
            // ~256MB of decoded segments ≈ 15 warmed titles at 24 segments each.
            cache: SegCache::new(
                buffer_config
                    .max_memory_bytes
                    .clamp(4 * 1024 * 1024, 1024 * 1024 * 1024),
            ),
            db,
            streams: Arc::new(Mutex::new(HashMap::new())),
            warmed: Arc::new(Mutex::new(HashMap::new())),
            recovery_slots: Arc::new(tokio::sync::Semaphore::new(2)),
        }
    }

    pub fn set_recovery_recorder(&mut self, recorder: Recorder) {
        self.repair.set_recorder(recorder.clone());
        self.recovery_recorder = Some(recorder);
    }
    fn record_session(&self, sid: &str, session: &str) {
        if let Some(recorder) = &self.recovery_recorder {
            let mut event = RecoveryEvent::new(
                "stream_session",
                sid,
                &format!("{sid}:{session}"),
                "foreground",
            );
            event.playback_session_id = Some(session.into());
            recorder.record(event);
        }
    }
    fn record_read_failure(&self, sid: &str, session: Option<&str>, reason: &str) {
        if let (Some(recorder), Some(session)) = (&self.recovery_recorder, session) {
            let mut event = RecoveryEvent::new(
                "stream_read_failed",
                sid,
                &format!("{sid}:{session}:{reason}"),
                "foreground",
            );
            event.playback_session_id = Some(session.into());
            event.reason = Some(reason.into());
            event.outcome = Some("failed".into());
            recorder.record(event);
        }
    }
    /// True if this NZB was verified incomplete within the last 7 days. The
    /// verdict EXPIRES: a brand-new post can be condemned mid-propagation while
    /// its articles are still filling in, so an old verdict earns one re-check
    /// (still bad → re-condemned with a fresh timestamp, costing one failover).
    pub fn is_condemned(&self, nzb_url: &str) -> bool {
        if self.streams.lock().unwrap().get(&fnv_hex(nzb_url.as_bytes())).is_some_and(|entry| entry.unsupported()) { return true; }
        if self.repair_enabled {
            return false;
        }
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
        self.streams
            .lock()
            .unwrap()
            .entry(id.clone())
            .or_insert_with(|| Self::entry(nzb_url.to_owned()));
        id
    }

    fn entry(nzb_url: String) -> Arc<StreamEntry> {
        Arc::new(StreamEntry {
            nzb_url,
            loaded: Mutex::new(None),
            unsupported_at: Mutex::new(None),
            manifest: Mutex::new(None),
            load_lock: tokio::sync::Mutex::new(()),
            verify_lock: tokio::sync::Mutex::new(()),
            playback_lock: tokio::sync::Mutex::new(()),
            verification_attempt: Mutex::new(None),
            recovery: Mutex::new(Recovery::default()),
            buffer: Mutex::new(VerifiedBuffer::default()),
        })
    }

    /// Local registry lookup only: no provider I/O or health gate. Restoring an
    /// id preserves the same NZB, never a similarly named replacement.
    fn lookup(&self, sid: &str) -> Option<Arc<StreamEntry>> {
        if !valid_stream_id(sid) {
            return None;
        }
        if let Some(entry) = self.streams.lock().unwrap().get(sid).cloned() {
            return Some(entry);
        }
        let nzb_url: String = {
            let conn = self.db.lock().unwrap();
            let url: String = conn
                .query_row(
                    "SELECT nzb_url FROM stream_registrations WHERE sid=?1",
                    [sid],
                    |r| r.get(0),
                )
                .ok()?;
            // Reject corrupted or manually mismatched rows rather than serving
            // any source whose exact stable identity does not match this id.
            if fnv_hex(url.as_bytes()) != sid {
                return None;
            }
            let _ = conn.execute(
                "UPDATE stream_registrations SET touched_at=strftime('%s','now')*1000 WHERE sid=?1",
                [sid],
            );
            url
        };
        let mut map = self.streams.lock().unwrap();
        Some(
            map.entry(sid.to_owned())
                .or_insert_with(|| Self::entry(nzb_url))
                .clone(),
        )
    }

    pub fn is_registered(&self, sid: &str) -> bool {
        self.lookup(sid).is_some()
    }

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
                entry.recovery.lock().unwrap().candidates = sids
                    .iter()
                    .filter(|candidate| *candidate != sid)
                    .take(5)
                    .cloned()
                    .collect();
            }
        }
    }

    fn health(&self, sid: &str) -> Option<StreamHealth> {
        let entry = self.lookup(sid)?;
        let entries = self.streams.lock().unwrap();
        let complete = entry
            .loaded
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|l| l.complete);
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
                    candidate
                        .loaded
                        .lock()
                        .unwrap()
                        .as_ref()
                        .and_then(|l| l.complete)
                        == Some(true)
                })
                && prepared
                    .segments
                    .iter()
                    .all(|id| self.cache.get(id).is_some())
        });
        Some(StreamHealth {
            error_code: match status { "unsupported" => Some("unsupported_archive"), "incomplete" => Some("missing_articles"), _ => None },
            status,
            exact_recovery: self.buffer_health(&entry),
            recovery: RecoveryHealth {
                status: if ready.is_some() {
                    "ready"
                } else if recovery.preparing {
                    "preparing"
                } else if recovery.attempted {
                    "unavailable"
                } else {
                    "idle"
                },
                stream_id: ready.map(|p| p.sid.clone()),
                prepared_fraction: ready.map(|p| p.fraction),
                seamless: false,
            },
        })
    }

    fn prepare_recovery(&self, sid: &str, fraction: f64) -> bool {
        let entry = self.lookup(sid);
        let Some(entry) = entry else { return false };
        {
            let mut recovery = entry.recovery.lock().unwrap();
            recovery.desired_fraction = fraction.clamp(0.0, 0.999);
            if recovery.preparing {
                return true;
            }
            if recovery
                .last_attempt
                .is_some_and(|at| at.elapsed() < std::time::Duration::from_secs(20))
                && recovery
                    .prepared
                    .as_ref()
                    .is_none_or(|p| (p.fraction - fraction).abs() < 0.002)
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
    let entry = st
        .lookup(sid)
        .ok_or_else(|| anyhow::anyhow!("unknown stream {sid}"))?;
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
    if st.repair_enabled && !ok {
        // A missing STAT is a repair opportunity, not proof that original bytes
        // cannot be recovered. Only the actual bounded reader may fail.
        return Ok(true);
    }
    if !ok && health.missing == 0 {
        anyhow::bail!("verification incomplete: providers temporarily unavailable");
    }
    if let Some(l) = entry.loaded.lock().unwrap().as_mut() {
        // A BODY failure discovered during the sweep is stronger evidence than
        // an earlier STAT success. Never erase an already-confirmed hole.
        if l.complete == Some(false) {
            return Ok(false);
        }
        l.complete = Some(ok);
    }
    if !ok {
        let reason = format!(
            "{} of {} segments confirmed missing",
            health.missing, health.total
        );
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

async fn warm_region(
    st: &StreamState,
    sid: &str,
    fraction: Option<f64>,
) -> anyhow::Result<Vec<String>> {
    let entry = st
        .lookup(sid)
        .ok_or_else(|| anyhow::anyhow!("unknown stream {sid}"))?;
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
                let state = st.clone();
                let sid = sid.to_string();
                let cache = st.cache.clone();
                let group = ext.group.clone();
                let seg = ext.segments[idx].clone();
                let part_size = ext.part_size;
                async move {
                    let (data, start) =
                        fetch_recovering(&state, &sid, &group, &seg, part_size, idx, true).await?;
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
                    if error.confirmed_bad() && !st.repair_enabled {
                        st.condemn_sid(sid, error.reason());
                    }
                    anyhow::bail!("{}", error.reason());
                }
            }
        }
    }
    tracing::info!(
        "warmed stream {sid} ({} extents, {:.2} GB)",
        extents.len(),
        total as f64 / 1e9
    );
    Ok(warmed_ids)
}

fn warm_targets(
    extents: &[Extent],
    starts: &[u64],
    media_off: u64,
    count: usize,
) -> Vec<(usize, usize)> {
    let Some(mut ei) = starts.iter().rposition(|&start| start <= media_off) else {
        return vec![];
    };
    let mut idx = ((extents[ei].data_start + media_off.saturating_sub(starts[ei]))
        / extents[ei].part_size.max(1)) as usize;
    // Include a little before the estimate for decoder keyframes and VBR drift.
    idx = idx.saturating_sub(2);
    let mut jobs = Vec::new();
    while ei < extents.len() && jobs.len() < count {
        let ext = &extents[ei];
        let last =
            ((ext.data_start + ext.data_len.saturating_sub(1)) / ext.part_size.max(1)) as usize;
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
        )
        .await;
        match result {
            Ok(Ok(mut segments)) => {
                // Loading a large NZB can take long enough for playback to
                // move (or seek). Refresh the latest requested region before
                // declaring readiness, with the layout and STAT now cached.
                let latest = entry.recovery.lock().unwrap().desired_fraction;
                let mut fraction = fraction;
                if (latest - fraction).abs() >= 0.002 {
                    match tokio::time::timeout(
                        std::time::Duration::from_secs(30),
                        warm_region(st, &candidate, Some(latest)),
                    )
                    .await
                    {
                        Ok(Ok(refreshed)) => {
                            segments = refreshed;
                            fraction = latest;
                        }
                        _ => continue,
                    }
                }
                entry.recovery.lock().unwrap().prepared = Some(PreparedRecovery {
                    sid: candidate,
                    fraction,
                    segments,
                    at: std::time::Instant::now(),
                });
                tracing::info!(
                    "stream {sid}: alternate prepared around {:.1}%",
                    fraction * 100.0
                );
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

async fn prepare(
    State(st): State<StreamState>,
    Path(id): Path<String>,
    Json(req): Json<PrepareRequest>,
) -> Response {
    if !req.fraction.is_finite() || !(0.0..=1.0).contains(&req.fraction) {
        return (StatusCode::BAD_REQUEST, "fraction must be between 0 and 1").into_response();
    }
    if st.prepare_recovery(&id, req.fraction) {
        StatusCode::ACCEPTED.into_response()
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

async fn health(
    State(st): State<StreamState>,
    Path(id): Path<String>,
    axum::extract::Query(query): axum::extract::Query<HashMap<String, String>>,
) -> Response {
    match st.health(&id) {
        Some(mut health) => {
            if let Some(entry) = st.lookup(&id) {
                let file_ids = entry
                    .buffer
                    .lock()
                    .unwrap()
                    .verified
                    .as_ref()
                    .map(|window| window.repaired_files.clone())
                    .unwrap_or_default();
                let mut verified_files = std::collections::HashSet::new();
                for file in file_ids {
                    if st.repair.verified_file(&id, &file).await {
                        verified_files.insert(file);
                    }
                }
                health.exact_recovery = st.buffer_health_for(
                    &entry,
                    query.get("sessionId").map(String::as_str),
                    &verified_files,
                );
            }
            let mut value = serde_json::to_value(health).unwrap_or_default();
            value["repair"] = serde_json::to_value(st.repair.status(&id).await).unwrap_or_default();
            ([(header::CACHE_CONTROL, "no-store")], Json(value)).into_response()
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

/// Router fragment for the range server.
pub fn router(state: StreamState) -> axum::Router {
    axum::Router::new()
        .route("/stream/:id", axum::routing::get(serve))
        .route("/stream/:id/prepare", axum::routing::post(prepare))
        .route("/stream/:id/health", axum::routing::get(health))
        .route("/stream/:id/playback", axum::routing::post(playback))
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
    let loading_session = if !headers.contains_key("x-velvet-probe") {
        headers
            .get("x-velvet-playback-session")
            .and_then(|v| v.to_str().ok())
            .filter(|v| valid_session(v))
            .map(str::to_owned)
    } else {
        None
    };
    if let Some(session) = &loading_session {
        st.record_session(&id, session);
    }
    let trigger = if headers.contains_key("x-velvet-probe") {
        "ahead"
    } else {
        "foreground"
    };
    if let Err(e) = ensure_loaded_context(st.clone(), entry.clone(), trigger, loading_session).await
    {
        tracing::warn!("stream {id}: preparation failed ({})", StreamError::from_preparation(&e).code());
        if !headers.contains_key("x-velvet-probe") {
            let session = headers
                .get("x-velvet-playback-session")
                .and_then(|v| v.to_str().ok())
                .filter(|v| valid_session(v));
            st.record_read_failure(&id, session, StreamError::from_preparation(&e).code());
        }
        return StreamError::from_preparation(&e).response();
    }

    // Read the cached load info into locals (brief lock, nothing held across await).
    let (total, extents, ext_media_start, complete) = {
        let guard = entry.loaded.lock().unwrap();
        let l = guard.as_ref().unwrap();
        (
            l.total_size,
            l.extents.clone(),
            l.ext_media_start.clone(),
            l.complete,
        )
    };

    match complete {
        // Verified holes: refuse so the app fails over at a clean request
        // boundary — never let the parser hit a zero-filled gap mid-scene.
        Some(false) if !st.repair_enabled => {
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
        Some(true) | Some(false) => {}
    }

    // Parse a single Range: `bytes=start-end` (end optional).
    let (start, end) = match parse_range(&headers, total) {
        Some(r) => r,
        None => return StreamError::InvalidRange.response(),
    };

    let probe_budget = {
        let buffer = entry.buffer.lock().unwrap();
        headers
            .get("x-velvet-probe")
            .and_then(|v| v.to_str().ok())
            .filter(|v| !buffer.probe_token.is_empty() && *v == buffer.probe_token)
            .and_then(|_| buffer.probe_budget.clone())
    };
    if headers.contains_key("x-velvet-probe") && probe_budget.is_none() {
        return StatusCode::FORBIDDEN.into_response();
    }
    let playback_session = if probe_budget.is_none() {
        headers
            .get("x-velvet-playback-session")
            .and_then(|v| v.to_str().ok())
            .filter(|v| valid_session(v))
            .map(str::to_owned)
    } else {
        None
    };
    if let Some(session) = &playback_session {
        st.record_session(&id, session);
    }
    let gen = StreamGen {
        playback_session,
        probe_budget,
        extents,
        ext_media_start,
        media_pos: start,
        end: end + 1,
        ext_idx: 0,
        seg_idx: 0,
        positioned: false,
        inflight: std::collections::VecDeque::new(),
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
    h.insert(
        header::CONTENT_LENGTH,
        (end - start + 1).to_string().parse().unwrap(),
    );
    h.insert(
        header::CONTENT_RANGE,
        format!("bytes {start}-{end}/{total}").parse().unwrap(),
    );
    resp.body(body).unwrap()
}

async fn ensure_loaded(st: StreamState, entry: Arc<StreamEntry>) -> anyhow::Result<()> {
    ensure_loaded_context(st, entry, "ahead", None).await
}
async fn ensure_loaded_context(
    st: StreamState,
    entry: Arc<StreamEntry>,
    trigger: &'static str,
    session: Option<String>,
) -> anyhow::Result<()> {
    // Fast path: already loaded (brief lock, no await held).
    if entry.loaded.lock().unwrap().is_some() {
        if st.repair_enabled {
            let manifest = entry.manifest.lock().unwrap().clone();
            if let Some(manifest) = manifest {
                let _ = st
                    .repair
                    .register(&fnv_hex(entry.nzb_url.as_bytes()), manifest)
                    .await;
            }
        }
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
    let parsed = Arc::new(crate::nzb::parse(&nzb_bytes)?);
    *entry.manifest.lock().unwrap() = Some(parsed.clone());
    let sid = fnv_hex(entry.nzb_url.as_bytes());
    if st.repair_enabled {
        if st.repair.register(&sid, parsed.clone()).await.is_err() {
            tracing::debug!("stream {sid}: bounded repair registration unavailable");
        }
    }

    // Build the media as extents: a raw media file → one extent; otherwise try to
    // stream from inside a store-mode archive — RAR5 volumes (many extents) or a
    // single-file store-mode 7z (one extent). Anything else (compressed data,
    // LZMA-encoded 7z header, multi-volume 7z, nothing) errors → the app fails
    // over. 7z is <1% of releases and always co-listed with raw/rar, so we cover
    // only the cheap store-mode case and let the rest fail over fast.
    let (extents, total_size) = if let Some(file) = parsed.primary_file() {
        let group = file.groups.first().cloned().unwrap_or_default();
        let segments = file.segments.clone();
        let first = segments
            .first()
            .ok_or_else(|| anyhow::anyhow!("no segments"))?;
        let (part_size, total) = if st.repair_enabled {
            let started = std::time::Instant::now();
            let (attempt, rescued) = st
                .pool
                .fetch_decoded_observed(&group, &first.message_id)
                .await;
            let decoded = match attempt {
                crate::pool::DecodedFetch::Found(decoded) => {
                    if rescued {
                        st.repair
                            .provider_rescue(
                                &sid,
                                &first.message_id,
                                &decoded,
                                trigger,
                                started.elapsed().as_millis().min(u64::MAX as u128) as u64,
                            )
                            .await;
                    }
                    decoded
                }
                failure => st
                    .repair
                    .recover_context(&sid, &first.message_id, trigger, session.as_deref())
                    .await
                    .map_err(|_| anyhow::Error::from(if matches!(failure, crate::pool::DecodedFetch::Missing) { StreamError::MissingArticles } else { StreamError::UpstreamUnavailable }))?,
            };
            let _ = st.repair.remember(&sid, &first.message_id, &decoded).await;
            let part = decoded.data.len() as u64;
            let total = decoded
                .total_size
                .ok_or_else(|| anyhow::anyhow!("initial article missing exact total size"))?;
            st.cache.put(
                &first.message_id,
                decoded.data,
                decoded.part_begin.unwrap_or(1) - 1,
            );
            (part, total)
        } else {
            match st.pool.fetch_checked(&group, &first.message_id).await {
                crate::pool::CheckedFetch::Found(raw) => {
                    let dec = crate::yenc::decode(&raw)?;
                    let part = dec.data.len() as u64;
                    (
                        part,
                        dec.total_size
                            .unwrap_or_else(|| part * segments.len() as u64),
                    )
                }
                crate::pool::CheckedFetch::Missing => return Err(StreamError::MissingArticles.into()),
                crate::pool::CheckedFetch::Unavailable => return Err(StreamError::UpstreamUnavailable.into()),
            }
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
    playback_session: Option<String>,
    probe_budget: Option<Arc<std::sync::atomic::AtomicU64>>,
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
    inflight:
        std::collections::VecDeque<tokio::task::JoinHandle<Result<(Vec<u8>, u64), FetchFailure>>>,
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
enum FetchFailure {
    Missing,
    Unavailable,
    Corrupt,
}

impl FetchFailure {
    fn confirmed_bad(&self) -> bool {
        !matches!(self, Self::Unavailable)
    }
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
                let start = d
                    .part_begin
                    .and_then(|b| b.checked_sub(1))
                    .unwrap_or(idx as u64 * part_size);
                cache.put(&seg.message_id, d.data.clone(), start);
                Ok((d.data, start))
            }
            _ => Err(FetchFailure::Corrupt),
        },
        crate::pool::CheckedFetch::Missing => Err(FetchFailure::Missing),
        crate::pool::CheckedFetch::Unavailable => Err(FetchFailure::Unavailable),
    }
}

/// Beta reads preserve exact original-file offsets and the HTTP resource. Every
/// ordinary successful fetch is persisted, so repair can reuse already verified
/// data. A failed speculative fetch never poisons concurrent range requests.
async fn fetch_recovering(
    st: &StreamState,
    sid: &str,
    group: &str,
    seg: &crate::nzb::Segment,
    part_size: u64,
    idx: usize,
    background: bool,
) -> Result<(Vec<u8>, u64), FetchFailure> {
    fetch_recovering_context(
        st,
        sid,
        group,
        seg,
        part_size,
        idx,
        background,
        None,
        if background { "ahead" } else { "foreground" },
    )
    .await
}
async fn fetch_recovering_context(
    st: &StreamState,
    sid: &str,
    group: &str,
    seg: &crate::nzb::Segment,
    part_size: u64,
    idx: usize,
    background: bool,
    session: Option<&str>,
    trigger: &'static str,
) -> Result<(Vec<u8>, u64), FetchFailure> {
    if !st.repair_enabled {
        return fetch_streaming(&st.pool, &st.cache, group, seg, part_size, idx).await;
    }
    if let Some((data, start)) = st.cache.get(&seg.message_id) {
        return Ok((data.as_ref().clone(), start));
    }
    let decoded = if let Some(decoded) = st.repair.read(sid, &seg.message_id).await {
        decoded
    } else {
        let started = std::time::Instant::now();
        let (attempt, rescued) = {
            let _background = if background {
                Some(st.pool.background_permit().await)
            } else {
                None
            };
            st.pool.fetch_decoded_observed(group, &seg.message_id).await
        };
        match attempt {
            crate::pool::DecodedFetch::Found(decoded) => {
                if rescued {
                    st.repair
                        .provider_rescue(
                            sid,
                            &seg.message_id,
                            &decoded,
                            trigger,
                            started.elapsed().as_millis().min(u64::MAX as u128) as u64,
                        )
                        .await;
                }
                let _ = st.repair.remember(sid, &seg.message_id, &decoded).await;
                decoded
            }
            failure => st
                .repair
                .recover_context(sid, &seg.message_id, trigger, session)
                .await
                .map_err(|_| match failure {
                    crate::pool::DecodedFetch::Missing => FetchFailure::Missing,
                    crate::pool::DecodedFetch::Corrupt => FetchFailure::Corrupt,
                    _ => FetchFailure::Unavailable,
                })?,
        }
    };
    let start = decoded
        .part_begin
        .unwrap_or(1)
        .checked_sub(1)
        .ok_or(FetchFailure::Corrupt)?;
    st.cache.put(&seg.message_id, decoded.data.clone(), start);
    Ok((decoded.data, start))
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
        let count = if self.state.repair_enabled {
            let byte_limit = self
                .probe_budget
                .as_ref()
                .map(|b| b.load(std::sync::atomic::Ordering::Relaxed))
                .unwrap_or(self.state.buffer_config.max_memory_bytes as u64 / 4);
            (byte_limit / (crate::nntp::MAX_ARTICLE_BYTES as u64).max(ext.part_size))
                .clamp(1, LOOKAHEAD as u64) as usize
        } else {
            LOOKAHEAD
        };
        while self.inflight.len() < count {
            let idx = self.seg_idx + self.inflight.len();
            if idx > last_needed {
                break;
            }

            let group = ext.group.clone();
            let seg = ext.segments[idx].clone();
            let part_size = ext.part_size;
            let state = self.state.clone();
            let sid = self.sid.clone();
            let background = self.probe_budget.is_some();
            let session = self.playback_session.clone();
            self.inflight.push_back(tokio::spawn(async move {
                let result = fetch_recovering_context(
                    &state,
                    &sid,
                    &group,
                    &seg,
                    part_size,
                    idx,
                    background,
                    session.as_deref(),
                    "ahead",
                )
                .await;
                // Report as soon as a look-ahead task discovers a hole, before
                // ordered emission (and hence the viewer) reaches that article.
                if let Err(error) = &result {
                    if error.confirmed_bad() && !state.repair_enabled {
                        state.condemn_sid(&sid, error.reason());
                    }
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
        self.state.record_read_failure(
            &self.sid, self.playback_session.as_deref(), "article_corrupt",
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
            if self.state.repair_enabled {
                if let Some(first) = ext.segments.first() {
                    let take = ext
                        .part_size
                        .min(ext_end - self.media_pos)
                        .min(self.end - self.media_pos)
                        .min(4 * 1024 * 1024) as usize;
                    if let Ok(Some(bytes)) = self
                        .state
                        .repair
                        .read_range(&self.sid, &first.message_id, vol_off, take)
                        .await
                    {
                        if !bytes.is_empty() {
                            self.abort_inflight();
                            if let Some(budget) = &self.probe_budget {
                                if budget
                                    .fetch_update(
                                        std::sync::atomic::Ordering::Relaxed,
                                        std::sync::atomic::Ordering::Relaxed,
                                        |remaining| remaining.checked_sub(bytes.len() as u64),
                                    )
                                    .is_err()
                                {
                                    self.media_pos = self.end;
                                    return Some((
                                        Err(std::io::Error::other("probe byte limit")),
                                        self,
                                    ));
                                }
                            }
                            if let Some(session) = &self.playback_session {
                                self.state
                                    .repair
                                    .served(
                                        &self.sid,
                                        &first.message_id,
                                        vol_off,
                                        bytes.len(),
                                        session,
                                    )
                                    .await;
                            }
                            self.media_pos += bytes.len() as u64;
                            self.positioned = false;
                            return Some((Ok(Bytes::from(bytes)), self));
                        }
                    }
                }
            }
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
                            fetch_recovering_context(
                                &self.state,
                                &self.sid,
                                &ext.group,
                                &ext.segments[self.seg_idx],
                                ext.part_size,
                                self.seg_idx,
                                self.probe_budget.is_some(),
                                self.playback_session.as_deref(),
                                if self.probe_budget.is_some() {
                                    "ahead"
                                } else {
                                    "foreground"
                                },
                            )
                            .await
                        }
                    },
                    None => {
                        fetch_recovering_context(
                            &self.state,
                            &self.sid,
                            &ext.group,
                            &ext.segments[self.seg_idx],
                            ext.part_size,
                            self.seg_idx,
                            self.probe_budget.is_some(),
                            self.playback_session.as_deref(),
                            if self.probe_budget.is_some() {
                                "ahead"
                            } else {
                                "foreground"
                            },
                        )
                        .await
                    }
                }
            } else {
                // Positioning: serial adaptive fetch until the exact segment for
                // media_pos is found (=ypart is ground truth, estimates can drift).
                fetch_recovering_context(
                    &self.state,
                    &self.sid,
                    &ext.group,
                    &ext.segments[self.seg_idx],
                    ext.part_size,
                    self.seg_idx,
                    self.probe_budget.is_some(),
                    self.playback_session.as_deref(),
                    if self.probe_budget.is_some() {
                        "ahead"
                    } else {
                        "foreground"
                    },
                )
                .await
            };
            let fetched = if self.state.repair_enabled && fetched.is_err() {
                // PAR2 verifies whole original files. Consecutive absent articles
                // need not have guessable boundaries: read the exact original
                // file offset required by this HTTP range instead.
                let id = &ext.segments[self.seg_idx].message_id;
                let take = ext
                    .part_size
                    .min(ext_end - self.media_pos)
                    .min(self.end - self.media_pos)
                    .min(4 * 1024 * 1024) as usize;
                match self
                    .state
                    .repair
                    .read_range(&self.sid, id, vol_off, take)
                    .await
                {
                    Ok(Some(bytes)) if !bytes.is_empty() => Ok((bytes, vol_off)),
                    _ => fetched,
                }
            } else {
                fetched
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
                        self.sid,
                        error.reason(),
                        self.media_pos,
                    );
                    if error.confirmed_bad() && !self.state.repair_enabled {
                        self.state.condemn_sid(&self.sid, error.reason());
                    }
                    self.state.record_read_failure(
                        &self.sid,
                        self.playback_session.as_deref(),
                        match error {
                            FetchFailure::Missing => "article_missing",
                            FetchFailure::Corrupt => "article_corrupt",
                            FetchFailure::Unavailable => "provider_unavailable",
                        },
                    );
                    self.abort_inflight();
                    self.media_pos = self.end; // next step() ends the stream
                    return Some((Err(std::io::Error::other(error.reason())), self));
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
            let seg_avail = (seg_end - vol_off)
                .min(ext_end - self.media_pos)
                .min(self.end - self.media_pos);
            let take = (seg_avail as usize).min(decoded.len() - from);
            if take == 0 {
                return self.invalid_position();
            }
            if let Some(budget) = &self.probe_budget {
                if budget
                    .fetch_update(
                        std::sync::atomic::Ordering::Relaxed,
                        std::sync::atomic::Ordering::Relaxed,
                        |remaining| remaining.checked_sub(take as u64),
                    )
                    .is_err()
                {
                    self.abort_inflight();
                    self.media_pos = self.end;
                    return Some((Err(std::io::Error::other("probe byte limit")), self));
                }
            }
            let chunk = Bytes::copy_from_slice(&decoded[from..from + take]);
            if let Some(session) = &self.playback_session {
                self.state
                    .repair
                    .served(
                        &self.sid,
                        &ext.segments[self.seg_idx].message_id,
                        vol_off,
                        take,
                        session,
                    )
                    .await;
            }
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
    let end: u64 = if e.is_empty() {
        total.saturating_sub(1)
    } else {
        e.parse().ok()?
    };
    if start > end || start >= total {
        return None;
    }
    Some((start, end.min(total.saturating_sub(1))))
}

pub fn valid_stream_id(id: &str) -> bool {
    id.len() == 16
        && id
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
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
        let other = restored
            .register("https://unreachable.invalid/other-release.nzb")
            .await;
        assert_ne!(sid, other);
        assert_eq!(restored.lookup(&sid).unwrap().nzb_url, source);
        assert!(!restored.is_registered("0000000000000000"));
    }

    #[test]
    fn corrupted_registration_and_noncanonical_ids_are_rejected() {
        let st = test_state();
        st.db
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO stream_registrations VALUES (?1, ?2, 1)",
                rusqlite::params!["0123456789abcdef", "https://fixture.invalid/wrong.nzb"],
            )
            .unwrap();
        assert!(!st.is_registered("0123456789abcdef"));
        for sid in [
            "",
            "0123456789ABCDEF",
            "0123456789abcdeg",
            "../0123456789abc",
            "0123456789abcdef?token=x",
        ] {
            assert!(!valid_stream_id(sid));
            assert!(!st.is_registered(sid));
        }
    }

    fn extent(prefix: &str, count: usize) -> Extent {
        Extent {
            segments: Arc::new(
                (0..count)
                    .map(|idx| crate::nzb::Segment {
                        number: idx as u32 + 1,
                        bytes: 100,
                        message_id: format!("{prefix}-{idx}"),
                    })
                    .collect(),
            ),
            group: "".into(),
            part_size: 100,
            data_start: 0,
            data_len: count as u64 * 100,
        }
    }

    async fn loaded_stream(st: &StreamState, name: &str, complete: Option<bool>) -> String {
        let sid = st.register(name).await;
        let entry = st.streams.lock().unwrap().get(&sid).cloned().unwrap();
        *entry.loaded.lock().unwrap() = Some(Loaded {
            extents: Arc::new(vec![extent(name, 5)]),
            ext_media_start: Arc::new(vec![0]),
            total_size: 500,
            complete,
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
        for idx in 0..5 {
            st.cache
                .put(&format!("backup-{idx}"), vec![1; 100], idx * 100);
        }
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
        let invalid = prepare(
            State(st.clone()),
            Path("missing".into()),
            Json(PrepareRequest { fraction: 1.5 }),
        )
        .await;
        assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
        let missing = prepare(
            State(st),
            Path("missing".into()),
            Json(PrepareRequest { fraction: 0.5 }),
        )
        .await;
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
            playback_session: None,
            probe_budget: None,
            extents: Arc::new(vec![ext.clone()]),
            ext_media_start: Arc::new(vec![0]),
            media_pos: 0,
            end: 500,
            ext_idx: 0,
            seg_idx: 0,
            positioned: true,
            inflight: std::collections::VecDeque::new(),
            state: st.clone(),
            sid: sid.clone(),
        };
        gen.top_up(&ext, 0, 500);
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while st.health(&sid).unwrap().status != "incomplete" {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(
            gen.media_pos, 0,
            "look-ahead must report before emission reaches the hole"
        );
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
mod beta_tests {
    use super::*;

    fn state(pool: Arc<Pool>) -> (StreamState, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "velvet-buffer-test-{}-{:x}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let db = crate::db::open(":memory:").unwrap();
        crate::sync::migrate(&db.lock().unwrap()).unwrap();
        let cfg = crate::repair::RepairConfig {
            enabled: true,
            cache_dir: path.to_string_lossy().into_owned(),
            min_free_bytes: 0,
            max_job_bytes: 1024 * 1024,
            max_cache_bytes: 4 * 1024 * 1024,
            ..Default::default()
        };
        (
            StreamState::with_recovery(
                pool,
                reqwest::Client::new(),
                db,
                cfg,
                BufferConfig {
                    enabled: true,
                    ..Default::default()
                },
                "http://127.0.0.1:1".into(),
            ),
            path,
        )
    }

    async fn loaded(st: &StreamState) -> (String, Arc<StreamEntry>) {
        let sid = st.register("https://fixture.invalid/exact.nzb").await;
        let segments = Arc::new(
            (0..5)
                .map(|i| crate::nzb::Segment {
                    number: i + 1,
                    bytes: 120,
                    message_id: format!("part-{i}"),
                })
                .collect::<Vec<_>>(),
        );
        let manifest = Arc::new(crate::nzb::Nzb {
            files: vec![crate::nzb::NzbFile {
                subject: "fixture.mp4".into(),
                groups: vec![],
                segments: segments.as_ref().clone(),
                total_bytes: 600,
            }],
        });
        st.repair.register(&sid, manifest.clone()).await.unwrap();
        let entry = st.lookup(&sid).unwrap();
        *entry.manifest.lock().unwrap() = Some(manifest);
        *entry.loaded.lock().unwrap() = Some(Loaded {
            extents: Arc::new(vec![Extent {
                segments,
                group: "".into(),
                part_size: 100,
                data_start: 0,
                data_len: 500,
            }]),
            ext_media_start: Arc::new(vec![0]),
            total_size: 500,
            complete: None,
        });
        (sid, entry)
    }

    fn point(session: &str, generation: u64) -> PlaybackRequest {
        PlaybackRequest {
            session_id: session.into(),
            generation,
            position_ms: 0,
            duration_ms: 10000,
            buffered_position_ms: 0,
            playing: true,
            stopped: false,
        }
    }

    #[tokio::test]
    async fn beta_missing_stat_and_speculative_fetch_do_not_poison_original_resource() {
        let (provider, server) = crate::pool::tests::fake_provider(430).await;
        let (mut st, path) = state(Pool::new_verified(&[provider], true));
        let analytics = crate::db::open(":memory:").unwrap();
        st.set_recovery_recorder(Recorder::new(analytics.clone()).unwrap());
        let (sid, entry) = loaded(&st).await;
        assert!(verify_stream(&st, &sid).await.unwrap());
        assert_ne!(st.health(&sid).unwrap().status, "incomplete");
        let segment = entry.loaded.lock().unwrap().as_ref().unwrap().extents[0].segments[2].clone();
        assert!(fetch_recovering(&st, &sid, "", &segment, 100, 2, true)
            .await
            .is_err());
        assert_ne!(st.health(&sid).unwrap().status, "incomplete");
        assert_eq!(
            st.db
                .lock()
                .unwrap()
                .query_row("SELECT count(*) FROM bad_releases", [], |r| r
                    .get::<_, u64>(0))
                .unwrap(),
            0
        );
        for _ in 0..100 {
            if analytics
                .lock()
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM recovery_events WHERE kind='repair_job'",
                    [],
                    |r| r.get::<_, i64>(0),
                )
                .unwrap()
                == 1
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert_eq!(
            analytics
                .lock()
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM recovery_events WHERE kind='stream_read_failed'",
                    [],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
            0,
            "speculative repair failure is not a viewer failure"
        );
        let mut headers = HeaderMap::new();
        headers.insert("x-velvet-playback-session", "watch-a".parse().unwrap());
        for _ in 0..3 {
            let response = serve(State(st.clone()), Path(sid.clone()), headers.clone()).await;
            assert!(axum::body::to_bytes(response.into_body(), 1024)
                .await
                .is_err());
        }
        for _ in 0..100 {
            if analytics
                .lock()
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM recovery_events WHERE kind='stream_read_failed'",
                    [],
                    |r| r.get::<_, i64>(0),
                )
                .unwrap()
                == 1
            {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert_eq!(
            analytics
                .lock()
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM recovery_events WHERE kind='stream_read_failed'",
                    [],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
            1,
            "retry requests cannot multiply the same watch/source failure"
        );
        st.repair.cancel(&sid).await;
        drop(entry);
        drop(st);
        server.abort();
        let _ = std::fs::remove_dir_all(path);
    }

    #[tokio::test]
    async fn verified_provider_fallback_and_disk_reuse_keep_one_http_resource_byte_exact() {
        let original: Vec<u8> = (0..=255).cycle().take(500).collect();
        let bodies = original
            .chunks(100)
            .enumerate()
            .map(|(i, data)| {
                (
                    format!("part-{i}"),
                    crate::pool::verified_fixtures::article(data, i as u64 * 100 + 1, 500, i + 1),
                )
            })
            .collect();
        let (bad, bad_server) = crate::pool::tests::fake_provider(223).await;
        let (good, good_server) = crate::pool::verified_fixtures::provider(bodies).await;
        let (mut st, path) = state(Pool::new_verified(&[bad, good], true));
        let analytics = crate::db::open(":memory:").unwrap();
        st.set_recovery_recorder(Recorder::new(analytics.clone()).unwrap());
        let (sid, entry) = loaded(&st).await;
        let mut headers = HeaderMap::new();
        headers.insert("x-velvet-playback-session", "watch-a".parse().unwrap());
        let response = serve(State(st.clone()), Path(sid.clone()), headers.clone()).await;
        assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(
            axum::body::to_bytes(response.into_body(), 1024)
                .await
                .unwrap()
                .as_ref(),
            original
        );
        // Evict the memory tier and make network impossible. The same URL still
        // serves verified ordinary bytes persisted by the first read.
        st.cache = SegCache::new(1024);
        st.pool = Pool::new_verified(&[], true);
        let response = serve(State(st.clone()), Path(sid.clone()), HeaderMap::new()).await;
        assert_eq!(
            axum::body::to_bytes(response.into_body(), 1024)
                .await
                .unwrap()
                .as_ref(),
            original
        );
        assert_ne!(st.health(&sid).unwrap().status, "incomplete");
        // Seeks in one watch cannot double the benefit; a second simultaneous
        // watch receives a separate association but does not repeat server work.
        for session in ["watch-a", "watch-a", "watch-b"] {
            headers.insert("x-velvet-playback-session", session.parse().unwrap());
            let response = serve(State(st.clone()), Path(sid.clone()), headers.clone()).await;
            assert_eq!(
                axum::body::to_bytes(response.into_body(), 1024)
                    .await
                    .unwrap()
                    .as_ref(),
                original
            );
        }
        for _ in 0..100 {
            let count: i64 = analytics
                .lock()
                .unwrap()
                .query_row(
                    "SELECT count(*) FROM recovery_events WHERE kind='provider_rescue_read'",
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            if count == 10 {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        {
            let c = analytics.lock().unwrap();
            let count = |kind: &str| {
                c.query_row(
                    "SELECT count(*) FROM recovery_events WHERE kind=?1",
                    [kind],
                    |r| r.get::<_, i64>(0),
                )
                .unwrap()
            };
            assert_eq!(count("provider_rescue"), 5);
            assert_eq!(count("provider_rescue_read"), 10);
            assert_eq!(count("stream_session"), 2);
            assert_eq!(count("repaired_read"), 0);
        }
        st.repair.cancel(&sid).await;
        drop(entry);
        drop(st);
        bad_server.abort();
        good_server.abort();
        let _ = std::fs::remove_dir_all(path);
    }

    #[tokio::test]
    async fn packet_timestamps_require_contiguous_tracks_and_resident_verified_bytes() {
        let (st, path) = state(Pool::new_verified(&[], true));
        let (sid, entry) = loaded(&st).await;
        for i in 0..5 {
            st.cache.put(&format!("part-{i}"), vec![1; 100], i * 100);
        }
        let packets: Vec<_> = (0..10).map(|i| serde_json::json!({"stream_index":0,"pos":(i * 50).to_string(),"size":"50","pts_time":i.to_string(),"duration_time":"1"})).collect();
        let mut index =
            serde_json::json!({"streams":[{"index":0,"codec_type":"video"}],"packets":packets});
        let window = st
            .verified_packet_window(&entry, &index, 0.0, 10.0, &std::collections::HashSet::new())
            .unwrap();
        assert_eq!((window.from, window.through), (0.0, 10.0));
        index["packets"][4]["pts_time"] = "40".into();
        assert!(st
            .verified_packet_window(&entry, &index, 0.0, 10.0, &std::collections::HashSet::new())
            .is_err());
        index["packets"][4]["pts_time"] = "4".into();
        st.cache.inner.lock().unwrap().map.remove("part-2");
        assert_eq!(
            st.verified_packet_window(&entry, &index, 0.0, 10.0, &std::collections::HashSet::new())
                .err(),
            Some("verified-bytes-evicted")
        );
        st.repair.cancel(&sid).await;
        drop(entry);
        drop(st);
        let _ = std::fs::remove_dir_all(path);
    }

    #[tokio::test]
    async fn repaired_file_coverage_must_be_revalidated_before_reporting_seconds() {
        let (st, path) = state(Pool::new_verified(&[], true));
        let (sid, entry) = loaded(&st).await;
        let packets: Vec<_> = (0..10).map(|i| serde_json::json!({"stream_index":0,"pos":(i * 50).to_string(),"size":"50","pts_time":i.to_string(),"duration_time":"1"})).collect();
        let index =
            serde_json::json!({"streams":[{"index":0,"codec_type":"video"}],"packets":packets});
        let proof = std::collections::HashSet::from(["part-0".to_owned()]);
        let window = st
            .verified_packet_window(&entry, &index, 0.0, 10.0, &proof)
            .unwrap();
        assert!(window.segments.is_empty());
        {
            let mut buffer = entry.buffer.lock().unwrap();
            buffer.current_session = "viewer".into();
            buffer.sessions.insert(
                "viewer".into(),
                PlaybackPoint {
                    request: point("viewer", 1),
                    at: std::time::Instant::now(),
                },
            );
            buffer.verified = Some(window);
        }
        assert_eq!(
            st.buffer_health_for(&entry, Some("viewer"), &proof)
                .verified_ahead_seconds,
            Some(10.0)
        );
        // The cached window alone is not a proof. The HTTP health endpoint
        // asynchronously checks the actual immutable repaired file, now absent.
        let response = health(
            State(st.clone()),
            Path(sid.clone()),
            axum::extract::Query(HashMap::from([("sessionId".into(), "viewer".into())])),
        )
        .await;
        let value: serde_json::Value = serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), 16384)
                .await
                .unwrap(),
        )
        .unwrap();
        assert!(value["exactRecovery"]["verifiedAheadSeconds"].is_null());
        st.repair.cancel(&sid).await;
        drop(entry);
        drop(st);
        let _ = std::fs::remove_dir_all(path);
    }

    #[tokio::test]
    async fn independent_viewer_and_stale_stop_do_not_cancel_active_probe() {
        let (st, path) = state(Pool::new_verified(&[], true));
        let (sid, entry) = loaded(&st).await;
        let task = tokio::spawn(std::future::pending::<()>());
        let abort = task.abort_handle();
        {
            let mut buffer = entry.buffer.lock().unwrap();
            buffer.current_session = "first".into();
            buffer.generation = 2;
            buffer.sessions.insert(
                "first".into(),
                PlaybackPoint {
                    request: point("first", 2),
                    at: std::time::Instant::now(),
                },
            );
            buffer.task = Some(task);
        }
        st.playback_update(&sid, point("second", 1)).await.unwrap();
        let mut stale = point("first", 1);
        stale.stopped = true;
        st.playback_update(&sid, stale).await.unwrap();
        assert!(!abort.is_finished());
        assert_eq!(entry.buffer.lock().unwrap().current_session, "first");
        let mut stop = point("first", 2);
        stop.stopped = true;
        st.playback_update(&sid, stop).await.unwrap();
        tokio::task::yield_now().await;
        assert!(abort.is_finished());
        let mut stop = point("second", 1);
        stop.stopped = true;
        st.playback_update(&sid, stop).await.unwrap();
        assert!(st.repair.status(&sid).await.is_none());
        ensure_loaded(st.clone(), entry.clone()).await.unwrap();
        assert!(
            st.repair.status(&sid).await.is_some(),
            "resuming a cached layout re-registers exact repair metadata"
        );
        st.repair.cancel(&sid).await;
        drop(entry);
        drop(st);
        let _ = std::fs::remove_dir_all(path);
    }
}

#[cfg(test)]
#[path = "stream_error_tests.rs"]
mod stream_error_tests;

#[cfg(test)]
#[path = "stream_position_tests.rs"]
mod stream_position_tests;
