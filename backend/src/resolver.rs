//! Stremio-protocol resolver: query newznab indexers for an IMDb id, get back a
//! ranked list of NZBs. (Availability-checking + release parsing land next; this
//! is the query + NZB-download half.)

use quick_xml::events::Event;
use quick_xml::Reader;

use crate::config::Indexer;

#[derive(Debug, Clone)]
pub struct NzbResult {
    pub title: String,
    /// URL that returns the .nzb file itself (newznab <enclosure>).
    pub nzb_url: String,
    pub size: u64,
    pub indexer: String,
    /// Explicit indexer identity can verify legitimate scene aliases/country
    /// tags without making a broad text-search title match permissive.
    pub imdb_id: Option<String>,
}

/// Metadata credentials are supplied at runtime and are never bundled.
pub(crate) fn tmdb_key() -> String {
    std::env::var("VELVET_TMDB_KEY").unwrap_or_default().trim().to_owned()
}

/// imdb digits → (title, year) via TMDB find-by-external-id, cached for the
/// process lifetime. Brand-new releases often exist on indexers before the
/// indexer's own IMDb mapping does — the title is what unlocks them.
async fn imdb_meta(
    client: &reqwest::Client,
    imdb_digits: &str,
    series: bool,
) -> Option<(String, Option<String>)> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, (String, Option<String>)>>> =
        std::sync::OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    let key = format!("{}{}", if series { "s" } else { "m" }, imdb_digits);
    if let Some(hit) = cache.lock().unwrap().get(&key).cloned() {
        return Some(hit);
    }
    let api_key = tmdb_key();
    if api_key.is_empty() { return None; }
    let url = format!(
        "https://api.themoviedb.org/3/find/tt{}?external_source=imdb_id&api_key={}",
        imdb_digits,
        api_key
    );
    let v: serde_json::Value = client.get(&url).send().await.ok()?.json().await.ok()?;
    // Prefer the bucket matching the kind, but take the other if it's all we have.
    let buckets: [&str; 2] = if series {
        ["tv_results", "movie_results"]
    } else {
        ["movie_results", "tv_results"]
    };
    let hit = buckets.iter().find_map(|b| v.get(b)?.get(0)).cloned()?;
    let title = hit
        .get("name")
        .or_else(|| hit.get("title"))?
        .as_str()?
        .to_string();
    let year = hit
        .get("first_air_date")
        .or_else(|| hit.get("release_date"))
        .and_then(|d| d.as_str())
        .and_then(|d| d.get(..4))
        .map(str::to_string);
    cache.lock().unwrap().insert(key, (title.clone(), year.clone()));
    Some((title, year))
}

/// Make a title safe as a newznab `q=`: "&"→"and", punctuation→spaces,
/// collapsed, lowercased — "HIS & HERS" → "his and hers".
fn sanitize_query(title: &str) -> String {
    let mut out = String::with_capacity(title.len() + 8);
    let mut last_space = true;
    for c in title.to_lowercase().replace('&', " and ").chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
            last_space = false;
        } else if !last_space {
            out.push(' ');
            last_space = true;
        }
    }
    out.trim_end().to_string()
}

async fn fetch_results(
    client: &reqwest::Client,
    ix: &Indexer,
    query: &str,
) -> anyhow::Result<Vec<NzbResult>> {
    let url = format!("{}/api?{}&apikey={}&extended=1&o=xml", ix.url.trim_end_matches('/'), query, ix.api_key);
    let body = client.get(&url).send().await?.error_for_status()?.text().await?;
    Ok(parse_newznab(&body, &ix.name))
}

/// newznab movie lookup by IMDb id (digits only, no "tt"), falling back to a
/// title (+year) search when the id turns up nothing — new movies are often
/// indexed before the indexer's IMDb mapping catches up.
pub async fn search_movie(
    client: &reqwest::Client,
    ix: &Indexer,
    imdb_digits: &str,
) -> anyhow::Result<Vec<NzbResult>> {
    let out = fetch_results(client, ix, &format!("t=movie&imdbid={imdb_digits}")).await?;
    if !out.is_empty() {
        return Ok(out);
    }
    let Some((title, year)) = imdb_meta(client, imdb_digits, false).await else {
        return Ok(out);
    };
    title_chain_movie(client, ix, &title, year).await
}

