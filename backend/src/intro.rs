//! velvet-intro — skip-intro detection worker (the former standalone velvet-intro
//! Python worker, folded into the monolith).
//!
//! A background loop reads intro "jobs" straight from the shared SQLite DB (the
//! `play_reports` / `segments` tables the sync module owns — the same data the
//! standalone worker used to pull over HTTP from `/intro_work`). For each
//! `(show, season)` with un-analyzed episodes it:
//!
//!   1. Decodes the first `ANALYZE_SECS` of audio from each episode's stream URL
//!      (ffmpeg -> mono 11 kHz wav) and fingerprints it with chromaprint
//!      (`fpcalc -raw`).
//!   2. The first time a season is seen, cross-correlates two episodes'
//!      fingerprints to find the long audio segment they share = THE INTRO
//!      (recaps/cold opens differ per episode; the title sequence is bit-for-bit
//!      the same audio every week). That matched slice becomes the season's
//!      cached "reference intro".
//!   3. Every other episode is matched against the reference to find where ITS
//!      intro sits (cold-open length varies per episode, so the offset differs).
//!   4. Results are written straight to the `segments` table; episodes analyzed
//!      but with no intro found are recorded `source = "none"` so they are never
//!      re-downloaded.
//!
//! Matching is the classic chromaprint approach (same family as Jellyfin's Intro
//! Skipper): vote candidate alignments via an inverted index of fingerprint
//! frames, then walk the best alignments counting frames whose windowed-mean
//! hamming distance stays low; the longest low-distance run >= `MIN_INTRO_SECS`
//! is the shared segment.
//!
//! State (fingerprint cache, per-season reference, retry bookkeeping) lives in
//! `data_dir` as plain JSON — safe to wipe; everything regenerates. This is a
//! faithful port of `intro_worker.py`; the correlation constants were tuned to
//! ~1s accuracy on a synthetic rig and are preserved exactly.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use serde::{Deserialize, Serialize};
use tokio::process::Command as TokioCommand;

// ── constants (identical to the Python worker — do NOT retune) ───────────────

/// First 12 min of each episode gets fingerprinted.
const ANALYZE_SECS: u64 = 720;
const MIN_INTRO_SECS: f64 = 12.0;
const MAX_INTRO_SECS: f64 = 155.0;
// Matching judges a WINDOWED MEAN of per-frame hamming distance, not individual
// frames: unrelated aligned audio averages ~14-16 differing bits of 32, the same
// audio re-encoded averages well under 11 (validated: 2.0 on the synthetic rig).
const SMOOTH_FRAMES: usize = 16; // ~2s at chromaprint's ~8 frames/s
const MEAN_HAMMING: f64 = 11.0;
/// How many top-voted alignments get the full walk.
const OFFSET_CANDIDATES: usize = 40;
/// Reference-in-episode match: fraction of reference frames that must align.
const REF_MATCH_MIN: f64 = 0.55;
// Per-episode fetch failures: retry at most this many times, spaced this far
// apart, then record source="none" so the season stops re-surfacing.
const MAX_ATTEMPTS: u32 = 3;
const RETRY_SPACING_S: f64 = 6.0 * 3600.0;

// ── persisted state shapes ───────────────────────────────────────────────────

#[derive(Serialize, Deserialize)]
struct FpCache {
    fp: Vec<u32>,
    rate: f64,
}

#[derive(Deserialize)]
struct FpcalcOut {
    #[serde(default)]
    duration: Option<f64>,
    fingerprint: Vec<u32>,
}

#[derive(Serialize, Deserialize, Clone)]
struct Reference {
    /// The matched slice of fingerprint. Empty = analyzed but intro-less season.
    fp: Vec<u32>,
    rate: f64,
}

#[derive(Serialize, Deserialize, Clone, Copy)]
struct Attempt {
    n: u32,
    last: f64,
}

impl Default for Attempt {
    fn default() -> Self {
        Attempt { n: 0, last: 0.0 }
    }
}

#[derive(Serialize, Deserialize, Default)]
struct SeasonState {
    reference: Option<Reference>,
    #[serde(default)]
    attempts: HashMap<String, Attempt>,
}

/// A `(show, season)` unit of work: every reported episode + which lack segments.
struct Job {
    imdb: String,
    season: i64,
    episodes: Vec<(i64, String)>, // (episode, url), ordered by episode
    missing: Vec<i64>,
}

