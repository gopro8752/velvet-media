//! Seekable audio compatibility for mobile players missing a source decoder.
//! Video continues to use the original range URL. VLC attaches this PCM WAV as
//! an audio slave, so its native clock, seeking, and exact-stream identity stay
//! intact. Only registered sources can be decoded; callers never supply URLs.

use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, Method, StatusCode},
    response::{IntoResponse, Response},
    Json, Router,
};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    io,
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, BufReader},
    process::{Child, ChildStdout, Command},
    sync::{OnceCell, OwnedSemaphorePermit, Semaphore},
};

const RATE: u64 = 48_000;
const FRAME_BYTES: u64 = 4; // signed 16-bit PCM, stereo
const CACHE_LIMIT: usize = 128;
const CACHE_TTL: Duration = Duration::from_secs(6 * 60 * 60);
const IO_TIMEOUT: Duration = Duration::from_secs(30);
const PROBE_LIMIT: u64 = 128 * 1024;
const MAX_DURATION_SECONDS: f64 = 24.0 * 60.0 * 60.0;

#[derive(Clone)]
struct AudioState {
    streams: crate::stream::StreamState,
    source_base: String,
    metadata: Arc<Mutex<HashMap<String, CachedMetadata>>>,
    probe_slots: Arc<Semaphore>,
    audio_slots: Arc<Semaphore>,
}
struct CachedMetadata {
    at: Instant,
    value: Arc<OnceCell<Arc<AudioMetadata>>>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AudioMetadata {
    duration_ms: u64,
    audio_tracks: Vec<AudioTrack>,
    subtitle_tracks: Vec<SubtitleTrack>,
}
#[derive(Clone, Debug, Serialize)]
struct SubtitleTrack {
    index: u32,
    codec: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
}
#[derive(Clone, Debug, Serialize)]
struct AudioTrack {
    index: u32,
    codec: String,
    channels: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip)]
    samples: u64,
}
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
}
#[derive(Deserialize)]
struct ProbeTrack {
    index: u32,
    codec_type: Option<String>,
    codec_name: Option<String>,
    channels: Option<u32>,
    duration: Option<String>,
    start_time: Option<String>,
    #[serde(default)]
    tags: HashMap<String, String>,
}

#[derive(Debug)]
struct AudioError(StatusCode, &'static str);
impl IntoResponse for AudioError {
    fn into_response(self) -> Response {
        (
            self.0,
            [(header::CACHE_CONTROL, "no-store")],
            Json(serde_json::json!({"error": self.1})),
        )
            .into_response()
    }
}
type AudioResult<T> = Result<T, AudioError>;

/// `source_base` comes from server configuration, never an HTTP request. The
/// loopback restriction also guards against accidental public-origin fetching.
pub fn router(streams: crate::stream::StreamState, source_base: String) -> anyhow::Result<Router> {
    let base = reqwest::Url::parse(&source_base)?;
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
        "audio source must be a server-owned loopback origin"
    );
    let state = AudioState {
        streams,
        source_base: source_base.trim_end_matches('/').to_owned(),
        metadata: Arc::new(Mutex::new(HashMap::new())),
        probe_slots: Arc::new(Semaphore::new(2)),
        audio_slots: Arc::new(Semaphore::new(4)),
    };
    Ok(Router::new()
        .route("/stream/:sid/audio", axum::routing::get(metadata))
        .route("/stream/:sid/audio/:track", axum::routing::get(wave))
        .with_state(state))
}

impl AudioState {
    fn source_url(&self, sid: &str) -> AudioResult<String> {
        if !self.streams.is_registered(sid) {
            return Err(AudioError(StatusCode::NOT_FOUND, "unknown_stream"));
        }
        Ok(format!("{}/stream/{sid}", self.source_base))
    }

