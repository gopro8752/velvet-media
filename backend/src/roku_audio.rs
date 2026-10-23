//! Native Roku audio compatibility: copy the registered video's bitstream and
//! convert one selected audio track to AAC. Sessions are bounded, private,
//! cancellable, and seek by starting at a measured source keyframe.
use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::PathBuf,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncSeekExt},
    process::{Child, Command},
    sync::{Notify, OwnedSemaphorePermit, Semaphore},
};

const IDLE: Duration = Duration::from_secs(90);
const LIFETIME: Duration = Duration::from_secs(12 * 3600);
const MAX_DURATION_MS: u64 = 24 * 3600 * 1000;
const MAX_FILE: u64 = 256 * 1024 * 1024;
const MAX_DISK: u64 = 4 * 1024 * 1024 * 1024;
const PROBE_LIMIT: u64 = 2 * 1024 * 1024;

#[derive(Clone)]
struct AudioState {
    streams: crate::stream::StreamState,
    source_base: String,
    root: PathBuf,
    sessions: Arc<Mutex<HashMap<String, Arc<Session>>>>,
    slots: Arc<Semaphore>,
    readers: Arc<Semaphore>,
}
struct Session {
    id: String,
    dir: PathBuf,
    created: Instant,
    touched: Mutex<Instant>,
    cancelled: AtomicBool,
    stopped: AtomicBool,
    cancel: Notify,
    delivered: AtomicU64,
    source_bitrate: u64,
    peak_bitrate: AtomicU64,
    status: Mutex<&'static str>,
    metadata: SessionInfo,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionInfo {
    session_id: String,
    playback_path: String,
    source_offset_ms: u64,
    requested_position_ms: u64,
    duration_ms: u64,
    audio_track: u32,
    audio_tracks: Vec<AudioTrack>,
    subtitle_track: Option<u32>,
    subtitle_tracks: Vec<SubtitleTrack>,
    video_codec: String,
}
#[derive(Clone, Serialize, Debug)]
struct SubtitleTrack {
    index: u32,
    codec: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
struct AudioTrack {
    index: u32,
    codec: String,
    channels: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartRequest {
    #[serde(default)]
    position_ms: u64,
    audio_track: Option<u32>,
    subtitle_track: Option<u32>,
    playback_session_id: Option<String>,
}
#[derive(Debug)]
struct AudioError(StatusCode, &'static str);
impl IntoResponse for AudioError {
    fn into_response(self) -> Response {
        (
            self.0,
            [(header::CACHE_CONTROL, "no-store")],
            Json(serde_json::json!({"error":self.1})),
        )
            .into_response()
    }
}
type Result<T> = std::result::Result<T, AudioError>;
#[derive(Deserialize)]
struct Probe {
    #[serde(default)]
    streams: Vec<ProbeTrack>,
    format: ProbeFormat,
}
#[derive(Deserialize)]
struct ProbeFormat {
    duration: Option<String>,
    start_time: Option<String>,
    bit_rate: Option<String>,
    size: Option<String>,
}
#[derive(Deserialize)]
struct ProbeTrack {
    index: u32,
    codec_type: Option<String>,
    codec_name: Option<String>,
    channels: Option<u32>,
    #[serde(default)]
    tags: HashMap<String, String>,
}
struct Metadata {
    duration_ms: u64,
    source_start: f64,
    source_bitrate: u64,
    video_codec: String,
    audio_tracks: Vec<AudioTrack>,
    subtitle_tracks: Vec<SubtitleTrack>,
}

pub fn router(streams: crate::stream::StreamState, source_base: String) -> anyhow::Result<Router> {
    validate_origin(&source_base)?;
    let root = std::env::temp_dir().join("velvet-roku-audio-v1");
    std::fs::create_dir_all(&root)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))?;
    }
    let state = AudioState {
        streams,
        source_base: source_base.trim_end_matches('/').to_owned(),
        root,
        sessions: Arc::new(Mutex::new(HashMap::new())),
        slots: Arc::new(Semaphore::new(2)),
        readers: Arc::new(Semaphore::new(8)),
    };
    // Clean files left by an interrupted previous server, never arbitrary paths.
    let cleanup = state.root.clone();
    tokio::spawn(async move {
        reap_orphans(cleanup).await;
    });
    Ok(Router::new()
        .route("/stream/:sid/roku/session", post(start))
        .route("/roku/audio/:id", get(status).delete(cancel))
        .route("/roku/audio/:id/:file", get(asset))
        .with_state(state))
}
fn validate_origin(source: &str) -> anyhow::Result<()> {
    let base = reqwest::Url::parse(source)?;
    anyhow::ensure!(
        base.scheme() == "http"
            && matches!(
                base.host_str(),
                Some("127.0.0.1") | Some("[::1]") | Some("::1")
            )
            && base.username().is_empty()
            && base.password().is_none()
            && base.query().is_none()
            && base.fragment().is_none()
            && base.path() == "/",
        "Roku audio source must be a server-owned loopback origin"
    );
    Ok(())
}
fn hex_id(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn random_id() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::getrandom(&mut bytes)
        .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "session_unavailable"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}
impl AudioState {
    fn source(&self, sid: &str) -> Result<String> {
        if !hex_id(sid, 16) || !self.streams.is_registered(sid) {
            return Err(AudioError(StatusCode::NOT_FOUND, "unknown_stream"));
        }
        Ok(format!("{}/stream/{sid}", self.source_base))
    }
    fn session(&self, id: &str) -> Result<Arc<Session>> {
        if !hex_id(id, 32) {
            return Err(AudioError(StatusCode::NOT_FOUND, "unknown_session"));
        }
        let value = self
            .sessions
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or(AudioError(StatusCode::NOT_FOUND, "unknown_session"))?;
        if value.cancelled.load(Ordering::Relaxed)
            || value.touched.lock().unwrap().elapsed() > IDLE
            || value.created.elapsed() > LIFETIME
        {
            value.cancel();
            return Err(AudioError(StatusCode::GONE, "session_expired"));
        }
        *value.touched.lock().unwrap() = Instant::now();
        Ok(value)
    }
}
impl Session {
    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        self.cancel.notify_one();
    }
}
async fn start(
    State(state): State<AudioState>,
    Path(sid): Path<String>,
    headers: HeaderMap,
    Json(request): Json<StartRequest>,
) -> Result<Json<SessionInfo>> {
    let playback_session = crate::stream::requested_playback_session(&headers, request.playback_session_id.as_deref())
        .map_err(|status| AudioError(status, "invalid_playback_session"))?;
    let source = state.source(&sid)?;
    if request.position_ms > MAX_DURATION_MS {
        return Err(AudioError(StatusCode::BAD_REQUEST, "invalid_position"));
    }
    let permit = tokio::time::timeout(Duration::from_secs(2), state.slots.clone().acquire_owned())
        .await
        .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_busy"))?
        .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_busy"))?;
    let metadata = probe(&source).await?;
    if request.position_ms >= metadata.duration_ms {
        return Err(AudioError(StatusCode::BAD_REQUEST, "position_after_end"));
    }
    let track = request
        .audio_track
        .or_else(|| metadata.audio_tracks.first().map(|t| t.index))
        .ok_or(AudioError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "audio_track_unavailable",
        ))?;
    if !metadata.audio_tracks.iter().any(|t| t.index == track) {
        return Err(AudioError(StatusCode::BAD_REQUEST, "invalid_audio_track"));
    }
    if request
        .subtitle_track
        .is_some_and(|index| !metadata.subtitle_tracks.iter().any(|t| t.index == index))
    {
        return Err(AudioError(
            StatusCode::BAD_REQUEST,
            "invalid_subtitle_track",
        ));
    }
    // Copying video requires seeking to an actual preceding random-access frame.
    let offset = if request.position_ms == 0 {
        0.0
    } else {
        keyframe(&source, request.position_ms, metadata.source_start).await?
    };
    let id = random_id()?;
    let dir = state.root.join(&id);
    tokio::fs::create_dir(&dir).await.map_err(|_| {
        AudioError(
            StatusCode::SERVICE_UNAVAILABLE,
            "session_storage_unavailable",
        )
    })?;
    let info = SessionInfo {
        session_id: id.clone(),
        playback_path: format!("/roku/audio/{id}/master.m3u8"),
        source_offset_ms: (offset * 1000.0).round() as u64,
        requested_position_ms: request.position_ms,
        duration_ms: metadata.duration_ms,
        audio_track: track,
        audio_tracks: metadata.audio_tracks,
        subtitle_track: request.subtitle_track,
        subtitle_tracks: metadata.subtitle_tracks,
        video_codec: metadata.video_codec.clone(),
    };
    let session = Arc::new(Session {
        id: id.clone(),
        dir,
        created: Instant::now(),
        touched: Mutex::new(Instant::now()),
        cancelled: AtomicBool::new(false),
        stopped: AtomicBool::new(false),
        cancel: Notify::new(),
        delivered: AtomicU64::new(0),
        source_bitrate: metadata.source_bitrate,
        peak_bitrate: AtomicU64::new(0),
        status: Mutex::new("starting"),
        metadata: info.clone(),
    });
    // Probe/keyframe reads above are speculative. Associate only media reads
    // by the running encoder, using the server-owned loopback URL.
    let encoder_source = crate::stream::attributed_source(&source, playback_session.as_deref());
    let child = match encoder(
        &encoder_source,
        request.position_ms as f64 / 1000.0,
        offset,
        track,
        request.subtitle_track,
        &metadata.video_codec,
        &session.dir,
    ) {
        Ok(child) => child,
        Err(error) => {
            let _ = tokio::fs::remove_dir_all(&session.dir).await;
            return Err(error);
        }
    };
    state.sessions.lock().unwrap().insert(id, session.clone());
    tokio::spawn(run_worker(state.clone(), session.clone(), child, permit));
    let ready = tokio::time::timeout(Duration::from_secs(25), async {
        loop {
            if session.cancelled.load(Ordering::Acquire)
                || *session.status.lock().unwrap() == "failed"
            {
                return Err(AudioError(
                    StatusCode::BAD_GATEWAY,
                    "audio_conversion_failed",
                ));
            }
            if let Ok(index) = tokio::fs::read_to_string(session.dir.join("index.m3u8")).await {
                if index.lines().any(|line| segment_index(line).is_some())
                    && tokio::fs::metadata(session.dir.join("master.m3u8"))
                        .await
                        .is_ok()
                {
                    return Ok(());
                }
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await;
    match ready {
        Ok(Ok(())) => {}
        Ok(Err(error)) => {
            session.cancel();
            return Err(error);
        }
        Err(_) => {
            session.cancel();
            return Err(AudioError(StatusCode::BAD_GATEWAY, "audio_start_timeout"));
        }
    }
    *session.touched.lock().unwrap() = Instant::now();
    Ok(Json(info))
}
async fn probe_output(mut command: Command) -> Result<Vec<u8>> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_probe_unavailable"))?;
    let stdout = child.stdout.take().unwrap();
    let mut bytes = Vec::new();
    let result = tokio::time::timeout(Duration::from_secs(20), async {
        stdout.take(PROBE_LIMIT + 1).read_to_end(&mut bytes).await?;
        child.wait().await
    })
    .await;
    if !matches!(result, Ok(Ok(status)) if status.success()) || bytes.len() as u64 > PROBE_LIMIT {
        return Err(AudioError(StatusCode::BAD_GATEWAY, "audio_probe_failed"));
    }
    Ok(bytes)
}
fn probe_command(source: &str) -> Command {
    let mut command = Command::new("ffprobe");
    command.args([
        "-v",
        "error",
        "-rw_timeout",
        "15000000",
        "-protocol_whitelist",
        "http,tcp",
        "-probesize",
        "5000000",
        "-analyzeduration",
        "5000000",
    ]);
    command.arg(source);
    command
}
async fn probe(source: &str) -> Result<Metadata> {
    let mut command = probe_command(source);
    command.args(["-show_entries", "format=duration,start_time,bit_rate,size:stream=index,codec_type,codec_name,channels:stream_tags=language,title", "-of", "json"]);
    parse_metadata(&probe_output(command).await?)
}
fn number(value: Option<&str>) -> Option<f64> {
    value
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|v| v.is_finite())
}
fn parse_metadata(bytes: &[u8]) -> Result<Metadata> {
    let probe: Probe = serde_json::from_slice(bytes)
        .map_err(|_| AudioError(StatusCode::BAD_GATEWAY, "audio_probe_failed"))?;
    let duration = number(probe.format.duration.as_deref())
        .filter(|v| *v > 0.0 && *v <= MAX_DURATION_MS as f64 / 1000.0)
        .ok_or(AudioError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "duration_unavailable",
        ))?;
    let video_codec = probe
        .streams
        .iter()
        .find(|t| t.codec_type.as_deref() == Some("video"))
        .and_then(|t| t.codec_name.clone())
        .ok_or(AudioError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "video_unavailable",
        ))?;
    if video_codec != "h264" && video_codec != "hevc" {
        return Err(AudioError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "unsupported_video_codec",
        ));
    }
    let audio_tracks = probe
        .streams
        .iter()
        .filter(|t| t.codec_type.as_deref() == Some("audio"))
        .map(|t| AudioTrack {
            index: t.index,
            codec: t.codec_name.clone().unwrap_or_default(),
            channels: t.channels.unwrap_or(0),
            language: t.tags.get("language").map(|s| s.chars().take(32).collect()),
            title: t.tags.get("title").map(|s| s.chars().take(256).collect()),
        })
        .collect();
    let subtitle_tracks = probe
        .streams
        .iter()
        .filter(|t| {
            t.codec_type.as_deref() == Some("subtitle")
                && matches!(
                    t.codec_name.as_deref(),
                    Some("subrip" | "srt" | "ass" | "ssa" | "webvtt" | "mov_text" | "text")
                )
        })
        .map(|t| SubtitleTrack {
            index: t.index,
            codec: t.codec_name.clone().unwrap_or_default(),
            language: t.tags.get("language").map(|s| s.chars().take(32).collect()),
            title: t.tags.get("title").map(|s| s.chars().take(256).collect()),
        })
        .collect();
    Ok(Metadata {
        duration_ms: (duration * 1000.0).round() as u64,
        source_start: number(probe.format.start_time.as_deref()).unwrap_or(0.0),
        source_bitrate: number(probe.format.bit_rate.as_deref())
            .filter(|v| *v > 0.0)
            .or_else(|| number(probe.format.size.as_deref()).map(|size| size * 8.0 / duration))
            .filter(|v| *v > 0.0)
            .unwrap_or(0.0)
            .min(2_000_000_000.0)
            .ceil() as u64,
        video_codec,
        audio_tracks,
        subtitle_tracks,
    })
}
async fn keyframe(source: &str, requested: u64, source_start: f64) -> Result<f64> {
    let target = requested as f64 / 1000.0 + source_start;
    // Use the same demux seek and stream-copy path as the worker. ffprobe's
    // read_intervals can choose a different HEVC open-GOP cue than ffmpeg -ss.
    // One copied packet reveals the actual random-access frame without decoding
    // or scanning the file, and copyts keeps its original source timestamp.
    let mut command = Command::new("ffmpeg");
    command.args([
        "-v",
        "error",
        "-nostdin",
        "-rw_timeout",
        "15000000",
        "-protocol_whitelist",
        "http,tcp",
        "-ss",
        &format!("{:.6}", requested as f64 / 1000.0),
        "-noaccurate_seek",
        "-copyts",
        "-i",
        source,
        "-map",
        "0:v:0",
        "-c:v",
        "copy",
        "-frames:v",
        "1",
        "-an",
        "-sn",
        "-avoid_negative_ts",
        "disabled",
        "-f",
        "framecrc",
        "-",
    ]);
    parse_keyframe(&probe_output(command).await?, target, source_start)
}
fn parse_keyframe(bytes: &[u8], target: f64, source_start: f64) -> Result<f64> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| AudioError(StatusCode::BAD_GATEWAY, "seek_probe_failed"))?;
    let time_base = text.lines().find_map(|line| {
        let (num, den) = line.strip_prefix("#tb 0:")?.trim().split_once('/')?;
        let num = number(Some(num))?;
        let den = number(Some(den))?;
        (num > 0.0 && den > 0.0).then_some(num / den)
    });
    let best = text
        .lines()
        .find_map(|line| {
            if line.starts_with('#') {
                return None;
            }
            let mut fields = line.split(',').map(str::trim);
            if fields.next()? != "0" {
                return None;
            }
            fields.next()?;
            Some(number(fields.next())? * time_base?)
        })
        .filter(|pts| *pts <= target + 0.001 && *pts >= source_start - 1.0)
        .ok_or(AudioError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "seek_keyframe_unavailable",
        ))?;
    let offset = (best - source_start).max(0.0);
    // Refuse an impractically distant cue rather than pretending a wrong time.
    if target - best > 120.0 {
        return Err(AudioError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "seek_keyframe_too_distant",
        ));
    }
    Ok(offset)
}
fn encoder(
    source: &str,
    seek: f64,
    offset: f64,
    track: u32,
    subtitle: Option<u32>,
    video_codec: &str,
    dir: &std::path::Path,
) -> Result<Child> {
    let mut command = Command::new("ffmpeg");
    command.current_dir(dir).args([
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-rw_timeout",
        "15000000",
        "-protocol_whitelist",
        "http,tcp",
        "-ss",
        &format!("{seek:.6}"),
        "-noaccurate_seek",
        // Fill Roku's initial HLS window faster, while the worker still pauses
        // at its bounded lookahead and caps disk use and concurrent encoders.
        "-readrate",
        "4",
        "-i",
        source,
        "-map",
        "0:v:0",
        "-map",
        &format!("0:{track}"),
        "-c:v",
        "copy",
        "-c:a",
        "aac",
        "-af",
        &format!("atrim=start={:.6}", offset - seek),
        "-b:a",
        "192k",
        "-ac",
        "2",
        "-ar",
        "48000",
        "-threads:a",
        "1",
        "-dn",
        "-avoid_negative_ts",
        "make_zero",
        "-max_muxing_queue_size",
        "1024",
        "-max_interleave_delta",
        "1000000",
    ]);
    if let Some(subtitle) = subtitle {
        command.args([
            "-map",
            &format!("0:{subtitle}"),
            "-c:s",
            "webvtt",
            "-var_stream_map",
            // `sname` is unavailable in FFmpeg 5/6 (including the Docker base).
            // Keep the portable map; the served master gets its friendly label.
            "v:0,a:0,s:0,sgroup:subs",
        ]);
    } else {
        command.arg("-sn");
    }
    // Roku supports muxed HEVC/AVC + AAC in transport streams, but not muxed
    // audio/video CMAF. Annex-B changes framing only, preserving encoded video.
    command.args([
        "-bsf:v",
        if video_codec == "hevc" {
            "hevc_mp4toannexb"
        } else {
            "h264_mp4toannexb"
        },
        "-muxdelay",
        "0",
        "-muxpreload",
        "0",
    ]);
    command
        .args([
            "-f",
            "hls",
            "-master_pl_name",
            "master.m3u8",
            "-hls_time",
            "2",
            "-hls_segment_type",
            "mpegts",
            "-hls_list_size",
            "48",
            "-hls_delete_threshold",
            "12",
            "-hls_flags",
            "delete_segments+temp_file+independent_segments",
            "-start_number",
            "0",
            "-hls_segment_filename",
            "seg-%06d.ts",
            "index.m3u8",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_encoder_unavailable"))
}
#[cfg(unix)]
fn set_paused(child: &Child, paused: bool) -> bool {
    let Some(pid) = child.id() else {
        return false;
    };
    // PID belongs to our unreaped Child, so it cannot be reused by another process.
    unsafe {
        libc::kill(
            pid as libc::pid_t,
            if paused { libc::SIGSTOP } else { libc::SIGCONT },
        ) == 0
    }
}
#[cfg(not(unix))]
fn set_paused(_child: &Child, _paused: bool) -> bool {
    false
}
async fn run_worker(
    state: AudioState,
    session: Arc<Session>,
    mut child: Child,
    _permit: OwnedSemaphorePermit,
) {
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    let mut finished = false;
    let mut paused = false;
    loop {
        tokio::select! {
            _ = session.cancel.notified() => break,
            result = child.wait(), if !finished => {
                finished = true;
                *session.status.lock().unwrap() = if matches!(result, Ok(s) if s.success()) { "complete" } else { "failed" };
            }
            _ = tick.tick() => {
                if session.cancelled.load(Ordering::Acquire) || session.touched.lock().unwrap().elapsed() > IDLE || session.created.elapsed() > LIFETIME { break; }
                let (bytes, produced, oversized) = storage(&session.dir).await;
                if bytes > MAX_DISK || oversized { *session.status.lock().unwrap() = "failed"; break; }
                if !finished {
                    let lead = produced.saturating_sub(session.delivered.load(Ordering::Relaxed));
                    let should_pause = if paused { lead > 12 } else { lead > 20 };
                    if should_pause != paused {
                        if !set_paused(&child, should_pause) { *session.status.lock().unwrap() = "failed"; break; }
                        paused = should_pause;
                    }
                    if produced > 0 { *session.status.lock().unwrap() = if paused { "buffered" } else { "playing" }; }
                }
            }
        }
    }
    session.cancelled.store(true, Ordering::Release);
    if !finished {
        if paused {
            set_paused(&child, false);
        }
        let _ = child.kill().await;
    }
    state.sessions.lock().unwrap().remove(&session.id);
    let _ = tokio::fs::remove_dir_all(&session.dir).await;
    drop(_permit);
    session.stopped.store(true, Ordering::Release);
}
async fn storage(dir: &std::path::Path) -> (u64, u64, bool) {
    let mut bytes = 0;
    let mut produced = 0;
    let mut oversized = false;
    if let Ok(mut files) = tokio::fs::read_dir(dir).await {
        while let Ok(Some(file)) = files.next_entry().await {
            if let Ok(meta) = file.metadata().await {
                bytes += meta.len();
                oversized |= meta.len() > MAX_FILE;
            }
            if let Some(index) = segment_index(&file.file_name().to_string_lossy()) {
                produced = produced.max(index);
            }
        }
    }
    (bytes, produced, oversized)
}
fn segment_index(file: &str) -> Option<u64> {
    let digits = file.strip_prefix("seg-")?.strip_suffix(".ts")?;
    if digits.len() != 6 || !digits.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

// Copied Matroska video often has no per-track bit_rate, so ffmpeg's generated
// master may advertise only AAC's bitrate. Include the source estimate and the
// actual muxed fragment sizes without scanning or downloading more source data.
async fn master_bitrates(session: &Session) -> (u64, u64) {
    let mut peak = 0;
    let mut bytes = 0u64;
    let mut seconds = 0.0;
    if let Ok(file) = tokio::fs::File::open(session.dir.join("index.m3u8")).await {
        let mut playlist = String::new();
        if file
            .take(256 * 1024)
            .read_to_string(&mut playlist)
            .await
            .is_ok()
        {
            let mut duration = None;
            for line in playlist.lines() {
                if let Some(value) = line.strip_prefix("#EXTINF:") {
                    duration = number(value.split(',').next()).filter(|v| *v > 0.0 && *v <= 120.0);
                } else if !line.starts_with('#') && !line.is_empty() {
                    if let Some(length) = duration.take() {
                        if segment_index(line).is_some() {
                            if let Ok(meta) = tokio::fs::metadata(session.dir.join(line)).await {
                                if meta.len() > 0 && meta.len() <= MAX_FILE {
                                    peak =
                                        peak.max((meta.len() as f64 * 8.0 / length).ceil() as u64);
                                    bytes += meta.len();
                                    seconds += length;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    session.peak_bitrate.fetch_max(peak, Ordering::Relaxed);
    let average = if seconds > 0.0 {
        (bytes as f64 * 8.0 / seconds).ceil() as u64
    } else {
        session.source_bitrate
    };
    // A small margin covers unobserved peaks at startup. Never drop the estimate
    // after a large fragment rolls out of this session's bounded playlist.
    let bandwidth = session
        .source_bitrate
        .max(session.peak_bitrate.load(Ordering::Relaxed))
        .max(average)
        .saturating_mul(110)
        .div_ceil(100);
    (bandwidth, average)
}

fn rewrite_master_bitrates(text: &str, bandwidth: u64, average: u64) -> String {
    let mut output = String::with_capacity(text.len() + 64);
    for line in text.lines() {
        if let Some(attributes) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            output.push_str(&format!(
                "#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},AVERAGE-BANDWIDTH={average}"
            ));
            // A plain comma split corrupts quoted CODECS lists and track names.
            let mut quoted = false;
            let mut start = 0;
            for (index, ch) in attributes
                .char_indices()
                .chain(std::iter::once((attributes.len(), ',')))
            {
                if ch == '"' {
                    quoted = !quoted;
                }
                if ch == ',' && !quoted {
                    let field = attributes[start..index].trim();
                    if !field.is_empty()
                        && !field.starts_with("BANDWIDTH=")
                        && !field.starts_with("AVERAGE-BANDWIDTH=")
                    {
                        output.push(',');
                        output.push_str(field);
                    }
                    start = index + 1;
                }
            }
        } else if line.starts_with("#EXT-X-MEDIA:TYPE=SUBTITLES,") {
            output.push_str(&line.replacen(
                ",NAME=\"subtitle_0\",",
                ",NAME=\"Subtitles\",",
                1,
            ));
        } else {
            output.push_str(line);
        }
        output.push('\n');
    }
    output
}
fn valid_asset(file: &str) -> bool {
    matches!(file, "index.m3u8" | "master.m3u8" | "index_vtt.m3u8")
        || segment_index(file).is_some()
        || subtitle_segment(file)
}
fn subtitle_segment(file: &str) -> bool {
    file.strip_prefix("index")
        .and_then(|s| s.strip_suffix(".vtt"))
        .is_some_and(|digits| {
            !digits.is_empty() && digits.len() <= 6 && digits.bytes().all(|c| c.is_ascii_digit())
        })
}
async fn status(
    State(state): State<AudioState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>> {
    let session = state.session(&id)?;
    let mut value = serde_json::to_value(&session.metadata).unwrap();
    value["status"] = serde_json::json!(*session.status.lock().unwrap());
    Ok(Json(value))
}
async fn cancel(State(state): State<AudioState>, Path(id): Path<String>) -> Result<StatusCode> {
    if !hex_id(&id, 32) {
        return Err(AudioError(StatusCode::NOT_FOUND, "unknown_session"));
    }
    let session = state.sessions.lock().unwrap().get(&id).cloned();
    if let Some(session) = session {
        session.cancel();
        // Permit release completes before a replacement session is requested.
        let _ = tokio::time::timeout(Duration::from_secs(2), async {
            while !session.stopped.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
    }
    Ok(StatusCode::NO_CONTENT)
}
async fn asset(
    State(state): State<AudioState>,
    Path((id, name)): Path<(String, String)>,
    method: Method,
    headers: HeaderMap,
) -> Result<Response> {
    if !valid_asset(&name) {
        return Err(AudioError(StatusCode::NOT_FOUND, "unknown_asset"));
    }
    let session = state.session(&id)?;
    let permit = tokio::time::timeout(
        Duration::from_secs(2),
        state.readers.clone().acquire_owned(),
    )
    .await
    .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_busy"))?
    .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_busy"))?;
    if name.ends_with(".m3u8") {
        let file = tokio::fs::File::open(session.dir.join(&name))
            .await
            .map_err(|_| AudioError(StatusCode::NOT_FOUND, "fragment_not_ready"))?;
        let mut text = String::new();
        file.take(256 * 1024)
            .read_to_string(&mut text)
            .await
            .map_err(|_| AudioError(StatusCode::BAD_GATEWAY, "playlist_unavailable"))?;
        if name == "master.m3u8" {
            let (bandwidth, average) = master_bitrates(&session).await;
            if bandwidth == 0 {
                return Err(AudioError(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "fragment_not_ready",
                ));
            }
            text = rewrite_master_bitrates(&text, bandwidth, average);
        }
        let text = text.replacen(
            "#EXTM3U",
            "#EXTM3U\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES",
            1,
        );
        return Ok((
            [
                (header::CONTENT_TYPE, "application/vnd.apple.mpegurl"),
                (header::CACHE_CONTROL, "no-store"),
            ],
            if method == Method::HEAD {
                String::new()
            } else {
                text
            },
        )
            .into_response());
    }
    let mut file = tokio::fs::File::open(session.dir.join(&name))
        .await
        .map_err(|_| AudioError(StatusCode::NOT_FOUND, "fragment_expired"))?;
    let length = file
        .metadata()
        .await
        .map_err(|_| AudioError(StatusCode::NOT_FOUND, "fragment_expired"))?
        .len();
    if length == 0 || length > MAX_FILE {
        return Err(AudioError(StatusCode::BAD_GATEWAY, "fragment_invalid"));
    }
    let (start, end, partial) = range(
        headers.get(header::RANGE).and_then(|v| v.to_str().ok()),
        length,
    )?;
    file.seek(std::io::SeekFrom::Start(start))
        .await
        .map_err(|_| AudioError(StatusCode::BAD_GATEWAY, "fragment_unavailable"))?;
    if let Some(index) = segment_index(&name) {
        session.delivered.fetch_max(index, Ordering::Relaxed);
    }
    let body = if method == Method::HEAD {
        Body::empty()
    } else {
        Body::from_stream(futures::stream::try_unfold(
            (file, end - start + 1, permit),
            |(mut file, remaining, permit)| async move {
                if remaining == 0 {
                    return Ok::<_, std::io::Error>(None);
                }
                let mut buffer = vec![0; remaining.min(64 * 1024) as usize];
                let n = file.read(&mut buffer).await?;
                if n == 0 {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::UnexpectedEof,
                        "fragment ended early",
                    ));
                }
                buffer.truncate(n);
                Ok(Some((
                    bytes::Bytes::from(buffer),
                    (file, remaining - n as u64, permit),
                )))
            },
        ))
    };
    let mut builder = Response::builder()
        .status(if partial {
            StatusCode::PARTIAL_CONTENT
        } else {
            StatusCode::OK
        })
        .header(
            header::CONTENT_TYPE,
            if name.ends_with(".vtt") {
                "text/vtt; charset=utf-8"
            } else {
                "video/mp2t"
            },
        )
        .header(header::CONTENT_LENGTH, end - start + 1)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "private, max-age=3600");
    if partial {
        builder = builder.header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{length}"),
        );
    }
    Ok(builder.body(body).unwrap())
}
fn range(value: Option<&str>, length: u64) -> Result<(u64, u64, bool)> {
    let Some(value) = value else {
        return Ok((0, length - 1, false));
    };
    let bad = || AudioError(StatusCode::RANGE_NOT_SATISFIABLE, "invalid_range");
    let range = value.strip_prefix("bytes=").ok_or_else(bad)?;
    if range.contains(',') {
        return Err(bad());
    }
    let (first, last) = range.split_once('-').ok_or_else(bad)?;
    let (start, end) = if first.is_empty() {
        let suffix: u64 = last.parse().map_err(|_| bad())?;
        if suffix == 0 {
            return Err(bad());
        }
        (length.saturating_sub(suffix), length - 1)
    } else {
        (
            first.parse::<u64>().map_err(|_| bad())?,
            if last.is_empty() {
                length - 1
            } else {
                last.parse::<u64>().map_err(|_| bad())?.min(length - 1)
            },
        )
    };
    if start >= length || end < start {
        return Err(bad());
    }
    Ok((start, end, true))
}
async fn reap_orphans(root: PathBuf) {
    let Ok(mut entries) = tokio::fs::read_dir(root).await else {
        return;
    };
    while let Ok(Some(entry)) = entries.next_entry().await {
        if !hex_id(&entry.file_name().to_string_lossy(), 32) {
            continue;
        }
        let Ok(meta) = entry.metadata().await else {
            continue;
        };
        if !meta.is_dir()
            || meta
                .modified()
                .ok()
                .and_then(|m| m.elapsed().ok())
                .is_none_or(|age| age < LIFETIME)
        {
            continue;
        }
        let _ = tokio::fs::remove_dir_all(entry.path()).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn origins_are_loopback_only() {
        for value in ["http://127.0.0.1:8799", "http://[::1]:8799/"] {
            assert!(validate_origin(value).is_ok());
        }
        for value in [
            "https://127.0.0.1",
            "http://localhost",
            "http://192.0.2.1",
            "http://example.com",
            "http://u@127.0.0.1",
            "http://127.0.0.1/path",
            "http://127.0.0.1/?url=x",
        ] {
            assert!(validate_origin(value).is_err(), "{value}");
        }
    }
    #[test]
    fn paths_are_closed() {
        assert!(hex_id("0123456789abcdef", 16));
        for value in [
            "../abcd",
            "ABCDEF0123456789",
            "0123456789abcdef/",
            "https://host/file",
        ] {
            assert!(!hex_id(value, 16));
        }
        for value in ["index.m3u8", "master.m3u8", "seg-000012.ts"] {
            assert!(valid_asset(value));
        }
        for value in [
            "../seg-000000.ts",
            "init.mp4",
            "seg-000000.m4s",
            "seg-1.ts",
            "seg-000001.ts.tmp",
            "/etc/passwd",
            "index.m3u8?url=other",
        ] {
            assert!(!valid_asset(value));
        }
    }
    #[test]
    fn keyframe_reports_real_source_origin() {
        let data = b"#tb 0: 1/1000\n0, 11917, 12000, 41, 3090, 0xc6fcff3a\n";
        assert_eq!(parse_keyframe(data, 15.0, 2.0).unwrap(), 10.0);
        assert!(parse_keyframe(data, 10.0, 0.0).is_err());
        assert!(parse_keyframe(b"#tb 0: 1/0\n0, 0, 0, 1, 1, 0\n", 1.0, 0.0).is_err());
    }
    #[test]
    fn track_indices_and_codec_are_preserved() {
        let data=br#"{"format":{"duration":"120.5","start_time":"1.4","bit_rate":"80000000"},"streams":[{"index":0,"codec_type":"video","codec_name":"hevc"},{"index":3,"codec_type":"audio","codec_name":"truehd","channels":8,"tags":{"language":"eng"}}]}"#;
        let metadata = parse_metadata(data).unwrap();
        assert_eq!(metadata.duration_ms, 120500);
        assert_eq!(metadata.audio_tracks[0].index, 3);
        assert_eq!(metadata.video_codec, "hevc");
        assert_eq!(metadata.source_bitrate, 80_000_000);
        let size_fallback = parse_metadata(br#"{"format":{"duration":"10","size":"1000000","bit_rate":"N/A"},"streams":[{"index":0,"codec_type":"video","codec_name":"h264"}]}"#).unwrap();
        assert_eq!(size_fallback.source_bitrate, 800_000);
        assert!(parse_metadata(br#"{"format":{"duration":"NaN"},"streams":[]}"#).is_err());
    }
    #[test]
    fn subtitle_metadata_excludes_image_tracks_and_asset_paths_are_closed() {
        let parsed=parse_metadata(br#"{"format":{"duration":"12"},"streams":[{"index":0,"codec_type":"video","codec_name":"h264"},{"index":2,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng","title":"English SDH"}},{"index":3,"codec_type":"subtitle","codec_name":"hdmv_pgs_subtitle"}]}"#).unwrap();
        assert_eq!(parsed.subtitle_tracks.len(), 1);
        assert_eq!(parsed.subtitle_tracks[0].index, 2);
        for name in [
            "master.m3u8",
            "index_vtt.m3u8",
            "index0.vtt",
            "index123.vtt",
        ] {
            assert!(valid_asset(name));
        }
        for name in [
            "index.vtt",
            "index../0.vtt",
            "index1.vtt.tmp",
            "index-1.vtt",
        ] {
            assert!(!valid_asset(name));
        }
    }
    #[test]
    fn ranges_are_bounded() {
        assert_eq!(range(Some("bytes=2-5"), 10).unwrap(), (2, 5, true));
        assert_eq!(range(Some("bytes=-3"), 10).unwrap(), (7, 9, true));
        assert!(range(Some("bytes=12-"), 10).is_err());
        assert!(range(Some("bytes=0-1,3-4"), 10).is_err());
    }
    #[test]
    fn strict_start_body() {
        assert!(serde_json::from_str::<StartRequest>(
            r#"{"positionMs":0,"url":"http://example.com"}"#
        )
        .is_err());
        assert!(serde_json::from_str::<StartRequest>(r#"{"positionMs":-1}"#).is_err());
    }
    #[tokio::test]
    async fn cancellation_wakes_waiter() {
        let id = "0".repeat(32);
        let session = Session {
            id: id.clone(),
            dir: PathBuf::new(),
            created: Instant::now(),
            touched: Mutex::new(Instant::now()),
            cancelled: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            cancel: Notify::new(),
            delivered: AtomicU64::new(0),
            source_bitrate: 0,
            peak_bitrate: AtomicU64::new(0),
            status: Mutex::new("starting"),
            metadata: SessionInfo {
                session_id: id,
                playback_path: String::new(),
                source_offset_ms: 0,
                requested_position_ms: 0,
                duration_ms: 1000,
                audio_track: 1,
                audio_tracks: vec![],
                subtitle_track: None,
                subtitle_tracks: vec![],
                video_codec: "h264".into(),
            },
        };
        session.cancel();
        assert!(session.cancelled.load(Ordering::Acquire));
        assert!(
            tokio::time::timeout(Duration::from_millis(10), session.cancel.notified())
                .await
                .is_ok()
        );
    }
    fn fixture() -> (AudioState, Arc<Session>) {
        let db = crate::db::open(":memory:").unwrap();
        crate::sync::migrate(&db.lock().unwrap()).unwrap();
        let id = random_id().unwrap();
        let root = std::env::temp_dir().join(format!("roku-audio-test-{id}"));
        std::fs::create_dir(&root).unwrap();
        let session = Arc::new(Session {
            id: id.clone(),
            dir: root.clone(),
            created: Instant::now(),
            touched: Mutex::new(Instant::now()),
            cancelled: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            cancel: Notify::new(),
            delivered: AtomicU64::new(0),
            source_bitrate: 1_000_000,
            peak_bitrate: AtomicU64::new(0),
            status: Mutex::new("starting"),
            metadata: SessionInfo {
                session_id: id.clone(),
                playback_path: String::new(),
                source_offset_ms: 0,
                requested_position_ms: 0,
                duration_ms: 1000,
                audio_track: 1,
                audio_tracks: vec![],
                subtitle_track: None,
                subtitle_tracks: vec![],
                video_codec: "h264".into(),
            },
        });
        let state = AudioState {
            streams: crate::stream::StreamState::new(
                crate::pool::Pool::new(&[]),
                reqwest::Client::new(),
                db,
            ),
            source_base: "http://127.0.0.1:8799".into(),
            root,
            sessions: Arc::new(Mutex::new(HashMap::from([(id, session.clone())]))),
            slots: Arc::new(Semaphore::new(2)),
            readers: Arc::new(Semaphore::new(8)),
        };
        (state, session)
    }
    #[tokio::test]
    async fn master_bandwidth_uses_source_and_fragment_video_rates_without_losing_attributes() {
        let (_state, session) = fixture();
        std::fs::write(
            session.dir.join("index.m3u8"),
            "#EXTM3U\n#EXTINF:2.0,\nseg-000000.ts\n",
        )
        .unwrap();
        std::fs::write(session.dir.join("seg-000000.ts"), vec![0u8; 10_000]).unwrap();
        assert_eq!(master_bitrates(&session).await, (1_100_000, 40_000));
        std::fs::write(session.dir.join("seg-000000.ts"), vec![0u8; 3_000_000]).unwrap();
        assert_eq!(master_bitrates(&session).await, (13_200_000, 12_000_000));
        let original = "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME=\"English, SDH\",GROUP-ID=\"subs\",URI=\"index_vtt.m3u8\"\n#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=128000,CODECS=\"hvc1.2.4.L153.B0,mp4a.40.2\",BANDWIDTH=211200,RESOLUTION=3840x2160,SUBTITLES=\"subs\"\nindex.m3u8\n";
        let rewritten = rewrite_master_bitrates(original, 13_200_000, 12_000_000);
        assert!(rewritten.contains("BANDWIDTH=13200000,AVERAGE-BANDWIDTH=12000000"));
        assert!(rewritten.contains("CODECS=\"hvc1.2.4.L153.B0,mp4a.40.2\""));
        assert!(rewritten.contains("NAME=\"English, SDH\""));
        assert!(rewritten.contains("RESOLUTION=3840x2160,SUBTITLES=\"subs\""));
        assert!(!rewritten.contains("211200") && !rewritten.contains("128000"));
        std::fs::write(session.dir.join("seg-000000.ts"), vec![0u8; 10_000]).unwrap();
        assert_eq!(
            master_bitrates(&session).await.0,
            13_200_000,
            "rolling out a peak must not shrink the advertised requirement"
        );
        std::fs::remove_dir_all(&session.dir).unwrap();
    }
    #[tokio::test]
    async fn only_registered_streams_become_inputs() {
        let (state, session) = fixture();
        assert!(state.source("0000000000000000").is_err());
        assert!(state.source("http://example.com/input").is_err());
        let sid = state
            .streams
            .register("https://unreachable.invalid/source.nzb")
            .await;
        assert_eq!(
            state.source(&sid).unwrap(),
            format!("http://127.0.0.1:8799/stream/{sid}")
        );
        std::fs::remove_dir_all(&session.dir).unwrap();
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn cancellation_reaps_child_removes_files_and_releases_slot() {
        let (state, session) = fixture();
        std::fs::write(session.dir.join("seg-000000.ts"), b"fixture").unwrap();
        let permit = state.slots.clone().acquire_owned().await.unwrap();
        let child = Command::new("sleep")
            .arg("60")
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        session.cancel();
        tokio::time::timeout(
            Duration::from_secs(2),
            run_worker(state.clone(), session.clone(), child, permit),
        )
        .await
        .unwrap();
        assert!(session.stopped.load(Ordering::Acquire));
        assert!(!session.dir.exists());
        assert!(!state.sessions.lock().unwrap().contains_key(&session.id));
        assert_eq!(state.slots.available_permits(), 2);
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn idle_worker_is_reaped_without_another_http_request() {
        let (state, session) = fixture();
        *session.touched.lock().unwrap() = Instant::now() - IDLE - Duration::from_secs(1);
        let permit = state.slots.clone().acquire_owned().await.unwrap();
        let child = Command::new("sleep")
            .arg("60")
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        tokio::time::timeout(
            Duration::from_secs(2),
            run_worker(state.clone(), session.clone(), child, permit),
        )
        .await
        .unwrap();
        assert!(session.stopped.load(Ordering::Acquire));
        assert!(!session.dir.exists());
        assert_eq!(state.slots.available_permits(), 2);
    }
    struct Running(tokio::task::JoinHandle<()>);
    impl Drop for Running {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    async fn serve_test(app: Router) -> (String, Running) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (base, Running(task))
    }
    #[tokio::test]
    async fn native_hls_http_session_preserves_video_subtitles_ranges_and_cleanup() {
        verify_native_hls_session("libx264", "h264").await;
        verify_native_hls_session("libx265", "hevc").await;
    }
    async fn verify_native_hls_session(encoder: &str, codec: &str) {
        let (mut state, seed) = fixture();
        state.sessions.lock().unwrap().clear();
        let original = state.root.join("original.mkv");
        let subtitles = state.root.join("captions.srt");
        std::fs::write(&subtitles,"1\n00:00:04,200 --> 00:00:06,000\nFirst caption\n\n2\n00:00:07,000 --> 00:00:10,000\nSecond caption\n").unwrap();
        let mut generator = Command::new("ffmpeg");
        generator
            .args([
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=160x90:rate=24",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=48000",
                "-i",
            ])
            .arg(&subtitles)
            .args([
                "-map",
                "0:v",
                "-map",
                "1:a",
                "-map",
                "2:0",
                "-t",
                "16",
                "-c:v",
                encoder,
                "-preset",
                "ultrafast",
                "-g",
                "48",
                "-keyint_min",
                "48",
                "-sc_threshold",
                "0",
                "-c:a",
                "truehd",
                "-strict",
                "-2",
                "-c:s",
                "srt",
                "-y",
            ]);
        if codec == "hevc" {
            generator.args([
                "-pix_fmt",
                "yuv420p10le",
                "-color_primaries",
                "bt2020",
                "-color_trc",
                "smpte2084",
                "-colorspace",
                "bt2020nc",
                "-x265-params",
                "pools=1:frame-threads=1:keyint=48:min-keyint=48:scenecut=0:colorprim=9:transfer=16:colormatrix=9",
            ]);
        }
        let generated = generator.arg(&original).output().await.unwrap();
        assert!(
            generated.status.success(),
            "{}",
            String::from_utf8_lossy(&generated.stderr)
        );
        let bytes = Arc::new(std::fs::read(&original).unwrap());
        let source_queries = Arc::new(Mutex::new(Vec::<String>::new()));
        let queries = source_queries.clone();
        let source = Router::new().route(
            "/stream/:sid",
            get(move |axum::extract::OriginalUri(uri): axum::extract::OriginalUri, headers: HeaderMap| {
                let bytes = bytes.clone();
                let queries = queries.clone();
                async move {
                    queries.lock().unwrap().push(uri.query().unwrap_or("").to_owned());
                    let n = bytes.len() as u64;
                    let (start, end, partial) =
                        range(headers.get(header::RANGE).and_then(|v| v.to_str().ok()), n).unwrap();
                    let mut response = Response::builder()
                        .status(if partial { 206 } else { 200 })
                        .header(header::CONTENT_TYPE, "video/x-matroska")
                        .header(header::CONTENT_LENGTH, end - start + 1)
                        .header(header::ACCEPT_RANGES, "bytes");
                    if partial {
                        response = response
                            .header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{n}"));
                    }
                    response
                        .body(Body::from(bytes[start as usize..=end as usize].to_vec()))
                        .unwrap()
                }
            }),
        );
        let (origin, _source) = serve_test(source).await;
        state.source_base = origin;
        let sid = state
            .streams
            .register("https://fixture.invalid/exact-release.nzb")
            .await;
        let app = Router::new()
            .route("/stream/:sid/roku/session", post(start))
            .route("/roku/audio/:id", get(status).delete(cancel))
            .route("/roku/audio/:id/:file", get(asset))
            .with_state(state.clone());
        let (base, _server) = serve_test(app).await;
        let client = reqwest::Client::new();
        let response = client
            .post(format!("{base}/stream/{sid}/roku/session"))
            .json(&serde_json::json!({"positionMs":5300,"audioTrack":1,"subtitleTrack":2,"playbackSessionId":"roku-watch-1"}))
            .send()
            .await
            .unwrap();
        let code = response.status();
        let info: serde_json::Value = response.json().await.unwrap();
        assert_eq!(code, StatusCode::OK, "{info}");
        {
            let queries = source_queries.lock().unwrap();
            assert!(queries.iter().any(String::is_empty), "metadata and keyframe probes remain unassociated");
            assert!(queries.iter().any(|q| q == "playbackSessionId=roku-watch-1"), "actual encoder reads carry the explicit watch");
            assert!(queries.iter().all(|q| q.is_empty() || q == "playbackSessionId=roku-watch-1"));
        }
        assert_eq!(info["sourceOffsetMs"], 4000);
        assert_eq!(info["durationMs"], 16000);
        assert_eq!(info["subtitleTracks"][0]["index"], 2);
        assert!(info["playbackPath"]
            .as_str()
            .unwrap()
            .ends_with("/master.m3u8"));
        let id = info["sessionId"].as_str().unwrap();
        let master = client
            .get(format!("{base}{}", info["playbackPath"].as_str().unwrap()))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(master.contains("TYPE=SUBTITLES"));
        assert!(master.contains("NAME=\"Subtitles\""));
        let advertised = master
            .split("BANDWIDTH=")
            .nth(1)
            .unwrap()
            .split(',')
            .next()
            .unwrap()
            .parse::<u64>()
            .unwrap();
        assert!(advertised >= std::fs::metadata(&original).unwrap().len() * 8 / 16);
        assert!(
            advertised > 192_000,
            "master includes copied video, not only AAC"
        );
        let playlist = client
            .get(format!("{base}/roku/audio/{id}/index.m3u8"))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(playlist.contains("#EXT-X-START:TIME-OFFSET=0"));
        assert!(
            !playlist.contains("#EXT-X-MAP"),
            "TS segments need no CMAF initialization asset"
        );
        let segment_response = client
            .get(format!("{base}/roku/audio/{id}/seg-000000.ts"))
            .send()
            .await
            .unwrap();
        assert_eq!(
            segment_response.headers()[header::CONTENT_TYPE],
            "video/mp2t"
        );
        let segment = segment_response.bytes().await.unwrap();
        assert_eq!(
            segment.len() % 188,
            0,
            "transport stream has complete packets"
        );
        assert!(segment.chunks(188).all(|packet| packet[0] == 0x47));
        let joined = state.root.join("converted.ts");
        std::fs::write(&joined, &segment).unwrap();
        let decoded = Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-show_entries",
                "format=start_time:stream=codec_name,codec_type,channels,start_time,color_primaries,color_transfer,color_space",
                "-of",
                "json",
            ])
            .arg(&joined)
            .output()
            .await
            .unwrap();
        assert!(decoded.status.success());
        let decoded: serde_json::Value = serde_json::from_slice(&decoded.stdout).unwrap();
        let tracks = decoded["streams"].as_array().unwrap();
        let video = tracks.iter().find(|s| s["codec_name"] == codec).unwrap();
        let media_start = decoded["format"]["start_time"]
            .as_str()
            .unwrap()
            .parse::<f64>()
            .unwrap();
        assert!(
            media_start.abs() < 0.25,
            "no MPEG-TS mux delay in source clock: {media_start}"
        );
        let video_start = video["start_time"]
            .as_str()
            .unwrap()
            .parse::<f64>()
            .unwrap();
        assert!(
            (video_start - media_start).abs() < 0.05,
            "only AAC priming precedes first video frame, not source seek preroll"
        );
        if codec == "hevc" {
            assert_eq!(video["color_primaries"], "bt2020");
            assert_eq!(video["color_transfer"], "smpte2084");
            assert_eq!(video["color_space"], "bt2020nc");
        }
        assert!(tracks
            .iter()
            .any(|s| s["codec_name"] == "aac" && s["channels"] == 2));
        // AVC/HEVC packets change only container framing (AVCC/HVCC to Annex-B).
        // Decoded frame hashes verify their actual pixels remain identical.
        let source_frames = frame_hashes(&original, Some("4")).await;
        let converted_frames = frame_hashes(&joined, None).await;
        assert_eq!(source_frames.len(), 24);
        assert_eq!(
            source_frames, converted_frames,
            "{codec} video is copied without re-encoding"
        );
        let captions = client
            .get(format!("{base}/roku/audio/{id}/index0.vtt"))
            .send()
            .await
            .unwrap();
        assert_eq!(
            captions.headers()[header::CONTENT_TYPE],
            "text/vtt; charset=utf-8"
        );
        assert!(captions.text().await.unwrap().contains("First caption"));
        let part = client
            .get(format!("{base}/roku/audio/{id}/seg-000000.ts"))
            .header(header::RANGE, "bytes=0-15")
            .send()
            .await
            .unwrap();
        assert_eq!(part.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(part.bytes().await.unwrap().len(), 16);
        assert_eq!(
            client
                .delete(format!("{base}/roku/audio/{id}"))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        assert!(!state.sessions.lock().unwrap().contains_key(id));
        assert!(!state.root.join(id).exists());
        assert_eq!(state.slots.available_permits(), 2);
        assert_eq!(
            client
                .get(format!("{base}/roku/audio/{id}"))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::NOT_FOUND
        );
        let plain: serde_json::Value = client
            .post(format!("{base}/stream/{sid}/roku/session"))
            .json(&serde_json::json!({"positionMs":0,"audioTrack":1}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert!(plain["playbackPath"]
            .as_str()
            .unwrap()
            .ends_with("/master.m3u8"));
        let plain_master = client
            .get(format!("{base}{}", plain["playbackPath"].as_str().unwrap()))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(plain_master.contains("#EXT-X-STREAM-INF:BANDWIDTH="));
        assert!(!plain_master.contains("TYPE=SUBTITLES"));
        let plain_bandwidth = plain_master
            .split("BANDWIDTH=")
            .nth(1)
            .unwrap()
            .split(',')
            .next()
            .unwrap()
            .parse::<u64>()
            .unwrap();
        assert!(plain_bandwidth >= std::fs::metadata(&original).unwrap().len() * 8 / 16);
        assert_eq!(
            client
                .delete(format!(
                    "{base}/roku/audio/{}",
                    plain["sessionId"].as_str().unwrap()
                ))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(state.slots.available_permits(), 2);
        std::fs::remove_dir_all(&seed.dir).unwrap();
    }
    async fn frame_hashes(path: &std::path::Path, seek: Option<&str>) -> Vec<String> {
        let mut command = Command::new("ffmpeg");
        command.args(["-v", "error"]);
        if let Some(seek) = seek {
            command.args(["-ss", seek]);
        }
        let result = command
            .arg("-i")
            .arg(path)
            .args(["-map", "0:v:0", "-frames:v", "24", "-f", "framemd5", "-"])
            .output()
            .await
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        String::from_utf8_lossy(&result.stdout)
            .lines()
            .filter(|line| !line.starts_with('#') && !line.trim().is_empty())
            .map(|line| line.rsplit(',').next().unwrap().trim().to_owned())
            .collect()
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn lookahead_pauses_and_resumes_worker_without_losing_cleanup() {
        let (state, session) = fixture();
        std::fs::write(session.dir.join("seg-000021.ts"), b"fixture").unwrap();
        let permit = state.slots.clone().acquire_owned().await.unwrap();
        let child = Command::new("sleep")
            .arg("60")
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let worker = tokio::spawn(run_worker(state.clone(), session.clone(), child, permit));
        tokio::time::timeout(Duration::from_secs(3), async {
            while *session.status.lock().unwrap() != "buffered" {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
        session.delivered.store(16, Ordering::Relaxed);
        tokio::time::timeout(Duration::from_secs(3), async {
            while *session.status.lock().unwrap() != "playing" {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
        session.cancel();
        tokio::time::timeout(Duration::from_secs(2), worker)
            .await
            .unwrap()
            .unwrap();
        assert!(!session.dir.exists());
        assert_eq!(state.slots.available_permits(), 2);
    }
}