/// One segment row to write back: `episode -> (startMs, endMs, source)`.
struct SegmentResult {
    episode: i64,
    start_ms: i64,
    end_ms: i64,
    source: &'static str,
}

impl SegmentResult {
    fn none(episode: i64) -> Self {
        SegmentResult { episode, start_ms: 0, end_ms: 0, source: "none" }
    }
}

// ── time / hashing helpers ───────────────────────────────────────────────────

/// Seconds since the epoch (matches Python's `time.time()`).
fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Milliseconds since the epoch (matches `int(time.time() * 1000)`).
fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Stable per-URL cache key. The Python used `sha1(url)[:20]`; we use a
/// hand-rolled FNV-1a to avoid pulling in a hashing crate — only stability and
/// low collision within one data dir matter here.
fn fnv_hex(s: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

// ── sequence matching (faithful port of the Python correlation math) ─────────

/// Candidate alignments (`offset = position in b minus position in a`), voted by
/// an inverted index on exact frame values plus a low-bits-masked variant that
/// tolerates codec differences between releases. Returned ordered like Python's
/// `Counter.most_common`: vote count desc, then first-seen order asc (stable).
fn vote_offsets(a: &[u32], b: &[u32]) -> Vec<i64> {
    let mut counts: HashMap<i64, u32> = HashMap::new();
    let mut first_seen: HashMap<i64, u64> = HashMap::new();
    let mut seq: u64 = 0;
    for &mask_shift in &[0u32, 8u32] {
        let mut index: HashMap<u32, Vec<i64>> = HashMap::new();
        for (i, &v) in a.iter().enumerate() {
            index.entry(v >> mask_shift).or_default().push(i as i64);
        }
        for (j, &v) in b.iter().enumerate() {
            if let Some(list) = index.get(&(v >> mask_shift)) {
                for &i in list {
                    let off = j as i64 - i;
                    let c = counts.entry(off).or_insert(0);
                    if *c == 0 {
                        first_seen.insert(off, seq);
                        seq += 1;
                    }
                    *c += 1;
                }
            }
        }
    }
    let mut items: Vec<(i64, u32, u64)> =
        counts.iter().map(|(&off, &c)| (off, c, first_seen[&off])).collect();
    // most_common: highest count first; ties broken by first-inserted-first.
    items.sort_by(|x, y| y.1.cmp(&x.1).then(x.2.cmp(&y.2)));
    items.into_iter().take(OFFSET_CANDIDATES).map(|(off, _, _)| off).collect()
}

/// At alignment `off`, the longest contiguous stretch whose centered
/// `SMOOTH_FRAMES`-window mean hamming stays <= `MEAN_HAMMING`.
/// Returns `(start_in_a, end_in_a_exclusive, region_mean)`.
fn longest_region(a: &[u32], b: &[u32], off: i64) -> (i64, i64, f64) {
    let lo = 0i64.max(-off);
    let hi = (a.len() as i64).min(b.len() as i64 - off);
    let n = hi - lo;
    if n < (SMOOTH_FRAMES as i64) * 2 {
        return (0, 0, 99.0);
    }
    // prefix[k] = sum of per-frame hamming d[0..k]; d[k] aligns a[lo+k]^b[lo+k+off].
    let mut prefix: Vec<i64> = Vec::with_capacity((n + 1) as usize);
    prefix.push(0);
    for k in 0..n {
        let ai = (lo + k) as usize;
        let bi = (lo + k + off) as usize;
        let d = (a[ai] ^ b[bi]).count_ones() as i64;
        let last = *prefix.last().unwrap();
        prefix.push(last + d);
    }
    let half = (SMOOTH_FRAMES / 2) as i64; // 8
    let mut best: (i64, i64) = (0, 0);
    let mut cur: Option<i64> = None;
    let mut i = half;
    while i < n - half {
        let window = prefix[(i + half) as usize] - prefix[(i - half) as usize];
        if (window as f64) / ((2 * half) as f64) <= MEAN_HAMMING {
            if cur.is_none() {
                cur = Some(i);
            }
        } else {
            if let Some(c) = cur {
                if i - c > best.1 - best.0 {
                    best = (c, i);
                }
            }
            cur = None;
        }
        i += 1;
    }
    if let Some(c) = cur {
        if (n - half) - c > best.1 - best.0 {
            best = (c, n - half);
        }
    }
    let (s, e) = best;
    if e <= s {
        return (0, 0, 99.0);
    }
    let mean = (prefix[e as usize] - prefix[s as usize]) as f64 / (e - s) as f64;
    (lo + s, lo + e, mean)
}

/// The longest audio segment `fp_a` and `fp_b` share. Returns
/// `(a_start, a_end, b_start, b_end)` frame indices, or None.
fn common_segment(fp_a: &[u32], fp_b: &[u32], rate: f64) -> Option<(i64, i64, i64, i64)> {
    let mut best: Option<(i64, i64, i64)> = None; // (s, e, off)
    for off in vote_offsets(fp_a, fp_b) {
        let (s, e, _) = longest_region(fp_a, fp_b, off);
        match best {
            None => best = Some((s, e, off)),
            Some((bs, be, _)) if e - s > be - bs => best = Some((s, e, off)),
            _ => {}
        }
    }
    let (s, mut e, off) = best?;
    if (e - s) as f64 / rate < MIN_INTRO_SECS {
        return None;
    }
    // Overlong "shared" audio usually means the two URLs are the same release of
    // the same episode (mis-reported) — everything matches. Not an intro.
    if (e - s) as f64 / rate > MAX_INTRO_SECS * 2.0 {
        return None;
    }
    let cap = s + (MAX_INTRO_SECS * rate) as i64;
    if e > cap {
        e = cap;
    }
    Some((s, e, s + off, e + off))
}

/// Where the season's reference intro sits inside an episode fingerprint.
/// Returns `(start_frame, end_frame)` in the episode, or None. (`rate` is unused,
/// exactly as in the Python; kept out of the signature.)
fn locate_reference(ref_fp: &[u32], ep_fp: &[u32]) -> Option<(i64, i64)> {
    let mut best: Option<(i64, i64, i64)> = None; // (s, e, off)
    for off in vote_offsets(ref_fp, ep_fp) {
        let (s, e, _) = longest_region(ref_fp, ep_fp, off);
        match best {
            None => best = Some((s, e, off)),
            Some((bs, be, _)) if e - s > be - bs => best = Some((s, e, off)),
            _ => {}
        }
    }
    let (s, e, off) = best?;
    if ((e - s) as f64) < ref_fp.len() as f64 * REF_MATCH_MIN {
        return None;
    }
    // Map the matched slice of the reference into episode coordinates.
    Some((0i64.max(s + off), (ep_fp.len() as i64).min(e + off)))
}

// ── fingerprinting (ffmpeg + fpcalc, identical args to the Python) ───────────

static WAV_COUNTER: AtomicU64 = AtomicU64::new(0);

fn temp_wav() -> PathBuf {
    let n = WAV_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!("velvet_intro_{}_{}_{}.wav", std::process::id(), nanos, n))
}