    async fn get_metadata(&self, sid: &str) -> AudioResult<Arc<AudioMetadata>> {
        let source = self.source_url(sid)?;
        let cell = {
            let mut cache = self.metadata.lock().unwrap();
            cache.retain(|_, entry| entry.at.elapsed() < CACHE_TTL);
            if !cache.contains_key(sid) && cache.len() >= CACHE_LIMIT {
                if let Some(oldest) = cache
                    .iter()
                    .min_by_key(|(_, value)| value.at)
                    .map(|(key, _)| key.clone())
                {
                    cache.remove(&oldest);
                }
            }
            cache
                .entry(sid.to_owned())
                .or_insert_with(|| CachedMetadata {
                    at: Instant::now(),
                    value: Arc::new(OnceCell::new()),
                })
                .value
                .clone()
        };
        cell.get_or_try_init(|| async {
            let _slot = acquire(self.probe_slots.clone()).await?;
            probe(&source).await.map(Arc::new)
        })
        .await
        .cloned()
    }
}

async fn acquire(slots: Arc<Semaphore>) -> AudioResult<OwnedSemaphorePermit> {
    tokio::time::timeout(Duration::from_secs(2), slots.acquire_owned())
        .await
        .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_busy"))?
        .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_busy"))
}

async fn probe(source: &str) -> AudioResult<AudioMetadata> {
    let mut child = Command::new("ffprobe")
        .args(["-v", "error", "-rw_timeout", "30000000", "-protocol_whitelist", "http,tcp", "-probesize", "5000000", "-analyzeduration", "5000000",
            "-show_entries", "format=duration,start_time:stream=index,codec_type,codec_name,channels,duration,start_time:stream_tags=language,title,DURATION", "-of", "json", source])
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true).spawn()
        .map_err(|_| AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_probe_unavailable"))?;
    let mut output = Vec::new();
    let stdout = child.stdout.take().unwrap();
    let read = tokio::time::timeout(
        IO_TIMEOUT,
        stdout.take(PROBE_LIMIT + 1).read_to_end(&mut output),
    )
    .await;
    if !matches!(read, Ok(Ok(_))) || output.len() as u64 > PROBE_LIMIT {
        return Err(AudioError(StatusCode::BAD_GATEWAY, "audio_probe_failed"));
    }
    let status = tokio::time::timeout(IO_TIMEOUT, child.wait()).await;
    if !matches!(status, Ok(Ok(status)) if status.success()) {
        return Err(AudioError(StatusCode::BAD_GATEWAY, "audio_probe_failed"));
    }
    parse_metadata(&output)
}

fn parse_metadata(output: &[u8]) -> AudioResult<AudioMetadata> {
    let parsed: Probe = serde_json::from_slice(output)
        .map_err(|_| AudioError(StatusCode::BAD_GATEWAY, "audio_probe_failed"))?;
    let seconds = parsed
        .format
        .duration
        .as_deref()
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|n| n.is_finite() && *n > 0.0 && *n <= MAX_DURATION_SECONDS)
        .ok_or(AudioError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "audio_duration_unavailable",
        ))?;
    let source_start = parsed
        .format
        .start_time
        .as_deref()
        .and_then(finite_timestamp)
        .unwrap_or(0.0);
    // Additive metadata for native Roku compatibility. The existing PCM/WAV
    // audio track selection, timing, samples and range responses are unchanged.
    let subtitle_tracks = parsed.streams.iter()
        .filter(|s| s.codec_type.as_deref() == Some("subtitle") && matches!(s.codec_name.as_deref(),
            Some("subrip" | "srt" | "ass" | "ssa" | "webvtt" | "mov_text" | "text")))
        .map(|s| SubtitleTrack {
            index: s.index,
            codec: s.codec_name.clone().unwrap_or_default(),
            language: s.tags.get("language").map(|s| s.chars().take(32).collect()),
            title: s.tags.get("title").map(|s| s.chars().take(256).collect()),
        }).collect();
    let audio_tracks = parsed
        .streams
        .into_iter()
        .filter(|s| s.codec_type.as_deref() == Some("audio"))
        .map(|s| AudioTrack {
            index: s.index,
            codec: s.codec_name.clone().unwrap_or_default(),
            channels: s.channels.unwrap_or(0),
            language: s.tags.get("language").map(|s| s.chars().take(32).collect()),
            title: s.tags.get("title").map(|s| s.chars().take(256).collect()),
            samples: track_samples(&s, seconds, source_start),
        })
        .collect();
    Ok(AudioMetadata {
        duration_ms: (seconds * 1000.0).round() as u64,
        audio_tracks,
        subtitle_tracks,
    })
}

