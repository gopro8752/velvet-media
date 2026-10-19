//! Live TV is separate from finite VOD/NZB playback and never touches watch state.
//! Only a configured PrismCast origin is reachable. Playback URLs are revocable,
//! idle-expiring capabilities; no provider credentials or bearer headers reach players.
use std::{collections::{HashMap, HashSet}, sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}, time::{Duration, Instant}};
use axum::{body::Body, extract::{Path, Request, State}, http::{header, HeaderMap, StatusCode}, middleware::{self, Next}, response::{IntoResponse, Response}, routing::{delete, get, post}, Json, Router};
use futures::StreamExt;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex as AsyncMutex, Semaphore};

use crate::config::LiveTv;

const IDLE: Duration = Duration::from_secs(120);
const CACHE_AGE: Duration = Duration::from_secs(60);
const MAX_SESSIONS: usize = 32;
const MAX_RESOURCES: usize = 512;
const MAX_CHANNELS: usize = 1000;
const MAX_PLAYLIST: usize = 512 * 1024;
const MAX_LINEUP: usize = 2 * 1024 * 1024;
const MAX_SEGMENT: usize = 64 * 1024 * 1024;
const HLS: &str = "application/vnd.apple.mpegurl";

type Result<T> = std::result::Result<T, LiveError>;
#[derive(Debug)]
struct LiveError(StatusCode, &'static str);
impl IntoResponse for LiveError {
    fn into_response(self) -> Response {
        no_store((self.0, Json(serde_json::json!({"error": self.1}))).into_response())
    }
}
fn invalid() -> LiveError { LiveError(StatusCode::BAD_GATEWAY, "Invalid live source response") }
fn unavailable() -> LiveError { LiveError(StatusCode::BAD_GATEWAY, "Live source unavailable; try again") }
fn expired() -> LiveError { LiveError(StatusCode::NOT_FOUND, "Live session ended; choose the channel again") }
fn no_store(mut response: Response) -> Response {
    response.headers_mut().insert(header::CACHE_CONTROL, "no-store, private".parse().unwrap());
    response.headers_mut().insert("referrer-policy", "no-referrer".parse().unwrap());
    response
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Channel {
    id: String,
    name: String,
    number: Option<String>,
    logo_url: Option<String>,
    group: Option<String>,
}
#[derive(Clone, Debug)]
struct Entry { channel: Channel, url: Url }
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Lineup { enabled: bool, source_name: String, channels: Vec<Channel>, message: Option<String> }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Tune { channel_id: String, client: Option<NativeClient> }
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum NativeClient { Roku }
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Tuned {
    session_id: String, playback_path: String, mime_type: &'static str,
    channel: Channel, can_pause: bool, can_seek: bool,
}
#[derive(Default)]
struct LineupCache { attempted: Option<Instant>, entries: Vec<Entry>, issue: Option<String> }
#[derive(Clone)]
struct Resource { url: Url, seen: Instant }
struct Session {
    root: String,
    touched: Instant,
    resources: HashMap<String, Resource>,
    revoked: Arc<AtomicBool>,
    roku: Option<Arc<crate::roku_live::Session>>,
}
impl Drop for Session {
    fn drop(&mut self) {
        self.revoked.store(true, Ordering::Relaxed);
        if let Some(roku) = &self.roku { roku.cancel(); }
    }
}
#[derive(Default)]
struct Sessions { items: HashMap<String, Session> }
impl Sessions {
    fn reap(&mut self, now: Instant) {
        self.items.retain(|_, session| {
            let keep = now.saturating_duration_since(session.touched) < IDLE;
            if !keep { session.revoked.store(true, Ordering::Relaxed); }
            keep
        });
    }
    fn create(&mut self, entry: &Entry, now: Instant) -> Result<String> {
        self.reap(now);
        if self.items.len() >= MAX_SESSIONS {
            return Err(LiveError(StatusCode::TOO_MANY_REQUESTS, "Too many live sessions; close another player and retry"));
        }
        let id = random_id()?;
        let root = entry.url.path().rsplit_once('/').ok_or_else(invalid)?.0.to_string() + "/";
        let resources = HashMap::from([("index.m3u8".into(), Resource { url: entry.url.clone(), seen: now })]);
        self.items.insert(id.clone(), Session { root, touched: now, resources, revoked: Arc::new(AtomicBool::new(false)), roku: None });
        Ok(id)
    }
    fn remove(&mut self, id: &str) {
        if let Some(session) = self.items.remove(id) { session.revoked.store(true, Ordering::Relaxed); }
    }
    fn resource(&mut self, id: &str, key: &str, now: Instant) -> Result<(Resource, Arc<AtomicBool>)> {
        self.reap(now);
        let session = self.items.get_mut(id).ok_or_else(expired)?;
        let resource = session.resources.get_mut(key).ok_or_else(expired)?;
        resource.seen = now;
        let resource = resource.clone();
        session.touched = now;
        Ok((resource, session.revoked.clone()))
    }
}
fn random_id() -> Result<String> {
    let mut bytes = [0u8; 24];
    getrandom::getrandom(&mut bytes).map_err(|_| LiveError(StatusCode::SERVICE_UNAVAILABLE, "Live sessions unavailable"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}
struct LiveState {
    cfg: LiveTv, token: String, origin: Url, lineup_url: Url, http: reqwest::Client,
    cache: AsyncMutex<LineupCache>, sessions: Mutex<Sessions>, requests: Arc<Semaphore>, guide: Arc<crate::epg::GuideService>,
    roku: Option<crate::roku_live::RokuLive>,
}

pub fn router(cfg: LiveTv, token: String) -> anyhow::Result<Router> {
    Ok(router_with_bridge(cfg, token)?.0)
}

#[derive(Clone)]
pub(crate) struct NativeBridge(Arc<LiveState>);
impl NativeBridge {
    pub(crate) async fn tune_sports(&self, embed: &str, event_id: &str, title: &str, client: Option<NativeClient>) -> crate::sports_native::BridgeResult<serde_json::Value> {
        if !self.0.cfg.enabled {
            return Err((StatusCode::SERVICE_UNAVAILABLE, "Native sports playback needs the live browser bridge"));
        }
        let _permit = self.0.requests.try_acquire().map_err(|_| (StatusCode::SERVICE_UNAVAILABLE, "Live browser is busy; retry shortly"))?;
        let url = crate::sports_native::start(&self.0.http, &self.0.origin, embed).await?;
        let channel = Channel { id: event_id.into(), name: title.into(), number: None, logo_url: None, group: Some("Live Sports".into()) };
        let entry = Entry { channel: channel.clone(), url };
        let id = self.0.sessions.lock().unwrap().create(&entry, Instant::now()).map_err(|e| (e.0, e.1))?;
        adapt_session(&self.0, &id, client).await.map_err(|e| (e.0,e.1))?;
        Ok(serde_json::json!({"sessionId":id,"playbackPath":format!("/live/streams/{id}/index.m3u8"),
            "mimeType":HLS,"channel":channel,"canPause":false,"canSeek":false}))
    }
}

pub(crate) fn router_with_bridge(cfg: LiveTv, token: String) -> anyhow::Result<(Router, NativeBridge)> {
    build_router(cfg,token,None)
}
pub(crate) fn router_with_roku_bridge(cfg: LiveTv, token: String, source_base: String) -> anyhow::Result<(Router, NativeBridge)> {
    build_router(cfg,token,Some(crate::roku_live::RokuLive::new(source_base)?))
}
fn build_router(cfg: LiveTv, token: String, roku: Option<crate::roku_live::RokuLive>) -> anyhow::Result<(Router, NativeBridge)> {
    let origin = configured_origin(&cfg.upstream_url).map_err(|_| anyhow::anyhow!("invalid live_tv.upstream_url: expected HTTP(S) origin without credentials or path"))?;
    let lineup_url = scoped_url(&origin, &origin, &cfg.lineup_path, "/playlist", true)
        .map_err(|_| anyhow::anyhow!("invalid live_tv.lineup_path: expected /playlist with optional query"))?;
    let http = reqwest::Client::builder().user_agent("velvet-live/0.1")
        .redirect(reqwest::redirect::Policy::none()).connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(60)).build()?;
    let guide_service = crate::epg::GuideService::new(cfg.enabled && cfg.guide_enabled);
    let state = Arc::new(LiveState { cfg, token, origin, lineup_url, http, guide: guide_service, roku,
        cache: AsyncMutex::new(LineupCache::default()), sessions: Mutex::new(Sessions::default()),
        requests: Arc::new(Semaphore::new(64)) });
    let weak = Arc::downgrade(&state);
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        loop {
            interval.tick().await;
            let Some(state) = weak.upgrade() else { break };
            state.sessions.lock().unwrap().reap(Instant::now());
        }
    });
    let protected = Router::new().route("/live/channels", get(channels))
        .route("/live/guide", get(guide)).route("/live/tune", post(tune)).route("/live/sessions/:id", delete(end_session))
        .layer(middleware::from_fn_with_state(state.clone(), auth));
    let bridge = NativeBridge(state.clone());
    Ok((protected.route("/live/streams/:id/:resource", get(playback)).with_state(state), bridge))
}
async fn auth(State(state): State<Arc<LiveState>>, request: Request, next: Next) -> Response {
    let authorized = state.token.is_empty() || request.headers().get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok()).is_some_and(|value| value == format!("Bearer {}", state.token));
    if authorized { no_store(next.run(request).await) }
    else { LiveError(StatusCode::UNAUTHORIZED, "unauthorized").into_response() }
}
async fn channels(State(state): State<Arc<LiveState>>) -> Response {
    if !state.cfg.enabled {
        return no_store(Json(Lineup { enabled: false, source_name: state.cfg.source_name.clone(), channels: vec![],
            message: Some("Live TV is not configured yet".into()) }).into_response());
    }
    let (entries, message) = load_lineup(&state).await;
    no_store(Json(Lineup { enabled: true, source_name: state.cfg.source_name.clone(),
        channels: entries.into_iter().map(|entry| entry.channel).collect(), message }).into_response())
}
async fn guide(State(state): State<Arc<LiveState>>) -> Response {
    let entries = if state.cfg.enabled { load_lineup(&state).await.0 } else { vec![] };
    let channels: Vec<_> = entries.into_iter().map(|entry| (entry.channel.id, entry.channel.name)).collect();
    no_store(Json(state.guide.snapshot(&state.cfg.source_name, &channels)).into_response())
}
async fn load_lineup(state: &LiveState) -> (Vec<Entry>, Option<String>) {
    let mut cache = state.cache.lock().await;
    if cache.attempted.is_some_and(|at| at.elapsed() < CACHE_AGE) {
        return (cache.entries.clone(), cache.issue.clone());
    }
    cache.attempted = Some(Instant::now());
    let fetched = async {
        let response = state.http.get(state.lineup_url.clone()).timeout(Duration::from_secs(12))
            .send().await.map_err(|_| unavailable())?;
        if !response.status().is_success() { return Err(unavailable()); }
        let text = read_text(response, MAX_LINEUP).await?;
        parse_lineup(&text, &state.origin)
    }.await;
    match fetched {
        Ok(entries) => {
            cache.entries = entries;
            cache.issue = if cache.entries.is_empty() { Some("No Spectrum channels are configured in the live source yet".into()) } else { None };
        },
        Err(_) => cache.issue = Some(if cache.entries.is_empty() { "Live source unavailable; try again shortly" }
            else { "Showing the last channel list; live source refresh failed" }.into()),
    }
    (cache.entries.clone(), cache.issue.clone())
}
async fn tune(State(state): State<Arc<LiveState>>, Json(request): Json<Tune>) -> Result<Response> {
    if !state.cfg.enabled { return Err(LiveError(StatusCode::SERVICE_UNAVAILABLE, "Live TV is not configured yet")); }
    if !safe_name(&request.channel_id) { return Err(LiveError(StatusCode::BAD_REQUEST, "Invalid channel")); }
    let (entries, _) = load_lineup(&state).await;
    let entry = entries.iter().find(|entry| entry.channel.id == request.channel_id)
        .ok_or(LiveError(StatusCode::NOT_FOUND, "Channel unavailable; refresh the channel list"))?;
    let id = state.sessions.lock().unwrap().create(entry, Instant::now())?;
    adapt_session(&state, &id, request.client).await?;
    Ok(no_store(Json(Tuned { playback_path: format!("/live/streams/{id}/index.m3u8"), session_id: id,
        mime_type: HLS, channel: entry.channel.clone(), can_pause: false, can_seek: false }).into_response()))
}
async fn adapt_session(state: &LiveState, id: &str, client: Option<NativeClient>) -> Result<()> {
    if client.is_none() { return Ok(()); }
    let result = async {
        let manager = state.roku.as_ref().ok_or(LiveError(StatusCode::SERVICE_UNAVAILABLE,"Roku live compatibility is not configured"))?;
        {
            let mut sessions = state.sessions.lock().unwrap();
            let session = sessions.items.get_mut(id).ok_or_else(expired)?;
            let source = session.resources.get("index.m3u8").cloned().ok_or_else(expired)?;
            session.resources.insert("source.m3u8".into(),source);
        }
        let remux = manager.start(id).await.map_err(|e| LiveError(e.0,e.1))?;
        {
            let mut sessions = state.sessions.lock().unwrap();
            let Some(session) = sessions.items.get_mut(id) else { remux.cancel(); return Err(expired()); };
            session.roku = Some(remux.clone());
        }
        remux.ready(Duration::from_secs(50)).await.map_err(|e| LiveError(e.0,e.1))
    }.await;
    if result.is_err() { state.sessions.lock().unwrap().remove(id); }
    result
}
async fn end_session(State(state): State<Arc<LiveState>>, Path(id): Path<String>) -> Response {
    state.sessions.lock().unwrap().remove(&id);
    no_store(StatusCode::NO_CONTENT.into_response())
}
async fn read_text(mut response: reqwest::Response, limit: usize) -> Result<String> {
    if response.content_length().is_some_and(|length| length > limit as u64) { return Err(invalid()); }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| unavailable())? {
        if bytes.len().saturating_add(chunk.len()) > limit { return Err(invalid()); }
        bytes.extend_from_slice(&chunk);
    }
    String::from_utf8(bytes).map_err(|_| invalid())
}
async fn playback(State(state): State<Arc<LiveState>>, Path((id, key)): Path<(String, String)>, headers: HeaderMap) -> Result<Response> {
    if key == "index.m3u8" || key == "media.m3u8" || key.starts_with("seg-") {
        let remux = {
            let mut sessions = state.sessions.lock().unwrap();
            sessions.reap(Instant::now());
            let session = sessions.items.get_mut(&id).ok_or_else(expired)?;
            session.touched = Instant::now();
            session.roku.clone()
        };
        if let Some(remux) = remux {
            return remux.asset(&key).await.map(no_store).map_err(|e| LiveError(e.0,e.1));
        }
    }
    let (resource, revoked) = state.sessions.lock().unwrap().resource(&id, &key, Instant::now())?;
    let permit = state.requests.clone().try_acquire_owned()
        .map_err(|_| LiveError(StatusCode::SERVICE_UNAVAILABLE, "Live source busy; retry shortly"))?;
    let playlist = resource.url.path().ends_with(".m3u8");
    let mut request = state.http.get(resource.url.clone());
    if !playlist {
        if let Some(range) = headers.get(header::RANGE) {
            let value = range.to_str().map_err(|_| LiveError(StatusCode::BAD_REQUEST, "Invalid byte range"))?;
            if !valid_range(value) { return Err(LiveError(StatusCode::BAD_REQUEST, "Invalid byte range")); }
            request = request.header(header::RANGE, value);
        }
    }
    let upstream = request.send().await.map_err(|error| {
        if error.is_timeout() { LiveError(StatusCode::GATEWAY_TIMEOUT, "Live channel took too long to start; retry") } else { unavailable() }
    })?;
    if revoked.load(Ordering::Relaxed) { return Err(expired()); }
    if !upstream.status().is_success() {
        // Never relay upstream bodies, cookies, redirects or login URLs.
        return Err(if upstream.status() == StatusCode::NOT_FOUND { LiveError(StatusCode::NOT_FOUND, "Live segment unavailable; retry the channel") }
            else { unavailable() });
    }
    if playlist {
        let text = read_text(upstream, MAX_PLAYLIST).await?;
        let mut sessions = state.sessions.lock().unwrap();
        sessions.reap(Instant::now());
        let session = sessions.items.get_mut(&id).ok_or_else(expired)?;
        let body = rewrite_playlist(&text, &state.origin, &resource.url, &id, session, Instant::now())?;
        return Ok(no_store(([(header::CONTENT_TYPE, HLS)], body).into_response()));
    }
    if upstream.content_length().is_some_and(|size| size > MAX_SEGMENT as u64) { return Err(invalid()); }
    let mut output = Response::builder().status(upstream.status());
    for name in [header::CONTENT_TYPE, header::CONTENT_LENGTH, header::CONTENT_RANGE, header::ACCEPT_RANGES] {
        if let Some(value) = upstream.headers().get(&name) { output = output.header(name, value.clone()); }
    }
    let bytes = upstream.bytes_stream();
    let streamed = futures::stream::unfold((bytes, permit, revoked, 0usize), |(mut bytes, permit, revoked, size)| async move {
        let next = bytes.next().await?;
        let item = match next {
            Ok(chunk) if !revoked.load(Ordering::Relaxed) && size.saturating_add(chunk.len()) <= MAX_SEGMENT => Ok(chunk),
            _ => Err(std::io::Error::other("Live segment interrupted")),
        };
        let total = size.saturating_add(item.as_ref().map_or(0, |chunk| chunk.len()));
        Some((item, (bytes, permit, revoked, total)))
    });
    Ok(no_store(output.body(Body::from_stream(streamed)).map_err(|_| invalid())?))
}
fn valid_range(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("bytes=") else { return false };
    if rest.len() > 42 { return false; }
    let Some((start, end)) = rest.split_once('-') else { return false };
    (!start.is_empty() || !end.is_empty()) && start.bytes().all(|b| b.is_ascii_digit()) && end.bytes().all(|b| b.is_ascii_digit())
}
fn safe_name(value: &str) -> bool {
    !value.is_empty() && value.len() <= 120 && value.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}
