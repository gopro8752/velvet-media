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
    let out = fetch_results(
        client,
        ix,
        &format!("t=tvsearch&imdbid={imdb_digits}&season={season}&ep={episode}"),
    )
    .await?;
    if !out.is_empty() {
        return Ok(out);
    }
    let Some((title, _)) = imdb_meta(client, imdb_digits, true).await else {
        return Ok(out);
    };
    title_chain_series(client, ix, &title, season, episode).await
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
    season: u32,
    episode: u32,
) -> anyhow::Result<Vec<NzbResult>> {
    let q = sanitize_query(title).replace(' ', "%20");
    let by_title =
        fetch_results(client, ix, &format!("t=tvsearch&q={q}&season={season}&ep={episode}")).await?;
    if !by_title.is_empty() {
        return Ok(by_title);
    }
    fetch_results(client, ix, &format!("t=search&q={q}%20s{season:02}e{episode:02}")).await
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
    let Some((title, _)) = tmdb_title(client, tmdb_id, true).await else {
        return Ok(Vec::new());
    };
    title_chain_series(client, ix, &title, season, episode).await
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
    let mut want_title_text = false;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => match e.name().as_ref() {
                b"item" => {
                    in_item = true;
                    cur_title.clear();
                    cur_url.clear();
                    cur_size = 0;
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
    #[test]
    fn query_sanitizing() {
        assert_eq!(super::sanitize_query("HIS & HERS"), "his and hers");
        assert_eq!(super::sanitize_query("Spider-Man: Brand New Day"), "spider man brand new day");
        assert_eq!(super::sanitize_query("  Wall·E  "), "wall e");
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
