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

use std::sync::Arc;

use crate::config::Indexer;
use crate::db::Db;
use crate::resolver::{search_movie, search_series, NzbResult};
use crate::stream::{warm_head, StreamState};

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

/// Fire-and-forget warm of already-registered stream ids, best-first: the first
/// one that loads gets warmed; the rest are skipped. Failures are loud (warn) —
/// a silent warm failure looks identical to "warm engine not running".
pub fn spawn_warm_streams(st: StreamState, sids: Vec<String>) {
    tokio::spawn(async move {
        for sid in sids {
            match warm_head(st.clone(), sid.clone(), None).await {
                Ok(()) => return,
                Err(e) => tracing::warn!("warm {sid} failed: {e} — trying next candidate"),
            }
        }
    });
}

/// Rank results with the same hierarchy the resolver endpoint serves.
fn sort_results(results: &mut Vec<NzbResult>) {
    results.sort_by(|a, b| crate::release::cmp_streams(&a.title, a.size, &b.title, b.size));
}

/// Resolve a title and warm the best loadable candidate (tries the top 3).
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

    for r in results.iter().filter(|r| !st.is_condemned(&r.nzb_url)).take(3) {
        let sid = st.register(&r.nzb_url).await;
        match warm_head(st.clone(), sid.clone(), req.fraction).await {
            Ok(()) => {
                tracing::info!(
                    "prewarmed {} tt{imdb} s{}e{}: {}",
                    if req.kind == WarmKind::Series { "series" } else { "movie" },
                    req.season,
                    req.episode,
                    r.title
                );
                return true;
            }
            Err(e) => tracing::debug!("warm candidate failed ({}): {e}", r.title),
        }
    }
    false
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