fn finite_seconds(value: &str) -> Option<f64> {
    value
        .parse::<f64>()
        .ok()
        .filter(|n| n.is_finite() && *n >= 0.0 && *n <= MAX_DURATION_SECONDS)
}

fn finite_timestamp(value: &str) -> Option<f64> {
    value
        .parse::<f64>()
        .ok()
        .filter(|n| n.is_finite() && n.abs() <= MAX_DURATION_SECONDS)
}

fn track_samples(track: &ProbeTrack, format_seconds: f64, source_start: f64) -> u64 {
    let duration = track
        .duration
        .as_deref()
        .and_then(finite_seconds)
        .map(|duration| {
            duration
                + track
                    .start_time
                    .as_deref()
                    .and_then(finite_timestamp)
                    .unwrap_or(source_start)
        })
        .or_else(|| {
            let mut parts = track.tags.get("DURATION")?.split(':');
            let hours = finite_seconds(parts.next()?)?;
            let minutes = finite_seconds(parts.next()?)?;
            let seconds = finite_seconds(parts.next()?)?;
            if parts.next().is_some() || minutes >= 60.0 || seconds >= 60.0 {
                return None;
            }
            Some(hours * 3600.0 + minutes * 60.0 + seconds)
        })
        // FFmpeg's default input clock starts at the container start timestamp.
        // Stream duration is a span; Matroska DURATION is an absolute end time.
        // Normalize only the track end, never format.duration (container spans
        // and end timestamps have different conventions across demuxers).
        .map(|end| end - source_start)
        .filter(|n| *n > 0.0 && *n <= format_seconds + 1.0)
        .unwrap_or(format_seconds);
    (duration * RATE as f64).round() as u64
}

async fn metadata(
    State(state): State<AudioState>,
    Path(sid): Path<String>,
) -> AudioResult<Response> {
    let value = state.get_metadata(&sid).await?;
    Ok((
        [(header::CACHE_CONTROL, "private, max-age=3600")],
        Json(value.as_ref()),
    )
        .into_response())
}

/// Standard RIFF below 4GiB, RF64 above it. The virtual length stays fixed for
/// every range request; no unknown-length WAV header from an FFmpeg pipe.
fn wav_header(samples: u64) -> Vec<u8> {
    let data_size = samples * FRAME_BYTES;
    let mut out = Vec::with_capacity(80);
    if data_size + 36 <= u32::MAX as u64 {
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&((data_size + 36) as u32).to_le_bytes());
        out.extend_from_slice(b"WAVE");
    } else {
        out.extend_from_slice(b"RF64\xff\xff\xff\xffWAVEds64");
        out.extend_from_slice(&28u32.to_le_bytes());
        out.extend_from_slice(&(data_size + 72).to_le_bytes());
        out.extend_from_slice(&data_size.to_le_bytes());
        out.extend_from_slice(&samples.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
    }
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&(RATE as u32).to_le_bytes());
    out.extend_from_slice(&((RATE * FRAME_BYTES) as u32).to_le_bytes());
    out.extend_from_slice(&(FRAME_BYTES as u16).to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(
        &(if data_size + 36 <= u32::MAX as u64 {
            data_size as u32
        } else {
            u32::MAX
        })
        .to_le_bytes(),
    );
    out
}

