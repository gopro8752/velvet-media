//! StreamFree's public event catalog and documented embed URLs. Native clients use
//! the configured browser bridge; no player credentials, watch-history writes,
//! extracted playback tokens, or client-supplied origins are accepted.
use crate::config::LiveSports;
use axum::{
    extract::{Path, Query, Request, State},
    http::{header, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, Semaphore};

const ORIGIN: &str = "https://strmfree.st";
const CATALOG: &str = "/api/v1/streams";
const CATEGORIES: &str = "/api/v1/categories";
const MAX_BODY: usize = 4 * 1024 * 1024;
const MAX_EVENTS: usize = 2000;
const CACHE_SIZE: usize = 128;
const TTL: Duration = Duration::from_secs(30);
type Result<T> = std::result::Result<T, SportsError>;
#[derive(Debug)]
struct SportsError(StatusCode, &'static str);
impl IntoResponse for SportsError {
    fn into_response(self) -> Response {
        response((self.0, Json(serde_json::json!({"error":self.1}))).into_response())
    }
}
fn unavailable() -> SportsError {
    SportsError(
        StatusCode::BAD_GATEWAY,
        "StreamFree is unavailable; try again shortly",
    )
}
fn response(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, "no-store, private".parse().unwrap());
    response
}
#[derive(Clone, Serialize, Deserialize)]
struct Sport {
    id: String,
    name: String,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Team {
    name: String,
    badge_url: Option<String>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Event {
    id: String,
    title: String,
    sport_id: String,
    sport_name: String,
    start_time: String,
    is_live: bool,
    popular: bool,
    poster_url: Option<String>,
    home_team: Option<Team>,
    away_team: Option<Team>,
    source_count: usize,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Events {
    enabled: bool,
    source_name: &'static str,
    sports: Vec<Sport>,
    events: Vec<Event>,
    message: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SportsStream {
    id: String,
    source: String,
    stream_no: u32,
    language: String,
    hd: bool,
    embed_url: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Streams {
    event_id: String,
    streams: Vec<SportsStream>,
    message: Option<String>,
}
#[derive(Deserialize, Default)]
#[serde(rename_all = "lowercase")]
enum Scope {
    #[default]
    Live,
    Today,
    All,
}
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct Filter {
    #[serde(default)]
    scope: Scope,
}
#[derive(Default)]
struct Cached {
    fetched: Option<Instant>,
    attempted: Option<Instant>,
    value: Option<Value>,
}
struct CacheEntry {
    used: Instant,
    value: Arc<Mutex<Cached>>,
}
struct SportsState {
    enabled: bool,
    token: String,
    http: reqwest::Client,
    origin: String,
    cache: Mutex<HashMap<String, CacheEntry>>,
    requests: Semaphore,
    clients: Semaphore,
    bridge: Option<crate::live::NativeBridge>,
}
pub(crate) fn router_with_bridge(
    cfg: LiveSports,
    token: String,
    bridge: crate::live::NativeBridge,
) -> anyhow::Result<Router> {
    build_router(cfg, token, Some(bridge))
}
fn build_router(
    cfg: LiveSports,
    token: String,
    bridge: Option<crate::live::NativeBridge>,
) -> anyhow::Result<Router> {
    let http = reqwest::Client::builder()
        .user_agent("Velvet/1.0 (StreamFree catalog)")
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(4))
        .timeout(Duration::from_secs(12))
        .build()?;
    Ok(router_with_state(Arc::new(SportsState {
        enabled: cfg.enabled,
        token,
        http,
        origin: ORIGIN.into(),
        cache: Mutex::new(HashMap::new()),
        requests: Semaphore::new(6),
        clients: Semaphore::new(32),
        bridge,
    })))
}
fn router_with_state(state: Arc<SportsState>) -> Router {
    Router::new()
        .route("/sports/events", get(events))
        .route("/sports/events/:id/streams", get(streams))
        .route("/sports/tune", post(tune_native))
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        .with_state(state)
}
async fn auth(State(state): State<Arc<SportsState>>, request: Request, next: Next) -> Response {
    if !state.token.is_empty()
        && !request
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v == format!("Bearer {}", state.token))
    {
        return SportsError(StatusCode::UNAUTHORIZED, "unauthorized").into_response();
    }
    let Ok(_permit) = state.clients.try_acquire() else {
        return SportsError(
            StatusCode::SERVICE_UNAVAILABLE,
            "Sports catalog busy; retry shortly",
        )
        .into_response();
    };
    response(next.run(request).await)
}
async fn fetch(state: &SportsState, path: &str) -> Result<Value> {
    let cell = {
        let mut cache = state.cache.lock().await;
        if !cache.contains_key(path) && cache.len() >= CACHE_SIZE {
            // Never evict an in-flight cell, which would defeat request coalescing.
            let oldest = cache
                .iter()
                .filter(|(_, e)| Arc::strong_count(&e.value) == 1)
                .min_by_key(|(_, e)| e.used)
                .map(|(key, _)| key.clone());
            if let Some(key) = oldest {
                cache.remove(&key);
            } else {
                return Err(unavailable());
            }
        }
        let entry = cache.entry(path.into()).or_insert_with(|| CacheEntry {
            used: Instant::now(),
            value: Arc::new(Mutex::new(Cached::default())),
        });
        entry.used = Instant::now();
        entry.value.clone()
    };
    let mut cache = cell.lock().await;
    if cache.fetched.is_some_and(|at| at.elapsed() < TTL) {
        return Ok(cache.value.as_ref().unwrap().clone());
    }
    if cache
        .attempted
        .is_some_and(|at| at.elapsed() < Duration::from_secs(5))
    {
        return Err(unavailable());
    }
    cache.attempted = Some(Instant::now());
    let _permit = tokio::time::timeout(Duration::from_secs(3), state.requests.acquire())
        .await
        .map_err(|_| unavailable())?
        .map_err(|_| unavailable())?;
    let limit = MAX_BODY;
    let mut response = state
        .http
        .get(format!("{}{path}", state.origin))
        .send()
        .await
        .map_err(|_| unavailable())?;
    if !response.status().is_success()
        || response.content_length().is_some_and(|n| n > limit as u64)
    {
        return Err(unavailable());
    }
    let mut data = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| unavailable())? {
        if data.len().saturating_add(chunk.len()) > limit {
            return Err(unavailable());
        }
        data.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&data).map_err(|_| unavailable())?;
    let entries = match path {
        CATALOG => value.get("streams"),
        CATEGORIES => value.get("categories"),
        _ => None,
    }
    .and_then(Value::as_array)
    .ok_or_else(unavailable)?;
    if entries.len() > MAX_EVENTS {
        return Err(unavailable());
    }
    cache.fetched = Some(Instant::now());
    cache.value = Some(value.clone());
    Ok(value)
}
async fn events(
    State(state): State<Arc<SportsState>>,
    Query(filter): Query<Filter>,
) -> Result<Json<Events>> {
    if !state.enabled {
        return Ok(Json(Events {
            enabled: false,
            source_name: "StreamFree",
            sports: vec![],
            events: vec![],
            message: Some("Live Sports is not configured yet".into()),
        }));
    }
    // The documented catalog contains current streams and pre-announced streams.
    // Never synthesize upcoming fixtures or infer liveness from the clock.
    let (catalog, categories) =
        tokio::try_join!(fetch(&state, CATALOG), fetch(&state, CATEGORIES))?;
    let sports = category_list(&categories);
    let names: HashMap<_, _> = sports
        .iter()
        .map(|s| (s.id.as_str(), s.name.as_str()))
        .collect();
    let today = Utc::now().date_naive();
    let mut ids = HashSet::new();
    let mut output: Vec<Event> = catalog["streams"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| event(v, &names))
        .filter(|v| match filter.scope {
            Scope::Live => v.is_live,
            // Include events still live across midnight; use the supplied UTC
            // timestamp for scheduled events, rather than the server timezone.
            Scope::Today => {
                v.is_live
                    || DateTime::parse_from_rfc3339(&v.start_time)
                        .is_ok_and(|d| d.date_naive() == today)
            }
            Scope::All => true,
        })
        .filter(|v| ids.insert(v.id.clone()))
        .collect();
    output.sort_by(|a, b| a.start_time.cmp(&b.start_time).then(a.id.cmp(&b.id)));
    let message = output
        .is_empty()
        .then(|| "No events are listed for this view right now".into());
    Ok(Json(Events {
        enabled: true,
        source_name: "StreamFree",
        sports,
        events: output,
        message,
    }))
}
fn label(s: &str, max: usize) -> bool {
    !s.trim().is_empty() && s.len() <= max && !s.chars().any(char::is_control)
}
fn slug(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 180
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn category_name(id: &str) -> String {
    match id {
        "soccer" => "Soccer",
        "basketball" => "Basketball",
        "hockey" => "Hockey",
        "combat" => "Combat sports",
        "baseball" => "Baseball",
        "football" => "American football",
        "racing" => "Racing",
        "tennis" => "Tennis",
        "cricket" => "Cricket",
        other => {
            return other
                .split('_')
                .map(|s| {
                    let mut c = s.chars();
                    c.next()
                        .map(|v| v.to_uppercase().to_string() + c.as_str())
                        .unwrap_or_default()
                })
                .collect::<Vec<_>>()
                .join(" ")
        }
    }
    .into()
}
fn category_list(value: &Value) -> Vec<Sport> {
    let mut seen = HashSet::new();
    value["categories"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|s| slug(s) && seen.insert(*s))
        .take(100)
        .map(|s| Sport {
            id: s.into(),
            name: category_name(s),
        })
        .collect()
}
fn stream_key(s: &str) -> bool {
    !s.is_empty()
        && s.chars().count() <= 200
        && s.chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
}
fn event_id(v: &Value) -> Option<String> {
    let category = v["category"].as_str()?;
    let key = v["stream_key"].as_str()?;
    if !slug(category) || !stream_key(key) {
        return None;
    }
    // Provider keys can contain Unicode. Stable ASCII IDs keep existing route,
    // launcher, Roku and handoff contracts without lossy name transliteration.
    Some(format!(
        "sf-{:x}",
        md5::compute(format!("{category}\0{key}"))
    ))
}
fn event(v: &Value, names: &HashMap<&str, &str>) -> Option<Event> {
    let id = event_id(v)?;
    let title = v["name"].as_str()?;
    let sport_id = v["category"].as_str()?;
    if !label(title, 400) {
        return None;
    }
    let date = DateTime::<Utc>::from_timestamp(v["match_timestamp"].as_i64()?, 0)?;
    if !(946684800..4102444800).contains(&date.timestamp()) {
        return None;
    }
    let variants = variants(v);
    if variants.is_empty() {
        return None;
    }
    let is_live = variants.iter().any(|v| v.live);
    Some(Event {
        id,
        title: title.into(),
        sport_id: sport_id.into(),
        sport_name: names
            .get(sport_id)
            .map(|s| s.to_string())
            .unwrap_or_else(|| category_name(sport_id)),
        start_time: date.to_rfc3339_opts(SecondsFormat::Secs, true),
        is_live,
        popular: false,
        poster_url: v["thumbnail_url"].as_str().and_then(poster),
        // StreamFree's team1/team2 fields do not designate home and away.
        home_team: None,
        away_team: None,
        source_count: variants.iter().filter(|v| !is_live || v.live).count(),
    })
}
// Decode exactly once. UTF-8 names such as Montréal are valid; encoded slashes,
// punctuation, double encoding, traversal and malformed UTF-8 are not.
fn path_segment(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let a = (*bytes.get(i + 1)? as char).to_digit(16)?;
            let b = (*bytes.get(i + 2)? as char).to_digit(16)?;
            out.push((a * 16 + b) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    let text = String::from_utf8(out).ok()?;
    stream_key(&text).then_some(text)
}
fn public_url(value: &str) -> Option<reqwest::Url> {
    if value.len() > 2000
        || value.contains('\\')
        || value.to_ascii_lowercase().contains("%2e")
        || value.chars().any(char::is_control)
    {
        return None;
    }
    let url = reqwest::Url::parse(value).ok()?;
    (url.scheme() == "https"
        && matches!(url.host_str(), Some("strmfree.st" | "streamfree.top"))
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none())
    .then_some(url)
}
fn embed_url(value: &str) -> Option<reqwest::Url> {
    // Reject dot segments before the URL parser normalizes them away.
    if value.contains("..") {
        return None;
    }
    let mut url = public_url(value)?;
    let segments: Vec<_> = url.path().strip_prefix("/embed/")?.split('/').collect();
    if segments.len() != 2 || !slug(segments[0]) || segments[0].len() > 80 {
        return None;
    }
    let canonical_path = format!("/embed/{}/{}", segments[0], path_segment(segments[1])?);
    url.set_path(&canonical_path);
    url.set_host(Some("strmfree.st")).ok()?;
    Some(url)
}
pub(crate) fn allowed_embed(value: &str) -> bool {
    embed_url(value).is_some()
}
fn poster(value: &str) -> Option<String> {
    if value.contains("..") {
        return None;
    }
    let url = public_url(value)?;
    let segment = url.path().strip_prefix("/thumbnails/")?;
    path_segment(segment)?;
    Some(url.to_string())
}
struct Variant {
    url: String,
    live: bool,
}
fn variants(v: &Value) -> Vec<Variant> {
    let live: HashSet<_> = v["live_sources"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter_map(embed_url)
        .map(|u| u.to_string())
        .take(64)
        .collect();
    let mut seen = HashSet::new();
    v["sources"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter_map(embed_url)
        .filter(|url| seen.insert(url.to_string()))
        .take(32)
        .map(|url| {
            let url = url.to_string();
            Variant {
                live: live.contains(&url),
                url,
            }
        })
        .collect()
}
fn valid_streams(v: &Value) -> Vec<SportsStream> {
    let mut variants = variants(v);
    let has_live = variants.iter().any(|v| v.live);
    variants.sort_by(|a, b| {
        b.url
            .contains("2160p")
            .cmp(&a.url.contains("2160p"))
            .then(a.url.cmp(&b.url))
    });
    variants
        .into_iter()
        .enumerate()
        .filter(|(_, v)| !has_live || v.live)
        .map(|(i, v)| {
            let url = v.url;
            let path = reqwest::Url::parse(&url).unwrap();
            let key = path.path().rsplit('/').next().unwrap_or_default();
            SportsStream {
                id: format!("sf-{:x}", md5::compute(&url)),
                source: "streamfree".into(),
                stream_no: (i + 1) as u32,
                language: "Original".into(),
                hd: key.contains("1080p") || key.contains("720p") || key.contains("2160p"),
                embed_url: url,
            }
        })
        .collect()
}
async fn streams(
    State(state): State<Arc<SportsState>>,
    Path(id): Path<String>,
) -> Result<Json<Streams>> {
    Ok(Json(load_streams(state, id).await?))
}
async fn catalog_item(state: &SportsState, id: &str) -> Result<Value> {
    if !state.enabled {
        return Err(SportsError(
            StatusCode::SERVICE_UNAVAILABLE,
            "Live Sports is not configured yet",
        ));
    }
    if !slug(id) {
        return Err(SportsError(StatusCode::BAD_REQUEST, "Invalid event"));
    }
    fetch(state, CATALOG).await?["streams"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| event_id(v).as_deref() == Some(id))
        .cloned()
        .ok_or(SportsError(
            StatusCode::NOT_FOUND,
            "Event is no longer listed; refresh Live Sports",
        ))
}
async fn load_streams(state: Arc<SportsState>, id: String) -> Result<Streams> {
    let item = catalog_item(&state, &id).await?;
    let streams = valid_streams(&item);
    let message = if streams.is_empty() {
        Some("No playable embeds are available yet; try another event or retry later".into())
    } else if !variants(&item).iter().any(|v| v.live) {
        Some("This event's sources are not live yet".into())
    } else {
        None
    };
    Ok(Streams {
        event_id: id,
        streams,
        message,
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NativeTune {
    event_id: String,
    stream_id: String,
    source: String,
    stream_no: u32,
    client: Option<crate::live::NativeClient>,
}
async fn tune_native(
    State(state): State<Arc<SportsState>>,
    Json(request): Json<NativeTune>,
) -> Result<Json<Value>> {
    if !slug(&request.event_id)
        || !slug(&request.source)
        || !label(&request.stream_id, 200)
        || !(1..=100).contains(&request.stream_no)
    {
        return Err(SportsError(
            StatusCode::BAD_REQUEST,
            "Invalid sports source",
        ));
    }
    let bridge = state.bridge.as_ref().ok_or(SportsError(
        StatusCode::SERVICE_UNAVAILABLE,
        "Native sports browser is not configured",
    ))?;
    let catalog = load_streams(state.clone(), request.event_id.clone()).await?;
    let selected = catalog
        .streams
        .iter()
        .find(|s| {
            s.id == request.stream_id
                && s.source == request.source
                && s.stream_no == request.stream_no
        })
        .ok_or(SportsError(
            StatusCode::NOT_FOUND,
            "Source is no longer listed; refresh Live Sports",
        ))?;
    let item = catalog_item(&state, &request.event_id).await?;
    let title = item["name"]
        .as_str()
        .filter(|s| label(s, 300))
        .unwrap_or("Live Sports");
    bridge
        .tune_sports(
            &selected.embed_url,
            &request.event_id,
            title,
            request.client,
        )
        .await
        .map(Json)
        .map_err(|(status, message)| SportsError(status, message))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture(key: &str, timestamp: i64, live: bool) -> Value {
        let one = format!("{ORIGIN}/embed/basketball/{key}1080p");
        let two = format!("{ORIGIN}/embed/basketball/{key}1080p2");
        json!({"name":"A vs B","stream_key":key,"category":"basketball","match_timestamp":timestamp,
            "sources":[one,two],"live_sources":if live {vec![one,two]} else {vec![]},
            "thumbnail_url":format!("https://streamfree.top/thumbnails/basketball_{key}")})
    }
    fn state(origin: String, token: &str) -> Arc<SportsState> {
        Arc::new(SportsState {
            enabled: true,
            token: token.into(),
            origin,
            http: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
            cache: Mutex::new(HashMap::new()),
            requests: Semaphore::new(6),
            clients: Semaphore::new(32),
            bridge: None,
        })
    }
    #[test]
    fn embed_hosts_and_paths_allow_unicode_without_opening_redirects_or_traversal() {
        for value in [
            "https://strmfree.st/embed/basketball/game1080p",
            "https://streamfree.top/embed/soccer/cf-montréal1080p",
            "https://strmfree.st/embed/soccer/cf-montr%C3%A9al1080p",
        ] {
            assert!(allowed_embed(value), "rejected {value}");
        }
        for value in [
            "https://embed.st/embed/admin/game/1",
            "http://strmfree.st/embed/soccer/game",
            "https://127.0.0.1/embed/soccer/game",
            "https://strmfree.st.evil/embed/soccer/game",
            "https://user@strmfree.st/embed/soccer/game",
            "https://strmfree.st:444/embed/soccer/game",
            "https://strmfree.st/embed/soccer/game?url=http://localhost",
            "https://strmfree.st/embed/soccer/game#fragment",
            "https://strmfree.st/embed/soccer/game/extra",
            "https://strmfree.st/embed/soccer/game/../other",
            "https://strmfree.st/embed/soccer/game/%2e%2E/other",
            "https://strmfree.st/embed/soccer/a%2fb",
            "https://strmfree.st/embed/soccer/a%5cb",
            "https://strmfree.st/embed/soccer/a%252fb",
            "https://strmfree.st/embed/soccer/%ff",
            "https://strmfree.st/embed/soccer/game/",
            "https://strmfree.st/admin",
        ] {
            assert!(!allowed_embed(value), "accepted {value}");
        }
        assert_eq!(
            embed_url("https://streamfree.top/embed/soccer/cf-montr%c3%a9al")
                .unwrap()
                .as_str(),
            "https://strmfree.st/embed/soccer/cf-montr%C3%A9al"
        );
    }
    #[test]
    fn event_seconds_live_sources_and_unicode_ids_preserve_metadata() {
        let mut item = fixture("montréal-vs-b", 1791766800, true);
        let e = event(&item, &HashMap::new()).unwrap();
        assert!(slug(&e.id));
        assert!(e.id.starts_with("sf-"));
        assert_eq!(e.start_time, "2026-10-12T01:00:00Z");
        assert!(e.is_live);
        assert_eq!(e.source_count, 2);
        assert_eq!(e.sport_name, "Basketball");
        assert!(e.home_team.is_none());
        assert!(e.away_team.is_none());
        item["live_sources"] = json!([]);
        let later = event(&item, &HashMap::new()).unwrap();
        assert!(!later.is_live);
        assert_eq!(e.id, later.id);
        item["match_timestamp"] = json!(1791766800000i64);
        assert!(event(&item, &HashMap::new()).is_none());
        item["match_timestamp"] = Value::Null;
        assert!(event(&item, &HashMap::new()).is_none());
    }
    #[test]
    fn only_declared_live_variants_are_offered_and_identity_survives_liveness_changes() {
        let mut item = fixture("game", 1791766800, true);
        let both = valid_streams(&item);
        assert_eq!(both.len(), 2);
        assert!(both.iter().all(|s| s.hd));
        item["sources"].as_array_mut().unwrap().reverse();
        assert_eq!(valid_streams(&item)[0].id, both[0].id);
        item["live_sources"] = json!([
            format!("{ORIGIN}/embed/basketball/game1080p2"),
            "https://evil.test/embed/basketball/game"
        ]);
        let only = valid_streams(&item);
        assert_eq!(only.len(), 1);
        assert_eq!(only[0].id, both[1].id);
        assert_eq!(only[0].stream_no, 2);
        item["sources"]
            .as_array_mut()
            .unwrap()
            .push(json!("https://streamfree.top/embed/basketball/game1080p2"));
        assert_eq!(valid_streams(&item).len(), 1);
    }
    #[test]
    fn images_are_confined_to_provider_thumbnail_paths() {
        assert!(poster("https://streamfree.top/thumbnails/soccer_cf-montréal_vs_B").is_some());
        for value in [
            "https://localhost/thumbnails/a",
            "https://strmfree.st/admin",
            "https://strmfree.st/thumbnails/a/b",
            "https://strmfree.st/thumbnails/a/%2e%2e/b",
            "https://strmfree.st/thumbnails/a?url=x",
        ] {
            assert!(poster(value).is_none(), "accepted {value}");
        }
    }
    #[test]
    fn categories_are_deduplicated_and_football_is_not_soccer() {
        let categories =
            category_list(&json!({"categories":["soccer","football","soccer","../bad",null]}));
        assert_eq!(categories.len(), 2);
        assert_eq!(categories[0].name, "Soccer");
        assert_eq!(categories[1].name, "American football");
    }
    #[tokio::test]
    async fn coalescing_rejects_redirects_and_malformed_envelopes() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let count = Arc::new(AtomicUsize::new(0));
        let hits = count.clone();
        let app = Router::new()
            .route(
                CATALOG,
                get(move || {
                    let hits = hits.clone();
                    async move {
                        hits.fetch_add(1, Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_millis(20)).await;
                        Json(json!({"streams":[]}))
                    }
                }),
            )
            .route(
                CATEGORIES,
                get(|| async { (StatusCode::FOUND, [(header::LOCATION, CATALOG)]) }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let shared = state(base, "");
        let (a, b) = tokio::join!(fetch(&shared, CATALOG), fetch(&shared, CATALOG));
        assert!(a.is_ok() && b.is_ok());
        assert_eq!(count.load(Ordering::SeqCst), 1);
        assert!(fetch(&shared, CATEGORIES).await.is_err());
        assert_eq!(count.load(Ordering::SeqCst), 1);
        task.abort();
        for body in [
            json!([]),
            json!({"streams":null}),
            json!({"streams":{}}),
            json!({"streams":vec![Value::Null;MAX_EVENTS+1]}),
        ] {
            let app = Router::new().route(
                CATALOG,
                get(move || {
                    let body = body.clone();
                    async move { Json(body) }
                }),
            );
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
            assert!(fetch(&state(base, ""), CATALOG).await.is_err());
            task.abort();
        }
    }
    #[tokio::test]
    async fn catalog_scopes_auth_unicode_choices_and_wire_contract() {
        let now = Utc::now().timestamp();
        let game = fixture("montréal-game", now - 3600, true);
        let id = event_id(&game).unwrap();
        let later = fixture("later", now + 86400, false);
        let catalog = json!({"streams":[game,later]});
        let app = Router::new()
            .route(
                CATALOG,
                get(move || {
                    let catalog = catalog.clone();
                    async move { Json(catalog) }
                }),
            )
            .route(
                CATEGORIES,
                get(|| async { Json(json!({"categories":["basketball"]})) }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let upstream = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let app = router_with_state(state(origin, "test-token"));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = reqwest::Client::new();
        assert_eq!(
            client
                .get(format!("{base}/sports/events"))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        for (scope, count) in [("live", 1), ("today", 1), ("all", 2)] {
            let response = client
                .get(format!("{base}/sports/events?scope={scope}"))
                .bearer_auth("test-token")
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(
                response.headers()[header::CACHE_CONTROL],
                "no-store, private"
            );
            let value: Value = response.json().await.unwrap();
            assert_eq!(value["sourceName"], "StreamFree");
            assert_eq!(value["events"].as_array().unwrap().len(), count);
            assert_eq!(value["events"][0]["id"], id);
            assert_eq!(value["events"][0]["isLive"], true);
            assert!(value["events"][0]["homeTeam"].is_null());
        }
        let response: Value = client
            .get(format!("{base}/sports/events/{id}/streams"))
            .bearer_auth("test-token")
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(response["eventId"], id);
        assert_eq!(response["streams"].as_array().unwrap().len(), 2);
        assert_eq!(response["streams"][0]["source"], "streamfree");
        assert!(response["streams"][0]["embedUrl"]
            .as_str()
            .unwrap()
            .contains("%C3%A9"));
        assert_eq!(
            client
                .get(format!("{base}/sports/events/missing/streams"))
                .bearer_auth("test-token")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );
        task.abort();
        upstream.abort();
    }
}