/// newznab TV lookup by IMDb id + season/episode, with the same title-based
/// fallback chain (tvsearch by q, then a generic "title sXXeYY" search).
pub async fn search_series(
    client: &reqwest::Client,
    ix: &Indexer,
    imdb_digits: &str,
    season: u32,
    episode: u32,
) -> anyhow::Result<Vec<NzbResult>> {
    let query = format!("t=tvsearch&imdbid={imdb_digits}&season={season}&ep={episode}");
    let (out, metadata) = tokio::join!(
        fetch_results(client, ix, &query),
        imdb_meta(client, imdb_digits, true),
    );
    let out = out?;
    let Some((title, year)) = metadata else {
        // Verified identifier results remain usable when metadata is down;
        // never run or trust an unverified broad search in that case.
        return Ok(matching_series_results(out, "", None, Some(imdb_digits), season, episode));
    };
    let out = matching_series_results(out, &title, year.as_deref(), Some(imdb_digits), season, episode);
    if !out.is_empty() {
        return Ok(out);
    }
    title_chain_series(client, ix, &title, year.as_deref(), Some(imdb_digits), season, episode).await
}

/// Title-based movie search: t=movie by q(+year), then a generic text search.
async fn title_chain_movie(
    client: &reqwest::Client,
    ix: &Indexer,
    title: &str,
    year: Option<String>,
) -> anyhow::Result<Vec<NzbResult>> {
    let q = sanitize_query(title).replace(' ', "%20");
    let year_q = year.map(|y| format!("&year={y}")).unwrap_or_default();
    let by_title = fetch_results(client, ix, &format!("t=movie&q={q}{year_q}")).await?;
    if !by_title.is_empty() {
        return Ok(by_title);
    }
    fetch_results(client, ix, &format!("t=search&q={q}")).await
}

/// Title-based episode search: tvsearch by q, then generic "title sXXeYY" —
/// the generic step is what finds day-one releases the indexer hasn't mapped
/// to ANY id yet (its tvsearch needs the show mapping; plain text does not).
async fn title_chain_series(
    client: &reqwest::Client,
    ix: &Indexer,
    title: &str,
    year: Option<&str>,
    imdb_digits: Option<&str>,
    season: u32,
    episode: u32,
) -> anyhow::Result<Vec<NzbResult>> {
    let q = sanitize_query(title).replace(' ', "%20");
    let by_title = matching_series_results(
        fetch_results(client, ix, &format!("t=tvsearch&q={q}&season={season}&ep={episode}")).await?,
        title, year, imdb_digits, season, episode,
    );
    if !by_title.is_empty() {
        return Ok(by_title);
    }
    let generic = fetch_results(client, ix, &format!("t=search&q={q}%20s{season:02}e{episode:02}")).await?;
    Ok(matching_series_results(generic, title, year, imdb_digits, season, episode))
}

/// Indexer text searches are word searches, not show-identity checks. In
/// particular, searching for Friends also returns Friends Like These, Smiling
/// Friends, and unrelated episodes with "friends" in the episode name. Verify
/// the entire show name before the episode marker before ranking or warming.
fn matching_series_results(
    results: Vec<NzbResult>,
    title: &str,
    year: Option<&str>,
    imdb_digits: Option<&str>,
    season: u32,
    episode: u32,
) -> Vec<NzbResult> {
    let expected_imdb = imdb_digits.and_then(normalized_imdb);
    results.into_iter().filter(|result| {
        if let (Some(expected), Some(actual)) = (&expected_imdb, &result.imdb_id) {
            // The requested ID alone is not evidence: verify the ID actually
            // attached to this result. This permits e.g. Shameless.US and
            // translated scene names, while rejecting other Friends shows.
            return expected == actual && series_episode_identity(&result.title)
                .is_some_and(|(_, s, e)| (s, e) == (season, episode));
        }
        series_release_matches(&result.title, title, year, season, episode)
    }).collect()
}

fn canonical_series_title(title: &str) -> String {
    title.to_lowercase().replace('&', "and").chars().filter(|c| c.is_alphanumeric()).collect()
}

