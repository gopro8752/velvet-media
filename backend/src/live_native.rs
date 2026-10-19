//! Fixed-origin transport for the private native Spectrum provider. The sidecar
//! owns provider authentication, DRM policy, manifest rewriting and lease expiry.
//! This adapter forwards only bounded media/CDM bytes and opaque capability paths.
use super::*;
use axum::body::{to_bytes, Bytes};

const MAX_LICENSE: usize = 1024 * 1024;
const MAX_MANIFEST: usize = 2 * 1024 * 1024;
const MAX_CERTIFICATE: usize = 64 * 1024;
const MAX_DESCRIPTOR: usize = 64 * 1024;
const MAX_GUIDE: usize = 16 * 1024 * 1024;
const DASH: &str = "application/dash+xml";
const CAPABILITIES: &str = "x-velvet-playback-capabilities";
const CLIENT: &str = "x-velvet-client";

#[derive(Default)]
struct CatalogCache { attempted: Option<Instant>, channels: Vec<Channel>, issue: Option<String> }
#[derive(Default)]
struct GuideCache { attempted: Option<Instant>, value: Option<crate::epg::Guide> }
pub(super) struct NativeSpectrum { origin: Url, http: reqwest::Client, cache: AsyncMutex<CatalogCache>, guide_cache: AsyncMutex<GuideCache> }

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Catalog { enabled: bool, channels: Vec<Channel> }
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Descriptor {
    session_id: String, playback_path: String, mime_type: String, channel: Channel,
    can_pause: bool, can_seek: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    drm: Option<Drm>,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Drm {
    scheme: String, license_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    certificate_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content_id_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    multi_session: Option<bool>,
}

fn valid_cap(id: &str) -> bool { id.len() == 48 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) }
fn valid_resource(value: &str) -> bool {
    !value.is_empty() && value.len() <= 240 && !value.starts_with('.') && !value.contains("..")
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
}
fn valid_key(value: &str) -> bool {
    !value.is_empty() && value.len() <= 160 && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}
fn stream_path(id: &str, path: &str) -> bool {
    valid_cap(id) && path.strip_prefix(&format!("/live/streams/{id}/")).is_some_and(valid_resource)
}
fn text_field(value: &str, maximum: usize) -> bool {
    !value.is_empty() && value.len() <= maximum && !value.chars().any(char::is_control)
}
fn valid_channel(channel: &Channel) -> bool {
    safe_name(&channel.id) && text_field(&channel.name, 256)
        && channel.number.as_deref().is_none_or(|s| text_field(s, 32))
        && channel.group.as_deref().is_none_or(|s| text_field(s, 120))
        && channel.logo_url.as_deref().is_none_or(|s| s.len() <= 2048 && Url::parse(s).is_ok_and(|url|
            matches!(url.scheme(), "http" | "https") && url.host_str().is_some() && url.username().is_empty() && url.password().is_none()))
}
fn update_required() -> LiveError {
    LiveError(StatusCode::UPGRADE_REQUIRED, "Update Velvet to play native Spectrum channels on this device")
}
fn busy() -> LiveError { LiveError(StatusCode::SERVICE_UNAVAILABLE, "Live source busy; retry shortly") }
fn capabilities(headers: &HeaderMap) -> Result<Vec<&str>> {
    let value = headers.get(CAPABILITIES).and_then(|v| v.to_str().ok()).filter(|v| v.len() <= 256).ok_or_else(update_required)?;
    let mut values = Vec::new();
    for item in value.split(',').map(str::trim) {
        if matches!(item, "hls-clear" | "dash-widevine" | "hls-fmp4-widevine" | "hls-fairplay") && !values.contains(&item) { values.push(item); }
    }
    if values.is_empty() { return Err(update_required()); }
    Ok(values)
}
fn validate_descriptor(value: &Descriptor, channel: &str, caps: &[&str]) -> Result<()> {
    if !stream_path(&value.session_id, &value.playback_path) || !valid_channel(&value.channel) || value.channel.id != channel { return Err(invalid()); }
    let hls = value.mime_type == HLS && value.playback_path.ends_with(".m3u8");
    let dash = value.mime_type == DASH && value.playback_path.ends_with(".mpd");
    if !hls && !dash { return Err(invalid()); }
    let capability = match &value.drm {
        None if hls => "hls-clear",
        None => return Err(update_required()),
        Some(drm) => {
            if drm.license_path != format!("/live/drm/{}", value.session_id) { return Err(invalid()); }
            match drm.scheme.as_str() {
                "widevine" if drm.certificate_path.is_none() && drm.content_id_mode.is_none() => {
                    if dash { "dash-widevine" } else { "hls-fmp4-widevine" }
                },
                "fairplay" if hls && drm.certificate_path.as_deref() == Some(&format!("/live/cert/{}", value.session_id))
                    && drm.content_id_mode.as_deref() == Some("spectrum-content-id") => "hls-fairplay",
                _ => return Err(invalid()),
            }
        },
    };
    if !caps.contains(&capability) { return Err(update_required()); }
    Ok(())
}