/// `(fp list, frames-per-second)` for the first `ANALYZE_SECS` of a stream URL.
/// Cached in `data_dir` by URL hash. Returns Err on fetch/decode failure.
async fn fingerprint_url(url: &str, data_dir: &str) -> anyhow::Result<(Vec<u32>, f64)> {
    let cache = Path::new(data_dir).join(format!("fp_{}.json", fnv_hex(url)));
    if cache.exists() {
        if let Ok(bytes) = std::fs::read(&cache) {
            if let Ok(c) = serde_json::from_slice::<FpCache>(&bytes) {
                return Ok((c.fp, c.rate));
            }
        }
    }
    let wav = temp_wav();
    let result = decode_and_fingerprint(url, &wav).await;
    let _ = std::fs::remove_file(&wav); // finally: always clean up the temp wav
    let (fp, rate) = result?;
    if let Ok(json) = serde_json::to_vec(&FpCache { fp: fp.clone(), rate }) {
        let _ = std::fs::write(&cache, json);
    }
    Ok((fp, rate))
}

async fn decode_and_fingerprint(url: &str, wav: &Path) -> anyhow::Result<(Vec<u32>, f64)> {
    let secs = ANALYZE_SECS.to_string();
    // ffmpeg: decode the first ANALYZE_SECS to mono 11025 Hz wav. `-rw_timeout`
    // is a 30s stall guard on the http reader.
    let ff = tokio::time::timeout(
        Duration::from_secs(1200),
        TokioCommand::new("ffmpeg")
            .args([
                "-nostdin", "-loglevel", "error", "-y", "-rw_timeout", "30000000", "-i", url, "-t",
                &secs, "-vn", "-sn", "-ac", "1", "-ar", "11025", "-f", "wav",
            ])
            .arg(wav)
            .output(),
    )
    .await
    .context("ffmpeg timed out")?
    .context("spawn ffmpeg")?;
    if !ff.status.success() {
        anyhow::bail!("ffmpeg exit {:?}", ff.status.code());
    }
    // fpcalc: raw chromaprint fingerprint as JSON.
    let fc = tokio::time::timeout(
        Duration::from_secs(300),
        TokioCommand::new("fpcalc")
            .args(["-raw", "-json", "-length", &secs])
            .arg(wav)
            .output(),
    )
    .await
    .context("fpcalc timed out")?
    .context("spawn fpcalc")?;
    if !fc.status.success() {
        anyhow::bail!("fpcalc exit {:?}", fc.status.code());
    }
    let data: FpcalcOut = serde_json::from_slice(&fc.stdout).context("parse fpcalc json")?;
    let fp = data.fingerprint;
    // Mirror Python's `float(data.get("duration") or ANALYZE_SECS)`: None or 0
    // falls back to ANALYZE_SECS; a present nonzero (incl. negative) is kept and
    // then rejected by the <= 0 guard below.
    let duration = match data.duration {
        Some(d) if d != 0.0 => d,
        _ => ANALYZE_SECS as f64,
    };
    if fp.is_empty() || duration <= 0.0 {
        anyhow::bail!("empty fingerprint");
    }
    let rate = fp.len() as f64 / duration;
    Ok((fp, rate))
}

