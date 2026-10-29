//! Live TV is separate from finite VOD/NZB playback and never touches watch state.
//! Only configured live-source origins are reachable. Playback URLs are revocable,
//! idle-expiring capabilities; no provider credentials or bearer headers reach players.
use std::{collections::{HashMap, HashSet}, sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}}, time::{Duration, Instant}};
use axum::{body::Body, extract::{Path, Request, State}, http::{header, HeaderMap, StatusCode}, middleware::{self, Next}, response::{IntoResponse, Response}, routing::{delete, get, post}, Json, Router};
use futures::StreamExt;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex as AsyncMutex, Semaphore};

use crate::config::LiveTv;

#[path = "live_native.rs"]
mod native;

const IDLE: Duration = Duration::from_secs(120);
const CACHE_AGE: Duration = Duration::from_secs(60);
const MAX_SESSIONS: usize = 32;
const MAX_RESOURCES: usize = 512;
const MAX_CHANNELS: usize = 1000;
const MAX_PLAYLIST: usize = 512 * 1024;
const MAX_LINEUP: usize = 2 * 1024 * 1024;
const MAX_SEGMENT: usize = 64 * 1024 * 1024;
const HLS: &str = "application/vnd.apple.mpegurl";
const DIRECT_PROBE_TIMEOUT: Duration = Duration::from_secs(12);
const DIRECT_RETRY: Duration = Duration::from_secs(120);
const MAX_DIRECT_PLAYLISTS: usize = 24;
// Network TVE feeds expose a longer DVR window and multiple ABR renditions than
// PrismCast's short capture playlist. Preserve their sequence/key semantics while
// keeping distinct, bounded budgets for the two source types.
const MAX_DIRECT_REFERENCES: usize = 1024;
const MAX_DIRECT_RESOURCES: usize = 4096;

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

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
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
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Tune { channel_id: String, #[serde(skip_serializing_if = "Option::is_none")] client: Option<NativeClient> }
#[derive(Clone, Copy, Deserialize, Serialize)]
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
#[derive(Clone, Debug)]
struct DirectScope { origin: Url, number: String, provider_id: String }
#[derive(Clone, Debug)]
struct DirectChannel { scope: DirectScope, url: Url, name: String, station_id: String }
#[derive(Default)]
struct DirectCache { attempted: Option<Instant>, channels: Vec<DirectChannel> }
type DirectFailures = Arc<Mutex<HashMap<String, Instant>>>;
#[derive(Clone)]
struct DirectFailureMark { failures: DirectFailures, provider_id: String }
impl DirectFailureMark {
    fn record(&self) { self.failures.lock().unwrap().insert(self.provider_id.clone(), Instant::now()); }
}
struct DirectTve {
    origin: Url,
    cache: AsyncMutex<DirectCache>,
    probes: Semaphore,
    failures: DirectFailures,
}
struct Session {
    root: String,
    direct: Option<DirectScope>,
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
        self.items.insert(id.clone(), Session { root, direct: None, touched: now, resources, revoked: Arc::new(AtomicBool::new(false)), roku: None });
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
    direct: Option<DirectTve>,
    native: Option<native::NativeSpectrum>,
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
    let native = cfg.native_spectrum_url.as_deref().map(native::NativeSpectrum::new).transpose()?;
    let origin = configured_origin(&cfg.upstream_url).map_err(|_| anyhow::anyhow!("invalid live_tv.upstream_url: expected HTTP(S) origin without credentials or path"))?;
    let lineup_url = scoped_url(&origin, &origin, &cfg.lineup_path, "/playlist", true)
        .map_err(|_| anyhow::anyhow!("invalid live_tv.lineup_path: expected /playlist with optional query"))?;
    let direct = cfg.direct_tve_url.as_deref().map(|value| {
        let origin = configured_origin(value).map_err(|_| anyhow::anyhow!("invalid live_tv.direct_tve_url: expected private HTTP(S) origin without credentials or path"))?;
        Ok::<_, anyhow::Error>(DirectTve { origin, cache: AsyncMutex::new(DirectCache::default()),
            probes: Semaphore::new(4), failures: Arc::new(Mutex::new(HashMap::new())) })
    }).transpose()?;
    let http = reqwest::Client::builder().user_agent("velvet-live/0.1")
        .redirect(reqwest::redirect::Policy::none()).connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(60)).build()?;
    let guide_service = crate::epg::GuideService::new(cfg.enabled && cfg.guide_enabled);
    let state = Arc::new(LiveState { cfg, token, origin, lineup_url, http, guide: guide_service, roku, direct, native,
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
    Ok((protected.route("/live/streams/:id/:resource", get(playback))
        .route("/live/drm/:id", post(native::license))
        .route("/live/cert/:id", get(native::certificate)).with_state(state), bridge))
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
    let (channels, message) = load_channels(&state).await;
    no_store(Json(Lineup { enabled: true, source_name: state.cfg.source_name.clone(),
        channels, message }).into_response())
}
async fn guide(State(state): State<Arc<LiveState>>) -> Response {
    let entries = if state.cfg.enabled { load_channels(&state).await.0 } else { vec![] };
    let channels: Vec<_> = entries.iter().map(|channel| (channel.id.clone(), channel.name.clone())).collect();
    let mut guide = state.guide.snapshot(&state.cfg.source_name, &channels);
    if state.cfg.enabled && state.cfg.guide_enabled {
        if let Some(native) = &state.native {
            if let Some(provider_guide) = native.guide(&entries).await { guide = guide.prefer_native(provider_guide); }
        }
    }
    no_store(Json(guide).into_response())
}
async fn load_channels(state: &LiveState) -> (Vec<Channel>, Option<String>) {
    if let Some(native) = &state.native { return native.channels().await; }
    let (entries, message) = load_lineup(state).await;
    (entries.into_iter().map(|entry| entry.channel).collect(), message)
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

// Reviewed national feed identities only. In particular, FOX affiliates and BTN
// overflow feeds must never be substituted based on a similar display name.
struct DirectMatch {
    channel_id: &'static str, channel_name: &'static str,
    provider_id: &'static str, name: &'static str, station_id: &'static str,
}
const DIRECT_MATCHES: &[DirectMatch] = &[
    DirectMatch { channel_id: "fox-sports-1", channel_name: "Fox Sports 1", provider_id: "foxone.FS1", name: "FS1", station_id: "82547" },
    DirectMatch { channel_id: "fox-sports-1", channel_name: "Fox Sports 1", provider_id: "foxsports.FS1", name: "FS1", station_id: "82547" },
    DirectMatch { channel_id: "fs2", channel_name: "FS2", provider_id: "foxone.FS2", name: "FS2", station_id: "59305" },
    DirectMatch { channel_id: "fs2", channel_name: "FS2", provider_id: "foxsports.FS2", name: "FS2", station_id: "59305" },
    DirectMatch { channel_id: "bigten", channel_name: "Big 10", provider_id: "foxone.B1G Network", name: "B1G Network", station_id: "58321" },
    DirectMatch { channel_id: "bigten", channel_name: "Big 10", provider_id: "foxsports.B1G Network", name: "B1G Network", station_id: "58321" },
    DirectMatch { channel_id: "fnc", channel_name: "Fox News", provider_id: "foxone.FOX News Channel", name: "FOX News Channel", station_id: "60179" },
    DirectMatch { channel_id: "fbc", channel_name: "Fox Business", provider_id: "foxone.FOX Business Network", name: "FOX Business Network", station_id: "58718" },
    DirectMatch { channel_id: "fox-weather", channel_name: "Fox Weather", provider_id: "foxone.Fox Weather", name: "Fox Weather", station_id: "121307" },
];
fn direct_matches(channel: &Channel) -> impl Iterator<Item = &'static DirectMatch> + '_ {
    DIRECT_MATCHES.iter().filter(|m| m.channel_id == channel.id && m.channel_name.eq_ignore_ascii_case(channel.name.trim()))
}
fn direct_number(value: &str) -> bool {
    !value.is_empty() && value.len() <= 10 && value.bytes().all(|b| b.is_ascii_digit())
}
fn direct_random(value: &str) -> bool {
    value.len() == 8 && value.bytes().all(|b| b.is_ascii_alphanumeric())
}
/// EPlusTV 4.16.6's proxy routes, confined to this channel and the configured
/// origin. Do not accept a generic URL proxy, CDN URL, query or redirect here.
fn direct_url(scope: &DirectScope, base: &Url, value: &str) -> Result<Url> {
    if value.is_empty() || value.len() > 4096 || value.chars().any(|c| c.is_whitespace() || c.is_control())
        || value.contains(['\\', '%', '#', '{', '}', '?']) || value.split('/').any(|p| p == "." || p == "..") { return Err(invalid()); }
    let url = base.join(value).map_err(|_| invalid())?;
    if url.origin() != scope.origin.origin() || !url.username().is_empty() || url.password().is_some()
        || url.query().is_some() || url.fragment().is_some() { return Err(invalid()); }
    if url.path() == format!("/channels/{}.m3u8", scope.number) { return Ok(url); }
    if let Some(file) = url.path().strip_prefix(&format!("/chunklist/{}/", scope.number)) {
        if file.strip_suffix(".m3u8").is_some_and(direct_random) { return Ok(url); }
    }
    if let Some(file) = url.path().strip_prefix(&format!("/channels/{}/", scope.number)) {
        for (kind, extension) in [("segment", "ts"), ("key", "key"), ("m4i", "m4i")] {
            if file.strip_prefix(&format!("{}-{kind}-", scope.number))
                .and_then(|name| name.strip_suffix(&format!(".{extension}"))).is_some_and(direct_random) { return Ok(url); }
        }
    }
    Err(invalid())
}
fn parse_direct_lineup(text: &str, origin: &Url) -> Result<Vec<DirectChannel>> {
    if text.len() > MAX_LINEUP || !text.trim_start_matches('\u{feff}').trim_start().starts_with("#EXTM3U") { return Err(invalid()); }
    let mut pending = None;
    let mut channels = Vec::new();
    let mut seen = HashSet::new();
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        if line.len() > 16_384 { return Err(invalid()); }
        if let Some(info) = line.strip_prefix("#EXTINF:") {
            let fields = split_quoted(info, ',')?;
            if fields.len() < 2 || pending.is_some() { return Err(invalid()); }
            pending = Some((attributes(fields[0])?, fields[1..].join(",").trim().to_string()));
        } else if !line.starts_with('#') && !line.starts_with('\u{feff}') {
            let (attrs, name) = pending.take().ok_or_else(invalid)?;
            let url = origin.join(line).map_err(|_| invalid())?;
            let number = url.path().strip_prefix("/channels/").and_then(|p| p.strip_suffix(".m3u8")).filter(|v| direct_number(v)).ok_or_else(invalid)?;
            let provider_id = attrs.get("channel-id").filter(|v| !v.is_empty() && v.len() <= 120).ok_or_else(invalid)?.clone();
            let scope = DirectScope { origin: origin.clone(), number: number.into(), provider_id: provider_id.clone() };
            let url = direct_url(&scope, origin, line)?;
            if attrs.get("tvg-id") != Some(&format!("{number}.eplustv")) || !seen.insert(provider_id) { return Err(invalid()); }
            channels.push(DirectChannel { scope, url, name, station_id: attrs.get("tvc-guide-stationid").cloned().unwrap_or_default() });
            if channels.len() > MAX_CHANNELS { return Err(invalid()); }
        }
    }
    if pending.is_some() { return Err(invalid()); }
    Ok(channels)
}
async fn load_direct_lineup(state: &LiveState, direct: &DirectTve) -> Result<Vec<DirectChannel>> {
    let mut cache = direct.cache.lock().await;
    if cache.attempted.is_some_and(|at| at.elapsed() < CACHE_AGE) { return Ok(cache.channels.clone()); }
    cache.attempted = Some(Instant::now());
    // A failed refresh cannot leave a stale channel-number association in use.
    cache.channels.clear();
    let response = state.http.get(direct.origin.join("/linear-channels.m3u").map_err(|_| invalid())?)
        .timeout(Duration::from_secs(4)).send().await.map_err(|_| unavailable())?;
    if !response.status().is_success() { return Err(unavailable()); }
    cache.channels = parse_direct_lineup(&read_text(response, MAX_LINEUP).await?, &direct.origin)?;
    Ok(cache.channels.clone())
}
fn direct_failure(state: &LiveState, scope: &DirectScope) {
    if let Some(direct) = &state.direct {
        direct.failures.lock().unwrap().insert(scope.provider_id.clone(), Instant::now());
    }
}
async fn choose_direct(state: &LiveState, channel: &Channel) -> Option<DirectChannel> {
    let direct = state.direct.as_ref()?;
    if direct_matches(channel).next().is_none() { return None; }
    let _permit = direct.probes.try_acquire().ok()?;
    tokio::time::timeout(DIRECT_PROBE_TIMEOUT, async {
        let channels = load_direct_lineup(state, direct).await.ok()?;
        for identity in direct_matches(channel) {
            let Some(candidate) = channels.iter().find(|c| c.scope.provider_id == identity.provider_id
                && c.station_id == identity.station_id && c.name == identity.name) else { continue };
            if direct.failures.lock().unwrap().get(identity.provider_id).is_some_and(|at| at.elapsed() < DIRECT_RETRY) { continue; }
            // Also covers cancellation by the overall deadline: the next tune
            // must not repeatedly spend its budget on the same stalled source.
            direct_failure(state, &candidate.scope);
            if probe_direct(state, candidate).await.is_ok() {
                direct.failures.lock().unwrap().remove(identity.provider_id);
                tracing::info!(channel_id = %channel.id, "Using direct TV Everywhere source");
                return Some(candidate.clone());
            }
        }
        None
    }).await.unwrap_or(None)
}
async fn probe_direct(state: &LiveState, candidate: &DirectChannel) -> Result<()> {
    let mut session = Session { root: String::new(), direct: Some(candidate.scope.clone()), touched: Instant::now(),
        resources: HashMap::new(), revoked: Arc::new(AtomicBool::new(false)), roku: None };
    let mut pending = vec![candidate.url.clone()];
    let mut seen = HashSet::new();
    let mut media = 0;
    let mut assets = Vec::new();
    while let Some(url) = pending.pop() {
        if !seen.insert(url.clone()) { continue; }
        if seen.len() > MAX_DIRECT_PLAYLISTS { return Err(invalid()); }
        let response = state.http.get(url.clone()).timeout(Duration::from_secs(5)).send().await.map_err(|_| unavailable())?;
        if !response.status().is_success() { return Err(unavailable()); }
        let text = read_text(response, MAX_PLAYLIST).await?;
        rewrite_playlist(&text, &candidate.scope.origin, &url, "probe", &mut session, Instant::now())?;
        let has_media = text.lines().any(|line| line.trim().starts_with("#EXTINF:"));
        let has_segment = text.lines().map(str::trim).any(|line| !line.is_empty() && !line.starts_with('#') && line.ends_with(".ts"));
        let has_child = text.lines().map(str::trim).any(|line| line.ends_with(".m3u8") || line.contains(".m3u8\""));
        if has_media && has_segment {
            media += 1;
            if assets.is_empty() {
                assets.extend(session.resources.values().filter(|r| matches!(r.url.path().rsplit('.').next(), Some("key" | "m4i"))).map(|r| r.url.clone()));
                let segment = text.lines().map(str::trim).rfind(|line| !line.starts_with('#') && line.ends_with(".ts")).ok_or_else(invalid)?;
                assets.push(direct_url(&candidate.scope, &url, segment)?);
                if assets.len() > 8 { return Err(invalid()); }
            }
        }
        else if !has_child { return Err(invalid()); }
        for resource in session.resources.values().filter(|r| r.url.path().ends_with(".m3u8")) {
            if !seen.contains(&resource.url) && !pending.contains(&resource.url) { pending.push(resource.url.clone()); }
        }
        if seen.len() + pending.len() > MAX_DIRECT_PLAYLISTS { return Err(invalid()); }
    }
    if media == 0 { return Err(invalid()); }
    // A syntactically valid cached playlist is not proof its media still works.
    // Check one current media rendition and its key/init without downloading a
    // whole live segment or exposing provider URLs to the player.
    for url in assets {
        let is_key = url.path().ends_with(".key");
        let mut response = state.http.get(url).timeout(Duration::from_secs(5)).send().await.map_err(|_| unavailable())?;
        if !response.status().is_success() || response.content_length().is_some_and(|v| v > MAX_SEGMENT as u64) { return Err(unavailable()); }
        if is_key {
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| unavailable())? {
                if bytes.len() + chunk.len() > 16 { return Err(invalid()); }
                bytes.extend_from_slice(&chunk);
            }
            if bytes.len() != 16 { return Err(invalid()); }
        } else {
            loop {
                let chunk = response.chunk().await.map_err(|_| unavailable())?.ok_or_else(unavailable)?;
                if chunk.len() > MAX_SEGMENT { return Err(invalid()); }
                if !chunk.is_empty() { break; }
            }
        }
    }
    Ok(())
}
async fn tune(State(state): State<Arc<LiveState>>, headers: HeaderMap, Json(request): Json<Tune>) -> Result<Response> {
    if !state.cfg.enabled { return Err(LiveError(StatusCode::SERVICE_UNAVAILABLE, "Live TV is not configured yet")); }
    if !safe_name(&request.channel_id) { return Err(LiveError(StatusCode::BAD_REQUEST, "Invalid channel")); }
    if let Some(native) = &state.native { return native.tune(&state, &request, &headers).await; }
    let (entries, _) = load_lineup(&state).await;
    let entry = entries.iter().find(|entry| entry.channel.id == request.channel_id)
        .ok_or(LiveError(StatusCode::NOT_FOUND, "Channel unavailable; refresh the channel list"))?;
    let direct = choose_direct(&state, &entry.channel).await;
    let selected = direct.as_ref().map(|source| Entry { channel: entry.channel.clone(), url: source.url.clone() });
    let direct_scope = direct.as_ref().map(|source| source.scope.clone());
    let mut id = {
        let mut sessions = state.sessions.lock().unwrap();
        let id = sessions.create(selected.as_ref().unwrap_or(entry), Instant::now())?;
        if let Some(source) = direct { sessions.items.get_mut(&id).unwrap().direct = Some(source.scope); }
        id
    };
    if let Err(error) = adapt_session(&state, &id, request.client).await {
        let failed_direct = direct_scope.as_ref().is_some_and(|scope| state.direct.as_ref().is_some_and(|direct|
            direct.failures.lock().unwrap().get(&scope.provider_id).is_some_and(|at| at.elapsed() < DIRECT_RETRY)));
        if error.0 != StatusCode::BAD_GATEWAY || !failed_direct { return Err(error); }
        id = state.sessions.lock().unwrap().create(entry, Instant::now())?;
        // Budget: lineup <=12s, direct <=12s, direct remux <=10s, fallback
        // remux <=40s. This stays below Roku's existing 85-second tune timeout.
        adapt_session_with_limit(&state, &id, request.client, Duration::from_secs(40)).await?;
    }
    let direct_active = state.sessions.lock().unwrap().items.get(&id).is_some_and(|session| session.direct.is_some());
    tracing::info!(channel_id = %entry.channel.id, client = if request.client.is_some() { "roku" } else { "native" },
        source = if direct_active { "direct_tve" } else { "capture_bridge" }, "Live tune ready");
    Ok(no_store(Json(Tuned { playback_path: format!("/live/streams/{id}/index.m3u8"), session_id: id,
        mime_type: HLS, channel: entry.channel.clone(), can_pause: false, can_seek: false }).into_response()))
}
async fn adapt_session(state: &LiveState, id: &str, client: Option<NativeClient>) -> Result<()> {
    adapt_session_with_limit(state, id, client, Duration::from_secs(50)).await
}
async fn adapt_session_with_limit(state: &LiveState, id: &str, client: Option<NativeClient>, maximum: Duration) -> Result<()> {
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
        let direct = state.sessions.lock().unwrap().items.get(id).and_then(|s| s.direct.clone());
        let limit = if direct.is_some() { maximum.min(Duration::from_secs(10)) } else { maximum };
        let ready = remux.ready(limit).await.map_err(|e| LiveError(e.0,e.1));
        if ready.as_ref().is_err_and(|e| e.0 == StatusCode::BAD_GATEWAY) {
            if let Some(scope) = direct {
                direct_failure(state, &scope);
                if !remux.cancel_and_wait(Duration::from_secs(2)).await {
                    return Err(LiveError(StatusCode::SERVICE_UNAVAILABLE, "Previous live source is still closing; retry shortly"));
                }
            }
        }
        ready
    }.await;
    if result.is_err() { state.sessions.lock().unwrap().remove(id); }
    result
}
async fn end_session(State(state): State<Arc<LiveState>>, Path(id): Path<String>, query: axum::extract::RawQuery) -> Result<Response> {
    let legacy = {
        let mut sessions = state.sessions.lock().unwrap();
        let present = sessions.items.contains_key(&id);
        if present { sessions.remove(&id); }
        present
    };
    if !legacy && state.cfg.enabled {
        if let Some(native) = &state.native {
            if query.0.is_some() { return Err(expired()); }
            // Native deletion performs I/O. Invalid-descriptor cleanup already
            // owns its tune permit and calls native.end directly.
            let _permit = state.requests.try_acquire().map_err(|_| LiveError(StatusCode::SERVICE_UNAVAILABLE, "Live source busy; retry shortly"))?;
            return native.end(&id).await;
        }
    }
    Ok(no_store(StatusCode::NO_CONTENT.into_response()))
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
async fn playback(State(state): State<Arc<LiveState>>, Path((id, key)): Path<(String, String)>, query: axum::extract::RawQuery, headers: HeaderMap) -> Result<Response> {
    let legacy = {
        let mut sessions = state.sessions.lock().unwrap();
        sessions.reap(Instant::now());
        sessions.items.contains_key(&id)
    };
    if !legacy && state.cfg.enabled {
        if let Some(native) = &state.native { return native.playback(&state, &id, &key, query.0.as_deref(), &headers).await; }
    }
    let result = playback_inner(&state, &id, &key, headers).await;
    // Clients already retune on live playback failure. The next tune falls back
    // instead of repeatedly selecting a broken direct provider. Never splice two
    // unrelated HLS timelines into a viewer's existing session.
    if result.as_ref().is_err_and(|e| matches!(e.0, StatusCode::BAD_GATEWAY | StatusCode::GATEWAY_TIMEOUT)) {
        let direct = state.sessions.lock().unwrap().items.get(&id).and_then(|s| s.direct.clone());
        if let Some(scope) = direct { direct_failure(&state, &scope); }
    }
    result
}
async fn playback_inner(state: &LiveState, id: &str, key: &str, headers: HeaderMap) -> Result<Response> {
    if key == "index.m3u8" || key == "media.m3u8" || key.starts_with("seg-") {
        let remux = {
            let mut sessions = state.sessions.lock().unwrap();
            sessions.reap(Instant::now());
            let session = sessions.items.get_mut(id).ok_or_else(expired)?;
            session.touched = Instant::now();
            session.roku.clone()
        };
        if let Some(remux) = remux {
            return remux.asset(&key).await.map(no_store).map_err(|e| LiveError(e.0,e.1));
        }
    }
    let (resource, revoked) = state.sessions.lock().unwrap().resource(id, key, Instant::now())?;
    let direct_failure = state.sessions.lock().unwrap().items.get(id).and_then(|s| s.direct.as_ref())
        .and_then(|scope| state.direct.as_ref().map(|direct| DirectFailureMark { failures: direct.failures.clone(), provider_id: scope.provider_id.clone() }));
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
        // This is a failed request for a registered upstream resource, including
        // EPlusTV's 404 for missing keys/segments. An unknown capability key never
        // reaches this branch and cannot poison a provider's health.
        if let Some(mark) = &direct_failure { mark.record(); }
        // Never relay upstream bodies, cookies, redirects or login URLs.
        return Err(if upstream.status() == StatusCode::NOT_FOUND { LiveError(StatusCode::NOT_FOUND, "Live segment unavailable; retry the channel") }
            else { unavailable() });
    }
    if playlist {
        let text = read_text(upstream, MAX_PLAYLIST).await?;
        let mut sessions = state.sessions.lock().unwrap();
        sessions.reap(Instant::now());
        let session = sessions.items.get_mut(id).ok_or_else(expired)?;
        let body = rewrite_playlist(&text, &state.origin, &resource.url, id, session, Instant::now())?;
        // FFmpeg probes every variant in an adaptive master before applying
        // stream maps. FOX's seven-variant feed can exhaust its probing budget
        // before it discovers AAC parameters, making stream-copy output fail.
        // Give only the Roku remuxer one AVC/AAC rendition; native viewers keep
        // the original adaptive master and all media timelines stay untouched.
        let body = if key == "source.m3u8" && session.direct.is_some() { roku_direct_playlist(&body)? } else { body };
        return Ok(no_store(([(header::CONTENT_TYPE, HLS)], body).into_response()));
    }
    if upstream.content_length().is_some_and(|size| size > MAX_SEGMENT as u64) { return Err(invalid()); }
    let mut output = Response::builder().status(upstream.status());
    for name in [header::CONTENT_TYPE, header::CONTENT_LENGTH, header::CONTENT_RANGE, header::ACCEPT_RANGES] {
        if let Some(value) = upstream.headers().get(&name) { output = output.header(name, value.clone()); }
    }
    let bytes = upstream.bytes_stream();
    let streamed = futures::stream::unfold((bytes, permit, revoked, 0usize, direct_failure), |(mut bytes, permit, revoked, size, direct_failure)| async move {
        let Some(next) = bytes.next().await else {
            if size == 0 && !revoked.load(Ordering::Relaxed) {
                if let Some(mark) = &direct_failure { mark.record(); }
            }
            return None;
        };
        let item = match next {
            Ok(chunk) if !revoked.load(Ordering::Relaxed) && size.saturating_add(chunk.len()) <= MAX_SEGMENT => Ok(chunk),
            _ => {
                if !revoked.load(Ordering::Relaxed) {
                    if let Some(mark) = &direct_failure { mark.record(); }
                }
                Err(std::io::Error::other("Live segment interrupted"))
            },
        };
        let total = size.saturating_add(item.as_ref().map_or(0, |chunk| chunk.len()));
        Some((item, (bytes, permit, revoked, total, direct_failure)))
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
    let url = if let Some(scope) = &session.direct { direct_url(scope, base, uri)? }
        else { scoped_url(origin, base, uri, &session.root, false)? };
    if let Some((key, resource)) = session.resources.iter_mut().find(|(_, resource)| resource.url == url) {
        resource.seen = now;
        return Ok(format!("/live/streams/{id}/{key}"));
    }
    let capacity = if session.direct.is_some() { MAX_DIRECT_RESOURCES } else { MAX_RESOURCES };
    if session.resources.len() >= capacity {
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
    // EPlusTV's m4i route contains an fMP4 initialization segment.
    let extension = if extension == "m4i" { "mp4" } else { extension };
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
        if session.direct.is_some() {
            validate_direct_tag(line)?;
            // Upstream comments are not player input and may contain private
            // source URLs. Only HLS directives and rewritten resources escape.
            if line.starts_with('#') && !line.starts_with("#EXT") { continue; }
        }
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
        // Keep any single response comfortably below the per-session map cap
        // so registering its references cannot evict its own earlier entries.
        let limit = if session.direct.is_some() { MAX_DIRECT_REFERENCES } else { MAX_RESOURCES / 2 };
        if references > limit { return Err(invalid()); }
        output.push('\n');
    }
    Ok(output)
}
fn validate_direct_tag(line: &str) -> Result<()> {
    if let Some(list) = line.strip_prefix("#EXT-X-KEY:").or_else(|| line.strip_prefix("#EXT-X-SESSION-KEY:")) {
        let mut attrs = HashMap::new();
        for part in split_quoted(list, ',')? {
            let (key, value) = part.split_once('=').ok_or_else(invalid)?;
            if attrs.insert(key.trim(), value.trim()).is_some() { return Err(invalid()); }
        }
        match attrs.get("METHOD").copied() {
            Some("NONE") if !attrs.contains_key("URI") => {},
            Some("AES-128") if attrs.contains_key("URI")
                && attrs.get("KEYFORMAT").is_none_or(|v| *v == "\"identity\"") => {},
            _ => return Err(invalid()),
        }
    }
    // These metadata/interactive tags can contain opaque URLs outside URI= and
    // are not needed for a linear channel. Reject rather than forward them.
    if line.starts_with("#EXT-X-SESSION-DATA:") || line.starts_with("#EXT-X-DATERANGE:") { return Err(invalid()); }
    Ok(())
}

fn hls_attributes(list: &str) -> Result<HashMap<&str, &str>> {
    let mut attrs = HashMap::new();
    for part in split_quoted(list, ',')? {
        let (key, value) = part.split_once('=').ok_or_else(invalid)?;
        let value = value.trim();
        let value = value.strip_prefix('"').and_then(|v| v.strip_suffix('"')).unwrap_or(value);
        if attrs.insert(key.trim(), value).is_some() { return Err(invalid()); }
    }
    Ok(attrs)
}
/// Restrict an already validated/re-written direct master to one Roku-compatible
/// video variant and its own media groups. Do not drop separately hosted audio.
fn roku_direct_playlist(text: &str) -> Result<String> {
    let lines: Vec<_> = text.lines().collect();
    let mut variants = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        if let Some(list) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            let attrs = hls_attributes(list)?;
            let uri = (index + 1..lines.len()).find(|i| !lines[*i].is_empty()).ok_or_else(invalid)?;
            if !lines[uri].starts_with("/live/streams/") { return Err(invalid()); }
            variants.push((index, uri, attrs));
        }
    }
    if variants.is_empty() { return Ok(text.to_string()); }
    let selected = variants.iter().filter_map(|variant| {
        let attrs = &variant.2;
        let codecs: Vec<_> = attrs.get("CODECS")?.split(',').map(str::trim).collect();
        if !codecs.iter().any(|c| c.starts_with("avc1.") || c.starts_with("avc3."))
            || !codecs.contains(&"mp4a.40.2") { return None; }
        let (width, height) = attrs.get("RESOLUTION")?.split_once('x')?;
        let (width, height) = (width.parse::<u32>().ok()?, height.parse::<u32>().ok()?);
        if width == 0 || height == 0 || width > 1920 || height > 1080 { return None; }
        Some((attrs.get("BANDWIDTH")?.parse::<u64>().ok()?, variant))
    }).max_by_key(|(bandwidth, _)| *bandwidth).map(|(_, variant)| variant).ok_or_else(invalid)?;
    let mut output = String::new();
    for (index, line) in lines.iter().enumerate() {
        if let Some(variant) = variants.iter().find(|variant| index == variant.0 || index == variant.1) {
            if variant.0 != selected.0 { continue; }
        } else if let Some(list) = line.strip_prefix("#EXT-X-MEDIA:") {
            let attrs = hls_attributes(list)?;
            let kind = attrs.get("TYPE").ok_or_else(invalid)?;
            if attrs.get("GROUP-ID").is_none_or(|group| selected.2.get(*kind) != Some(group)) { continue; }
        } else if line.starts_with("#EXT-X-I-FRAME-STREAM-INF:") { continue; }
        else if !line.is_empty() && !line.starts_with('#') { return Err(invalid()); }
        output.push_str(line); output.push('\n');
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    static ROKU_HTTP_TEST_LOCK: AsyncMutex<()> = AsyncMutex::const_new(());

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
    async fn direct_tve_preserves_lineup_and_proxies_media_without_credentials() {
        let prism_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let prism_base = format!("http://{}", prism_listener.local_addr().unwrap());
        let captures = Arc::new(AtomicUsize::new(0));
        let count = captures.clone();
        let _prism = serve_fixture(Router::new()
            .route("/playlist", get(|| async { "#EXTM3U\n#EXTINF:-1 channel-number=\"33\",Fox Sports 1\n/hls/fox-sports-1/stream.m3u8\n#EXTINF:-1,FOX (WJW)\n/hls/fox-wjw/stream.m3u8\n#EXTINF:-1,Big Ten Network Overflow\n/hls/big-ten-network-overflow/stream.m3u8\n" }))
            .route("/hls/fox-sports-1/stream.m3u8", get(move || { let count = count.clone(); async move { count.fetch_add(1, Ordering::Relaxed); "#EXTM3U\n#EXTINF:2,\nsegment.ts\n" } }))
            .route("/hls/fox-wjw/stream.m3u8", get(|| async { "#EXTM3U\n#EXTINF:2,\nsegment.ts\n" })), prism_listener).await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let direct_base = format!("http://{}", listener.local_addr().unwrap());
        let lineup_reads = Arc::new(AtomicUsize::new(0));
        let reads = lineup_reads.clone();
        let failed = Arc::new(AtomicBool::new(false));
        let failed_media = failed.clone();
        let _direct = serve_fixture(Router::new()
            .route("/linear-channels.m3u", get(move |headers: HeaderMap| { let reads = reads.clone(); async move {
                assert!(!headers.contains_key(header::AUTHORIZATION));
                reads.fetch_add(1, Ordering::Relaxed);
                "#EXTM3U\n#EXTINF:0 tvg-id=\"8010.eplustv\" channel-id=\"foxsports.FS1\" tvc-guide-stationid=\"82547\", FS1\n/channels/8010.m3u8\n"
            } }))
            .route("/channels/8010.m3u8", get(|headers: HeaderMap| async move {
                assert!(!headers.contains_key(header::AUTHORIZATION));
                "#EXTM3U\n# source https://private.invalid/signed-secret\n#EXT-X-STREAM-INF:BANDWIDTH=6000000\n/chunklist/8010/aB012345.m3u8\n"
            }))
            .route("/chunklist/8010/aB012345.m3u8", get(move || { let failed = failed_media.clone(); async move {
                if failed.load(Ordering::Relaxed) { return "#EXTM3U\n#EXTINF:2,\nhttps://private.invalid/unproxied-secret.ts\n"; }
                "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"/channels/8010/8010-key-aB012345.key\"\n#EXT-X-MAP:URI=\"/channels/8010/8010-m4i-aB012345.m4i\"\n#EXTINF:2,\n/channels/8010/8010-segment-aB012345.ts\n"
            } }))
            .route("/channels/8010/8010-key-aB012345.key", get(|headers: HeaderMap| async move { assert!(!headers.contains_key(header::AUTHORIZATION)); vec![7u8; 16] }))
            .route("/channels/8010/8010-m4i-aB012345.m4i", get(|| async { b"init".to_vec() }))
            .route("/channels/8010/8010-segment-aB012345.ts", get(|| async { b"original-media".to_vec() })), listener).await;
        let cfg = LiveTv { enabled: true, upstream_url: prism_base.clone(), direct_tve_url: Some(direct_base.clone()), ..LiveTv::default() };
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let _server = serve_fixture(router(cfg, "shared".into()).unwrap(), listener).await;
        let client = reqwest::Client::new();
        let lineup: serde_json::Value = client.get(format!("{base}/live/channels")).bearer_auth("shared").send().await.unwrap().json().await.unwrap();
        assert_eq!(lineup["channels"].as_array().unwrap().len(), 3);
        assert_eq!(lineup["channels"][0]["id"], "fox-sports-1");
        assert_eq!(lineup["channels"][0]["name"], "Fox Sports 1");
        assert_eq!(lineup["channels"][0]["number"], "33");
        assert_eq!(lineup_reads.load(Ordering::Relaxed), 0, "browsing must never tune or contact TVE");
        for channel in ["fox-wjw", "big-ten-network-overflow"] {
            assert_eq!(client.post(format!("{base}/live/tune")).bearer_auth("shared").json(&serde_json::json!({"channelId":channel})).send().await.unwrap().status(), StatusCode::OK);
        }
        assert_eq!(lineup_reads.load(Ordering::Relaxed), 0, "unreviewed affiliate and overflow identities cannot merge");
        let tune = || client.post(format!("{base}/live/tune")).bearer_auth("shared").json(&serde_json::json!({"channelId":"fox-sports-1"}));
        let tuned: serde_json::Value = tune().send().await.unwrap().json().await.unwrap();
        assert_eq!(tuned["channel"], lineup["channels"][0]);
        assert_eq!(captures.load(Ordering::Relaxed), 0);
        let master = client.get(format!("{base}{}", tuned["playbackPath"].as_str().unwrap())).send().await.unwrap().text().await.unwrap();
        for private in [&direct_base, &prism_base, "signed-secret"] { assert!(!master.contains(private)); }
        let leaf_path = master.lines().find(|line| line.starts_with("/live/")).unwrap();
        let media = client.get(format!("{base}{leaf_path}")).send().await.unwrap().text().await.unwrap();
        assert!(!media.contains("/channels/") && !media.contains(&direct_base));
        let key_path = media.split("URI=\"").nth(1).unwrap().split('"').next().unwrap();
        let init_path = media.split("URI=\"").nth(2).unwrap().split('"').next().unwrap();
        let segment_path = media.lines().find(|line| line.starts_with("/live/")).unwrap();
        assert!(init_path.ends_with(".mp4"));
        assert_eq!(client.get(format!("{base}{key_path}")).send().await.unwrap().bytes().await.unwrap().as_ref(), &[7u8;16]);
        assert_eq!(client.get(format!("{base}{init_path}")).send().await.unwrap().bytes().await.unwrap().as_ref(), b"init");
        assert_eq!(client.get(format!("{base}{segment_path}")).send().await.unwrap().bytes().await.unwrap().as_ref(), b"original-media");
        failed.store(true, Ordering::Relaxed);
        let rejected = client.get(format!("{base}{leaf_path}")).send().await.unwrap();
        assert_eq!(rejected.status(), StatusCode::BAD_GATEWAY);
        assert!(!rejected.text().await.unwrap().contains("unproxied-secret"));
        let replacement: serde_json::Value = tune().send().await.unwrap().json().await.unwrap();
        let response = client.get(format!("{base}{}", replacement["playbackPath"].as_str().unwrap())).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(captures.load(Ordering::Relaxed), 1, "retune during direct cooldown must use Spectrum");
        assert_eq!(lineup_reads.load(Ordering::Relaxed), 1);
        client.delete(format!("{base}/live/sessions/{}", tuned["sessionId"].as_str().unwrap())).bearer_auth("shared").send().await.unwrap();
        assert_eq!(client.get(format!("{base}{segment_path}")).send().await.unwrap().status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn direct_tve_route_scope_and_feed_identity_are_exact() {
        let origin = Url::parse("http://direct:8000").unwrap();
        let text = "#EXTM3U\n#EXTINF:0 tvg-id=\"8010.eplustv\" channel-id=\"foxsports.FS1\" tvc-guide-stationid=\"82547\", FS1\n/channels/8010.m3u8\n";
        let channel = parse_direct_lineup(text, &origin).unwrap().remove(0);
        for path in ["/channels/8010.m3u8", "/chunklist/8010/aB012345.m3u8", "/channels/8010/8010-key-aB012345.key", "/channels/8010/8010-m4i-aB012345.m4i", "/channels/8010/8010-segment-aB012345.ts"] {
            assert!(direct_url(&channel.scope, &channel.url, path).is_ok(), "rejected {path}");
        }
        for path in ["/channels/8011.m3u8", "/chunklist/8011/aB012345.m3u8", "/channels/8010/8011-key-aB012345.key", "/channels/8010/8010-segment-aB012345.mp4",
            "/channels/8010/8010-key-aB012345.key?secret=x", "http://elsewhere/channels/8010.m3u8", "http://u:p@direct:8000/channels/8010.m3u8",
            "/admin", "/channels/8010/../8011.m3u8", "/channels/%38%30%31%30.m3u8", "//elsewhere/channels/8010.m3u8", "data:text/plain;base64,AAAA"] {
            assert!(direct_url(&channel.scope, &channel.url, path).is_err(), "accepted {path}");
        }
        for malformed in [text.replace("8010.eplustv", "8011.eplustv"), text.replace("/channels/8010.m3u8", "http://elsewhere/channels/8010.m3u8"), format!("{text}{}", text.trim_start_matches("#EXTM3U\n"))] {
            assert!(parse_direct_lineup(&malformed, &origin).is_err());
        }
        let mut original = entry().channel;
        original.id = "fox-sports-1".into(); original.name = "Fox Sports 1".into();
        assert_eq!(direct_matches(&original).count(), 2);
        original.name = "FOX (WJW)".into();
        assert_eq!(direct_matches(&original).count(), 0);
        for value in ["http://u:p@direct:8000", "http://direct:8000/private", "http://direct:8000?token=x"] {
            assert!(configured_origin(value).is_err());
        }
    }

    #[test]
    fn direct_tve_long_dvr_windows_survive_abr_switches_and_bounded_eviction() {
        let direct_origin = Url::parse("http://direct:8000").unwrap();
        let scope = DirectScope { origin: direct_origin.clone(), number: "412".into(), provider_id: "foxone.FS1".into() };
        let base = direct_origin.join("/channels/412.m3u8").unwrap();
        let (id, mut session) = session();
        session.direct = Some(scope);
        session.resources.get_mut("index.m3u8").unwrap().url = base.clone();
        let start = Instant::now();
        let mut master = String::from("#EXTM3U\n#EXT-X-INDEPENDENT-SEGMENTS\n");
        for rendition in 0..7 {
            master.push_str(&format!("#EXT-X-STREAM-INF:BANDWIDTH={}\n/chunklist/412/{rendition:08x}.m3u8\n", 1_000_000 * (rendition + 1)));
        }
        let output = rewrite_playlist(&master, &direct_origin, &base, &id, &mut session, start).unwrap();
        let playlist_keys: Vec<_> = output.lines().filter(|line| !line.starts_with('#')).map(|line| line.rsplit('/').next().unwrap().to_string()).collect();
        let reference_keys = |output: &str| -> Vec<String> {
            output.lines().filter_map(|line| {
                if line.starts_with("/live/") { Some(line) }
                else { line.split_once("URI=\"").map(|(_, value)| value.split('"').next().unwrap()) }
            }).map(|path| path.rsplit('/').next().unwrap().to_string()).collect()
        };
        // The real FOX feed exposes seven renditions, each with roughly 450
        // two-second segments. Keep its full DVR window and key/sequence tags.
        for epoch in 0..3 {
            let mut current_window = Vec::new();
            for rendition in 0..7 {
                let sequence = 2_030_583 + epoch * 450;
                let mut source = format!("#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:{sequence}\n#EXT-X-DISCONTINUITY-SEQUENCE:{epoch}\n");
                for segment in 0..450 {
                    if segment % 225 == 0 {
                        let key = epoch * 100 + rendition * 2 + segment / 225;
                        source.push_str(&format!("#EXT-X-KEY:KEYFORMATVERSIONS=\"1\",METHOD=AES-128,URI=\"/channels/412/412-key-{key:08x}.key\",IV=0x00000000000000000000000000000001,KEYFORMAT=\"identity\"\n"));
                    }
                    if segment == 225 { source.push_str("#EXT-X-DISCONTINUITY\n"); }
                    let asset = epoch * 10_000 + rendition * 450 + segment;
                    source.push_str(&format!("#EXTINF:2.002,\n/channels/412/412-segment-{asset:08x}.ts\n"));
                }
                let leaf = direct_origin.join(&format!("/chunklist/412/{rendition:08x}.m3u8")).unwrap();
                let now = start + Duration::from_secs((epoch * 7 + rendition + 1) as u64);
                let output = rewrite_playlist(&source, &direct_origin, &leaf, &id, &mut session, now).unwrap();
                assert_eq!(output.matches("#EXTINF:2.002,").count(), 450);
                assert_eq!(output.matches("IV=0x00000000000000000000000000000001,KEYFORMAT=\"identity\"").count(), 2);
                assert!(output.contains(&format!("#EXT-X-MEDIA-SEQUENCE:{sequence}\n")));
                assert!(output.contains(&format!("#EXT-X-DISCONTINUITY-SEQUENCE:{epoch}\n")));
                assert_eq!(output.matches("#EXT-X-DISCONTINUITY\n").count(), 1);
                assert!(!output.contains("/channels/") && !output.contains("direct:8000"));
                current_window.extend(reference_keys(&output));
                assert!(session.resources.len() <= MAX_DIRECT_RESOURCES);
            }
            assert!(current_window.iter().all(|key| session.resources.contains_key(key)), "all current ABR rendition windows must remain usable");
            assert!(playlist_keys.iter().all(|key| session.resources.contains_key(key)), "stable master references survive media eviction");
            assert!(session.resources.contains_key("index.m3u8"));
            if epoch == 0 { assert_eq!(session.resources.len(), 1 + 7 + 7 * 452); }
            else { assert_eq!(session.resources.len(), MAX_DIRECT_RESOURCES); }
        }
    }

    #[test]
    fn direct_tve_larger_reference_budget_does_not_expand_capture_limits() {
        let direct_origin = Url::parse("http://direct:8000").unwrap();
        let base = direct_origin.join("/channels/412.m3u8").unwrap();
        let (id, mut direct) = session();
        direct.direct = Some(DirectScope { origin: direct_origin.clone(), number: "412".into(), provider_id: "foxone.FS1".into() });
        let mut manifest = String::from("#EXTM3U\n");
        for n in 0..MAX_DIRECT_REFERENCES { manifest.push_str(&format!("#EXTINF:2,\n/channels/412/412-segment-{n:08x}.ts\n")); }
        assert!(rewrite_playlist(&manifest, &direct_origin, &base, &id, &mut direct, Instant::now()).is_ok());
        manifest.push_str("#EXTINF:2,\n/channels/412/412-segment-ffffffff.ts\n");
        assert!(rewrite_playlist(&manifest, &direct_origin, &base, &id, &mut direct, Instant::now()).is_err());

        let (id, mut capture) = session();
        let mut manifest = String::from("#EXTM3U\n");
        for n in 0..MAX_RESOURCES / 2 { manifest.push_str(&format!("#EXTINF:2,\nsegment{n}.ts\n")); }
        assert!(rewrite_playlist(&manifest, &origin(), &entry().url, &id, &mut capture, Instant::now()).is_ok());
        manifest.push_str("#EXTINF:2,\nsegment-extra.ts\n");
        assert!(rewrite_playlist(&manifest, &origin(), &entry().url, &id, &mut capture, Instant::now()).is_err());
    }

    #[test]
    fn roku_direct_master_keeps_one_supported_variant_and_its_audio_group() {
        let source = concat!("#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-INDEPENDENT-SEGMENTS\n",
            "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"/live/streams/session/key.key\"\n",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"main\",NAME=\"English\",DEFAULT=YES,URI=\"/live/streams/session/english.m3u8\"\n",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"other\",NAME=\"Other\",URI=\"/live/streams/session/other.m3u8\"\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=30000000,RESOLUTION=3840x2160,CODECS=\"hvc1.1.6.L153,mp4a.40.2\"\n/live/streams/session/hevc.m3u8\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,CODECS=\"avc1.640033,mp4a.40.2\"\n/live/streams/session/4k.m3u8\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=12000000,RESOLUTION=1920x1080,CODECS=\"avc1.64002A,mp4a.40.2\",AUDIO=\"main\"\n/live/streams/session/fullhd.m3u8\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1280x720,CODECS=\"avc1.640020,mp4a.40.2\",AUDIO=\"other\"\n/live/streams/session/hd.m3u8\n",
            "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,URI=\"/live/streams/session/trickplay.m3u8\"\n");
        let output = roku_direct_playlist(source).unwrap();
        assert_eq!(output.matches("#EXT-X-STREAM-INF:").count(), 1);
        assert!(output.contains("/fullhd.m3u8") && output.contains("/english.m3u8"));
        assert!(output.contains("#EXT-X-INDEPENDENT-SEGMENTS\n") && output.contains("/key.key"));
        for absent in ["/hevc.m3u8", "/4k.m3u8", "/hd.m3u8", "/other.m3u8", "/trickplay.m3u8"] { assert!(!output.contains(absent)); }
        for invalid in [source.replace("avc1.", "unknown."), source.replace("mp4a.40.2", "mp4a.69"), source.replace("AUDIO=\"main\"", "BANDWIDTH=1")] {
            assert!(roku_direct_playlist(&invalid).is_err());
        }
        let media = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:42\n#EXTINF:2,\n/live/streams/session/segment.ts\n";
        assert_eq!(roku_direct_playlist(media).unwrap(), media, "media timelines are never trimmed or rewritten here");
    }

    #[tokio::test]
    async fn roku_direct_adaptive_source_remuxes_audio_video_without_starting_capture() {
        let _guard = ROKU_HTTP_TEST_LOCK.lock().await;
        let dir = std::env::temp_dir().join(format!("velvet-direct-roku-test-{}", random_id().unwrap()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let generated = tokio::process::Command::new("ffmpeg").current_dir(&dir)
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=60", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-t", "12", "-c:v", "libx264", "-preset", "ultrafast", "-g", "120", "-c:a", "aac", "-ac", "2", "-f", "hls", "-hls_time", "2",
                "-hls_list_size", "0", "-hls_flags", "omit_endlist+independent_segments", "-hls_segment_filename", "8010-segment-%08d.ts", "media.m3u8"])
            .output().await.unwrap();
        assert!(generated.status.success());
        let media = tokio::fs::read_to_string(dir.join("media.m3u8")).await.unwrap().replace("8010-segment-", "/channels/8010/8010-segment-");
        let mut master = String::from("#EXTM3U\n");
        for n in 0..7 { master.push_str(&format!("#EXT-X-STREAM-INF:BANDWIDTH={},RESOLUTION=320x180,CODECS=\"avc1.42e01e,mp4a.40.2\"\n/chunklist/8010/{n:08x}.m3u8\n", 7_000_000 - n * 1_000_000)); }
        let captures = Arc::new(AtomicUsize::new(0));
        let counted = captures.clone();
        let serve_dir = dir.clone();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream = format!("http://{}", listener.local_addr().unwrap());
        let _source = serve_fixture(Router::new()
            .route("/playlist", get(|| async { "#EXTM3U\n#EXTINF:-1,Fox Sports 1\n/hls/fox-sports-1/stream.m3u8\n" }))
            .route("/linear-channels.m3u", get(|| async { "#EXTM3U\n#EXTINF:0 tvg-id=\"8010.eplustv\" channel-id=\"foxsports.FS1\" tvc-guide-stationid=\"82547\", FS1\n/channels/8010.m3u8\n" }))
            .route("/channels/8010.m3u8", get(move || { let master = master.clone(); async move { master } }))
            .route("/chunklist/8010/:file", get(move || { let media = media.clone(); async move { media } }))
            .route("/channels/8010/:file", get(move |Path(file): Path<String>| { let dir = serve_dir.clone(); async move {
                if !file.strip_prefix("8010-segment-").and_then(|name| name.strip_suffix(".ts"))
                    .is_some_and(|name| name.len() == 8 && name.bytes().all(|b| b.is_ascii_digit())) { return StatusCode::NOT_FOUND.into_response(); }
                match tokio::fs::read(dir.join(file)).await { Ok(bytes) => bytes.into_response(), Err(_) => StatusCode::NOT_FOUND.into_response() }
            } }))
            .route("/hls/fox-sports-1/stream.m3u8", get(move || { let count = counted.clone(); async move { count.fetch_add(1, Ordering::Relaxed); StatusCode::SERVICE_UNAVAILABLE } })), listener).await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let cfg = LiveTv { enabled:true, upstream_url:upstream.clone(), direct_tve_url:Some(upstream), ..LiveTv::default() };
        let (router, bridge) = router_with_roku_bridge(cfg, String::new(), base.clone()).unwrap();
        let _adapter = serve_fixture(router, listener).await;
        let client = reqwest::Client::new();
        let response = client.post(format!("{base}/live/tune")).timeout(Duration::from_secs(15))
            .json(&serde_json::json!({"channelId":"fox-sports-1","client":"roku"})).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let tuned: serde_json::Value = response.json().await.unwrap();
        let id = tuned["sessionId"].as_str().unwrap();
        let session = bridge.0.sessions.lock().unwrap().items[id].roku.clone().unwrap();
        assert!(bridge.0.sessions.lock().unwrap().items[id].direct.is_some(), "verify the final session, not the initial source selection");
        let original = bridge.0.sessions.lock().unwrap().items[id].resources["source.m3u8"].clone();
        bridge.0.sessions.lock().unwrap().items.get_mut(id).unwrap().resources.insert("native.m3u8".into(), original);
        let reduced = client.get(format!("{base}/live/streams/{id}/source.m3u8")).send().await.unwrap().text().await.unwrap();
        let native = client.get(format!("{base}/live/streams/{id}/native.m3u8")).send().await.unwrap().text().await.unwrap();
        assert_eq!(reduced.matches("#EXT-X-STREAM-INF:").count(), 1);
        assert_eq!(native.matches("#EXT-X-STREAM-INF:").count(), 7);
        let inspected = tokio::process::Command::new("ffprobe").args(["-v", "error", "-show_entries", "stream=codec_name,codec_type,sample_rate,channels", "-of", "json"])
            .arg(format!("{base}{}", tuned["playbackPath"].as_str().unwrap())).output().await.unwrap();
        assert!(inspected.status.success());
        let tracks: serde_json::Value = serde_json::from_slice(&inspected.stdout).unwrap();
        let tracks = tracks["streams"].as_array().unwrap();
        assert!(tracks.iter().any(|s| s["codec_name"] == "h264"));
        assert!(tracks.iter().any(|s| s["codec_name"] == "aac" && s["sample_rate"] == "48000" && s["channels"] == 2));
        assert_eq!(captures.load(Ordering::Relaxed), 0, "successful Roku output must come from direct TVE");
        bridge.0.sessions.lock().unwrap().remove(id);
        assert!(session.cancel_and_wait(Duration::from_secs(2)).await);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }

    #[tokio::test]
    async fn direct_tve_unavailable_drm_or_unproxied_feeds_fall_back_before_playback() {
        for (status, playlist) in [
            (StatusCode::SERVICE_UNAVAILABLE, "private upstream error"),
            (StatusCode::FOUND, "private redirect body"),
            (StatusCode::OK, "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"/channels/8010/8010-key-aB012345.key\"\n#EXTINF:2,\n/channels/8010/8010-segment-aB012345.ts\n"),
            (StatusCode::OK, "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"data:text/plain;base64,AAAA\"\n#EXT-X-STREAM-INF:BANDWIDTH=6000000\n/chunklist/8010/aB012345.m3u8\n"),
            (StatusCode::OK, "#EXTM3U\n#EXTINF:2,\nhttps://private.invalid/secret-segment.ts\n"),
            (StatusCode::OK, "#EXTM3U\n#EXTINF:2,\n/channels/8010/8010-segment-aB012345.ts\n"),
            (StatusCode::OK, "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"/channels/8010/8010-key-aB012345.key\"\n#EXTINF:2,\n/channels/8010/8010-segment-aB012345.ts\n"),
            (StatusCode::OK, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=6000000\n/chunklist/8010/aB012345.m3u8\n"),
        ] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let upstream = format!("http://{}", listener.local_addr().unwrap());
            let admin_calls = Arc::new(AtomicUsize::new(0));
            let count = admin_calls.clone();
            let _source = serve_fixture(Router::new()
                .route("/playlist", get(|| async { "#EXTM3U\n#EXTINF:-1,Fox Sports 1\n/hls/fox-sports-1/stream.m3u8\n" }))
                .route("/linear-channels.m3u", get(|| async { "#EXTM3U\n#EXTINF:0 tvg-id=\"8010.eplustv\" channel-id=\"foxsports.FS1\" tvc-guide-stationid=\"82547\", FS1\n/channels/8010.m3u8\n" }))
                .route("/channels/8010.m3u8", get(move || async move { (status, [(header::LOCATION, "/admin")], playlist) }))
                .route("/chunklist/8010/aB012345.m3u8", get(|| async { "#EXTM3U\n#EXTINF:2,\nhttps://private.invalid/secret-leaf.ts\n" }))
                .route("/admin", get(move || { let count = count.clone(); async move { count.fetch_add(1, Ordering::Relaxed); "private" } }))
                .route("/hls/fox-sports-1/stream.m3u8", get(|| async { "#EXTM3U\n#EXTINF:2,\nsegment.ts\n" })), listener).await;
            let cfg = LiveTv { enabled:true, upstream_url:upstream.clone(), direct_tve_url:Some(upstream), ..LiveTv::default() };
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let _adapter = serve_fixture(router(cfg, String::new()).unwrap(), listener).await;
            let client = reqwest::Client::new();
            let tuned: serde_json::Value = client.post(format!("{base}/live/tune")).json(&serde_json::json!({"channelId":"fox-sports-1"})).send().await.unwrap().json().await.unwrap();
            let response = client.get(format!("{base}{}",tuned["playbackPath"].as_str().unwrap())).send().await.unwrap();
            assert_eq!(response.status(), StatusCode::OK, "failed fallback for {playlist}");
            let manifest = response.text().await.unwrap();
            assert!(!manifest.contains("private") && !manifest.contains("secret"));
            assert_eq!(admin_calls.load(Ordering::Relaxed), 0);
        }
    }

    #[tokio::test]
    async fn direct_tve_registered_asset_failures_trigger_fallback_but_unknown_keys_do_not() {
        for failure in [1, 2, 3] {
            let mode = Arc::new(AtomicUsize::new(0));
            let active_mode = mode.clone();
            let captures = Arc::new(AtomicUsize::new(0));
            let count = captures.clone();
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let upstream = format!("http://{}", listener.local_addr().unwrap());
            let _source = serve_fixture(Router::new()
                .route("/playlist", get(|| async { "#EXTM3U\n#EXTINF:-1,Fox Sports 1\n/hls/fox-sports-1/stream.m3u8\n" }))
                .route("/linear-channels.m3u", get(|| async { "#EXTM3U\n#EXTINF:0 tvg-id=\"8010.eplustv\" channel-id=\"foxsports.FS1\" tvc-guide-stationid=\"82547\", FS1\n/channels/8010.m3u8\n" }))
                .route("/channels/8010.m3u8", get(|| async { "#EXTM3U\n#EXTINF:2,\n/channels/8010/8010-segment-aB012345.ts\n" }))
                .route("/channels/8010/8010-segment-aB012345.ts", get(move || { let mode = active_mode.clone(); async move {
                    match mode.load(Ordering::Relaxed) {
                        1 => StatusCode::NOT_FOUND.into_response(),
                        2 => Body::from_stream(futures::stream::unfold(0, |step| async move {
                            match step {
                                0 => Some((Ok::<_, std::io::Error>(bytes::Bytes::from_static(b"part")), 1)),
                                1 => { tokio::time::sleep(Duration::from_millis(10)).await; Some((Err(std::io::Error::other("upstream failed")), 2)) },
                                _ => None,
                            }
                        })).into_response(),
                        3 => Body::empty().into_response(),
                        _ => b"media".to_vec().into_response(),
                    }
                } }))
                .route("/hls/fox-sports-1/stream.m3u8", get(move || { let count = count.clone(); async move {
                    count.fetch_add(1, Ordering::Relaxed); "#EXTM3U\n#EXTINF:2,\nsegment.ts\n"
                } })), listener).await;
            let cfg = LiveTv { enabled:true, upstream_url:upstream.clone(), direct_tve_url:Some(upstream), ..LiveTv::default() };
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let _adapter = serve_fixture(router(cfg, String::new()).unwrap(), listener).await;
            let client = reqwest::Client::new();
            let tune = || client.post(format!("{base}/live/tune")).json(&serde_json::json!({"channelId":"fox-sports-1"}));
            let first: serde_json::Value = tune().send().await.unwrap().json().await.unwrap();
            let unknown = format!("{base}/live/streams/{}/unregistered.ts", first["sessionId"].as_str().unwrap());
            assert_eq!(client.get(unknown).send().await.unwrap().status(), StatusCode::NOT_FOUND);
            let tuned: serde_json::Value = tune().send().await.unwrap().json().await.unwrap();
            let master = client.get(format!("{base}{}", tuned["playbackPath"].as_str().unwrap())).send().await.unwrap().text().await.unwrap();
            assert_eq!(captures.load(Ordering::Relaxed), 0, "invalid capabilities must not poison direct health");
            let path = master.lines().find(|line| line.starts_with("/live/")).unwrap();
            mode.store(failure, Ordering::Relaxed);
            if let Ok(response) = client.get(format!("{base}{path}")).send().await { let _ = response.bytes().await; }
            let fallback: serde_json::Value = tune().send().await.unwrap().json().await.unwrap();
            assert_eq!(client.get(format!("{base}{}", fallback["playbackPath"].as_str().unwrap())).send().await.unwrap().status(), StatusCode::OK);
            assert_eq!(captures.load(Ordering::Relaxed), 1, "asset failure {failure} must select fallback");
        }
    }

    #[tokio::test]
    async fn direct_tve_roku_media_failure_retries_spectrum_with_a_bounded_budget() {
        let _guard = ROKU_HTTP_TEST_LOCK.lock().await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream = format!("http://{}", listener.local_addr().unwrap());
        let captures = Arc::new(AtomicUsize::new(0));
        let count = captures.clone();
        let _source = serve_fixture(Router::new()
            .route("/playlist", get(|| async { "#EXTM3U\n#EXTINF:-1,Fox Sports 1\n/hls/fox-sports-1/stream.m3u8\n" }))
            .route("/linear-channels.m3u", get(|| async { "#EXTM3U\n#EXTINF:0 tvg-id=\"8010.eplustv\" channel-id=\"foxsports.FS1\" tvc-guide-stationid=\"82547\", FS1\n/channels/8010.m3u8\n" }))
            .route("/channels/8010.m3u8", get(|| async { "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n/channels/8010/8010-segment-aB012345.ts\n#EXT-X-ENDLIST\n" }))
            .route("/channels/8010/8010-segment-aB012345.ts", get(|| async { b"corrupt-media".to_vec() }))
            .route("/hls/fox-sports-1/stream.m3u8", get(move || { let count = count.clone(); async move {
                count.fetch_add(1, Ordering::Relaxed); "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n"
            } }))
            .route("/hls/fox-sports-1/segment.ts", get(|| async { b"corrupt-fallback-media".to_vec() })), listener).await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let cfg = LiveTv { enabled:true, upstream_url:upstream.clone(), direct_tve_url:Some(upstream), ..LiveTv::default() };
        let (router, bridge) = router_with_roku_bridge(cfg, String::new(), base.clone()).unwrap();
        let _adapter = serve_fixture(router, listener).await;
        let client = reqwest::Client::new();
        let response = client.post(format!("{base}/live/tune")).timeout(Duration::from_secs(20))
            .json(&serde_json::json!({"channelId":"fox-sports-1","client":"roku"})).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
        assert!(captures.load(Ordering::Relaxed) > 0, "source-caused Roku failure must try Spectrum before returning");
        assert!(bridge.0.direct.as_ref().unwrap().failures.lock().unwrap().contains_key("foxsports.FS1"));
        assert!(bridge.0.sessions.lock().unwrap().items.is_empty(), "failed remux sessions must be released");
    }

    #[tokio::test]
    async fn direct_tve_does_not_replace_roku_sports_browser_origin() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let prism = format!("http://{}", listener.local_addr().unwrap());
        let calls = Arc::new(AtomicUsize::new(0));
        let count = calls.clone();
        let _prism = serve_fixture(Router::new().route("/play", get(move || { let count = count.clone(); async move {
            count.fetch_add(1, Ordering::Relaxed);
            (StatusCode::FOUND, [(header::LOCATION, "/hls/play-0123abcd/stream.m3u8")])
        } })), listener).await;
        let cfg = LiveTv { enabled:true, upstream_url:prism, direct_tve_url:Some("http://127.0.0.1:1".into()), ..LiveTv::default() };
        let (_, bridge) = router_with_bridge(cfg, String::new()).unwrap();
        let session = bridge.tune_sports("https://strmfree.st/embed/basketball/event1080p", "event-1", "Game", None).await.unwrap();
        assert_eq!(session["channel"]["id"], "event-1");
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        let sessions = bridge.0.sessions.lock().unwrap();
        assert!(sessions.items[session["sessionId"].as_str().unwrap()].direct.is_none());
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