fn series_release_matches(release: &str, title: &str, year: Option<&str>, season: u32, episode: u32) -> bool {
    let expected = canonical_series_title(title);
    if expected.is_empty() { return false; }
    let Some((mut prefix, release_season, release_episode)) = series_episode_identity(release) else { return false; };
    if (release_season, release_episode) != (season, episode) { return false; }
    // Scene/uploader tags sometimes precede the actual show name.
    while let Some(rest) = prefix.strip_prefix('[') {
        let Some(end) = rest.find(']') else { break; };
        prefix = rest[end + 1..].trim_start_matches(|c: char| !c.is_alphanumeric() && c != '[');
    }
    if canonical_series_title(prefix) == expected { return true; }
    // A release may disambiguate reboots by the show's first-air year.
    // Only remove this suffix after trying the full title (e.g. "1883").
    let words = sanitize_query(prefix);
    if let Some((name, release_year)) = words.rsplit_once(' ') {
        if release_year.len() == 4 && release_year.bytes().all(|b| b.is_ascii_digit()) {
            return canonical_series_title(name) == expected && year == Some(release_year);
        }
    }
    false
}

fn series_episode_identity(release: &str) -> Option<(&str, u32, u32)> {
    let lower = release.to_ascii_lowercase();
    let bytes = lower.as_bytes();
    for start in 0..bytes.len() {
        if start > 0 && bytes[start - 1].is_ascii_alphanumeric() { continue; }
        let mut pos = start;
        let prefixed = bytes[pos] == b's';
        if prefixed { pos += 1; }
        let Some(release_season) = episode_number(bytes, &mut pos) else { continue; };
        if prefixed {
            while bytes.get(pos).is_some_and(|b| matches!(b, b' ' | b'.' | b'_' | b'-')) { pos += 1; }
        }
        let separator = if prefixed { b'e' } else { b'x' };
        if bytes.get(pos) != Some(&separator) { continue; }
        pos += 1;
        let Some(release_episode) = episode_number(bytes, &mut pos) else { continue; };
        if bytes.get(pos).is_some_and(u8::is_ascii_alphanumeric) { continue; }
        return Some((release[..start].trim(), release_season, release_episode));
    }
    None
}

fn normalized_imdb(value: &str) -> Option<String> {
    let digits = value.trim().strip_prefix("tt").unwrap_or(value.trim());
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) { return None; }
    let digits = digits.trim_start_matches('0');
    (!digits.is_empty()).then(|| digits.to_string())
}

fn episode_number(bytes: &[u8], pos: &mut usize) -> Option<u32> {
    let start = *pos;
    let mut value = 0u32;
    while let Some(digit) = bytes.get(*pos).filter(|b| b.is_ascii_digit()) {
        value = value.checked_mul(10)?.checked_add((digit - b'0') as u32)?;
        *pos += 1;
    }
    (*pos > start).then_some(value)
}

/// TMDB id → (title, year), for shows so new they have NO imdb/tvdb mapping
/// anywhere (the app then sends `tmdb:<id>` instead of a tt id). Cached.
async fn tmdb_title(
    client: &reqwest::Client,
    tmdb_id: &str,
    series: bool,
) -> Option<(String, Option<String>)> {
    static CACHE: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, (String, Option<String>)>>> =
        std::sync::OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    let key = format!("T{}{}", if series { "s" } else { "m" }, tmdb_id);
    if let Some(hit) = cache.lock().unwrap().get(&key).cloned() {
        return Some(hit);
    }
    let kind = if series { "tv" } else { "movie" };
    let api_key = tmdb_key();
    if api_key.is_empty() { return None; }
    let url = format!("https://api.themoviedb.org/3/{kind}/{tmdb_id}?api_key={api_key}");
    let v: serde_json::Value = client.get(&url).send().await.ok()?.json().await.ok()?;
    let title = v.get("name").or_else(|| v.get("title"))?.as_str()?.to_string();
    let year = v
        .get("first_air_date")
        .or_else(|| v.get("release_date"))
        .and_then(|d| d.as_str())
        .and_then(|d| d.get(..4))
        .map(str::to_string);
    cache.lock().unwrap().insert(key, (title.clone(), year.clone()));
    Some((title, year))
}

/// Movie lookup by TMDB id (no imdb exists yet): straight to the title chain.
pub async fn search_movie_tmdb(
    client: &reqwest::Client,
    ix: &Indexer,
    tmdb_id: &str,
) -> anyhow::Result<Vec<NzbResult>> {
    let Some((title, year)) = tmdb_title(client, tmdb_id, false).await else {
        return Ok(Vec::new());
    };
    title_chain_movie(client, ix, &title, year).await
}