// ── per-season state files ───────────────────────────────────────────────────

fn season_path(data_dir: &str, imdb: &str, season: i64) -> PathBuf {
    Path::new(data_dir).join(format!("season_{imdb}_{season}.json"))
}

fn load_season(data_dir: &str, imdb: &str, season: i64) -> SeasonState {
    match std::fs::read(season_path(data_dir, imdb, season)) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => SeasonState::default(),
    }
}

fn save_season(data_dir: &str, imdb: &str, season: i64, state: &SeasonState) -> anyhow::Result<()> {
    let bytes = serde_json::to_vec(state)?;
    std::fs::write(season_path(data_dir, imdb, season), bytes)?;
    Ok(())
}

fn should_attempt(state: &SeasonState, episode: i64) -> bool {
    let a = state.attempts.get(&episode.to_string()).copied().unwrap_or_default();
    if a.n >= MAX_ATTEMPTS {
        return false;
    }
    now_secs() - a.last > RETRY_SPACING_S || a.n == 0
}

fn note_attempt(state: &mut SeasonState, episode: i64) {
    let a = state.attempts.entry(episode.to_string()).or_default();
    a.n += 1;
    a.last = now_secs();
}

fn ms(frame: i64, rate: f64) -> i64 {
    // int(frame / rate * 1000) — truncates toward zero for non-negative inputs.
    (frame as f64 / rate * 1000.0) as i64
}

// ── DB access (lock briefly, never across `.await` or a subprocess) ──────────

fn lock<'a>(
    db: &'a crate::db::Db,
) -> std::sync::MutexGuard<'a, rusqlite::Connection> {
    // Recover the guard from a poisoned mutex rather than panicking the worker.
    db.lock().unwrap_or_else(|p| p.into_inner())
}

/// The current job list: each `(imdb, season)` with reported episodes where some
/// episode lacks a `segments` row. Equivalent to the old `GET /intro_work`.
fn read_jobs(db: &crate::db::Db) -> anyhow::Result<Vec<Job>> {
    let conn = lock(db);
    let seasons: Vec<(String, i64)> = {
        let mut stmt = conn.prepare("SELECT DISTINCT imdb, season FROM play_reports")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    let mut jobs = Vec::new();
    for (imdb, season) in seasons {
        let episodes: Vec<(i64, String)> = {
            let mut stmt = conn.prepare(
                "SELECT episode, url FROM play_reports WHERE imdb = ? AND season = ? ORDER BY episode",
            )?;
            let rows = stmt.query_map(rusqlite::params![imdb, season], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })?;
            rows.collect::<Result<_, _>>()?
        };
        let done: HashSet<i64> = {
            let mut stmt =
                conn.prepare("SELECT episode FROM segments WHERE imdb = ? AND season = ?")?;
            let rows = stmt.query_map(rusqlite::params![imdb, season], |r| r.get::<_, i64>(0))?;
            rows.collect::<Result<_, _>>()?
        };
        let missing: Vec<i64> =
            episodes.iter().filter(|(e, _)| !done.contains(e)).map(|(e, _)| *e).collect();
        if !missing.is_empty() {
            jobs.push(Job { imdb, season, episodes, missing });
        }
    }
    Ok(jobs)
}

