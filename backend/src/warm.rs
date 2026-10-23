//! Pre-warm engine — the "it just starts instantly" machinery.
//!
//! Three triggers feed it:
//!   • resolve (`/stream/:kind/:id.json`): the top-ranked candidate is warmed the
//!     moment a details page asks for streams — by Play, the head is cached.
//!   • report_play: starting S2E4 warms S2E5 in the background, so "next
//!     episode" (or autoplay) begins with zero resolve/load/fetch latency.
//!   • a periodic sweep of the sync progress table: every few hours, the next
//!     episode of every in-progress show (and the resume point of anything
//!     mid-watch) is re-validated and re-warmed — dead-NZB roulette is played
//!     here, in the background, instead of when someone presses Play.
//!
//! A warm = resolve candidates (same quality hierarchy as the endpoint), then
//! for the best candidate: download+parse NZB, build extents, pull the head
//! segments into the byte-capped SegCache. A candidate that fails to load falls
//! through to the next — so the cache ends up holding a PROVEN-playable head.

use std::collections::HashSet;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use crate::config::Indexer;
use crate::db::Db;
use crate::resolver::{search_movie, search_series, NzbResult};
use crate::stream::{warm_head, warm_startup, StreamState};

/// A request to warm one title (movie: season/episode 0).
#[derive(Debug)]
pub struct WarmReq {
    pub kind: WarmKind,
    /// IMDb id, with or without the "tt" prefix.
    pub imdb: String,
    pub season: u32,
    pub episode: u32,
    /// Also warm around this fraction of the file (resume point).
    pub fraction: Option<f64>,
}

#[derive(Debug, PartialEq)]
pub enum WarmKind {
    Movie,
    Series,
}

pub type WarmTx = tokio::sync::mpsc::UnboundedSender<WarmReq>;

#[derive(Clone)]
pub(crate) struct WarmCandidate {
    pub sid: String,
    pub title: String,
    pub size: u64,
}

const STARTUP_PROBE_TIMEOUT: Duration = Duration::from_secs(11);
const READY_BACKUPS: usize = 3;

struct WarmCoordinator {
    slots: Arc<tokio::sync::Semaphore>,
    batches: Arc<tokio::sync::Semaphore>,
    active: Mutex<HashSet<(usize, String)>>,
    concurrency: usize,
}
impl WarmCoordinator {
    fn new(concurrency: usize) -> Arc<Self> {
        let concurrency = concurrency.clamp(1, 8);
        Arc::new(Self {
            slots: Arc::new(tokio::sync::Semaphore::new(concurrency)),
            batches: Arc::new(tokio::sync::Semaphore::new(4)),
            active: Mutex::new(HashSet::new()),
            concurrency,
        })
    }
}
fn coordinator(capacity: usize) -> Arc<WarmCoordinator> {
    static COORDINATOR: OnceLock<Arc<WarmCoordinator>> = OnceLock::new();
    COORDINATOR.get_or_init(|| WarmCoordinator::new(capacity / 8)).clone()
}
struct ActiveWarm {
    coordinator: Arc<WarmCoordinator>,
    key: (usize, String),
}
impl Drop for ActiveWarm {
    fn drop(&mut self) { self.coordinator.active.lock().unwrap().remove(&self.key); }
}

/// Discovery preserves a quality-first lane, but also tries compact, broadly
/// decodable releases. A long run of unavailable UHD remuxes must not hide an
/// ordinary 1080p encode dozens of positions below them. This changes probe
/// order only; the resolver still ranks playable sources by quality.
fn discovery_order(candidates: Vec<WarmCandidate>) -> Vec<WarmCandidate> {
    let mut seen = HashSet::new();
    let candidates: Vec<_> = candidates.into_iter().filter(|c| seen.insert(c.sid.clone())).collect();
    let mut compatible: Vec<_> = candidates.iter().filter(|c| {
        !crate::release::is_3d(&c.title) && !crate::release::is_remux(&c.title)
            && crate::release::hdr_rank(&c.title) == 0
            && (2..=3).contains(&crate::release::quality_rank(&c.title))
            && crate::release::parse(&c.title).iter().any(|tag| tag.label == "H.264")
    }).cloned().collect();
    compatible.sort_by(|a, b| {
        crate::release::quality_rank(&b.title).cmp(&crate::release::quality_rank(&a.title))
            .then(a.size.max(1).cmp(&b.size.max(1)))
    });
    let mut quality = candidates.into_iter();
    let mut fallback = compatible.into_iter();
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    loop {
        let next = [quality.next(), fallback.next()];
        if next.iter().all(Option::is_none) { break; }
        for candidate in next.into_iter().flatten() {
            if seen.insert(candidate.sid.clone()) { out.push(candidate); }
        }
    }
    out
}

