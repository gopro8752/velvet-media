//! Streamed's public event catalog and intended embed URLs. Native clients use
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
use futures::{stream, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, Semaphore};

const ORIGIN: &str = "https://streamed.st";
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
        "Streamed is unavailable; try again shortly",
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
pub(crate) fn router_with_bridge(cfg: LiveSports, token: String, bridge: crate::live::NativeBridge) -> anyhow::Result<Router> {
    build_router(cfg, token, Some(bridge))
}
fn build_router(cfg: LiveSports, token: String, bridge: Option<crate::live::NativeBridge>) -> anyhow::Result<Router> {
    let http = reqwest::Client::builder()
        .user_agent("Velvet/1.0 (Streamed catalog)")
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
    let limit = if path.starts_with("/api/stream/") {
        256 * 1024
    } else {
        MAX_BODY
    };
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
    if !value.is_array() || value.as_array().unwrap().len() > MAX_EVENTS {
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
            source_name: "Streamed",
            sports: vec![],
            events: vec![],
            message: Some("Live Sports is not configured yet".into()),
        }));
    }
    let selected = match filter.scope {
        Scope::Live => "/api/matches/live",
        Scope::Today => "/api/matches/all-today",
        Scope::All => "/api/matches/all",
    };
    let (matches, live, sports) = tokio::try_join!(
        fetch(&state, selected),
        fetch(&state, "/api/matches/live"),
        fetch(&state, "/api/sports")
    )?;
    let sports: Vec<Sport> = sports
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|s| serde_json::from_value::<Sport>(s.clone()).ok())
        .filter(|s| slug(&s.id) && label(&s.name, 100))
        .take(100)
        .collect();
    let names: HashMap<_, _> = sports
        .iter()
        .map(|s| (s.id.as_str(), s.name.as_str()))
        .collect();
    let live_ids: HashSet<_> = live
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| v["id"].as_str())
        .collect();
    let mut ids = HashSet::new();
    let mut output: Vec<Event> = matches
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| event(v, &names, &live_ids))
        .filter(|v| ids.insert(v.id.clone()))
        .collect();
    output.sort_by(|a, b| a.start_time.cmp(&b.start_time).then(a.id.cmp(&b.id)));
    let message = if output.is_empty() {
        Some("No events are listed for this view right now".into())
    } else {
        None
    };
    Ok(Json(Events {
        enabled: true,
        source_name: "Streamed",
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
fn sources(v: &Value) -> Vec<(String, String)> {
    let mut seen = HashSet::new();
    v["sources"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| {
            let (source, id) = (s["source"].as_str()?, s["id"].as_str()?);
            (slug(source) && slug(id)).then(|| (source.into(), id.into()))
        })
        .filter(|s| seen.insert(s.clone()))
        .take(12)
        .collect()
}
fn event(v: &Value, names: &HashMap<&str, &str>, live: &HashSet<&str>) -> Option<Event> {
    let (id, title, sport_id) = (
        v["id"].as_str()?,
        v["title"].as_str()?,
        v["category"].as_str()?,
    );
    if !slug(id) || !label(title, 400) || !slug(sport_id) {
        return None;
    }
    let date = DateTime::<Utc>::from_timestamp_millis(v["date"].as_i64()?)?;
    // Reject obviously corrupt epoch values without inventing an event duration.
    if !(946684800..4102444800).contains(&date.timestamp()) {
        return None;
    }
    Some(Event {
        id: id.into(),
        title: title.into(),
        sport_id: sport_id.into(),
        sport_name: names.get(sport_id).copied().unwrap_or(sport_id).into(),
        start_time: date.to_rfc3339_opts(SecondsFormat::Secs, true),
        is_live: live.contains(id),
        popular: v["popular"].as_bool().unwrap_or(false),
        poster_url: v["poster"].as_str().and_then(poster),
        home_team: team(&v["teams"]["home"]),
        away_team: team(&v["teams"]["away"]),
        source_count: sources(v).len(),
    })
}
fn image_token(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 1800
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-+=".contains(&b))
}
fn poster(s: &str) -> Option<String> {
    let path = s
        .strip_prefix(ORIGIN)
        .or_else(|| s.strip_prefix("https://streamed.pk"))
        .unwrap_or(s);
    let path = path.strip_prefix("/api/images/proxy/")?;
    let token = path.strip_suffix(".webp").unwrap_or(path);
    image_token(token).then(|| format!("{ORIGIN}/api/images/proxy/{token}.webp"))
}
fn team(v: &Value) -> Option<Team> {
    let name = v["name"].as_str()?;
    if !label(name, 200) {
        return None;
    }
    Some(Team {
        name: name.into(),
        badge_url: v["badge"]
            .as_str()
            .filter(|s| image_token(s))
            .map(|s| format!("{ORIGIN}/api/images/badge/{s}.webp")),
    })
}
pub(crate) fn allowed_embed(value: &str) -> bool {
    let Ok(url) = reqwest::Url::parse(value) else {
        return false;
    };
    !value.contains(['%', '\\'])
        && !value.contains("..")
        && value.len() <= 2000
        && url.scheme() == "https"
        && matches!(url.host_str(), Some("embed.st" | "embed.pk"))
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && url
            .path()
            .strip_prefix("/embed/")
            .is_some_and(|p| !p.is_empty() && p.split('/').all(slug))
}
fn valid_streams(value: Value, source: &str) -> Vec<SportsStream> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| serde_json::from_value::<SportsStream>(v.clone()).ok())
        .filter(|s| {
            s.source == source
                && slug(&s.source)
                && label(&s.id, 200)
                && (1..=100).contains(&s.stream_no)
                && label(&s.language, 100)
                && allowed_embed(&s.embed_url)
        })
        .take(32)
        .collect()
}
async fn streams(
    State(state): State<Arc<SportsState>>,
    Path(id): Path<String>,
) -> Result<Json<Streams>> {
    Ok(Json(load_streams(state, id).await?))
}
async fn load_streams(state: Arc<SportsState>, id: String) -> Result<Streams> {
    if !state.enabled {
        return Err(SportsError(
            StatusCode::SERVICE_UNAVAILABLE,
            "Live Sports is not configured yet",
        ));
    }
    if !slug(&id) {
        return Err(SportsError(StatusCode::BAD_REQUEST, "Invalid event"));
    }
    let (all, live) = tokio::try_join!(
        fetch(&state, "/api/matches/all"),
        fetch(&state, "/api/matches/live")
    )?;
    let item = live
        .as_array()
        .unwrap()
        .iter()
        .chain(all.as_array().unwrap())
        .find(|v| v["id"].as_str() == Some(&id))
        .ok_or(SportsError(
            StatusCode::NOT_FOUND,
            "Event is no longer listed; refresh Live Sports",
        ))?;
    let results: Vec<_> = stream::iter(sources(item))
        .map(|(source, id)| {
            let state = state.clone();
            async move {
                fetch(&state, &format!("/api/stream/{source}/{id}"))
                    .await
                    .map(|v| valid_streams(v, &source))
            }
        })
        .buffered(6)
        .collect()
        .await;
    let partial = results.iter().any(|r| r.is_err());
    let mut seen = HashSet::new();
    let streams: Vec<_> = results
        .into_iter()
        .filter_map(|r| r.ok())
        .flatten()
        .filter(|s| {
            seen.insert((
                s.source.clone(),
                s.id.clone(),
                s.stream_no,
                s.embed_url.clone(),
            ))
        })
        .take(128)
        .collect();
    let message = if streams.is_empty() {
        Some("No playable embeds are available yet; try another event or retry later".into())
    } else if partial {
        Some("Some stream sources are temporarily unavailable".into())
    } else {
        None
    };
    Ok(Streams { event_id: id, streams, message })
}

#[derive(Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
struct NativeTune { event_id: String, stream_id: String, source: String, stream_no: u32, client: Option<crate::live::NativeClient> }
async fn tune_native(State(state): State<Arc<SportsState>>, Json(request): Json<NativeTune>) -> Result<Json<Value>> {
    if !slug(&request.event_id) || !slug(&request.source) || !label(&request.stream_id,200) || !(1..=100).contains(&request.stream_no) {
        return Err(SportsError(StatusCode::BAD_REQUEST,"Invalid sports source"));
    }
    let bridge = state.bridge.as_ref().ok_or(SportsError(StatusCode::SERVICE_UNAVAILABLE,"Native sports browser is not configured"))?;
    let catalog = load_streams(state.clone(), request.event_id.clone()).await?;
    let selected = catalog.streams.iter().find(|s| s.id == request.stream_id && s.source == request.source && s.stream_no == request.stream_no)
        .ok_or(SportsError(StatusCode::NOT_FOUND,"Source is no longer listed; refresh Live Sports"))?;
    let live = fetch(&state,"/api/matches/live").await?;
    let all = fetch(&state,"/api/matches/all").await?;
    let title = live.as_array().into_iter().flatten().chain(all.as_array().into_iter().flatten())
        .find(|e| e["id"].as_str() == Some(&request.event_id)).and_then(|e| e["title"].as_str()).filter(|s| label(s,300)).unwrap_or("Live Sports");
    bridge.tune_sports(&selected.embed_url,&request.event_id,title,request.client).await
        .map(Json).map_err(|(status,message)| SportsError(status,message))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn embeds_only_allow_documented_public_hosts_and_bounded_paths() {
        assert!(allowed_embed("https://embed.st/embed/admin/game/1"));
        assert!(allowed_embed("https://embed.pk/embed/hotel/game/2"));
        for url in [
            "http://embed.st/embed/a/b/1",
            "https://127.0.0.1/embed/a",
            "https://embed.st.attacker.test/embed/a",
            "https://user@embed.st/embed/a",
            "https://embed.st:444/embed/a",
            "https://embed.st/embed/%2fadmin",
            "https://embed.st/embed/a?url=http://localhost",
            "https://embed.st/admin",
        ] {
            assert!(!allowed_embed(url), "{url}");
        }
    }
    #[test]
    fn event_dates_and_live_status_are_not_guessed() {
        let v = json!({"id":"game","title":"A vs B","category":"football","date":1791766800000i64,"sources":[{"source":"admin","id":"game"},{"source":"admin","id":"game"},{"source":"../bad","id":"game"}]});
        let out = event(
            &v,
            &HashMap::from([("football", "Football")]),
            &HashSet::new(),
        )
        .unwrap();
        assert_eq!(out.start_time, "2026-10-12T01:00:00Z");
        assert!(!out.is_live);
        assert_eq!(out.source_count, 1);
        assert!(
            event(&v, &HashMap::new(), &HashSet::from(["game"]))
                .unwrap()
                .is_live
        );
    }
    #[test]
    fn images_cannot_target_private_or_arbitrary_hosts() {
        assert_eq!(
            poster("/api/images/proxy/a+_-.webp").unwrap(),
            format!("{ORIGIN}/api/images/proxy/a+_-.webp")
        );
        assert!(poster("https://localhost/api/images/proxy/a").is_none());
        assert!(poster("/api/images/proxy/../../secret").is_none());
        assert!(team(&json!({"name":"Team","badge":"http://localhost"}))
            .unwrap()
            .badge_url
            .is_none());
    }
    #[test]
    fn duplicate_raw_stream_ids_keep_distinct_hd_sd_variants() {
        let v = json!([{"id":"game","source":"admin","streamNo":1,"language":"English","hd":true,"embedUrl":"https://embed.st/embed/admin/game/1"},
            {"id":"game","source":"admin","streamNo":2,"language":"English","hd":false,"embedUrl":"https://embed.st/embed/admin/game/2"},
            {"id":"game","source":"evil","streamNo":1,"language":"English","hd":true,"embedUrl":"https://embed.st/embed/admin/game/1"}]);
        assert_eq!(valid_streams(v, "admin").len(), 2);
    }
    #[tokio::test]
    async fn concurrent_cache_calls_coalesce_and_redirects_are_not_followed() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let count = Arc::new(AtomicUsize::new(0));
        let hits = count.clone();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let app = Router::new()
            .route(
                "/ok",
                get(move || {
                    let hits = hits.clone();
                    async move {
                        hits.fetch_add(1, Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_millis(20)).await;
                        Json(json!([]))
                    }
                }),
            )
            .route(
                "/redirect",
                get(|| async { (StatusCode::FOUND, [(header::LOCATION, "/ok")]) }),
            );
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let state = Arc::new(SportsState {
            enabled: true,
            token: String::new(),
            origin,
            http: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
            cache: Mutex::new(HashMap::new()),
            requests: Semaphore::new(6),
            clients: Semaphore::new(32),
            bridge: None,
        });
        let (a, b) = tokio::join!(fetch(&state, "/ok"), fetch(&state, "/ok"));
        assert!(a.is_ok() && b.is_ok());
        assert_eq!(count.load(Ordering::SeqCst), 1);
        assert!(fetch(&state, "/redirect").await.is_err());
        assert_eq!(count.load(Ordering::SeqCst), 1);
        task.abort();
    }
    #[tokio::test]
    async fn http_catalog_scopes_auth_and_embed_choices_keep_the_wire_contract() {
        let game = json!({"id":"game","title":"A vs B","category":"football","date":1791766800000i64,"sources":[{"source":"admin","id":"game"}]});
        let mut later = game.clone();
        later["id"] = json!("later");
        later["date"] = json!(1791853200000i64);
        let live = game.clone();
        let today = game.clone();
        let upstream=Router::new().route("/api/sports",get(||async{Json(json!([{"id":"football","name":"Football"}]))}))
            .route("/api/matches/live",get(move||{let game=live.clone();async move{Json(json!([game]))}}))
            .route("/api/matches/all-today",get(move||{let game=today.clone();async move{Json(json!([game]))}}))
            .route("/api/matches/all",get(move||{let game=game.clone();let later=later.clone();async move{Json(json!([game,later]))}}))
            .route("/api/stream/admin/game",get(||async{Json(json!([
                {"id":"game","source":"admin","streamNo":1,"language":"English","hd":true,"embedUrl":"https://embed.st/embed/admin/game/1"},
                {"id":"game","source":"admin","streamNo":2,"language":"English","hd":false,"embedUrl":"https://embed.st/embed/admin/game/2"},
                {"id":"game","source":"admin","streamNo":3,"language":"English","hd":false,"embedUrl":"https://localhost/embed/game"}
            ]))}));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let upstream_task =
            tokio::spawn(async move { axum::serve(listener, upstream).await.unwrap() });
        let state = Arc::new(SportsState {
            enabled: true,
            token: "test-token".into(),
            origin,
            http: reqwest::Client::new(),
            cache: Mutex::new(HashMap::new()),
            requests: Semaphore::new(6),
            clients: Semaphore::new(32),
            bridge: None,
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let app = router_with_state(state);
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let http = reqwest::Client::new();
        assert_eq!(
            http.get(format!("{base}/sports/events"))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        for (scope, count) in [("live", 1), ("today", 1), ("all", 2)] {
            let response = http
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
            let body: Value = response.json().await.unwrap();
            assert_eq!(body["events"].as_array().unwrap().len(), count);
            assert_eq!(body["events"][0]["isLive"], true);
            assert_eq!(body["events"][0]["startTime"], "2026-10-12T01:00:00Z");
            assert!(body["events"][0]["homeTeam"].is_null());
            if scope == "all" {
                assert_eq!(body["events"][1]["isLive"], false);
            }
        }
        let response: Value = http
            .get(format!("{base}/sports/events/game/streams"))
            .bearer_auth("test-token")
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(response["eventId"], "game");
        assert_eq!(response["streams"].as_array().unwrap().len(), 2);
        assert_eq!(
            http.get(format!("{base}/sports/events/unknown/streams"))
                .bearer_auth("test-token")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );
        task.abort();
        upstream_task.abort();
    }
}