/// Write segment rows back. Equivalent to the old `POST /segments`.
fn write_segments(
    db: &crate::db::Db,
    imdb: &str,
    season: i64,
    results: &[SegmentResult],
) -> anyhow::Result<()> {
    let now = now_ms();
    let conn = lock(db);
    let mut stmt = conn.prepare(
        "INSERT OR REPLACE INTO segments (imdb, season, episode, start_ms, end_ms, source, updated_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?)",
    )?;
    for r in results {
        stmt.execute(rusqlite::params![
            imdb, season, r.episode, r.start_ms, r.end_ms, r.source, now
        ])?;
    }
    Ok(())
}

// ── per-season pipeline ──────────────────────────────────────────────────────

/// Fingerprint one episode; on failure count an attempt and, once `MAX_ATTEMPTS`
/// is hit, record `source="none"` so the episode stops re-surfacing.
async fn fp_for(
    state: &mut SeasonState,
    results: &mut Vec<SegmentResult>,
    imdb: &str,
    season: i64,
    ep: i64,
    url: &str,
    data_dir: &str,
) -> Option<(Vec<u32>, f64)> {
    match fingerprint_url(url, data_dir).await {
        Ok(v) => Some(v),
        Err(e) => {
            tracing::info!("[intro] {} S{}E{}: fingerprint failed ({})", imdb, season, ep, e);
            note_attempt(state, ep);
            let n = state.attempts.get(&ep.to_string()).map(|a| a.n).unwrap_or(0);
            if n >= MAX_ATTEMPTS {
                results.push(SegmentResult::none(ep));
            }
            None
        }
    }
}