async fn run_discovery<F, Fut>(
    coordinator: Arc<WarmCoordinator>,
    scope: usize,
    candidates: Vec<WarmCandidate>,
    probe_timeout: Duration,
    probe: F,
) -> Option<String>
where
    F: Fn(WarmCandidate) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    use futures::StreamExt;
    // Repeated details/resolver requests cannot queue unbounded background work.
    let _batch = coordinator.batches.clone().try_acquire_owned().ok()?;
    let ranks: std::collections::HashMap<_, _> = candidates.iter().enumerate().map(|(rank, c)| (c.sid.clone(), rank)).collect();
    let mut pending: HashSet<_> = ranks.values().copied().collect();
    let mut ready = Vec::new();
    let work = futures::stream::iter(discovery_order(candidates)).map(|candidate| {
        let coordinator = coordinator.clone();
        let probe = &probe;
        async move {
            let key = (scope, candidate.sid.clone());
            let sid = candidate.sid.clone();
            if !coordinator.active.lock().unwrap().insert(key.clone()) { return (sid, false); }
            let _active = ActiveWarm { coordinator: coordinator.clone(), key };
            let Ok(_slot) = coordinator.slots.clone().acquire_owned().await else { return (sid, false); };
            let usable = tokio::time::timeout(probe_timeout, probe(candidate)).await.unwrap_or(false);
            (sid, usable)
        }
    }).buffer_unordered(coordinator.concurrency);
    tokio::pin!(work);
    while let Some((sid, usable)) = work.next().await {
        let rank = ranks[&sid];
        pending.remove(&rank);
        if usable { ready.push((rank, sid)); }
        if ready.len() >= READY_BACKUPS {
            let best = ready.iter().map(|(rank, _)| *rank).min().unwrap();
            // A quick compatible fallback is usable immediately, but never
            // stop discovery while a higher-quality option is still unknown.
            if pending.iter().all(|rank| *rank > best) { break; }
        }
    }
    ready.into_iter().min_by_key(|(rank, _)| *rank).map(|(_, sid)| sid)
}

async fn discover_startup(st: StreamState, candidates: Vec<WarmCandidate>) -> Option<String> {
    let scope = Arc::as_ptr(&st.cache) as usize;
    run_discovery(coordinator(st.pool.total_capacity()), scope, candidates, STARTUP_PROBE_TIMEOUT, |candidate| {
        let st = st.clone();
        async move {
            match st.source_readiness(&candidate.sid).status {
                "ready" => true,
                "unavailable" => false,
                _ => warm_startup(st.clone(), candidate.sid.clone()).await.is_ok()
                    && st.source_readiness(&candidate.sid).status == "ready",
            }
        }
    }).await
}

/// Fire-and-forget bounded startup discovery across the whole candidate set.
/// Duplicate sources share capacity-aware global slots, while NNTP background
/// permits reserve provider room for playback. Every probe has a deadline; the
/// finite candidate list continues until best-ready plus backups are found.
pub(crate) fn spawn_warm_streams(st: StreamState, candidates: Vec<WarmCandidate>) {
    tokio::spawn(async move { discover_startup(st, candidates).await; });
}

/// Rank results with the same hierarchy the resolver endpoint serves.
fn sort_results(results: &mut Vec<NzbResult>) {
    results.sort_by(|a, b| crate::release::cmp_streams(&a.title, a.size, &b.title, b.size));
}