/// Episode lookup by TMDB id (no imdb exists yet): straight to the title chain.
pub async fn search_series_tmdb(
    client: &reqwest::Client,
    ix: &Indexer,
    tmdb_id: &str,
    season: u32,
    episode: u32,
) -> anyhow::Result<Vec<NzbResult>> {
    let Some((title, year)) = tmdb_title(client, tmdb_id, true).await else {
        return Ok(Vec::new());
    };
    title_chain_series(client, ix, &title, year.as_deref(), None, season, episode).await
}

pub async fn download_nzb(client: &reqwest::Client, url: &str) -> anyhow::Result<Vec<u8>> {
    // Big releases have big NZBs (tens of MB) — allow well past the client's
    // default 60s total-request timeout.
    let bytes = client
        .get(url)
        .timeout(std::time::Duration::from_secs(300))
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?;
    Ok(bytes.to_vec())
}

// ─── Stremio-protocol HTTP endpoints ─────────────────────────────────────────

use axum::extract::{Path, State};
use axum::response::IntoResponse;
use axum::Json;
use serde_json::json;

/// State for the resolver endpoints: registers NZBs with the range server and
/// knows the public URL to build stream links against.
#[derive(Clone)]
pub struct ResolverState {
    pub stream: crate::stream::StreamState,
    pub indexers: std::sync::Arc<Vec<Indexer>>,
    pub public_base: String,
}

pub fn router(state: ResolverState) -> axum::Router {
    axum::Router::new()
        .route("/manifest.json", axum::routing::get(manifest))
        .route("/stream/:kind/:id", axum::routing::get(streams))
        .with_state(state)
}

async fn manifest() -> impl IntoResponse {
    Json(json!({
        "id": "tv.velvet.backend",
        "version": env!("CARGO_PKG_VERSION"),
        "name": "Velvet",
        "description": "Self-hosted usenet streaming for Velvet.",
        "resources": ["stream"],
        "types": ["movie", "series"],
        "catalogs": [],
    }))
}

/// GET /stream/{movie|series}/{id}.json — the app-compatible stream list. `id`
/// is `tt123` for movies or `tt123:season:episode` for series (with `.json`).
async fn streams(
    State(st): State<ResolverState>,
    Path((kind, id)): Path<(String, String)>,
) -> impl IntoResponse {
    let id = id.strip_suffix(".json").unwrap_or(&id);
    let parts: Vec<&str> = id.split(':').collect();
    // Two id forms: `tt123[:s:e]` (imdb) and `tmdb:299939[:s:e]` — the apps send
    // the latter when a title is so new TMDB has no imdb mapping for it yet.
    let is_tmdb = parts[0] == "tmdb";
    let key = if is_tmdb { parts.get(1).copied().unwrap_or("") } else { parts[0].trim_start_matches("tt") };
    let se_at = if is_tmdb { 2 } else { 1 };
    let se: Option<(u32, u32)> = if kind == "series" && parts.len() >= se_at + 2 {
        Some((
            parts[se_at].parse().unwrap_or(0),
            parts[se_at + 1].parse().unwrap_or(0),
        ))
    } else {
        None
    };

    // Query every indexer, merge results.
    let mut results: Vec<NzbResult> = Vec::new();
    for ix in st.indexers.iter() {
        let r = match (is_tmdb, se) {
            (false, Some((s, e))) => search_series(&st.stream.http, ix, key, s, e).await,
            (false, None) => search_movie(&st.stream.http, ix, key).await,
            (true, Some((s, e))) => search_series_tmdb(&st.stream.http, ix, key, s, e).await,
            (true, None) => search_movie_tmdb(&st.stream.http, ix, key).await,
        };
        if let Ok(mut list) = r {
            results.append(&mut list);
        }
    }

    // Server-side ordering (benefits every Stremio client, not just Velvet).
    // Full quality hierarchy — "the actual best quality possible" first:
    //   1. 2D before 3D            (3D is almost never wanted on a flat screen)
    //   2. resolution              (4K > 1080p > 720p > …)
    //   3. remux over re-encode    (untouched disc bitrate)
    //   4. dynamic range           (Dolby Vision > HDR10+ > HDR10/HDR > SDR)
    //   5. audio                   (TrueHD Atmos > DTS-X > TrueHD > DTS-HD MA > …)
    //   6. size                    (within the same tier, bigger ≈ higher bitrate)
    results.sort_by(|a, b| crate::release::cmp_streams(&a.title, a.size, &b.title, b.size));

    // De-dupe by title, register each NZB, and shape as Stremio streams. The raw
    // release title still rides through so the app's own tag parse + 3D badge apply.
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    let mut top_sids: Vec<String> = Vec::new();
    let mut all_sids: Vec<String> = Vec::new();
    for r in results {
        if !seen.insert(r.title.clone()) {
            continue;
        }
        // Never offer a release the verifier has condemned (missing articles) —
        // this is what makes each mid-play failure a one-time event instead of
        // a nightly ritual.
        if st.stream.is_condemned(&r.nzb_url) {
            continue;
        }
        let stream_id = st.stream.register(&r.nzb_url).await;
        all_sids.push(stream_id.clone());
        if top_sids.len() < 3 {
            top_sids.push(stream_id.clone());
        }
        let url = format!("{}/stream/{}", st.public_base.trim_end_matches('/'), stream_id);
        let quality = crate::release::quality(&r.title).unwrap_or("");
        out.push(json!({
            "name": format!("Velvet{}", if quality.is_empty() { String::new() } else { format!(" {quality}") }),
            "title": r.title,
            "url": url,
            "behaviorHints": {
                "filename": r.title,
                "videoSize": r.size,
                "bingeGroup": format!("velvet-{}", release_group(&r.title)),
            },
        }));
    }

    // Instant play: pre-warm the best loadable candidate in the background — by
    // the time the user presses Play, the NZB is parsed, extents are built, and
    // the head segments are already in the cache. Tries the top 3 in order, so a
    // broken #1 doesn't leave Play cold (the app's autopick skips it too).
    st.stream.set_recovery_candidates(&all_sids);
    crate::warm::spawn_warm_streams(st.stream.clone(), top_sids);

    Json(json!({ "streams": out }))
}