fn coded_error(code: &str) -> Option<LiveError> {
    Some(match code {
        "sign_in_required" => LiveError(StatusCode::UNAUTHORIZED, "Sign in to Spectrum again to watch live TV"),
        "channel_not_entitled" => LiveError(StatusCode::FORBIDDEN, "This channel is not included in your Spectrum subscription"),
        "home_network_required" => LiveError(StatusCode::FORBIDDEN, "Connect to your Spectrum home network to watch this channel"),
        "location_restricted" => LiveError(StatusCode::FORBIDDEN, "Spectrum does not allow this channel at your current location"),
        "concurrency_limit" => LiveError(StatusCode::TOO_MANY_REQUESTS, "Spectrum's stream limit was reached; close another player and retry"),
        "native_update_required" => update_required(),
        "drm_unavailable" => LiveError(StatusCode::SERVICE_UNAVAILABLE, "Protected Spectrum playback is unavailable on this device right now"),
        "source_unavailable" => LiveError(StatusCode::SERVICE_UNAVAILABLE, "Spectrum is temporarily unavailable; try again shortly"),
        _ => return None,
    })
}
async fn read_bytes(mut response: reqwest::Response, maximum: usize) -> Result<Bytes> {
    if response.content_length().is_some_and(|length| length > maximum as u64) { return Err(invalid()); }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| unavailable())? {
        if bytes.len().saturating_add(chunk.len()) > maximum { return Err(invalid()); }
        bytes.extend_from_slice(&chunk);
    }
    Ok(Bytes::from(bytes))
}
async fn sidecar_error(response: reqwest::Response) -> LiveError {
    let status = response.status();
    #[derive(Deserialize)] struct Failure { code: Option<String> }
    if let Ok(bytes) = read_bytes(response, 16 * 1024).await {
        if let Some(error) = serde_json::from_slice::<Failure>(&bytes).ok().and_then(|f| f.code).as_deref().and_then(coded_error) { return error; }
    }
    match status {
        StatusCode::NOT_FOUND | StatusCode::GONE => expired(),
        StatusCode::TOO_MANY_REQUESTS => coded_error("concurrency_limit").unwrap(),
        StatusCode::UPGRADE_REQUIRED => update_required(),
        _ => unavailable(),
    }
}
fn transport_error(error: reqwest::Error) -> LiveError {
    if error.is_timeout() { LiveError(StatusCode::GATEWAY_TIMEOUT, "Spectrum took too long to respond; try again") } else { unavailable() }
}