/// Resolve a title and prepare an actually readable startup, including a lower
/// quality fallback when the highest quality releases are unavailable.
async fn warm_title(
    http: &reqwest::Client,
    indexers: &[Indexer],
    st: &StreamState,
    req: &WarmReq,
) -> bool {
    // The apps report `tmdb:<id>` for titles TMDB has no imdb mapping for yet.
    let tmdb_id = req.imdb.strip_prefix("tmdb:").map(|s| s.split(':').next().unwrap_or(""));
    let imdb = req.imdb.trim_start_matches("tt");
    if imdb.is_empty() {
        return false;
    }
    let series = req.kind == WarmKind::Series;
    async fn ep_search(
        http: &reqwest::Client,
        ix: &Indexer,
        tmdb_id: Option<&str>,
        imdb: &str,
        s: u32,
        e: u32,
    ) -> anyhow::Result<Vec<NzbResult>> {
        match tmdb_id {
            Some(t) => crate::resolver::search_series_tmdb(http, ix, t, s, e).await,
            None => search_series(http, ix, imdb, s, e).await,
        }
    }
    let mut results: Vec<NzbResult> = Vec::new();
    for ix in indexers.iter() {
        let r = if series {
            ep_search(http, ix, tmdb_id, imdb, req.season, req.episode).await
        } else {
            match tmdb_id {
                Some(t) => crate::resolver::search_movie_tmdb(http, ix, t).await,
                None => search_movie(http, ix, imdb).await,
            }
        };
        if let Ok(mut list) = r {
            results.append(&mut list);
        }
    }
    // Season rollover: nothing for S(n) E(m) — try S(n+1) E1 once.
    if results.is_empty() && series && req.episode > 1 {
        for ix in indexers.iter() {
            if let Ok(mut list) = ep_search(http, ix, tmdb_id, imdb, req.season + 1, 1).await {
                results.append(&mut list);
            }
        }
    }
    if results.is_empty() {
        return false;
    }
    sort_results(&mut results);

    let mut candidates = Vec::new();
    for r in results.iter().filter(|r| !st.is_condemned(&r.nzb_url)) {
        candidates.push(WarmCandidate { sid: st.register(&r.nzb_url).await, title: r.title.clone(), size: r.size });
    }
    let Some(sid) = discover_startup(st.clone(), candidates).await else { return false; };
    // A resume region is optional extra preparation, never a gate on startup.
    if req.fraction.is_some() {
        let _ = tokio::time::timeout(Duration::from_secs(15), warm_head(st.clone(), sid.clone(), req.fraction)).await;
    }
    tracing::info!("prewarmed {} tt{imdb} s{}e{}: {sid}", if series { "series" } else { "movie" }, req.season, req.episode);
    true
}

/// The warm worker: consumes trigger requests and runs the periodic sweep.
pub async fn run_worker(
    mut rx: tokio::sync::mpsc::UnboundedReceiver<WarmReq>,
    http: reqwest::Client,
    indexers: Arc<Vec<Indexer>>,
    st: StreamState,
    db: Db,
) {
    let mut sweep = tokio::time::interval(std::time::Duration::from_secs(6 * 3600));
    loop {
        tokio::select! {
            req = rx.recv() => {
                let Some(req) = req else { return };
                warm_title(&http, &indexers, &st, &req).await;
            }
            _ = sweep.tick() => {
                sweep_progress(&http, &indexers, &st, &db).await;
            }
        }
    }
}