fn byte_range(headers: &HeaderMap, total: u64) -> Option<(u64, u64, bool)> {
    let Some(value) = headers.get(header::RANGE) else {
        return Some((0, total - 1, false));
    };
    let range = value.to_str().ok()?.strip_prefix("bytes=")?;
    if range.contains(',') {
        return None;
    }
    let (a, b) = range.split_once('-')?;
    if a.is_empty() {
        let suffix = b.parse::<u64>().ok()?;
        if suffix == 0 {
            return None;
        }
        return Some((total.saturating_sub(suffix), total - 1, true));
    }
    let start = a.parse::<u64>().ok()?;
    let end = if b.is_empty() {
        total - 1
    } else {
        b.parse::<u64>().ok()?.min(total - 1)
    };
    (start < total && start <= end).then_some((start, end, true))
}

async fn wave(
    State(state): State<AudioState>,
    Path((sid, track)): Path<(String, String)>,
    axum::extract::Query(query): axum::extract::Query<crate::stream::PlaybackSessionQuery>,
    method: Method,
    headers: HeaderMap,
) -> AudioResult<Response> {
    let playback_session = crate::stream::requested_playback_session(&headers, query.playback_session_id.as_deref())
        .map_err(|status| AudioError(status, "invalid_playback_session"))?;
    let index = track
        .strip_suffix(".wav")
        .and_then(|s| s.parse::<u32>().ok())
        .filter(|n| format!("{n}.wav") == track)
        .ok_or(AudioError(StatusCode::NOT_FOUND, "unknown_audio_track"))?;
    let value = state.get_metadata(&sid).await?;
    let track = value
        .audio_tracks
        .iter()
        .find(|track| track.index == index)
        .ok_or(AudioError(StatusCode::NOT_FOUND, "unknown_audio_track"))?;
    let wave_header = wav_header(track.samples);
    let header_size = wave_header.len() as u64;
    let total = header_size + track.samples * FRAME_BYTES;
    let Some((start, end, partial)) = byte_range(&headers, total) else {
        return Ok((
            StatusCode::RANGE_NOT_SATISFIABLE,
            [(header::CONTENT_RANGE, format!("bytes */{total}"))],
        )
            .into_response());
    };
    let length = end - start + 1;
    let mut response = Response::builder()
        .status(if partial {
            StatusCode::PARTIAL_CONTENT
        } else {
            StatusCode::OK
        })
        .header(header::CONTENT_TYPE, "audio/wav")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_LENGTH, length.to_string())
        .header(header::CACHE_CONTROL, "private, no-store");
    if partial {
        response = response.header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{total}"),
        );
    }
    if method == Method::HEAD {
        return Ok(response.body(Body::empty()).unwrap());
    }
    let prefix = if start < header_size {
        wave_header[start as usize..((end + 1).min(header_size)) as usize].to_vec()
    } else {
        vec![]
    };
    let pcm_length = length - prefix.len() as u64;
    if pcm_length == 0 {
        return Ok(response.body(Body::from(prefix)).unwrap());
    }
    // Metadata probes stay unassociated; only the decoder's actual media read
    // carries the client's explicit watch identity.
    let source = crate::stream::attributed_source(&state.source_url(&sid)?, playback_session.as_deref());
    let slot = acquire(state.audio_slots.clone()).await?;
    let pcm_offset = start.saturating_sub(header_size);
    let mut decoder = Decoder::spawn(&source, index, pcm_offset, pcm_length, slot)?;
    // Check actual decoded output before committing a successful HTTP status.
    let first = decoder
        .read_chunk()
        .await
        .map_err(|_| AudioError(StatusCode::BAD_GATEWAY, "audio_decode_failed"))?;
    if first.is_empty() {
        return Err(AudioError(StatusCode::BAD_GATEWAY, "audio_decode_failed"));
    }
    let initial = Bytes::from([prefix, first].concat());
    let stream = futures::stream::unfold(
        (decoder, Some(initial)),
        |(mut decoder, initial)| async move {
            if let Some(bytes) = initial {
                return Some((Ok::<Bytes, io::Error>(bytes), (decoder, None)));
            }
            if decoder.remaining == 0 {
                return None;
            }
            match decoder.read_chunk().await {
                Ok(bytes) if !bytes.is_empty() => Some((Ok(Bytes::from(bytes)), (decoder, None))),
                Ok(_) => None,
                Err(error) => {
                    decoder.remaining = 0;
                    Some((Err(error), (decoder, None)))
                }
            }
        },
    );
    Ok(response.body(Body::from_stream(stream)).unwrap())
}