fn configured_origin(value: &str) -> Result<Url> {
    let url = Url::parse(value).map_err(|_| invalid())?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() || !url.username().is_empty()
        || url.password().is_some() || url.path() != "/" || url.query().is_some() || url.fragment().is_some() { return Err(invalid()); }
    Ok(url)
}
/// Validate before URL joining, which would otherwise silently normalize traversal.
fn scoped_url(origin: &Url, base: &Url, value: &str, scope: &str, lineup: bool) -> Result<Url> {
    if value.is_empty() || value.len() > 4096 || value.chars().any(|c| c.is_whitespace() || c.is_control())
        || value.contains(['\\', '%', '#', '{', '}']) || value.split(['/', '?']).any(|p| p == "." || p == "..") { return Err(invalid()); }
    let url = base.join(value).map_err(|_| invalid())?;
    if url.origin() != origin.origin() || !url.username().is_empty() || url.password().is_some()
        || url.fragment().is_some() { return Err(invalid()); }
    if lineup {
        if url.path() != scope { return Err(invalid()); }
    } else {
        if let Some(query) = url.query() {
            // Capture recovery deliberately changes init.mp4?v=N so players
            // fetch the new codec/timescale initialization after discontinuity.
            let versioned_init = url.path() == format!("{scope}init.mp4")
                && query.strip_prefix("v=").is_some_and(|digits| !digits.is_empty()
                    && digits.len() <= 20 && digits.bytes().all(|c| c.is_ascii_digit()));
            if !versioned_init { return Err(invalid()); }
        }
        // PrismCast's startup/composite playlists use shared, static preroll
        // media outside the channel directory. Permit only those exact public
        // media shapes, still on the configured origin and capability-mapped.
        if preroll_path(url.path()) { return Ok(url); }
        let filename = url.path().strip_prefix(scope).ok_or_else(invalid)?;
        if filename.is_empty() || filename.contains('/') || filename.len() > 180
            || !filename.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
            || filename.starts_with('.') { return Err(invalid()); }
        let extension = filename.rsplit('.').next().unwrap_or("");
        if !matches!(extension, "m3u8" | "m4s" | "mp4" | "ts" | "aac" | "vtt" | "key") { return Err(invalid()); }
    }
    Ok(url)
}
fn preroll_path(path: &str) -> bool {
    let Some(rest) = path.strip_prefix("/preroll/") else { return false };
    let Some((codec, file)) = rest.split_once('/') else { return false };
    if !matches!(codec, "h264" | "hevc") { return false; }
    if file == "init.mp4" { return true; }
    file.strip_prefix("segment").and_then(|s| s.strip_suffix(".m4s"))
        .is_some_and(|digits| !digits.is_empty() && digits.len() <= 10 && digits.bytes().all(|c| c.is_ascii_digit()))
}