impl NativeSpectrum {
    pub(super) fn new(value: &str) -> anyhow::Result<Self> {
        let origin = configured_origin(value).map_err(|_| anyhow::anyhow!("invalid live_tv.native_spectrum_url: expected private HTTP(S) origin without credentials or path"))?;
        let http = reqwest::Client::builder().user_agent("velvet-native-live/0.1")
            .no_proxy().redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5)).timeout(Duration::from_secs(60)).build()?;
        Ok(Self { origin, http, cache: AsyncMutex::new(CatalogCache::default()), guide_cache: AsyncMutex::new(GuideCache::default()) })
    }
    fn url(&self, path: &str) -> Result<Url> { self.origin.join(path).map_err(|_| invalid()) }
    pub(super) async fn guide(&self, channels: &[Channel]) -> Option<crate::epg::Guide> {
        let mut cache = self.guide_cache.lock().await;
        if cache.attempted.is_some_and(|at| at.elapsed() < CACHE_AGE) { return cache.value.clone(); }
        cache.attempted = Some(Instant::now());
        let fetched = async {
            let response = self.http.get(self.url("/live/guide")?).timeout(Duration::from_secs(40)).send().await.map_err(transport_error)?;
            if !response.status().is_success() { return Err(sidecar_error(response).await); }
            let mut guide: crate::epg::Guide = serde_json::from_slice(&read_bytes(response, MAX_GUIDE).await?).map_err(|_| invalid())?;
            let known: HashSet<_> = channels.iter().map(|c| c.id.as_str()).collect();
            let mut seen = HashSet::new();
            if !guide.enabled || guide.channels.len() > MAX_CHANNELS || guide.updated_at.as_deref().is_some_and(|date| chrono::DateTime::parse_from_rfc3339(date).is_err()) { return Err(invalid()); }
            for row in &mut guide.channels {
                if !known.contains(row.channel_id.as_str()) || !seen.insert(row.channel_id.clone()) || row.programs.len() > 160 { return Err(invalid()); }
                let mut starts = HashSet::new();
                for p in &row.programs {
                    let start = chrono::DateTime::parse_from_rfc3339(&p.start_time).map_err(|_| invalid())?;
                    let end = chrono::DateTime::parse_from_rfc3339(&p.end_time).map_err(|_| invalid())?;
                    if !text_field(&p.id, 256) || !text_field(&p.title, 400) || end <= start || end - start > chrono::Duration::hours(24)
                        || !starts.insert(start.timestamp()) || p.description.as_deref().is_some_and(|s| !text_field(s, 4000))
                        || p.episode_title.as_deref().is_some_and(|s| !text_field(s, 400)) || p.rating.as_deref().is_some_and(|s| !text_field(s, 32))
                        || p.genres.len() > 12 || p.genres.iter().any(|s| !text_field(s, 80))
                        || p.image_url.as_deref().is_some_and(|s| s.len() > 2048 || !Url::parse(s).is_ok_and(|u| u.scheme() == "https" && u.host_str() == Some("cdnimg.spectrum.net") && u.port().is_none() && u.path().starts_with("/imageserver/program/") && u.username().is_empty() && u.password().is_none() && u.query().is_none() && u.fragment().is_none())) { return Err(invalid()); }
                }
                row.programs.sort_by(|a, b| a.start_time.cmp(&b.start_time));
            }
            Ok(guide)
        }.await;
        if let Ok(guide) = fetched { cache.value = Some(guide); }
        cache.value.clone()
    }
    pub(super) async fn channels(&self) -> (Vec<Channel>, Option<String>) {
        let mut cache = self.cache.lock().await;
        if cache.attempted.is_some_and(|at| at.elapsed() < CACHE_AGE) { return (cache.channels.clone(), cache.issue.clone()); }
        cache.attempted = Some(Instant::now());
        let fetched = async {
            let response = self.http.get(self.url("/live/channels")?).timeout(Duration::from_secs(12)).send().await.map_err(transport_error)?;
            if !response.status().is_success() { return Err(sidecar_error(response).await); }
            let catalog: Catalog = serde_json::from_slice(&read_bytes(response, MAX_LINEUP).await?).map_err(|_| invalid())?;
            let mut seen = HashSet::new();
            if !catalog.enabled || catalog.channels.len() > MAX_CHANNELS
                || catalog.channels.iter().any(|c| !valid_channel(c) || !seen.insert(c.id.clone())) { return Err(invalid()); }
            Ok(catalog.channels)
        }.await;
        match fetched {
            Ok(channels) => { cache.channels = channels; cache.issue = None; },
            Err(error) => cache.issue = Some(error.1.into()),
        }
        (cache.channels.clone(), cache.issue.clone())
    }
    pub(super) async fn tune(&self, state: &LiveState, tune: &Tune, headers: &HeaderMap) -> Result<Response> {
        let caps = capabilities(headers)?;
        let _permit = state.requests.try_acquire().map_err(|_| busy())?;
        let mut request = self.http.post(self.url("/live/tune")?).timeout(Duration::from_secs(45))
            .header(CAPABILITIES, caps.join(",")).json(tune);
        if let Some(client) = headers.get(CLIENT) {
            let client = client.to_str().map_err(|_| invalid())?;
            if !matches!(client, "android" | "ios" | "roku") { return Err(LiveError(StatusCode::BAD_REQUEST, "Invalid live playback client")); }
            request = request.header(CLIENT, client);
        }
        let response = request.send().await.map_err(transport_error)?;
        if !response.status().is_success() { return Err(sidecar_error(response).await); }
        let bytes = read_bytes(response, MAX_DESCRIPTOR).await?;
        #[derive(Deserialize)] #[serde(rename_all = "camelCase")] struct Allocation { session_id: String }
        let allocated = serde_json::from_slice::<Allocation>(&bytes).ok().map(|v| v.session_id).filter(|v| valid_cap(v));
        let validated = serde_json::from_slice::<Descriptor>(&bytes).map_err(|_| invalid()).and_then(|descriptor| {
            validate_descriptor(&descriptor, &tune.channel_id, &caps)?;
            if state.sessions.lock().unwrap().items.contains_key(&descriptor.session_id) { return Err(invalid()); }
            Ok(descriptor)
        });
        match validated {
            Ok(descriptor) => Ok(no_store(Json(descriptor).into_response())),
            Err(error) => {
                if let Some(id) = allocated { let _ = self.end(&id).await; }
                Err(error)
            },
        }
    }
    pub(super) async fn end(&self, id: &str) -> Result<Response> {
        if !valid_cap(id) { return Err(expired()); }
        let response = self.http.delete(self.url(&format!("/live/sessions/{id}"))?).timeout(Duration::from_secs(10))
            .send().await.map_err(transport_error)?;
        if !response.status().is_success() && response.status() != StatusCode::NOT_FOUND { return Err(sidecar_error(response).await); }
        Ok(no_store(StatusCode::NO_CONTENT.into_response()))
    }
    pub(super) async fn playback(&self, state: &LiveState, id: &str, key: &str, query: Option<&str>, headers: &HeaderMap) -> Result<Response> {
        if !valid_cap(id) || !valid_resource(key) || query.is_some() { return Err(expired()); }
        let permit = state.requests.clone().try_acquire_owned().map_err(|_| busy())?;
        let manifest = key.ends_with(".m3u8") || key.ends_with(".mpd");
        let mut request = self.http.get(self.url(&format!("/live/streams/{id}/{key}"))?);
        if !manifest {
            if let Some(range) = headers.get(header::RANGE) {
                let range = range.to_str().map_err(|_| LiveError(StatusCode::BAD_REQUEST, "Invalid byte range"))?;
                if !valid_range(range) { return Err(LiveError(StatusCode::BAD_REQUEST, "Invalid byte range")); }
                request = request.header(header::RANGE, range);
            }
        }
        let response = request.send().await.map_err(transport_error)?;
        if !response.status().is_success() { return Err(sidecar_error(response).await); }
        if manifest {
            let body = read_bytes(response, MAX_MANIFEST).await?;
            return Ok(no_store(([(header::CONTENT_TYPE, if key.ends_with(".mpd") { DASH } else { HLS })], body).into_response()));
        }
        if response.content_length().is_some_and(|length| length > MAX_SEGMENT as u64) { return Err(invalid()); }
        let mut output = Response::builder().status(response.status());
        for name in [header::CONTENT_LENGTH, header::CONTENT_RANGE, header::ACCEPT_RANGES] {
            if let Some(value) = response.headers().get(&name) { output = output.header(name, value.clone()); }
        }
        let content_type = response.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("application/octet-stream");
        output = output.header(header::CONTENT_TYPE, if matches!(content_type, "video/mp4" | "audio/mp4" | "video/mp2t" | "application/mp4" | "audio/aac") { content_type } else { "application/octet-stream" });
        let stream = futures::stream::try_unfold((response.bytes_stream(), permit, 0usize), |(mut stream, permit, total)| async move {
            let Some(next) = stream.next().await else { return Ok(None); };
            let chunk = next.map_err(|_| std::io::Error::other("Live segment interrupted"))?;
            let total = total.saturating_add(chunk.len());
            if total > MAX_SEGMENT { return Err(std::io::Error::other("Live segment interrupted")); }
            Ok(Some((chunk, (stream, permit, total))))
        });
        Ok(no_store(output.body(Body::from_stream(stream)).map_err(|_| invalid())?))
    }
}