/// The response stream owns child + permit. Dropping a disconnected response
/// kills FFmpeg and releases capacity; no detached worker can keep downloading.
struct Decoder {
    child: Child,
    stdout: BufReader<ChildStdout>,
    remaining: u64,
    skip: usize,
    _slot: OwnedSemaphorePermit,
}
impl Decoder {
    fn spawn(
        source: &str,
        track: u32,
        offset: u64,
        length: u64,
        slot: OwnedSemaphorePermit,
    ) -> AudioResult<Self> {
        let sample = offset / FRAME_BYTES;
        // Fractional -ss rounds to compressed-frame timestamps. Decode at most
        // two seconds of preroll, then trim exact output samples instead.
        let seek_seconds = (sample / RATE).saturating_sub(1);
        let trim = sample - seek_seconds * RATE;
        let filter = format!(
            "aresample=48000:async=1:first_pts=0,atrim=start_sample={trim},asetpts=PTS-STARTPTS"
        );
        let mut child = Command::new("ffmpeg")
            .args([
                "-nostdin",
                "-loglevel",
                "error",
                "-threads",
                "1",
                "-rw_timeout",
                "30000000",
                "-protocol_whitelist",
                "http,tcp",
                "-ss",
                &seek_seconds.to_string(),
                "-i",
                source,
                "-map",
                &format!("0:{track}"),
                "-vn",
                "-sn",
                "-dn",
                "-af",
                &filter,
                "-ac",
                "2",
                "-ar",
                "48000",
                "-threads",
                "1",
                "-f",
                "s16le",
                "pipe:1",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| {
                AudioError(StatusCode::SERVICE_UNAVAILABLE, "audio_decoder_unavailable")
            })?;
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Ok(Self {
            child,
            stdout,
            remaining: length,
            skip: (offset % FRAME_BYTES) as usize,
            _slot: slot,
        })
    }

    async fn read_chunk(&mut self) -> io::Result<Vec<u8>> {
        if self.remaining == 0 {
            return Ok(vec![]);
        }
        if self.skip > 0 {
            let mut skip = vec![0; self.skip];
            tokio::time::timeout(IO_TIMEOUT, self.stdout.read_exact(&mut skip))
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "audio decode timed out"))??;
            self.skip = 0;
        }
        let mut bytes = vec![0; self.remaining.min(32 * 1024) as usize];
        let count = tokio::time::timeout(IO_TIMEOUT, self.stdout.read(&mut bytes))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "audio decode timed out"))??;
        if count == 0 {
            // Never invent silence for a missing/failed source. A short decoder
            // result must terminate the HTTP body, not masquerade as healthy.
            let _ = self.child.start_kill();
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "audio source ended early",
            ));
        }
        bytes.truncate(count);
        self.remaining -= count as u64;
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wav_headers_support_riff_and_long_rf64() {
        let small = wav_header(48_000);
        assert_eq!(small.len(), 44);
        assert_eq!(&small[0..4], b"RIFF");
        assert_eq!(
            u32::from_le_bytes(small[40..44].try_into().unwrap()),
            192_000
        );
        let large = wav_header(48_000 * 10 * 3600);
        assert_eq!(large.len(), 80);
        assert_eq!(&large[0..4], b"RF64");
        assert_eq!(&large[12..16], b"ds64");
        assert_eq!(
            u64::from_le_bytes(large[28..36].try_into().unwrap()),
            48_000 * 10 * 3600 * 4
        );
    }
    #[test]
    fn range_parser_handles_headers_suffix_and_unaligned_bytes() {
        let mut headers = HeaderMap::new();
        assert_eq!(byte_range(&headers, 100), Some((0, 99, false)));
        for (raw, expected) in [
            ("bytes=40-55", Some((40, 55, true))),
            ("bytes=45-", Some((45, 99, true))),
            ("bytes=-8", Some((92, 99, true))),
            ("bytes=0-500", Some((0, 99, true))),
            ("bytes=100-", None),
            ("bytes=3-2", None),
            ("bytes=0-2,7-8", None),
            ("bytes=-0", None),
        ] {
            headers.insert(header::RANGE, raw.parse().unwrap());
            assert_eq!(byte_range(&headers, 100), expected, "{raw}");
        }
    }
    #[test]
    fn metadata_only_allows_real_audio_tracks_and_finite_duration() {
        let parsed = parse_metadata(br#"{"format":{"duration":"12.5"},"streams":[{"index":0,"codec_type":"video","codec_name":"hevc"},{"index":2,"codec_type":"audio","codec_name":"truehd","channels":8,"tags":{"language":"eng","title":"Atmos"}}]}"#).unwrap();
        assert_eq!(parsed.duration_ms, 12_500);
        assert_eq!(parsed.audio_tracks[0].samples, 600_000);
        assert_eq!(parsed.audio_tracks.len(), 1);
        assert_eq!(parsed.audio_tracks[0].index, 2);
        assert_eq!(parsed.audio_tracks[0].codec, "truehd");
        for value in ["NaN", "inf", "-1", "100000"] {
            assert!(parse_metadata(
                format!(r#"{{"format":{{"duration":"{value}"}},"streams":[]}}"#).as_bytes()
            )
            .is_err());
        }
    }
    #[test]
    fn metadata_adds_convertible_subtitles_without_changing_audio_samples() {
        let parsed = parse_metadata(br#"{"format":{"duration":"12.5"},"streams":[{"index":1,"codec_type":"audio","codec_name":"truehd","channels":8},{"index":3,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng","title":"English SDH"}},{"index":4,"codec_type":"subtitle","codec_name":"hdmv_pgs_subtitle"}]}"#).unwrap();
        assert_eq!(parsed.audio_tracks[0].samples, 600_000);
        assert_eq!(parsed.subtitle_tracks.len(), 1);
        assert_eq!(parsed.subtitle_tracks[0].index, 3);
        let json = serde_json::to_value(parsed).unwrap();
        assert_eq!(json["subtitleTracks"][0]["language"], "eng");
        assert_eq!(json["subtitleTracks"][0]["title"], "English SDH");
        assert_eq!(json["audioTracks"][0]["codec"], "truehd");
    }

    fn fixture_streams() -> crate::stream::StreamState {
        let db = crate::db::open(":memory:").unwrap();
        crate::sync::migrate(&db.lock().unwrap()).unwrap();
        crate::stream::StreamState::new(crate::pool::Pool::new(&[]), reqwest::Client::new(), db)
    }

    #[test]
    fn audio_routes_merge_with_existing_range_and_resolver_routes() {
        let streams = fixture_streams();
        let resolver = crate::resolver::ResolverState {
            stream: streams.clone(),
            indexers: Arc::new(vec![]),
            public_base: "http://127.0.0.1:8799".into(),
        };
        let _ = Router::new()
            .merge(crate::resolver::router(resolver))
            .merge(crate::stream::router(streams.clone()))
            .merge(router(streams, "http://127.0.0.1:8799".into()).unwrap());
    }

    #[test]
    fn constructor_rejects_non_loopback_and_path_sources() {
        for origin in [
            "https://127.0.0.1:8799",
            "http://example.com",
            "http://localhost:8799",
            "http://127.0.0.1:8799/path",
            "http://user@127.0.0.1:8799",
            "http://127.0.0.1:8799/?url=x",
        ] {
            assert!(
                router(fixture_streams(), origin.into()).is_err(),
                "{origin}"
            );
        }
    }

    struct Running(tokio::task::JoinHandle<()>);
    impl Drop for Running {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    async fn run(app: Router) -> (String, Running) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (base, Running(task))
    }

    #[tokio::test]
    async fn real_truehd_decode_ranges_head_validation_and_cancellation() {
        // This exercises the installed decoder, rather than mocking its output.
        // FFmpeg is a required production image dependency (also used by intro).
        for (container_offset, audio_delay) in [(0, 0), (5, 0), (5, 1)] {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "velvet-audio-test-{}-{nonce}.mkv",
                std::process::id()
            ));
            let fixture = Command::new("ffmpeg")
                .args([
                    "-nostdin",
                    "-loglevel",
                    "error",
                    "-itsoffset",
                    &audio_delay.to_string(),
                    "-f",
                    "lavfi",
                    "-i",
                    "anoisesrc=color=pink:seed=42:sample_rate=48000:duration=3",
                    "-f",
                    "lavfi",
                    "-i",
                    "color=c=black:s=64x64:r=1:d=5",
                    "-ac",
                    "2",
                    "-c:a",
                    "truehd",
                    "-strict",
                    "-2",
                    "-c:v",
                    "mpeg4",
                    "-f",
                    "matroska",
                    "-output_ts_offset",
                    &container_offset.to_string(),
                ])
                .arg(&path)
                .output()
                .await
                .expect("ffmpeg must be installed for audio compatibility integration tests");
            assert!(fixture.status.success());
            let source_bytes = Arc::new(std::fs::read(&path).unwrap());
            std::fs::remove_file(path).unwrap();
            let source_reads = Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let reads = source_reads.clone();
            let source_queries = Arc::new(Mutex::new(Vec::<String>::new()));
            let queries = source_queries.clone();
            let source_app = Router::new().route(
                "/stream/:sid",
                axum::routing::get(move |axum::extract::OriginalUri(uri): axum::extract::OriginalUri, headers: HeaderMap| {
                    let source_bytes = source_bytes.clone();
                    let reads = reads.clone();
                    let queries = queries.clone();
                    async move {
                        reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        queries.lock().unwrap().push(uri.query().unwrap_or("").to_owned());
                        let total = source_bytes.len() as u64;
                        let (start, end, partial) = byte_range(&headers, total).unwrap();
                        let mut response = Response::builder()
                            .status(if partial { 206 } else { 200 })
                            .header(header::CONTENT_TYPE, "audio/x-matroska")
                            .header(header::ACCEPT_RANGES, "bytes")
                            .header(header::CONTENT_LENGTH, (end - start + 1).to_string());
                        if partial {
                            response = response.header(
                                header::CONTENT_RANGE,
                                format!("bytes {start}-{end}/{total}"),
                            );
                        }
                        response
                            .body(Body::from(
                                source_bytes[start as usize..=end as usize].to_vec(),
                            ))
                            .unwrap()
                    }
                }),
            );
            let (source_base, _source) = run(source_app).await;
            let streams = fixture_streams();
            let sid = streams
                .register("https://fixture.invalid/private-nzb")
                .await;
            let state = AudioState {
                streams,
                source_base,
                metadata: Arc::new(Mutex::new(HashMap::new())),
                probe_slots: Arc::new(Semaphore::new(2)),
                audio_slots: Arc::new(Semaphore::new(4)),
            };
            let (base, _server) = run(Router::new()
                .route("/stream/:sid/audio", axum::routing::get(metadata))
                .route("/stream/:sid/audio/:track", axum::routing::get(wave))
                .with_state(state.clone()))
            .await;
            let client = reqwest::Client::new();
            let info: serde_json::Value = client
                .get(format!("{base}/stream/{sid}/audio"))
                .send()
                .await
                .unwrap()
                .error_for_status()
                .unwrap()
                .json()
                .await
                .unwrap();
            assert_eq!(info["audioTracks"][0]["codec"], "truehd");
            let index = info["audioTracks"][0]["index"].as_u64().unwrap();
            assert!(source_queries.lock().unwrap().iter().all(String::is_empty), "metadata must remain unassociated");
            source_queries.lock().unwrap().clear();
            let url = format!("{base}/stream/{sid}/audio/{index}.wav?playbackSessionId=audio-watch-1");
            let before_head = source_reads.load(std::sync::atomic::Ordering::SeqCst);
            let head = client.head(&url).send().await.unwrap();
            assert_eq!(head.status(), 200);
            assert_eq!(head.headers()[header::ACCEPT_RANGES], "bytes");
            assert_eq!(
                source_reads.load(std::sync::atomic::Ordering::SeqCst),
                before_head,
                "cached HEAD must not decode source audio"
            );
            let full_response = client.get(&url).send().await.unwrap();
            assert_eq!(full_response.status(), 200);
            let full = full_response.bytes().await.unwrap();
            assert!(!source_queries.lock().unwrap().is_empty());
            assert!(source_queries.lock().unwrap().iter().all(|q| q == "playbackSessionId=audio-watch-1"), "only decoder reads carry the explicit watch");
            assert_eq!(&full[..4], b"RIFF");
            assert!(full[44..].iter().any(|b| *b != 0));
            assert_eq!(
                full.len(),
                44 + (3 + audio_delay as usize) * 48_000 * 4,
                "WAV normalizes container start and preserves real audio delay"
            );
            for (start, end) in [
                (0, 8),
                (40, 55),
                (45, 3100),
                (192004, 288007),
                (400001, 499999),
            ] {
                let response = client
                    .get(&url)
                    .header(header::RANGE, format!("bytes={start}-{end}"))
                    .send()
                    .await
                    .unwrap();
                assert_eq!(response.status(), 206);
                assert_eq!(
                    response.headers()[header::CONTENT_RANGE],
                    format!("bytes {start}-{end}/{}", full.len())
                );
                assert_eq!(
                    response.bytes().await.unwrap().as_ref(),
                    &full[start..=end],
                    "PCM range must represent the exact same samples"
                );
            }
            let suffix = client
                .get(&url)
                .header(header::RANGE, "bytes=-33")
                .send()
                .await
                .unwrap()
                .bytes()
                .await
                .unwrap();
            assert_eq!(suffix.as_ref(), &full[full.len() - 33..]);
            let bad = client
                .get(&url)
                .header(header::RANGE, format!("bytes={}-", full.len()))
                .send()
                .await
                .unwrap();
            assert_eq!(bad.status(), 416);
            assert_eq!(
                bad.headers()[header::CONTENT_RANGE],
                format!("bytes */{}", full.len())
            );
            assert_eq!(
                client
                    .get(format!("{base}/stream/{sid}/audio/999.wav"))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                404
            );
            assert_eq!(
                client
                    .get(format!("{base}/stream/0000000000000000/audio"))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                404
            );
            let response = wave(
                State(state.clone()),
                Path((sid, index.to_string() + ".wav")),
                axum::extract::Query(crate::stream::PlaybackSessionQuery::default()),
                Method::GET,
                HeaderMap::new(),
            )
            .await
            .unwrap();
            assert_eq!(state.audio_slots.available_permits(), 3);
            drop(response);
            assert_eq!(
                state.audio_slots.available_permits(),
                4,
                "dropping body releases decoder capacity immediately"
            );
        }
    }
}