async fn process_job(db: &crate::db::Db, data_dir: &str, job: &Job) -> anyhow::Result<()> {
    let imdb = job.imdb.as_str();
    let season = job.season;
    let urls: HashMap<i64, String> = job.episodes.iter().cloned().collect();
    let mut missing = job.missing.clone();
    missing.sort_unstable();
    let mut sorted_eps: Vec<i64> = urls.keys().copied().collect();
    sorted_eps.sort_unstable();

    let mut state = load_season(data_dir, imdb, season);
    let mut results: Vec<SegmentResult> = Vec::new();

    // 1. Establish the season reference from the two lowest-numbered episodes.
    if state.reference.is_none() {
        let candidates: Vec<i64> =
            sorted_eps.iter().copied().filter(|&e| should_attempt(&state, e)).collect();
        let mut pair: Vec<(i64, (Vec<u32>, f64))> = Vec::new();
        for ep in candidates {
            let url = urls[&ep].clone();
            if let Some(got) =
                fp_for(&mut state, &mut results, imdb, season, ep, &url, data_dir).await
            {
                pair.push((ep, got));
            }
            if pair.len() == 2 {
                break;
            }
        }
        if pair.len() < 2 {
            save_season(data_dir, imdb, season, &state)?;
            if !results.is_empty() {
                write_segments(db, imdb, season, &results)?;
            }
            return Ok(());
        }
        let mut it = pair.into_iter();
        let (ep_a, (fp_a, rate_a)) = it.next().unwrap();
        let (ep_b, (fp_b, rate_b)) = it.next().unwrap();
        match common_segment(&fp_a, &fp_b, rate_a) {
            None => {
                tracing::info!("[intro] {} S{}: no common intro between E{}/E{}", imdb, season, ep_a, ep_b);
                results.push(SegmentResult::none(ep_a));
                results.push(SegmentResult::none(ep_b));
                state.reference = Some(Reference { fp: Vec::new(), rate: rate_a }); // intro-less season
            }
            Some((a_s, a_e, b_s, b_e)) => {
                state.reference =
                    Some(Reference { fp: fp_a[a_s as usize..a_e as usize].to_vec(), rate: rate_a });
                results.push(SegmentResult {
                    episode: ep_a,
                    start_ms: ms(a_s, rate_a),
                    end_ms: ms(a_e, rate_a),
                    source: "fingerprint",
                });
                results.push(SegmentResult {
                    episode: ep_b,
                    start_ms: ms(b_s, rate_b),
                    end_ms: ms(b_e, rate_b),
                    source: "fingerprint",
                });
                tracing::info!(
                    "[intro] {} S{}: intro locked from E{}/E{} ({:.1}s @ {:.1}s)",
                    imdb,
                    season,
                    ep_a,
                    ep_b,
                    (a_e - a_s) as f64 / rate_a,
                    a_s as f64 / rate_a,
                );
            }
        }
    }

    // 2. Match every remaining missing episode against the reference.
    let reference = match state.reference.clone() {
        Some(r) => r,
        None => {
            // Only reachable if step 1 could not establish a reference; nothing
            // more to do this pass.
            save_season(data_dir, imdb, season, &state)?;
            return Ok(());
        }
    };
    let done: HashSet<i64> = results.iter().map(|r| r.episode).collect();
    for ep in missing.iter().copied() {
        if done.contains(&ep) || !urls.contains_key(&ep) {
            continue;
        }
        if reference.fp.is_empty() {
            results.push(SegmentResult::none(ep));
            continue;
        }
        if !should_attempt(&state, ep) {
            continue;
        }
        let url = urls[&ep].clone();
        let got = fp_for(&mut state, &mut results, imdb, season, ep, &url, data_dir).await;
        let (ep_fp, ep_rate) = match got {
            Some(g) => g,
            None => continue,
        };
        match locate_reference(&reference.fp, &ep_fp) {
            None => {
                tracing::info!("[intro] {} S{}E{}: reference not found", imdb, season, ep);
                results.push(SegmentResult::none(ep));
            }
            Some((s, e)) => {
                results.push(SegmentResult {
                    episode: ep,
                    start_ms: ms(s, ep_rate),
                    end_ms: ms(e, ep_rate),
                    source: "fingerprint",
                });
                tracing::info!("[intro] {} S{}E{}: intro at {:.1}s", imdb, season, ep, s as f64 / ep_rate);
            }
        }
    }

    save_season(data_dir, imdb, season, &state)?;
    if !results.is_empty() {
        write_segments(db, imdb, season, &results)?;
        tracing::info!("[intro] {} S{}: wrote {} segment rows", imdb, season, results.len());
    }
    Ok(())
}

// ── the background loop ──────────────────────────────────────────────────────

/// Background worker: poll the DB for intro jobs and process them forever.
/// Never panics the process — every job error is logged and skipped.
pub async fn run(db: crate::db::Db, data_dir: String, poll_secs: u64) {
    if let Err(e) = std::fs::create_dir_all(&data_dir) {
        tracing::warn!("[intro] could not create data dir {}: {}", data_dir, e);
    }
    tracing::info!("[intro] velvet-intro worker up — analyze={}s, data={}", ANALYZE_SECS, data_dir);
    loop {
        match read_jobs(&db) {
            Ok(jobs) => {
                for job in jobs {
                    if let Err(e) = process_job(&db, &data_dir, &job).await {
                        tracing::warn!("[intro] job {} S{} failed: {}", job.imdb, job.season, e);
                    }
                }
            }
            Err(e) => tracing::warn!("[intro] read jobs failed: {}", e),
        }
        tokio::time::sleep(Duration::from_secs(poll_secs)).await;
    }
}