pub(super) async fn license(State(state): State<Arc<LiveState>>, Path(id): Path<String>, request: Request) -> Result<Response> {
    let native = state.native.as_ref().filter(|_| state.cfg.enabled).ok_or_else(expired)?;
    if !valid_cap(&id) { return Err(expired()); }
    let mut url = native.url(&format!("/live/drm/{id}"))?;
    if let Some(query) = request.uri().query() {
        let key = query.strip_prefix("key=").filter(|v| valid_key(v)).ok_or(LiveError(StatusCode::BAD_REQUEST, "Invalid live license request"))?;
        url.set_query(Some(&format!("key={key}")));
    }
    let _permit = state.requests.try_acquire().map_err(|_| busy())?;
    let body = tokio::time::timeout(Duration::from_secs(15), to_bytes(request.into_body(), MAX_LICENSE)).await
        .map_err(|_| LiveError(StatusCode::REQUEST_TIMEOUT, "Live license request timed out"))?
        .map_err(|_| LiveError(StatusCode::PAYLOAD_TOO_LARGE, "Live license request is too large"))?;
    if body.is_empty() { return Err(LiveError(StatusCode::BAD_REQUEST, "Empty live license request")); }
    let response = native.http.post(url).header(header::CONTENT_TYPE, "application/octet-stream").body(body)
        .timeout(Duration::from_secs(25)).send().await.map_err(transport_error)?;
    if !response.status().is_success() { return Err(sidecar_error(response).await); }
    let bytes = read_bytes(response, MAX_LICENSE).await?;
    if bytes.is_empty() { return Err(invalid()); }
    Ok(no_store(([(header::CONTENT_TYPE, "application/octet-stream")], bytes).into_response()))
}
pub(super) async fn certificate(State(state): State<Arc<LiveState>>, Path(id): Path<String>, query: axum::extract::RawQuery) -> Result<Response> {
    let native = state.native.as_ref().filter(|_| state.cfg.enabled).ok_or_else(expired)?;
    if !valid_cap(&id) || query.0.is_some() { return Err(expired()); }
    let _permit = state.requests.try_acquire().map_err(|_| busy())?;
    let response = native.http.get(native.url(&format!("/live/cert/{id}"))?).timeout(Duration::from_secs(15))
        .send().await.map_err(transport_error)?;
    if !response.status().is_success() { return Err(sidecar_error(response).await); }
    let bytes = read_bytes(response, MAX_CERTIFICATE).await?;
    if bytes.is_empty() { return Err(invalid()); }
    Ok(no_store(([(header::CONTENT_TYPE, "application/octet-stream")], bytes).into_response()))
}

#[cfg(test)]
#[path = "live_native_tests.rs"]
mod tests;
