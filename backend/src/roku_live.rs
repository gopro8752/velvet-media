//! Roku cannot play muxed audio/video CMAF. Remux the existing, scoped live
//! capability to a bounded rolling MPEG-TS HLS window without re-encoding.
use axum::{
    http::{header, StatusCode},
    response::{IntoResponse, Response},
};
use std::{
    path::PathBuf,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tokio::{
    process::{Child, Command},
    sync::{Notify, OwnedSemaphorePermit, Semaphore},
};

const IDLE: Duration = Duration::from_secs(60);
const LIFETIME: Duration = Duration::from_secs(12 * 3600);
const MAX_FILE: u64 = 64 * 1024 * 1024;
const MAX_DISK: u64 = 512 * 1024 * 1024;
pub(crate) type Result<T> = std::result::Result<T, (StatusCode, &'static str)>;
const FAILED: (StatusCode, &str) = (
    StatusCode::BAD_GATEWAY,
    "Live audio compatibility could not start; retry the channel",
);

pub(crate) struct RokuLive {
    source_base: String,
    root: PathBuf,
    slots: Arc<Semaphore>,
    readers: Arc<Semaphore>,
}
pub(crate) struct Session {
    dir: PathBuf,
    created: Instant,
    touched: Mutex<Instant>,
    cancelled: AtomicBool,
    failed: AtomicBool,
    finished: AtomicBool,
    cancel: Notify,
    readers: Arc<Semaphore>,
}

fn hex_id(id: &str) -> bool {
    id.len() == 48
        && id
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn source_url(base: &str, id: &str) -> Result<String> {
    let url = reqwest::Url::parse(base).map_err(|_| FAILED)?;
    if url.scheme() != "http"
        || !matches!(
            url.host_str(),
            Some("127.0.0.1") | Some("[::1]") | Some("::1")
        )
        || url.path() != "/"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !hex_id(id)
    {
        return Err(FAILED);
    }
    Ok(format!(
        "{}/live/streams/{id}/source.m3u8",
        base.trim_end_matches('/')
    ))
}
fn allowed_asset(file: &str) -> bool {
    if matches!(file, "index.m3u8" | "media.m3u8") {
        return true;
    }
    file.strip_prefix("seg-")
        .and_then(|s| s.strip_suffix(".ts"))
        .is_some_and(|s| s.len() == 12 && s.bytes().all(|c| c.is_ascii_digit()))
}
impl RokuLive {
    pub(crate) fn new(source_base: String) -> anyhow::Result<Self> {
        source_url(&source_base, &"0".repeat(48))
            .map_err(|_| anyhow::anyhow!("Roku live source must be a loopback origin"))?;
        let root = std::env::temp_dir().join("velvet-roku-live-v1");
        std::fs::create_dir_all(&root)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))?;
        }
        // Only directories named by our capabilities belong to this service.
        for entry in std::fs::read_dir(&root)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() && entry.file_name().to_str().is_some_and(hex_id) {
                std::fs::remove_dir_all(entry.path())?;
            }
        }
        Ok(Self {
            source_base,
            root,
            slots: Arc::new(Semaphore::new(3)),
            readers: Arc::new(Semaphore::new(12)),
        })
    }
    pub(crate) async fn start(&self, id: &str) -> Result<Arc<Session>> {
        let source = source_url(&self.source_base, id)?;
        let permit = self.slots.clone().try_acquire_owned().map_err(|_| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                "Three Roku live players are already active; close one and retry",
            )
        })?;
        let dir = self.root.join(id);
        tokio::fs::create_dir(&dir).await.map_err(|_| FAILED)?;
        let session = Arc::new(Session {
            dir,
            created: Instant::now(),
            touched: Mutex::new(Instant::now()),
            cancelled: AtomicBool::new(false),
            failed: AtomicBool::new(false),
            finished: AtomicBool::new(false),
            cancel: Notify::new(),
            readers: self.readers.clone(),
        });
        let child = match remux(&source, &session.dir) {
            Ok(child) => child,
            Err(error) => {
                let _ = tokio::fs::remove_dir_all(&session.dir).await;
                return Err(error);
            }
        };
        tokio::spawn(run_worker(session.clone(), child, permit));
        Ok(session)
    }
}
fn remux(source: &str, dir: &std::path::Path) -> Result<Child> {
    Command::new("ffmpeg")
        .current_dir(dir)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-rw_timeout",
            "15000000",
            "-protocol_whitelist",
            "http,tcp,crypto",
            "-live_start_index",
            "-3",
            "-i",
            source,
            "-map",
            "0:v:0",
            "-map",
            "0:a:0",
            "-c:v",
            "copy",
            "-c:a",
            "copy",
            "-sn",
            "-dn",
            "-avoid_negative_ts",
            "make_zero",
            "-max_muxing_queue_size",
            "1024",
            "-max_interleave_delta",
            "1000000",
            "-f",
            "hls",
            "-hls_time",
            "4",
            "-hls_segment_type",
            "mpegts",
            "-hls_list_size",
            "12",
            "-hls_delete_threshold",
            "3",
            "-hls_flags",
            "delete_segments+temp_file+independent_segments",
            "-hls_segment_filename",
            "seg-%012d.ts",
            "media.m3u8",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                "Live compatibility remuxer unavailable",
            )
        })
}
impl Session {
    pub(crate) fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        self.cancel.notify_one();
    }
    pub(crate) async fn ready(&self, timeout: Duration) -> Result<()> {
        let result = tokio::time::timeout(timeout, async {
            loop {
                if self.cancelled.load(Ordering::Acquire) || self.failed.load(Ordering::Acquire) {
                    return Err(FAILED);
                }
                if let Ok(text) = tokio::fs::read_to_string(self.dir.join("media.m3u8")).await {
                    if text
                        .lines()
                        .any(|line| line.starts_with("seg-") && allowed_asset(line))
                    {
                        return Ok(());
                    }
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await;
        match result {
            Ok(Ok(())) => Ok(()),
            _ => {
                self.cancel();
                Err(FAILED)
            }
        }
    }
    pub(crate) async fn asset(&self, file: &str) -> Result<Response> {
        if !allowed_asset(file) {
            return Err((StatusCode::NOT_FOUND, "Live asset unavailable"));
        }
        if self.cancelled.load(Ordering::Acquire) || self.failed.load(Ordering::Acquire) {
            return Err(FAILED);
        }
        *self.touched.lock().unwrap() = Instant::now();
        if file == "index.m3u8" {
            // A conservative bandwidth avoids declaring this copied 720p stream
            // as audio-only when FFmpeg cannot infer the input's video bitrate.
            let body =
                "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-STREAM-INF:BANDWIDTH=16000000\nmedia.m3u8\n";
            return Ok((
                [(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")],
                body,
            )
                .into_response());
        }
        let _permit = self
            .readers
            .clone()
            .try_acquire_owned()
            .map_err(|_| (StatusCode::SERVICE_UNAVAILABLE, "Live player busy; retry"))?;
        let path = self.dir.join(file);
        let metadata = tokio::fs::metadata(&path)
            .await
            .map_err(|_| (StatusCode::NOT_FOUND, "Live segment expired; retry"))?;
        if !metadata.is_file() || metadata.len() > MAX_FILE {
            return Err(FAILED);
        }
        let bytes = tokio::fs::read(path).await.map_err(|_| FAILED)?;
        if bytes.len() as u64 > MAX_FILE {
            return Err(FAILED);
        }
        if self.cancelled.load(Ordering::Acquire) {
            return Err(FAILED);
        }
        let mime = if file.ends_with(".m3u8") {
            "application/vnd.apple.mpegurl"
        } else {
            "video/mp2t"
        };
        Ok(([(header::CONTENT_TYPE, mime)], bytes).into_response())
    }
}
async fn run_worker(session: Arc<Session>, mut child: Child, _permit: OwnedSemaphorePermit) {
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            _ = session.cancel.notified() => break,
            result = child.wait() => {
                // A live feed ending is a retryable source failure, even exit0.
                let _ = result;
                session.failed.store(true, Ordering::Release);
                break;
            },
            _ = tick.tick() => {
                if session.cancelled.load(Ordering::Acquire) || session.created.elapsed() > LIFETIME
                    || session.touched.lock().unwrap().elapsed() > IDLE { break; }
                let mut size = 0u64;
                if let Ok(mut entries) = tokio::fs::read_dir(&session.dir).await {
                    while let Ok(Some(entry)) = entries.next_entry().await {
                        if let Ok(meta) = entry.metadata().await { size = size.saturating_add(meta.len()); }
                    }
                }
                if size > MAX_DISK { session.failed.store(true, Ordering::Release); break; }
            }
        }
    }
    session.cancelled.store(true, Ordering::Release);
    let _ = child.kill().await;
    let _ = child.wait().await;
    let _ = tokio::fs::remove_dir_all(&session.dir).await;
    session.finished.store(true, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sources_and_assets_are_strictly_server_owned() {
        let id = "a".repeat(48);
        assert!(source_url("http://127.0.0.1:8799", &id)
            .unwrap()
            .ends_with("/source.m3u8"));
        for base in [
            "https://127.0.0.1",
            "http://example.com",
            "http://user@127.0.0.1",
            "http://127.0.0.1/x",
            "http://127.0.0.1?url=x",
        ] {
            assert!(source_url(base, &id).is_err());
        }
        for id in ["a".repeat(16), "A".repeat(48), "../".repeat(16)] {
            assert!(source_url("http://127.0.0.1", &id).is_err());
        }
        for file in ["index.m3u8", "media.m3u8", "seg-000000000001.ts"] {
            assert!(allowed_asset(file));
        }
        for file in [
            "source.m3u8",
            "../media.m3u8",
            "seg-1.ts",
            "seg-000000000001.ts.tmp",
            "seg-000000000001.ts?x",
        ] {
            assert!(!allowed_asset(file));
        }
    }
    fn session(dir: PathBuf) -> Arc<Session> {
        Arc::new(Session {
            dir,
            created: Instant::now(),
            touched: Mutex::new(Instant::now()),
            cancelled: AtomicBool::new(false),
            failed: AtomicBool::new(false),
            finished: AtomicBool::new(false),
            cancel: Notify::new(),
            readers: Arc::new(Semaphore::new(1)),
        })
    }
    #[tokio::test]
    async fn startup_timeout_and_failure_cancel_session() {
        let value = session(std::env::temp_dir().join("velvet-roku-live-missing-test"));
        assert!(value.ready(Duration::from_millis(5)).await.is_err());
        assert!(value.cancelled.load(Ordering::Acquire));
        let value = session(std::env::temp_dir().join("velvet-roku-live-missing-test"));
        value.failed.store(true, Ordering::Release);
        assert!(value.ready(Duration::from_secs(1)).await.is_err());
    }
    #[tokio::test]
    async fn cancel_reaps_worker_files_and_slot() {
        let dir =
            std::env::temp_dir().join(format!("velvet-roku-live-cancel-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        tokio::fs::write(dir.join("segment.tmp"), b"test")
            .await
            .unwrap();
        let value = session(dir.clone());
        let slots = Arc::new(Semaphore::new(1));
        let permit = slots.clone().acquire_owned().await.unwrap();
        let child = Command::new("sleep")
            .arg("20")
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let worker = tokio::spawn(run_worker(value.clone(), child, permit));
        value.cancel();
        tokio::time::timeout(Duration::from_secs(2), worker)
            .await
            .unwrap()
            .unwrap();
        assert!(value.finished.load(Ordering::Acquire));
        assert!(!dir.exists());
        assert_eq!(slots.available_permits(), 1);
    }
    #[tokio::test]
    async fn unused_worker_expires_without_another_request() {
        let dir =
            std::env::temp_dir().join(format!("velvet-roku-live-idle-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let value = session(dir.clone());
        *value.touched.lock().unwrap() = Instant::now() - IDLE - Duration::from_secs(1);
        let slots = Arc::new(Semaphore::new(1));
        let child = Command::new("sleep")
            .arg("20")
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        tokio::time::timeout(
            Duration::from_secs(2),
            run_worker(value.clone(), child, slots.acquire_owned().await.unwrap()),
        )
        .await
        .unwrap();
        assert!(value.cancelled.load(Ordering::Acquire));
        assert!(!dir.exists());
    }
    #[tokio::test]
    async fn real_muxed_fmp4_becomes_ts_with_video_and_audio() {
        use axum::{http::Uri, routing::get, Router};
        let dir =
            std::env::temp_dir().join(format!("velvet-roku-live-fixture-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let generated = Command::new("ffmpeg")
            .current_dir(&dir)
            .args([
                "-v",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=320x180:rate=25",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=48000",
                "-t",
                "8",
                "-c:v",
                "libx264",
                "-preset",
                "ultrafast",
                "-g",
                "25",
                "-c:a",
                "aac",
                "-ac",
                "2",
                "-f",
                "hls",
                "-hls_time",
                "2",
                "-hls_segment_type",
                "fmp4",
                "-hls_list_size",
                "0",
                "-hls_flags",
                "omit_endlist+independent_segments",
                "-hls_fmp4_init_filename",
                "input.mp4",
                "-hls_segment_filename",
                "input-%06d.m4s",
                "source.m3u8",
            ])
            .output()
            .await
            .unwrap();
        assert!(generated.status.success(), "fixture generation failed");
        let serve_dir = dir.clone();
        let router = Router::new().fallback(get(move |uri: Uri| {
            let root = serve_dir.clone();
            async move {
                let file = uri.path().rsplit('/').next().unwrap_or("");
                let valid = matches!(file, "source.m3u8" | "input.mp4")
                    || file
                        .strip_prefix("input-")
                        .and_then(|s| s.strip_suffix(".m4s"))
                        .is_some_and(|s| s.len() == 6 && s.bytes().all(|c| c.is_ascii_digit()));
                if !valid {
                    return StatusCode::NOT_FOUND.into_response();
                }
                match tokio::fs::read(root.join(file)).await {
                    Ok(bytes) => (
                        [(
                            header::CONTENT_TYPE,
                            if file.ends_with(".m3u8") {
                                "application/vnd.apple.mpegurl"
                            } else {
                                "video/mp4"
                            },
                        )],
                        bytes,
                    )
                        .into_response(),
                    Err(_) => StatusCode::NOT_FOUND.into_response(),
                }
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let manager = RokuLive {
            source_base: base,
            root: dir.clone(),
            slots: Arc::new(Semaphore::new(1)),
            readers: Arc::new(Semaphore::new(1)),
        };
        let value = manager.start(&"b".repeat(48)).await.unwrap();
        let ready = value.ready(Duration::from_secs(15)).await;
        assert!(ready.is_ok(), "real TS remux failed: {ready:?}");
        let playlist = tokio::fs::read_to_string(value.dir.join("media.m3u8"))
            .await
            .unwrap();
        assert!(!playlist.contains("EXT-X-MAP"));
        let segment = playlist
            .lines()
            .find(|line| line.starts_with("seg-"))
            .unwrap();
        let inspected = Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-show_entries",
                "stream=codec_name,codec_type,channels",
                "-of",
                "json",
            ])
            .arg(value.dir.join(segment))
            .output()
            .await
            .unwrap();
        let data: serde_json::Value = serde_json::from_slice(&inspected.stdout).unwrap();
        let tracks = data["streams"].as_array().unwrap();
        assert!(tracks.iter().any(|t| t["codec_name"] == "h264"));
        assert!(tracks
            .iter()
            .any(|t| t["codec_name"] == "aac" && t["channels"] == 2));
        value.cancel();
        tokio::time::timeout(Duration::from_secs(2), async {
            while !value.finished.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        server.abort();
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
}