/// Splits commas outside quoted strings, respecting escaped quotes in M3U attributes.
fn split_quoted(value: &str, separator: char) -> Result<Vec<&str>> {
    let mut quoted = false;
    let mut escaped = false;
    let mut start = 0;
    let mut result = Vec::new();
    for (index, ch) in value.char_indices() {
        if escaped { escaped = false; continue; }
        if quoted && ch == '\\' { escaped = true; continue; }
        if ch == '"' { quoted = !quoted; }
        if ch == separator && !quoted { result.push(&value[start..index]); start = index + ch.len_utf8(); }
    }
    if quoted || escaped { return Err(invalid()); }
    result.push(&value[start..]);
    Ok(result)
}
fn attributes(value: &str) -> Result<HashMap<String, String>> {
    let bytes = value.as_bytes();
    let mut index = 0;
    let mut result = HashMap::new();
    while index < bytes.len() {
        while index < bytes.len() && bytes[index].is_ascii_whitespace() { index += 1; }
        let start = index;
        while index < bytes.len() && !bytes[index].is_ascii_whitespace() && bytes[index] != b'=' { index += 1; }
        let key = &value[start..index];
        if index == bytes.len() || bytes[index] != b'=' { continue; }
        index += 1;
        let mut out = String::new();
        if bytes.get(index) == Some(&b'"') {
            index += 1;
            let start = index;
            let mut escaped = false;
            while index < bytes.len() {
                if !escaped && bytes[index] == b'"' { break; }
                if !escaped && bytes[index] == b'\\' { escaped = true; } else { escaped = false; }
                index += 1;
            }
            if index == bytes.len() { return Err(invalid()); }
            let raw = &value[start..index];
            let mut chars = raw.chars();
            while let Some(ch) = chars.next() { out.push(if ch == '\\' { chars.next().ok_or_else(invalid)? } else { ch }); }
            index += 1;
        } else {
            let start = index;
            while index < bytes.len() && !bytes[index].is_ascii_whitespace() { index += 1; }
            out.push_str(&value[start..index]);
        }
        if result.insert(key.to_string(), out).is_some() { return Err(invalid()); }
    }
    Ok(result)
}
fn parse_lineup(text: &str, origin: &Url) -> Result<Vec<Entry>> {
    if text.len() > MAX_LINEUP || !text.trim_start_matches('\u{feff}').trim_start().starts_with("#EXTM3U") { return Err(invalid()); }
    let mut pending: Option<(HashMap<String, String>, String)> = None;
    let mut entries = Vec::new();
    let mut seen = HashSet::new();
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        if line.len() > 16_384 { return Err(invalid()); }
        if let Some(info) = line.strip_prefix("#EXTINF:") {
            let fields = split_quoted(info, ',')?;
            if fields.len() < 2 { return Err(invalid()); }
            pending = Some((attributes(fields[0])?, fields[1..].join(",").trim().to_string()));
        } else if !line.starts_with('#') && !line.starts_with('\u{feff}') {
            let Some((attrs, title)) = pending.take() else { return Err(invalid()); };
            let url = origin.join(line).map_err(|_| invalid())?;
            let path: Vec<_> = url.path().split('/').collect();
            if path.len() != 4 || path[1] != "hls" || !safe_name(path[2]) || path[3] != "stream.m3u8" { return Err(invalid()); }
            let root = format!("/hls/{}/", path[2]);
            let url = scoped_url(origin, origin, line, &root, false)?;
            // The upstream channel key is the durable identity; metadata cannot redirect it.
            let id = path[2].to_string();
            if !seen.insert(id.clone()) { continue; }
            let label = if title.is_empty() { attrs.get("tvg-name").cloned().unwrap_or_else(|| id.clone()) } else { title };
            let optional = |key: &str| attrs.get(key).filter(|value| !value.is_empty()).cloned();
            let logo_url = optional("tvg-logo").and_then(|value| Url::parse(&value).ok())
                .filter(|url| matches!(url.scheme(), "http" | "https") && url.username().is_empty() && url.password().is_none())
                .map(|url| url.to_string());
            entries.push(Entry { channel: Channel { id, name: label, number: optional("channel-number").or_else(|| optional("tvg-chno")),
                logo_url, group: optional("group-title") }, url });
            if entries.len() > MAX_CHANNELS { return Err(invalid()); }
        }
    }
    if pending.is_some() { return Err(invalid()); }
    Ok(entries)
}
fn register_uri(origin: &Url, base: &Url, uri: &str, id: &str, session: &mut Session, now: Instant) -> Result<String> {
    let url = scoped_url(origin, base, uri, &session.root, false)?;
    if let Some((key, resource)) = session.resources.iter_mut().find(|(_, resource)| resource.url == url) {
        resource.seen = now;
        return Ok(format!("/live/streams/{id}/{key}"));
    }
    if session.resources.len() >= MAX_RESOURCES {
        // Players can keep refreshing a media/audio playlist for hours without
        // asking for its master again. Never evict those stable entry points.
        let oldest = session.resources.iter().filter(|(_, resource)| !resource.url.path().ends_with(".m3u8"))
            .min_by_key(|(_, resource)| resource.seen).map(|(key, _)| key.clone()).ok_or_else(invalid)?;
        session.resources.remove(&oldest);
    }
    // HLS demuxers validate/identify media by its extension, even with a valid
    // Content-Type. Retain only the extension already accepted by scoped_url;
    // the basename stays opaque and initialization query versions stay mapped.
    let extension = url.path().rsplit('.').next().ok_or_else(invalid)?;
    let key = format!("{}.{}", random_id()?, extension);
    session.resources.insert(key.clone(), Resource { url, seen: now });
    Ok(format!("/live/streams/{id}/{key}"))
}
fn rewrite_playlist(text: &str, origin: &Url, base: &Url, id: &str, session: &mut Session, now: Instant) -> Result<String> {
    if text.len() > MAX_PLAYLIST || text.lines().next().map(str::trim) != Some("#EXTM3U") { return Err(invalid()); }
    let mut output = String::new();
    let mut references = 0usize;
    for raw in text.lines() {
        let line = raw.trim();
        if line.len() > 16_384 { return Err(invalid()); }
        if line.starts_with("#EXT-X-DEFINE:") || line.starts_with("#EXT-X-CONTENT-STEERING:") { return Err(invalid()); }
        if !line.is_empty() && !line.starts_with('#') {
            references += 1;
            output.push_str(&register_uri(origin, base, line, id, session, now)?);
        } else if line.starts_with("#EXT") && line.contains("URI") {
            let (tag, list) = line.split_once(':').ok_or_else(invalid)?;
            let mut rewritten = Vec::new();
            for attr in split_quoted(list, ',')? {
                if let Some((key, value)) = attr.split_once('=') {
                    if key.trim() == "URI" {
                        references += 1;
                        let uri = value.trim().strip_prefix('"').and_then(|v| v.strip_suffix('"')).ok_or_else(invalid)?;
                        rewritten.push(format!("URI=\"{}\"", register_uri(origin, base, uri, id, session, now)?));
                        continue;
                    } else if key.contains("URI") { return Err(invalid()); }
                }
                rewritten.push(attr.to_string());
            }
            output.push_str(tag); output.push(':'); output.push_str(&rewritten.join(","));
        } else {
            output.push_str(line);
        }
        // A valid PrismCast window has only a handful of references. Keeping a
        // single response below half the map cap prevents self-eviction.
        if references > MAX_RESOURCES / 2 { return Err(invalid()); }
        output.push('\n');
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    fn origin() -> Url { Url::parse("http://bridge:5589/").unwrap() }
    fn entry() -> Entry {
        parse_lineup("#EXTM3U\n#EXTINF:-1 channel-id=\"espn\",ESPN\n/hls/espn/stream.m3u8\n", &origin()).unwrap().remove(0)
    }
    fn session() -> (String, Session) {
        let mut sessions = Sessions::default();
        let id = sessions.create(&entry(), Instant::now()).unwrap();
        let session = sessions.items.remove(&id).unwrap();
        (id, session)
    }

    #[test]
    fn m3u_keeps_real_channel_metadata_and_quoted_commas() {
        let text = "\u{feff}#EXTM3U\r\n#EXTINF:-1 channel-id=\"untrusted-display-id\" tvg-name=\"ESPN, HD\" channel-number=\"30\" group-title=\"Sports, Live\" tvg-logo=\"https://images.example/espn.png\",ESPN, HD\r\nhttp://bridge:5589/hls/espn/stream.m3u8\r\n#EXTINF:-1,Duplicate\n/hls/espn/stream.m3u8\n";
        let result = parse_lineup(text, &origin()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].channel, Channel { id: "espn".into(), name: "ESPN, HD".into(), number: Some("30".into()),
            logo_url: Some("https://images.example/espn.png".into()), group: Some("Sports, Live".into()) });
        assert_eq!(attributes("-1 tvg-name=\"The \\\"Game\\\"\"").unwrap()["tvg-name"], "The \"Game\"");
    }

    #[test]
    fn malformed_or_foreign_lineups_never_become_tunable() {
        for text in ["<html>Sign in</html>", "#EXTM3U\n#EXTINF:-1,ESPN", "#EXTM3U\n/hls/espn/stream.m3u8",
            "#EXTM3U\n#EXTINF:-1,ESPN\nhttps://evil.example/hls/espn/stream.m3u8",
            "#EXTM3U\n#EXTINF:-1,ESPN\n/hls/espn/../admin/stream.m3u8",
            "#EXTM3U\n#EXTINF:-1,ESPN\n/config",
            "#EXTM3U\n#EXTINF:-1 tvg-name=\"unterminated,ESPN\n/hls/espn/stream.m3u8"] {
            assert!(parse_lineup(text, &origin()).is_err(), "accepted {text}");
        }
        assert!(parse_lineup("#EXTM3U\n", &origin()).unwrap().is_empty());
    }

    #[test]
    fn scoped_urls_reject_traversal_foreign_origin_and_cross_channel() {
        let base = entry().url;
        for uri in ["https://evil.example/x.ts", "//evil.example/x.ts", "http://bridge:5590/hls/espn/x.ts", "http://user@bridge:5589/hls/espn/x.ts",
            "../fs1/x.ts", "./x.ts", "%2e%2e/x.ts", "%252e%252e/x.ts", "/hls/fs1/x.ts", "/admin/config", "\\evil.example\\x.ts",
            "segment.ts?url=http://evil.example", "data:text/plain,a", "/hls/espn/.hidden.ts", "/hls/espn/sub/x.ts", "{$host}/x.ts"] {
            assert!(scoped_url(&origin(), &base, uri, "/hls/espn/", false).is_err(), "accepted {uri}");
        }
        for uri in ["segment12.m4s", "/hls/espn/init.mp4", "http://bridge:5589/hls/espn/audio.m3u8"] {
            assert!(scoped_url(&origin(), &base, uri, "/hls/espn/", false).is_ok());
        }
        for url in ["file:///tmp", "http://bridge:5589/path", "http://user:secret@bridge:5589", "http://bridge:5589/?a=b"] {
            assert!(configured_origin(url).is_err());
        }
    }

    #[test]
    fn master_media_map_key_and_segment_references_stay_in_the_session() {
        let (id, mut session) = session();
        let source = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio, main\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=6000000,AUDIO=\"audio, main\"\nvideo.m3u8\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.key\"\n#EXTINF:2.000,\nsegment1.m4s\n";
        let rewritten = rewrite_playlist(source, &origin(), &entry().url, &id, &mut session, Instant::now()).unwrap();
        assert!(!rewritten.contains("bridge:5589"));
        assert_eq!(rewritten.matches(&format!("/live/streams/{id}/")).count(), 5);
        assert!(rewritten.contains("GROUP-ID=\"audio, main\""));
        assert_eq!(session.resources.len(), 6);
        let again = rewrite_playlist(source, &origin(), &entry().url, &id, &mut session, Instant::now()).unwrap();
        assert_eq!(again, rewritten);
        assert_eq!(session.resources.len(), 6);
    }

    #[test]
    fn playlists_cannot_smuggle_external_or_indirect_references() {
        for payload in ["#EXT-X-MAP:URI=\"https://evil.example/init.mp4\"", "#EXT-X-MEDIA:URI = \"https://evil.example/audio.m3u8\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"/admin/key.key\"", "#EXT-X-CONTENT-STEERING:SERVER-URI=\"steering.json\"",
            "#EXT-X-DEFINE:NAME=\"host\",VALUE=\"evil.example\"", "../fs1/stream.m3u8", "#EXT-X-MAP:URI=init.mp4"] {
            let (id, mut session) = session();
            assert!(rewrite_playlist(&format!("#EXTM3U\n{payload}\n"), &origin(), &entry().url, &id, &mut session, Instant::now()).is_err(), "accepted {payload}");
        }
    }

    #[test]
    fn preroll_accepts_only_documented_static_media_on_the_trusted_origin() {
        let base = entry().url;
        for codec in ["h264", "hevc"] {
            for file in ["init.mp4", "segment0.m4s", "segment123.m4s"] {
                let path = format!("http://bridge:5589/preroll/{codec}/{file}");
                assert!(scoped_url(&origin(), &base, &path, "/hls/espn/", false).is_ok());
            }
        }
        for path in ["/preroll/h264/admin", "/preroll/h264/stream.m3u8", "/preroll/h264/segment-1.m4s", "/preroll/h264/segment.m4s",
            "/preroll/h264/segment0.ts", "/preroll/av1/init.mp4", "/preroll/hevc/sub/init.mp4", "/preroll/h264/init.mp4?url=admin",
            "/preroll/h264/../admin/init.mp4", "/preroll/%68%32%36%34/init.mp4", "http://evil.example/preroll/h264/init.mp4"] {
            assert!(scoped_url(&origin(), &base, path, "/hls/espn/", false).is_err(), "accepted {path}");
        }
        let (id, mut session) = session();
        let playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"http://bridge:5589/preroll/h264/init.mp4\"\n#EXTINF:2,\nhttp://bridge:5589/preroll/h264/segment0.m4s\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\nsegment1.m4s\n";
        let output = rewrite_playlist(playlist, &origin(), &base, &id, &mut session, Instant::now()).unwrap();
        assert_eq!(output.matches(&format!("/live/streams/{id}/")).count(), 4);
        assert!(output.contains("#EXT-X-DISCONTINUITY"));
        assert!(!output.contains("/preroll/"));
    }

    #[test]
    fn capture_init_versions_keep_distinct_resources_and_reject_other_queries() {
        let (id, mut session) = session();
        let first = register_uri(&origin(), &entry().url, "init.mp4?v=0", &id, &mut session, Instant::now()).unwrap();
        let next = register_uri(&origin(), &entry().url, "init.mp4?v=1", &id, &mut session, Instant::now()).unwrap();
        assert_ne!(first, next);
        assert!(first.ends_with(".mp4") && next.ends_with(".mp4"));
        assert!(session.resources.values().any(|resource| resource.url.query() == Some("v=1")));
        for uri in ["init.mp4?v=", "init.mp4?v=-1", "init.mp4?v=1&other=2", "init.mp4?url=http://evil.example", "segment1.m4s?v=1", "audio.m3u8?v=1", "/preroll/h264/init.mp4?v=1"] {
            assert!(scoped_url(&origin(), &entry().url, uri, "/hls/espn/", false).is_err(), "accepted {uri}");
        }
    }

    #[test]
    fn opaque_media_paths_preserve_hls_demuxer_extensions() {
        let (id, mut session) = session();
        for uri in ["video.m3u8", "init.mp4?v=7", "segment12.m4s", "audio12.ts", "audio.aac", "captions.vtt", "encryption.key",
            "/preroll/h264/init.mp4", "/preroll/hevc/segment1.m4s"] {
            let path = register_uri(&origin(), &entry().url, uri, &id, &mut session, Instant::now()).unwrap();
            let extension = uri.split('?').next().unwrap().rsplit('.').next().unwrap();
            let filename = path.rsplit('/').next().unwrap();
            let (opaque, actual_extension) = filename.rsplit_once('.').unwrap();
            assert_eq!(actual_extension, extension);
            assert_eq!(opaque.len(), 48);
            assert!(opaque.bytes().all(|byte| byte.is_ascii_hexdigit()));
            assert_eq!(session.resources[filename].url.path().rsplit('.').next(), Some(extension));
        }
    }

    #[test]
    fn sessions_are_isolated_revocable_and_idle_expire_without_absolute_deadline() {
        let mut sessions = Sessions::default();
        let start = Instant::now();
        let first = sessions.create(&entry(), start).unwrap();
        let second = sessions.create(&entry(), start).unwrap();
        assert_ne!(first, second);
        assert_eq!(first.len(), 48);
        let (_, revoked) = sessions.resource(&first, "index.m3u8", start).unwrap();
        sessions.remove(&first);
        sessions.remove(&first); // idempotent
        assert!(revoked.load(Ordering::Relaxed));
        assert!(sessions.resource(&first, "index.m3u8", start).is_err());
        for minute in 1..360 {
            assert!(sessions.resource(&second, "index.m3u8", start + Duration::from_secs(minute * 60)).is_ok());
        }
        assert!(sessions.resource(&second, "index.m3u8", start + Duration::from_secs(360 * 60 + 60)).is_err());
        assert!(sessions.items.is_empty());
    }

    #[test]
    fn session_capacity_does_not_evict_an_active_viewer_and_abandoned_tunes_expire() {
        let mut sessions = Sessions::default();
        let start = Instant::now();
        let mut ids = Vec::new();
        for _ in 0..MAX_SESSIONS { ids.push(sessions.create(&entry(), start).unwrap()); }
        assert_eq!(sessions.create(&entry(), start).unwrap_err().0, StatusCode::TOO_MANY_REQUESTS);
        assert!(sessions.resource(&ids[0], "index.m3u8", start + Duration::from_secs(90)).is_ok());
        sessions.reap(start + Duration::from_secs(121));
        assert_eq!(sessions.items.len(), 1);
        assert!(sessions.items.contains_key(&ids[0]));
        assert!(sessions.create(&entry(), start + Duration::from_secs(121)).is_ok());
    }

    #[test]
    fn long_running_channels_keep_resource_memory_bounded() {
        let (id, mut session) = session();
        let start = Instant::now();
        for n in 0..MAX_RESOURCES * 3 {
            let uri = format!("segment{n}.m4s");
            register_uri(&origin(), &entry().url, &uri, &id, &mut session, start + Duration::from_secs(n as u64)).unwrap();
        }
        assert_eq!(session.resources.len(), MAX_RESOURCES);
        assert!(session.resources.contains_key("index.m3u8"));
        assert!(session.resources.values().any(|r| r.url.path().ends_with(&format!("segment{}.m4s", MAX_RESOURCES * 3 - 1))));
        assert!(!session.resources.values().any(|r| r.url.path().ends_with("segment0.m4s")));
    }

    #[test]
    fn active_media_and_audio_playlists_survive_hours_of_segment_eviction() {
        let mut sessions = Sessions::default();
        let start = Instant::now();
        let id = sessions.create(&entry(), start).unwrap();
        let session = sessions.items.get_mut(&id).unwrap();
        let video_path = register_uri(&origin(), &entry().url, "video.m3u8", &id, session, start).unwrap();
        let audio_path = register_uri(&origin(), &entry().url, "audio.m3u8", &id, session, start).unwrap();
        let video_key = video_path.rsplit('/').next().unwrap();
        let audio_key = audio_path.rsplit('/').next().unwrap();
        for n in 0..MAX_RESOURCES * 4 {
            let now = start + Duration::from_secs(n as u64 * 6);
            for key in [video_key, audio_key] {
                let (resource, _) = sessions.resource(&id, key, now).unwrap();
                assert_eq!(resource.seen, now);
            }
            let session = sessions.items.get_mut(&id).unwrap();
            register_uri(&origin(), &entry().url, &format!("segment{n}.m4s"), &id, session, now).unwrap();
        }
        let session = &sessions.items[&id];
        assert_eq!(session.resources.len(), MAX_RESOURCES);
        assert!(session.resources.contains_key("index.m3u8"));
        assert!(session.resources.contains_key(video_key));
        assert!(session.resources.contains_key(audio_key));
    }

    struct Server(tokio::task::JoinHandle<()>);
    impl Drop for Server { fn drop(&mut self) { self.0.abort(); } }
    async fn serve_fixture(router: Router, listener: tokio::net::TcpListener) -> Server {
        Server(tokio::spawn(async move { axum::serve(listener, router).await.unwrap(); }))
    }

    #[tokio::test]
    async fn live_http_contract_auth_rewrite_bytes_and_viewer_isolation() {
        let upstream_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_base = format!("http://{}", upstream_listener.local_addr().unwrap());
        let starts = Arc::new(AtomicUsize::new(0));
        let counted = starts.clone();
        let preroll_base = upstream_base.clone();
        let upstream = Router::new()
            .route("/playlist", get(|| async { "#EXTM3U\n#EXTINF:-1 channel-number=\"30\",ESPN\n/hls/espn/stream.m3u8\n" }))
            .route("/hls/espn/stream.m3u8", get(move || { let counted = counted.clone(); async move {
                counted.fetch_add(1, Ordering::Relaxed);
                "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=6000000,AUDIO=\"audio\"\nvideo.m3u8\n"
            } }))
            .route("/hls/espn/video.m3u8", get(move || { let base = preroll_base.clone(); async move {
                format!("#EXTM3U\n#EXT-X-MAP:URI=\"{base}/preroll/h264/init.mp4\"\n#EXTINF:2,\n{base}/preroll/h264/segment0.m4s\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init.mp4?v=3\"\n#EXTINF:2,\nsegment1.m4s\n")
            } }))
            .route("/preroll/h264/init.mp4", get(|| async { b"preroll-init".to_vec() }))
            .route("/preroll/h264/segment0.m4s", get(|| async { b"preroll".to_vec() }))
            .route("/hls/espn/audio.m3u8", get(|| async { "#EXTM3U\n#EXTINF:2,\naudio1.ts\n" }))
            .route("/hls/espn/audio1.ts", get(|| async { b"audio".to_vec() }))
            .route("/hls/espn/init.mp4", get(|uri: axum::http::Uri| async move { assert_eq!(uri.query(), Some("v=3")); ([(header::CONTENT_TYPE, "video/mp4")], b"init".to_vec()) }))
            .route("/hls/espn/segment1.m4s", get(|headers: HeaderMap| async move {
                assert_eq!(headers.get(header::RANGE).unwrap(), "bytes=0-3");
                (StatusCode::PARTIAL_CONTENT, [(header::CONTENT_TYPE, "video/mp4"), (header::CONTENT_RANGE, "bytes 0-3/8")], b"abcd".to_vec())
            }));
        let _upstream = serve_fixture(upstream, upstream_listener).await;
        let adapter = router(LiveTv { enabled: true, upstream_url: upstream_base, ..LiveTv::default() }, "shared".into()).unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let _adapter = serve_fixture(adapter, listener).await;
        let client = reqwest::Client::new();
        assert_eq!(client.get(format!("{base}/live/channels")).send().await.unwrap().status(), StatusCode::UNAUTHORIZED);
        let lineup: serde_json::Value = client.get(format!("{base}/live/channels")).bearer_auth("shared").send().await.unwrap().json().await.unwrap();
        assert_eq!(lineup["enabled"], true);
        assert_eq!(lineup["channels"][0]["id"], "espn");
        let mut tuned = Vec::new();
        for _ in 0..2 {
            let response = client.post(format!("{base}/live/tune")).bearer_auth("shared").json(&serde_json::json!({"channelId":"espn"})).send().await.unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            tuned.push(response.json::<serde_json::Value>().await.unwrap());
        }
        assert_eq!(starts.load(Ordering::Relaxed), 0, "tune must not await upstream capture");
        assert_eq!(tuned[0]["canSeek"], false);
        assert_eq!(tuned[0]["canPause"], false);
        assert_eq!(tuned[0]["mimeType"], HLS);
        let first_path = tuned[0]["playbackPath"].as_str().unwrap();
        let response = client.get(format!("{base}{first_path}")).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK); // no bearer on capability
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store, private");
        let master = response.text().await.unwrap();
        let audio_path = master.split("URI=\"").nth(1).unwrap().split('"').next().unwrap();
        let audio_playlist = client.get(format!("{base}{audio_path}")).send().await.unwrap().text().await.unwrap();
        let audio_segment = audio_playlist.lines().find(|line| line.starts_with("/live/")).unwrap();
        assert!(audio_segment.ends_with(".ts"));
        assert_eq!(client.get(format!("{base}{audio_segment}")).send().await.unwrap().bytes().await.unwrap().as_ref(), b"audio");
        let video_path = master.lines().find(|line| line.starts_with("/live/")).unwrap();
        let playlist = client.get(format!("{base}{video_path}")).send().await.unwrap().text().await.unwrap();
        let preroll_map = playlist.split("URI=\"").nth(1).unwrap().split('"').next().unwrap();
        assert!(preroll_map.ends_with(".mp4"));
        assert_eq!(client.get(format!("{base}{preroll_map}")).send().await.unwrap().bytes().await.unwrap().as_ref(), b"preroll-init");
        let preroll_segment = playlist.lines().find(|line| line.starts_with("/live/")).unwrap();
        assert!(preroll_segment.ends_with(".m4s"));
        assert_eq!(client.get(format!("{base}{preroll_segment}")).send().await.unwrap().bytes().await.unwrap().as_ref(), b"preroll");
        let map_path = playlist.split("URI=\"").nth(2).unwrap().split('"').next().unwrap();
        assert!(map_path.ends_with(".mp4"));
        assert_eq!(client.get(format!("{base}{map_path}")).send().await.unwrap().bytes().await.unwrap().as_ref(), b"init");
        let segment_path = playlist.lines().filter(|line| line.starts_with("/live/")).nth(1).unwrap();
        assert!(segment_path.ends_with(".m4s"));
        let segment = client.get(format!("{base}{segment_path}")).header(header::RANGE, "bytes=0-3").send().await.unwrap();
        assert_eq!(segment.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(segment.headers()[header::CONTENT_RANGE], "bytes 0-3/8");
        assert_eq!(segment.bytes().await.unwrap().as_ref(), b"abcd");
        let delete_url = format!("{base}/live/sessions/{}", tuned[0]["sessionId"].as_str().unwrap());
        assert_eq!(client.delete(&delete_url).send().await.unwrap().status(), StatusCode::UNAUTHORIZED);
        for _ in 0..2 { assert_eq!(client.delete(&delete_url).bearer_auth("shared").send().await.unwrap().status(), StatusCode::NO_CONTENT); }
        assert_eq!(client.get(format!("{base}{first_path}")).send().await.unwrap().status(), StatusCode::NOT_FOUND);
        assert_eq!(client.get(format!("{base}{}", tuned[1]["playbackPath"].as_str().unwrap())).send().await.unwrap().status(), StatusCode::OK);
        assert_eq!(starts.load(Ordering::Relaxed), 2);
        assert_eq!(client.get(format!("{base}/live/streams/{}/admin", tuned[1]["sessionId"].as_str().unwrap())).send().await.unwrap().status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn http_proxy_refuses_redirects_and_playlist_traversal() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_base = format!("http://{}", listener.local_addr().unwrap());
        let admin_calls = Arc::new(AtomicUsize::new(0));
        let counted = admin_calls.clone();
        let target = format!("{upstream_base}/admin");
        let upstream = Router::new()
            .route("/playlist", get(|| async { "#EXTM3U\n#EXTINF:-1,Redirect\n/hls/redirect/stream.m3u8\n#EXTINF:-1,Escape\n/hls/escape/stream.m3u8\n" }))
            .route("/hls/redirect/stream.m3u8", get(move || { let target = target.clone(); async move { (StatusCode::FOUND, [(header::LOCATION, target)]) } }))
            .route("/hls/escape/stream.m3u8", get(|| async { "#EXTM3U\n#EXT-X-MAP:URI=\"../../admin.mp4\"\n" }))
            .route("/admin", get(move || { let counted = counted.clone(); async move { counted.fetch_add(1, Ordering::Relaxed); "private" } }));
        let _upstream = serve_fixture(upstream, listener).await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let _server = serve_fixture(router(LiveTv { enabled: true, upstream_url: upstream_base, ..LiveTv::default() }, String::new()).unwrap(), listener).await;
        let client = reqwest::Client::new();
        for channel in ["redirect", "escape"] {
            let tuned: serde_json::Value = client.post(format!("{base}/live/tune")).json(&serde_json::json!({"channelId":channel})).send().await.unwrap().json().await.unwrap();
            let response = client.get(format!("{base}{}", tuned["playbackPath"].as_str().unwrap())).send().await.unwrap();
            assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
            let message = response.text().await.unwrap();
            assert!(!message.contains("private"));
            assert!(!message.contains("127.0.0.1"));
        }
        assert_eq!(admin_calls.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn disabled_live_tv_needs_no_working_bridge_and_does_not_tune() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let _server = serve_fixture(router(LiveTv::default(), String::new()).unwrap(), listener).await;
        let client = reqwest::Client::new();
        let lineup: serde_json::Value = client.get(format!("{base}/live/channels")).send().await.unwrap().json().await.unwrap();
        assert_eq!(lineup["enabled"], false);
        assert_eq!(lineup["channels"].as_array().unwrap().len(), 0);
        assert_eq!(client.post(format!("{base}/live/tune")).json(&serde_json::json!({"channelId":"espn"})).send().await.unwrap().status(), StatusCode::SERVICE_UNAVAILABLE);
    }
}