// ── unit tests for the pure correlation math ─────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic pseudo-random u32 stream (Numerical-Recipes-style 64-bit
    /// LCG, high 32 bits) — no external crates.
    struct Lcg(u64);
    impl Lcg {
        fn next_u32(&mut self) -> u32 {
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (self.0 >> 32) as u32
        }
    }

    fn rand_vec(seed: u64, n: usize) -> Vec<u32> {
        let mut l = Lcg(seed);
        (0..n).map(|_| l.next_u32()).collect()
    }

    // A shared intro of K frames embedded in two episodes whose cold opens differ
    // in length, so the alignment offset differs: exactly the real-world case.
    const K: usize = 240;
    const A_PREFIX: usize = 50;
    const B_PREFIX: usize = 120;
    const TRUE_OFF: i64 = (B_PREFIX as i64) - (A_PREFIX as i64); // 70
    const RATE: f64 = 8.0;

    fn build_pair() -> (Vec<u32>, Vec<u32>, Vec<u32>) {
        let intro = rand_vec(0xBEEF, K);
        let mut fp_a = rand_vec(0xA1, A_PREFIX);
        fp_a.extend_from_slice(&intro);
        fp_a.extend(rand_vec(0xA2, 300));
        let mut fp_b = rand_vec(0xB1, B_PREFIX);
        fp_b.extend_from_slice(&intro);
        fp_b.extend(rand_vec(0xB2, 250));
        (fp_a, fp_b, intro)
    }

    #[test]
    fn vote_offsets_finds_the_true_alignment() {
        let (fp_a, fp_b, _) = build_pair();
        let offs = vote_offsets(&fp_a, &fp_b);
        assert!(!offs.is_empty());
        // The K identical intro frames dominate the vote for the true offset.
        assert_eq!(offs[0], TRUE_OFF, "top-voted offset should be the intro alignment");
    }

    #[test]
    fn longest_region_at_true_offset_spans_the_intro() {
        let (fp_a, fp_b, _) = build_pair();
        let (s, e, mean) = longest_region(&fp_a, &fp_b, TRUE_OFF);
        let len = e - s;
        // Region should be ~K frames (fuzzy by a few frames at the boundaries).
        assert!(len >= K as i64 - 24 && len <= K as i64 + 24, "region len {len} not ~{K}");
        // Starts near the true intro start in a (frame 50).
        assert!((s - A_PREFIX as i64).abs() <= 16, "region start {s} not near {A_PREFIX}");
        // The matched region is almost all zero-hamming.
        assert!(mean < 5.0, "region mean {mean} too high for a real match");
    }

    #[test]
    fn common_segment_locates_the_shared_intro() {
        let (fp_a, fp_b, _) = build_pair();
        let seg = common_segment(&fp_a, &fp_b, RATE).expect("intro should be found");
        let (a_s, a_e, b_s, b_e) = seg;
        // b coordinates are exactly a coordinates shifted by the winning offset.
        assert_eq!(b_s - a_s, TRUE_OFF, "b start must be a start + offset");
        assert_eq!(b_e - a_e, TRUE_OFF, "b end must be a end + offset");
        // Long enough to clear the MIN_INTRO_SECS gate, not an over-match.
        let len = a_e - a_s;
        assert!(len as f64 / RATE >= MIN_INTRO_SECS, "detected intro too short");
        assert!(len <= K as i64 + SMOOTH_FRAMES as i64, "detected region unexpectedly large");
        // Located within the true intro span in a ([50, 290)).
        assert!((a_s - A_PREFIX as i64).abs() <= 16, "a start {a_s} not near {A_PREFIX}");
    }

    #[test]
    fn common_segment_rejects_unrelated_fingerprints() {
        let fp_x = rand_vec(0x1111, 400);
        let fp_y = rand_vec(0x2222, 400);
        // No shared audio run -> nothing >= MIN_INTRO_SECS.
        assert!(common_segment(&fp_x, &fp_y, RATE).is_none());
    }

    #[test]
    fn locate_reference_places_intro_in_episode() {
        let (_, fp_b, intro) = build_pair();
        // The cached reference is the intro itself; ep_fp is episode B, whose
        // intro sits at [B_PREFIX, B_PREFIX+K). The matched slice is exact, so
        // the result is fully deterministic: [half, K-half) mapped by offset
        // B_PREFIX -> [B_PREFIX + half, B_PREFIX + K - half).
        let loc = locate_reference(&intro, &fp_b).expect("reference must be located");
        let half = (SMOOTH_FRAMES / 2) as i64;
        let expect_s = B_PREFIX as i64 + half;
        let expect_e = B_PREFIX as i64 + K as i64 - half;
        assert_eq!(loc, (expect_s, expect_e), "located intro span mismatch");
        // And it comfortably clears the REF_MATCH_MIN fraction.
        assert!((loc.1 - loc.0) as f64 >= intro.len() as f64 * REF_MATCH_MIN);
    }
}