/// Sweep the sync progress table: for every in-progress show, warm the next
/// episode (if the current one is nearly done) or the resume point (if mid-way).
/// Movies mid-watch get their resume point warmed too.
async fn sweep_progress(
    http: &reqwest::Client,
    indexers: &Arc<Vec<Indexer>>,
    st: &StreamState,
    db: &Db,
) {
    // (kind, imdb, season, episode, fraction)
    let rows: Vec<(String, String, i64, i64, f64)> = {
        let conn = db.lock().unwrap();
        let mut stmt = match conn.prepare(
            "SELECT type, imdb_id, COALESCE(season,0), COALESCE(episode,0), \
                    CAST(position_ms AS REAL) / CAST(duration_ms AS REAL) \
             FROM progress \
             WHERE imdb_id IS NOT NULL AND imdb_id != '' AND duration_ms > 0",
        ) {
            Ok(s) => s,
            Err(_) => return,
        };
        let mapped = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, f64>(4)?,
            ))
        });
        match mapped {
            Ok(it) => it.filter_map(Result::ok).collect(),
            Err(_) => return,
        }
    };

    let mut warmed = 0;
    for (ty, imdb, season, episode, frac) in rows {
        if warmed >= 12 {
            break; // bounded sweep; the next tick continues
        }
        let req = if ty == "series" && season > 0 {
            if frac >= 0.8 {
                // Nearly done — the next episode is what they'll want.
                WarmReq { kind: WarmKind::Series, imdb, season: season as u32, episode: episode as u32 + 1, fraction: None }
            } else {
                // Mid-episode — make the resume instant.
                WarmReq { kind: WarmKind::Series, imdb, season: season as u32, episode: episode as u32, fraction: Some(frac) }
            }
        } else if ty == "movie" && frac < 0.95 {
            WarmReq { kind: WarmKind::Movie, imdb, season: 0, episode: 0, fraction: Some(frac) }
        } else {
            continue;
        };
        if warm_title(http, indexers, st, &req).await {
            warmed += 1;
        }
    }
    if warmed > 0 {
        tracing::info!("[warm] sweep warmed {warmed} title(s)");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn candidate(index: usize, title: &str, size: u64) -> WarmCandidate {
        WarmCandidate { sid: index.to_string(), title: title.into(), size }
    }
    fn remuxes(count: usize) -> Vec<WarmCandidate> {
        (0..count).map(|i| candidate(i, "Show.S01E03.2160p.UHD.REMUX.HEVC", 10_000 - i as u64)).collect()
    }

    #[test]
    fn discovery_reaches_compatible_rank_29_early_without_truncating_candidates() {
        let mut candidates = remuxes(28);
        candidates.push(candidate(28, "Show.S01E03.1080p.BRRip.x264", 1_018_303_956));
        candidates.push(candidate(29, "Show.S01E03.1080p.WEB.H264", 699_979_199));
        candidates.extend((30..80).map(|i| candidate(i, "Show.S01E03.720p.HEVC", i as u64)));
        candidates.push(candidates[0].clone());
        let ordered = discovery_order(candidates);
        assert_eq!(ordered.len(), 80, "do not discard the rest of the source list");
        assert_eq!(ordered.iter().take(4).map(|c| c.sid.as_str()).collect::<Vec<_>>(), ["0", "29", "1", "28"]);
    }

    #[tokio::test]
    async fn discovery_keeps_searching_after_three_dead_sources_and_retains_backups() {
        let coordinator = WarmCoordinator::new(2);
        let calls = AtomicUsize::new(0);
        let result = run_discovery(coordinator.clone(), 1, remuxes(12), Duration::from_secs(1), |candidate| {
            calls.fetch_add(1, Ordering::SeqCst);
            async move { candidate.sid.parse::<usize>().unwrap() >= 7 }
        }).await;
        assert_eq!(result.as_deref(), Some("7"));
        assert!(calls.load(Ordering::SeqCst) >= 10, "best source plus two ready backups");
        assert!(coordinator.active.lock().unwrap().is_empty());
        assert_eq!(coordinator.slots.available_permits(), 2);
    }

    #[tokio::test]
    async fn discovery_can_reach_the_last_source_beyond_old_caps() {
        let calls = AtomicUsize::new(0);
        let result = run_discovery(WarmCoordinator::new(4), 1, remuxes(80), Duration::from_secs(1), |candidate| {
            calls.fetch_add(1, Ordering::SeqCst);
            async move { candidate.sid == "79" }
        }).await;
        assert_eq!(result.as_deref(), Some("79"));
        assert_eq!(calls.load(Ordering::SeqCst), 80);
    }

    #[tokio::test]
    async fn discovery_keeps_best_quality_even_when_compatible_backups_finish_first() {
        let candidates = vec![
            candidate(0, "Show.2160p.REMUX.HEVC", 10_000),
            candidate(1, "Show.1080p.WEB.H264", 100),
            candidate(2, "Show.1080p.WEB.H264", 200),
        ];
        let result = run_discovery(WarmCoordinator::new(3), 1, candidates, Duration::from_secs(1), |candidate| async move {
            if candidate.sid == "0" { tokio::time::sleep(Duration::from_millis(20)).await; }
            true
        }).await;
        assert_eq!(result.as_deref(), Some("0"));
    }

    #[tokio::test]
    async fn concurrent_batches_share_source_claims_and_global_capacity() {
        let coordinator = WarmCoordinator::new(2);
        let calls = AtomicUsize::new(0);
        let active = AtomicUsize::new(0);
        let maximum = AtomicUsize::new(0);
        let probe = |_| async {
            calls.fetch_add(1, Ordering::SeqCst);
            let count = active.fetch_add(1, Ordering::SeqCst) + 1;
            maximum.fetch_max(count, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(10)).await;
            active.fetch_sub(1, Ordering::SeqCst);
            true
        };
        let (a, b) = tokio::join!(
            run_discovery(coordinator.clone(), 1, remuxes(4), Duration::from_secs(1), &probe),
            run_discovery(coordinator.clone(), 1, remuxes(4), Duration::from_secs(1), &probe),
        );
        assert!(a.is_some() || b.is_some());
        assert_eq!(calls.load(Ordering::SeqCst), 4, "concurrent viewers must not fetch each source twice");
        assert!(maximum.load(Ordering::SeqCst) <= 2);
        assert!(coordinator.active.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn cancelled_batch_releases_claims_and_slots() {
        let coordinator = WarmCoordinator::new(2);
        let result = tokio::time::timeout(Duration::from_millis(10), run_discovery(
            coordinator.clone(), 1, remuxes(8), Duration::from_secs(1), |_| async {
                std::future::pending::<bool>().await
            },
        )).await;
        assert!(result.is_err());
        assert!(coordinator.active.lock().unwrap().is_empty());
        assert_eq!(coordinator.slots.available_permits(), 2);
        assert_eq!(coordinator.batches.available_permits(), 4);
    }
}