/// The release group ("-TSRG") drives bingeGroup so autoplay-next stays on the
/// same source chain across episodes.
fn release_group(title: &str) -> String {
    title
        .rsplit(['-', '.'])
        .next()
        .unwrap_or("rls")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(16)
        .collect::<String>()
        .to_lowercase()
}

/// Parse a newznab RSS response: each <item> carries a <title> and an
/// <enclosure url=… length=…> pointing at the NZB.
fn parse_newznab(xml: &str, indexer: &str) -> Vec<NzbResult> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut out = Vec::new();
    let mut buf = Vec::new();
    let mut in_item = false;
    let mut cur_title = String::new();
    let mut cur_url = String::new();
    let mut cur_size = 0u64;
    let mut cur_imdb = None;
    let mut want_title_text = false;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => match e.name().as_ref() {
                b"item" => {
                    in_item = true;
                    cur_title.clear();
                    cur_url.clear();
                    cur_size = 0;
                    cur_imdb = None;
                }
                b"title" if in_item => want_title_text = true,
                _ => {}
            },
            Ok(Event::Empty(e)) => {
                if in_item {
                    match e.name().as_ref() {
                        b"enclosure" => {
                            for a in e.attributes().flatten() {
                                match a.key.as_ref() {
                                    b"url" => {
                                        cur_url =
                                            a.unescape_value().unwrap_or_default().into_owned()
                                    }
                                    b"length" => {
                                        cur_size = a
                                            .unescape_value()
                                            .unwrap_or_default()
                                            .parse()
                                            .unwrap_or(0)
                                    }
                                    _ => {}
                                }
                            }
                        }
                        // <newznab:attr name="size" value="…"/> — more reliable size.
                        b"newznab:attr" | b"attr" => {
                            let mut name = String::new();
                            let mut value = String::new();
                            for a in e.attributes().flatten() {
                                match a.key.as_ref() {
                                    b"name" => {
                                        name = a.unescape_value().unwrap_or_default().into_owned()
                                    }
                                    b"value" => {
                                        value = a.unescape_value().unwrap_or_default().into_owned()
                                    }
                                    _ => {}
                                }
                            }
                            if name == "size" {
                                if let Ok(v) = value.parse() {
                                    cur_size = v;
                                }
                            }
                            if name == "imdb" || name == "imdbid" {
                                cur_imdb = normalized_imdb(&value);
                            }
                        }
                        _ => {}
                    }
                }
            }
            Ok(Event::Text(e)) if want_title_text => {
                cur_title = e.unescape().unwrap_or_default().into_owned();
                want_title_text = false;
            }
            Ok(Event::End(e)) => {
                if e.name().as_ref() == b"item" && in_item {
                    in_item = false;
                    if !cur_url.is_empty() {
                        out.push(NzbResult {
                            title: std::mem::take(&mut cur_title),
                            nzb_url: std::mem::take(&mut cur_url),
                            size: cur_size,
                            indexer: indexer.to_string(),
                            imdb_id: cur_imdb.take(),
                        });
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    out
}


#[cfg(test)]
mod fallback_tests {
    use super::*;

    #[test]
    fn query_sanitizing() {
        assert_eq!(super::sanitize_query("HIS & HERS"), "his and hers");
        assert_eq!(super::sanitize_query("Spider-Man: Brand New Day"), "spider man brand new day");
        assert_eq!(super::sanitize_query("  Wall·E  "), "wall e");
    }

    #[test]
    fn friends_matches_the_show_not_a_search_keyword() {
        for release in [
            "Friends.S01E02.The.One.with.the.Sonogram.at.the.End.2160p.UHD.BluRay.REMUX-TRiToN",
            "Friends.1994.S01E02.1080p.AMZN.WEB-DL-HONE",
            "Friends - S01E02 - The One With The Sonogram At The End - Bluray-720p",
            "[Group] Friends 1x02 720p",
            "FRIENDS.s1.e2.1080p",
        ] {
            assert!(series_release_matches(release, "Friends", Some("1994"), 1, 2), "{release}");
        }
        for release in [
            "Friends.Like.These.The.Murder.of.Skylar.Neese.S01E02.The.Betrayal.2160p.DSNP.WEB-DL-playWEB",
            "Your.Friends.and.Neighbors.S01E02.2025.2160p.ATVP.WEB-DL-HHWEB",
            "Friends.Sex.and.Games.S01E02.2160p.WEB-EDITH",
            "Smiling.Friends.S01E02.Mr.Frog.1080p.WEB-DL",
            "Magnolia.Table.with.Joanna.Gaines.S01E02.A.Friendsgiving.Feast.1080p.WEB-DL",
            "Friends.2021.S01E02.1080p.VIKI.WEB-DL",
            "Friends.S01E03.1080p.BluRay",
            "Friends.S02E02.1080p.BluRay",
            "Friends.S01E020.1080p.BluRay",
            "Friends.S01E02E03.1080p.BluRay",
            "Friends.E02.720p.HDTV",
            "Friends.S01.COMPLETE.1080p.BluRay",
        ] {
            assert!(!series_release_matches(release, "Friends", Some("1994"), 1, 2), "{release}");
        }
    }

    #[test]
    fn series_identity_handles_punctuation_without_accepting_sequels_or_reboots() {
        assert!(series_release_matches("Schitts.Creek.S02E01.WEB", "Schitt's Creek", Some("2015"), 2, 1));
        assert!(series_release_matches("His.and.Hers.S01E01.WEB", "His & Hers", None, 1, 1));
        assert!(series_release_matches("1883.S01E02.WEB", "1883", Some("2021"), 1, 2));
        assert!(series_release_matches("The.Office.2005.S01E02.WEB", "The Office", Some("2005"), 1, 2));
        assert!(!series_release_matches("The.Office.2001.S01E02.WEB", "The Office", Some("2005"), 1, 2));
        assert!(!series_release_matches("Ghosts.2021.S01E02.WEB", "Ghosts", Some("2019"), 1, 2));
        assert!(!series_release_matches("House.of.the.Dragon.S01E02.WEB", "House", Some("2004"), 1, 2));
        assert!(!series_release_matches("Friends.S01E02.WEB", "", None, 1, 2));
    }

    #[test]
    fn verified_result_ids_preserve_scene_aliases_but_not_other_shows_or_episodes() {
        for (title, release, imdb) in [
            ("Shameless", "Shameless.US.S01E02.1080p.WEB", "1586680"),
            ("The Office", "The.Office.US.S01E02.1080p.WEB", "0386676"),
            ("Ghosts", "Ghosts.US.S01E02.1080p.WEB", "11379026"),
            ("Marvel’s Daredevil", "Daredevil.S01E02.1080p.WEB", "3322312"),
        ] {
            let xml = format!(r#"<rss><channel><item><title>{release}</title><enclosure url="https://example.invalid/verified.nzb"/><newznab:attr name="imdb" value="tt{imdb}"/></item></channel></rss>"#);
            let candidates = parse_newznab(&xml, "fixture");
            assert_eq!(matching_series_results(candidates.clone(), title, None, Some(imdb), 1, 2).len(), 1, "{release}");
            assert!(matching_series_results(candidates.clone(), title, None, Some(imdb), 1, 3).is_empty());
            assert!(matching_series_results(candidates.clone(), title, None, Some("0108778"), 1, 2).is_empty());
            // Querying the right ID is not enough by itself: the result must
            // carry that ID before an otherwise ambiguous alias is accepted.
            let mut unverified = candidates;
            unverified[0].imdb_id = None;
            assert!(matching_series_results(unverified, title, None, Some(imdb), 1, 2).is_empty());
        }
    }

    #[test]
    fn explicit_other_imdb_is_rejected_even_if_the_show_name_matches() {
        let xml = r#"<rss><channel>
            <item><title>Friends.S01E02.WEB</title><enclosure url="https://example.invalid/other.nzb"/><newznab:attr name="imdbid" value="tt9999999"/></item>
            <item><title>Friends.S01E02.WEB</title><enclosure url="https://example.invalid/right.nzb"/><newznab:attr name="imdb" value="108778"/></item>
            <item><title>Friends.S01E02.WEB</title><enclosure url="https://example.invalid/unmapped.nzb"/></item>
        </channel></rss>"#;
        let candidates = parse_newznab(xml, "fixture");
        assert_eq!(candidates[0].imdb_id.as_deref(), Some("9999999"));
        assert_eq!(candidates[1].imdb_id.as_deref(), Some("108778"));
        assert!(candidates[2].imdb_id.is_none(), "identity must not leak from the preceding item");
        let filtered = matching_series_results(candidates.clone(), "Friends", Some("1994"), Some("0108778"), 1, 2);
        assert_eq!(filtered.len(), 2);
        assert!(filtered.iter().all(|r| !r.nzb_url.ends_with("other.nzb")));
        // If TMDB is unavailable, only an explicitly verified ID is usable.
        assert_eq!(matching_series_results(candidates, "", None, Some("0108778"), 1, 2).len(), 1);
    }

    #[tokio::test]
    async fn unrelated_tvsearch_results_do_not_stop_verified_generic_fallback() {
        use axum::{extract::Query, routing::get, Router};
        use std::collections::HashMap;
        use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
        let requests = Arc::new(AtomicUsize::new(0));
        let count = requests.clone();
        let app = Router::new().route("/api", get(move |Query(q): Query<HashMap<String, String>>| {
            count.fetch_add(1, Ordering::SeqCst);
            async move {
                let wrong = r#"<item><title>Friends.Like.These.S01E02.2160p.WEB</title><enclosure url="https://example.invalid/wrong.nzb"/></item>"#;
                let right = if q.get("t").map(String::as_str) == Some("search") {
                    r#"<item><title>Friends.1994.S01E02.1080p.WEB</title><enclosure url="https://example.invalid/right.nzb"/></item>"#
                } else { "" };
                format!("<rss><channel>{wrong}{right}</channel></rss>")
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let ix = Indexer { name: "fixture".into(), url: format!("http://{addr}"), api_key: "test-only".into() };
        let results = title_chain_series(&reqwest::Client::new(), &ix, "Friends", Some("1994"), Some("0108778"), 1, 2).await.unwrap();
        server.abort();
        assert_eq!(requests.load(Ordering::SeqCst), 2);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "Friends.1994.S01E02.1080p.WEB");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_newznab_items() {
        let xml = r#"<?xml version="1.0"?>
        <rss><channel>
          <item>
            <title>Inception.2010.1080p.BluRay.x264-GROUP</title>
            <enclosure url="https://ix/getnzb/abc.nzb" length="9000000000" type="application/x-nzb"/>
            <newznab:attr name="size" value="9123456789"/>
          </item>
          <item>
            <title>Inception.2010.2160p.UHD-GROUP</title>
            <enclosure url="https://ix/getnzb/def.nzb" length="40000000000"/>
          </item>
        </channel></rss>"#;
        let r = parse_newznab(xml, "TestIx");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].title, "Inception.2010.1080p.BluRay.x264-GROUP");
        assert_eq!(r[0].nzb_url, "https://ix/getnzb/abc.nzb");
        assert_eq!(r[0].size, 9_123_456_789); // attr overrides enclosure length
        assert_eq!(r[1].size, 40_000_000_000);
    }
}
