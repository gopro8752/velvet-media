//! Bounded, opt-in exact-byte PAR2 recovery. Never substitutes another release.
//!
//! Raw posted files (including archive volumes) are retained by yEnc offsets.
//! Every recovery packet and pathname is validated before invoking par2. A
//! repaired set becomes readable only after independent full-file MD5 checks.
use crate::{
    nzb::Nzb,
    pool::{DecodedFetch, FetchBudget, Pool},
    yenc::DecodedSegment,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    ffi::CString,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tokio::{
    fs,
    io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt},
    sync::{Mutex, Notify, Semaphore},
};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct RepairConfig {
    pub enabled: bool,
    pub cache_dir: String,
    pub par2_binary: String,
    /// Total protected file bytes, not the compressed playback length.
    pub max_job_bytes: u64,
    /// Includes sparse input, repair output/backup, and parity reservations.
    pub max_cache_bytes: u64,
    /// Hard NNTP BODY transfer allowance across all providers/retries. Failed
    /// partial transfers conservatively consume their reserved body allowance.
    pub max_download_bytes: u64,
    pub max_parity_bytes: u64,
    pub max_jobs: usize,
    pub max_registered: usize,
    pub max_job_seconds: u64,
    pub max_article_seconds: u64,
    pub min_free_bytes: u64,
    pub max_memory_mib: u32,
    pub fetch_parallelism: usize,
    pub cache_ttl_seconds: u64,
}
impl Default for RepairConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            cache_dir: "/data/recovery".into(),
            par2_binary: "par2".into(),
            max_job_bytes: 16 << 30,
            max_cache_bytes: 64 << 30,
            max_download_bytes: 32 << 30,
            max_parity_bytes: 2 << 30,
            max_jobs: 1,
            max_registered: 128,
            max_job_seconds: 180,
            max_article_seconds: 15,
            min_free_bytes: 2 << 30,
            max_memory_mib: 256,
            fetch_parallelism: 4,
            cache_ttl_seconds: 1800,
        }
    }
}
#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum RepairError {
    #[error("exact repair is disabled")]
    Disabled,
    #[error("source metadata is not registered")]
    UnknownSource,
    #[error("no usable PAR2 recovery metadata in this release")]
    NoParity,
    #[error("release exceeds the repair file-size budget")]
    FileBudget,
    #[error("repair cache capacity is exhausted")]
    CacheBudget,
    #[error("repair download budget is exhausted")]
    DownloadBudget,
    #[error("PAR2 download budget is exhausted")]
    ParityBudget,
    #[error("not enough free disk space for bounded repair")]
    LowDisk,
    #[error("repair deadline expired")]
    Timeout,
    #[error("repair was cancelled")]
    Cancelled,
    #[error("invalid or unsafe recovery metadata")]
    InvalidMetadata,
    #[error("unsupported PAR2 packet; recovery was not executed")]
    UnsupportedPacket,
    #[error("the source article range cannot be determined exactly")]
    AmbiguousRange,
    #[error("the protected file is not described by this recovery set")]
    Unprotected,
    #[error("insufficient recovery blocks or supporting file data")]
    InsufficientParity,
    #[error("repaired bytes did not match the original file checksum")]
    Verification,
    #[error("PAR2 executable could not be started")]
    Executable,
    #[error("recovery file I/O failed")]
    Io,
}
impl From<std::io::Error> for RepairError {
    fn from(_: std::io::Error) -> Self {
        Self::Io
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct RepairStatus {
    pub phase: String,
    pub detail: Option<String>,
    /// Actual complete NNTP bodies plus conservative interrupted-body charges.
    pub charged_download_bytes: u64,
    pub reserved_bytes: u64,
}
#[derive(Clone)]
pub struct RepairRegistry {
    inner: Arc<Inner>,
}
struct Inner {
    cfg: RepairConfig,
    pool: Arc<Pool>,
    entries: Mutex<HashMap<String, Arc<Entry>>>,
    slots: Semaphore,
    reserved: Arc<AtomicU64>,
    _cache_lock: Option<std::fs::File>,
    cache_error: Option<RepairError>,
}
struct Entry {
    nzb: Arc<Nzb>,
    index: HashMap<String, (usize, usize)>,
    dir: PathBuf,
    state: Mutex<EntryState>,
    started: AtomicBool,
    cancelled: AtomicBool,
    cancel: Notify,
    done: Notify,
    last_used: std::sync::Mutex<Instant>,
    download_budget: FetchBudget,
    reserved: AtomicU64,
    global_reserved: Arc<AtomicU64>,
}
struct EntryState {
    files: HashMap<usize, InputFile>,
    phase: &'static str,
    result: Option<Result<Ready, RepairError>>,
}
struct InputFile {
    name: String,
    size: u64,
    articles: BTreeMap<usize, ArticleRange>,
}
#[derive(Clone, Debug)]
struct ArticleRange {
    begin: u64,
    len: u64,
}
struct Ready {
    files: HashMap<usize, ReadyFile>,
}
struct ReadyFile {
    path: PathBuf,
    name: String,
    size: u64,
}
impl Drop for Entry {
    fn drop(&mut self) {
        // Unique job directories are never shared with another stream or process.
        let _ = std::fs::remove_dir_all(&self.dir);
        self.global_reserved
            .fetch_sub(self.reserved.load(Ordering::Relaxed), Ordering::Relaxed);
    }
}
impl RepairRegistry {
    pub fn new(cfg: RepairConfig, pool: Arc<Pool>) -> Self {
        let (cache_lock, cache_error) = if cfg.enabled {
            match prepare_cache(&cfg) {
                Ok(lock) => (Some(lock), None),
                Err(error) => (None, Some(error)),
            }
        } else {
            (None, None)
        };
        Self {
            inner: Arc::new(Inner {
                slots: Semaphore::new(cfg.max_jobs.max(1).min(8)),
                cfg,
                pool,
                entries: Mutex::new(HashMap::new()),
                reserved: Arc::new(AtomicU64::new(0)),
                _cache_lock: cache_lock,
                cache_error,
            }),
        }
    }
    pub async fn register(&self, sid: &str, nzb: Arc<Nzb>) -> Result<(), RepairError> {
        if !self.inner.cfg.enabled {
            return Err(RepairError::Disabled);
        }
        if let Some(error) = &self.inner.cache_error {
            return Err(error.clone());
        }
        let mut entries = self.inner.entries.lock().await;
        let ttl = Duration::from_secs(self.inner.cfg.cache_ttl_seconds.max(1));
        entries.retain(|_, e| {
            let keep = e
                .last_used
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .elapsed()
                < ttl;
            if !keep {
                e.cancelled.store(true, Ordering::Release);
                e.cancel.notify_waiters();
            }
            keep
        });
        if let Some(e) = entries.get(sid) {
            *e.last_used.lock().unwrap_or_else(|p| p.into_inner()) = Instant::now();
            return Ok(());
        }
        if entries.len() >= self.inner.cfg.max_registered.max(1) {
            return Err(RepairError::CacheBudget);
        }
        let mut index = HashMap::new();
        for (f, file) in nzb.files.iter().enumerate() {
            if file.segments.len() > 200_000
                || nzb.files.len() > 10_000
                || index.len().saturating_add(file.segments.len()) > 200_000
            {
                return Err(RepairError::InvalidMetadata);
            }
            for (s, seg) in file.segments.iter().enumerate() {
                if index.insert(seg.message_id.clone(), (f, s)).is_some() {
                    return Err(RepairError::InvalidMetadata);
                }
            }
        }
        let mut random = [0u8; 16];
        getrandom::getrandom(&mut random).map_err(|_| RepairError::Io)?;
        let token: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let dir = Path::new(&self.inner.cfg.cache_dir).join(format!("job-{token}"));
        fs::create_dir_all(&self.inner.cfg.cache_dir).await?;
        fs::create_dir(&dir).await?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).await?;
        }
        fs::create_dir(dir.join("inputs")).await?;
        entries.insert(
            sid.to_owned(),
            Arc::new(Entry {
                nzb,
                index,
                dir,
                state: Mutex::new(EntryState {
                    files: HashMap::new(),
                    phase: "buffering",
                    result: None,
                }),
                started: AtomicBool::new(false),
                cancelled: AtomicBool::new(false),
                cancel: Notify::new(),
                done: Notify::new(),
                last_used: std::sync::Mutex::new(Instant::now()),
                download_budget: FetchBudget::new(self.inner.cfg.max_download_bytes),
                reserved: AtomicU64::new(0),
                global_reserved: self.inner.reserved.clone(),
            }),
        );
        Ok(())
    }
    async fn entry(&self, sid: &str) -> Result<Arc<Entry>, RepairError> {
        if !self.inner.cfg.enabled {
            return Err(RepairError::Disabled);
        }
        let entry = self
            .inner
            .entries
            .lock()
            .await
            .get(sid)
            .cloned()
            .ok_or(RepairError::UnknownSource)?;
        if entry.cancelled.load(Ordering::Acquire) {
            return Err(RepairError::Cancelled);
        }
        *entry.last_used.lock().unwrap_or_else(|p| p.into_inner()) = Instant::now();
        Ok(entry)
    }
    pub async fn remember(
        &self,
        sid: &str,
        id: &str,
        segment: &DecodedSegment,
    ) -> Result<(), RepairError> {
        let entry = self.entry(sid).await?;
        remember(&self.inner, &entry, id, segment).await
    }
    /// Reads retained checksummed input or independently verified repaired data.
    pub async fn read(&self, sid: &str, id: &str) -> Option<DecodedSegment> {
        let entry = self.entry(sid).await.ok()?;
        read_article(&entry, id).await.ok()
    }
    pub async fn recover(&self, sid: &str, id: &str) -> Result<DecodedSegment, RepairError> {
        self.recover_file(sid, id).await?;
        let entry = self.entry(sid).await?;
        read_article(&entry, id).await
    }
    pub async fn recover_file(&self, sid: &str, id: &str) -> Result<(), RepairError> {
        let entry = self.entry(sid).await?;
        if !entry.index.contains_key(id) {
            return Err(RepairError::UnknownSource);
        }
        if !entry.started.swap(true, Ordering::AcqRel) {
            let inner = self.inner.clone();
            let job = entry.clone();
            tokio::spawn(async move {
                let deadline = Duration::from_secs(inner.cfg.max_job_seconds.max(1));
                let work = async {
                    let _slot = inner
                        .slots
                        .acquire()
                        .await
                        .map_err(|_| RepairError::Cancelled)?;
                    run_repair(&inner, &job).await
                };
                let result = tokio::select! {
                    _ = job.cancel.notified() => Err(RepairError::Cancelled),
                    result = tokio::time::timeout(deadline, work) => result.unwrap_or(Err(RepairError::Timeout)),
                };
                if result.is_err() {
                    let _ = fs::remove_dir_all(job.dir.join("staging")).await;
                    let _ = fs::remove_dir_all(job.dir.join("verified-next")).await;
                }
                let mut state = job.state.lock().await;
                state.phase = if result.is_ok() { "ready" } else { "failed" };
                state.result = Some(result);
                drop(state);
                job.done.notify_waiters();
            });
        }
        loop {
            let done = entry.done.notified();
            if let Some(result) = &entry.state.lock().await.result {
                return match result {
                    Ok(ready) if ready.files.contains_key(&entry.index[id].0) => Ok(()),
                    Ok(_) => Err(RepairError::Unprotected),
                    Err(e) => Err(e.clone()),
                };
            }
            if entry.cancelled.load(Ordering::Acquire) {
                return Err(RepairError::Cancelled);
            }
            done.await;
        }
    }
    /// `offset` is a zero-based offset in the ORIGINAL posted file, before any
    /// archive/media slicing. This also supports consecutive missing articles.
    pub async fn read_range(
        &self,
        sid: &str,
        id: &str,
        offset: u64,
        len: usize,
    ) -> Result<Option<Vec<u8>>, RepairError> {
        let entry = self.entry(sid).await?;
        let (fi, _) = *entry.index.get(id).ok_or(RepairError::UnknownSource)?;
        let state = entry.state.lock().await;
        let Some(Ok(ready)) = &state.result else {
            return Ok(None);
        };
        let file = ready.files.get(&fi).ok_or(RepairError::Unprotected)?;
        if len > 32 << 20
            || offset
                .checked_add(len as u64)
                .filter(|end| *end <= file.size)
                .is_none()
        {
            return Err(RepairError::InvalidMetadata);
        }
        Ok(Some(read_at(&file.path, offset, len).await?))
    }
    /// A published repair file has already passed its full PAR2 MD5 check and
    /// is immutable for this registry's lifetime. This reports durable coverage
    /// without reading the file into the stream's bounded memory cache.
    pub async fn verified_file(&self, sid: &str, id: &str) -> bool {
        let Ok(entry) = self.entry(sid).await else {
            return false;
        };
        let Some(&(fi, _)) = entry.index.get(id) else {
            return false;
        };
        let state = entry.state.lock().await;
        let Some(Ok(ready)) = &state.result else {
            return false;
        };
        let Some(file) = ready.files.get(&fi) else {
            return false;
        };
        fs::symlink_metadata(&file.path)
            .await
            .is_ok_and(|metadata| metadata.file_type().is_file() && metadata.len() == file.size)
    }
    pub async fn status(&self, sid: &str) -> Option<RepairStatus> {
        let e = self.entry(sid).await.ok()?;
        let s = e.state.lock().await;
        Some(RepairStatus {
            phase: s.phase.into(),
            detail: s
                .result
                .as_ref()
                .and_then(|r| r.as_ref().err())
                .map(ToString::to_string),
            charged_download_bytes: e.download_budget.used(),
            reserved_bytes: e.reserved.load(Ordering::Relaxed),
        })
    }
    pub async fn cancel(&self, sid: &str) {
        if let Some(e) = self.inner.entries.lock().await.remove(sid) {
            e.cancelled.store(true, Ordering::Release);
            e.cancel.notify_waiters();
            e.done.notify_waiters();
        }
    }
}
fn prepare_cache(cfg: &RepairConfig) -> Result<std::fs::File, RepairError> {
    use std::os::unix::{fs::PermissionsExt, io::AsRawFd};
    std::fs::create_dir_all(&cfg.cache_dir)?;
    if !std::fs::symlink_metadata(&cfg.cache_dir)?.is_dir() {
        return Err(RepairError::Io);
    }
    std::fs::set_permissions(&cfg.cache_dir, std::fs::Permissions::from_mode(0o700))?;
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(Path::new(&cfg.cache_dir).join(".owner.lock"))?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(RepairError::CacheBudget);
    }
    // The exclusive owner lock makes crash leftovers safe to reap. Unknown
    // entries are untouched; this directory must be a dedicated beta cache.
    for item in std::fs::read_dir(&cfg.cache_dir)? {
        let item = item?;
        let name = item.file_name();
        let name = name.to_string_lossy();
        if name.len() == 36
            && name.starts_with("job-")
            && name[4..].bytes().all(|b| b.is_ascii_hexdigit())
            && item.file_type()?.is_dir()
        {
            std::fs::remove_dir_all(item.path())?;
        }
    }
    Ok(lock)
}
fn input_path(e: &Entry, fi: usize) -> PathBuf {
    e.dir.join("inputs").join(format!("file-{fi:06}"))
}
fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 240
        && !name.starts_with('.')
        && !name.ends_with([' ', '.'])
        && !name.contains(['/', '\\', ':', '\0'])
        && !name.chars().any(char::is_control)
}
fn check_free(path: &Path, needed: u64, cfg: &RepairConfig) -> Result<(), RepairError> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| RepairError::Io)?;
        let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
            return Err(RepairError::Io);
        }
        let stat = unsafe { stat.assume_init() };
        let free = (stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64);
        if free < needed.saturating_add(cfg.min_free_bytes) {
            return Err(RepairError::LowDisk);
        }
    }
    Ok(())
}
fn reserve(inner: &Inner, e: &Entry, bytes: u64) -> Result<(), RepairError> {
    let before = inner
        .reserved
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            n.checked_add(bytes)
                .filter(|sum| *sum <= inner.cfg.max_cache_bytes)
        })
        .map_err(|_| RepairError::CacheBudget)?;
    // Sparse files have not consumed their promised blocks yet. Include other
    // live reservations, conservatively even already materialized blocks, so
    // concurrent jobs cannot each promise themselves the same free disk space.
    if let Err(error) = check_free(&e.dir, before + bytes, &inner.cfg) {
        inner.reserved.fetch_sub(bytes, Ordering::AcqRel);
        return Err(error);
    }
    e.reserved.fetch_add(bytes, Ordering::Relaxed);
    Ok(())
}
async fn remember(
    inner: &Inner,
    e: &Entry,
    id: &str,
    seg: &DecodedSegment,
) -> Result<(), RepairError> {
    if e.cancelled.load(Ordering::Acquire) {
        return Err(RepairError::Cancelled);
    }
    let &(fi, si) = e.index.get(id).ok_or(RepairError::UnknownSource)?;
    let name = seg
        .name
        .as_deref()
        .filter(|s| safe_name(s))
        .ok_or(RepairError::InvalidMetadata)?;
    let size = seg
        .total_size
        .filter(|n| *n > 0 && *n <= inner.cfg.max_job_bytes)
        .ok_or(RepairError::FileBudget)?;
    let begin = seg
        .part_begin
        .unwrap_or(1)
        .checked_sub(1)
        .ok_or(RepairError::InvalidMetadata)?;
    let end = begin
        .checked_add(seg.data.len() as u64)
        .filter(|n| *n <= size)
        .ok_or(RepairError::InvalidMetadata)?;
    if seg.part_end.is_some_and(|n| n != end) || seg.data.is_empty() {
        return Err(RepairError::InvalidMetadata);
    }
    let mut state = e.state.lock().await;
    if let Some(file) = state.files.get(&fi) {
        if file.name != name || file.size != size {
            return Err(RepairError::InvalidMetadata);
        }
        if let Some(old) = file.articles.get(&si) {
            return if old.begin == begin && old.len == seg.data.len() as u64 {
                Ok(())
            } else {
                Err(RepairError::InvalidMetadata)
            };
        }
        for (other_si, range) in &file.articles {
            if begin < range.begin + range.len && range.begin < end
                || (*other_si < si && range.begin >= begin)
                || (*other_si > si && range.begin <= begin)
            {
                return Err(RepairError::InvalidMetadata);
            }
        }
    } else {
        let total = state
            .files
            .values()
            .try_fold(size, |a, f| a.checked_add(f.size))
            .ok_or(RepairError::FileBudget)?;
        if total > inner.cfg.max_job_bytes {
            return Err(RepairError::FileBudget);
        }
        // Input + staging copy + possible par2 backup/output. Sparse reservations
        // are charged at their full logical size, not their currently used blocks.
        reserve(
            inner,
            e,
            size.checked_mul(3).ok_or(RepairError::FileBudget)?,
        )?;
        let file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(input_path(e, fi))
            .await?;
        file.set_len(size).await?;
        state.files.insert(
            fi,
            InputFile {
                name: name.to_owned(),
                size,
                articles: BTreeMap::new(),
            },
        );
    }
    check_free(&e.dir, seg.data.len() as u64, &inner.cfg)?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .open(input_path(e, fi))
        .await?;
    file.seek(std::io::SeekFrom::Start(begin)).await?;
    file.write_all(&seg.data).await?;
    // Tokio File may buffer a pending blocking write. Do not advertise the
    // article to concurrent readers until those bytes are actually written.
    file.flush().await?;
    state.files.get_mut(&fi).unwrap().articles.insert(
        si,
        ArticleRange {
            begin,
            len: seg.data.len() as u64,
        },
    );
    Ok(())
}
async fn read_at(path: &Path, offset: u64, len: usize) -> Result<Vec<u8>, RepairError> {
    let mut f = fs::File::open(path).await?;
    f.seek(std::io::SeekFrom::Start(offset)).await?;
    let mut data = vec![0; len];
    f.read_exact(&mut data).await?;
    Ok(data)
}
async fn copy_bounded(from: &Path, to: &Path, e: &Entry) -> Result<(), RepairError> {
    // fs::copy runs the entire copy on a blocking worker and cannot be stopped
    // when its future is cancelled. Keep pending disk I/O to one small chunk.
    let mut source = fs::File::open(from).await?;
    let mut destination = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(to)
        .await?;
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        if e.cancelled.load(Ordering::Acquire) {
            return Err(RepairError::Cancelled);
        }
        let count = source.read(&mut buffer).await?;
        if count == 0 {
            break;
        }
        destination.write_all(&buffer[..count]).await?;
        destination.flush().await?;
    }
    Ok(())
}
async fn read_article(e: &Entry, id: &str) -> Result<DecodedSegment, RepairError> {
    let &(fi, si) = e.index.get(id).ok_or(RepairError::UnknownSource)?;
    let state = e.state.lock().await;
    let observed = state.files.get(&fi);
    let repaired = state
        .result
        .as_ref()
        .and_then(|r| r.as_ref().ok())
        .and_then(|r| r.files.get(&fi));
    let (path, name, size) = if let Some(f) = repaired {
        (f.path.clone(), f.name.clone(), f.size)
    } else if let Some(f) = observed {
        (input_path(e, fi), f.name.clone(), f.size)
    } else {
        return Err(RepairError::AmbiguousRange);
    };
    let range = observed
        .and_then(|f| f.articles.get(&si))
        .cloned()
        .or_else(|| {
            if repaired.is_none() {
                return None;
            }
            let count = e.nzb.files[fi].segments.len();
            let begin = if si == 0 {
                Some(0)
            } else {
                observed
                    .and_then(|f| f.articles.get(&(si - 1)))
                    .map(|r| r.begin + r.len)
            }?;
            let end = if si + 1 == count {
                Some(size)
            } else {
                observed
                    .and_then(|f| f.articles.get(&(si + 1)))
                    .map(|r| r.begin)
            }?;
            (end > begin).then_some(ArticleRange {
                begin,
                len: end - begin,
            })
        })
        .ok_or(RepairError::AmbiguousRange)?;
    if range.len > 32 << 20 {
        return Err(RepairError::InvalidMetadata);
    }
    let data = read_at(&path, range.begin, range.len as usize).await?;
    Ok(DecodedSegment {
        data,
        part_begin: Some(range.begin + 1),
        part_end: Some(range.begin + range.len),
        total_size: Some(size),
        name: Some(name),
    })
}

async fn fetch(
    inner: &Inner,
    e: &Entry,
    fi: usize,
    si: usize,
) -> Result<Option<DecodedSegment>, RepairError> {
    let file = &e.nzb.files[fi];
    let article = &file.segments[si];
    let group = file.groups.first().map(String::as_str).unwrap_or("");
    let _background = inner.pool.background_permit().await;
    match tokio::time::timeout(
        Duration::from_secs(inner.cfg.max_article_seconds.max(1)),
        inner
            .pool
            .fetch_decoded_budgeted(group, &article.message_id, &e.download_budget),
    )
    .await
    {
        Ok(Ok(DecodedFetch::Found(seg))) => Ok(Some(seg)),
        Ok(Err(_)) => Err(RepairError::DownloadBudget),
        _ => Ok(None),
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Description {
    id: [u8; 16],
    name: String,
    size: u64,
    hash: [u8; 16],
}
#[derive(Default)]
struct Metadata {
    set: Option<[u8; 16]>,
    main: Option<Vec<u8>>,
    block_size: u64,
    ids: Vec<[u8; 16]>,
    descriptions: HashMap<[u8; 16], Description>,
    recovery: HashMap<u32, (u64, [u8; 16])>,
    verification: HashMap<[u8; 16], (usize, [u8; 16])>,
}
impl Metadata {
    fn packet(&mut self, kind: &[u8], body: &[u8], set: [u8; 16]) -> Result<(), RepairError> {
        if self.set.is_some_and(|id| id != set) {
            return Err(RepairError::InvalidMetadata);
        }
        self.set = Some(set);
        match kind {
            b"PAR 2.0\0Main\0\0\0\0" => {
                if body.len() < 28 || (body.len() - 12) % 16 != 0 || md5::compute(body).0 != set {
                    return Err(RepairError::InvalidMetadata);
                }
                let block = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let count = u32::from_le_bytes(body[8..12].try_into().unwrap()) as usize;
                if block == 0
                    || block % 4 != 0
                    || block > 64 << 20
                    || count == 0
                    || count > 10_000
                    || (body.len() - 12) / 16 > 10_000
                    || count > (body.len() - 12) / 16
                {
                    return Err(RepairError::InvalidMetadata);
                }
                if self.main.as_deref().is_some_and(|old| old != body) {
                    return Err(RepairError::InvalidMetadata);
                }
                self.block_size = block;
                self.ids = body[12..12 + count * 16]
                    .chunks_exact(16)
                    .map(|b| b.try_into().unwrap())
                    .collect();
                if self.ids.iter().collect::<HashSet<_>>().len() != count {
                    return Err(RepairError::InvalidMetadata);
                }
                self.main = Some(body.to_vec());
            }
            b"PAR 2.0\0FileDesc" => {
                if self.descriptions.len() >= 10_000 {
                    return Err(RepairError::InvalidMetadata);
                }
                if body.len() < 60 || body.len() > 312 {
                    return Err(RepairError::InvalidMetadata);
                }
                let end = body
                    .iter()
                    .rposition(|b| *b != 0)
                    .map(|n| n + 1)
                    .unwrap_or(0);
                if end < 57 || body.len() - end > 3 {
                    return Err(RepairError::InvalidMetadata);
                }
                let name = std::str::from_utf8(&body[56..end])
                    .map_err(|_| RepairError::InvalidMetadata)?;
                if !safe_name(name) || name.to_ascii_lowercase().ends_with(".par2") {
                    return Err(RepairError::InvalidMetadata);
                }
                // The File ID excludes filename padding (PAR2 section 4.4).
                let mut hash = md5::Context::new();
                hash.consume(&body[32..56]);
                hash.consume(&body[56..end]);
                let id: [u8; 16] = body[0..16].try_into().unwrap();
                if hash.compute().0 != id {
                    return Err(RepairError::InvalidMetadata);
                }
                let description = Description {
                    id,
                    name: name.into(),
                    size: u64::from_le_bytes(body[48..56].try_into().unwrap()),
                    hash: body[16..32].try_into().unwrap(),
                };
                if self
                    .descriptions
                    .values()
                    .any(|d| d.id != id && d.name.to_lowercase() == name.to_lowercase())
                    || self
                        .descriptions
                        .get(&id)
                        .is_some_and(|d| d != &description)
                {
                    return Err(RepairError::InvalidMetadata);
                }
                self.descriptions.insert(id, description);
            }
            b"PAR 2.0\0IFSC\0\0\0\0" => {
                if body.len() < 16 || (body.len() - 16) % 20 != 0 {
                    return Err(RepairError::InvalidMetadata);
                }
                let id: [u8; 16] = body[..16].try_into().unwrap();
                let value = ((body.len() - 16) / 20, md5::compute(body).0);
                if self.verification.get(&id).is_some_and(|old| old != &value) {
                    return Err(RepairError::InvalidMetadata);
                }
                self.verification.insert(id, value);
                // Bound checksum metadata before handing it to the external
                // tool. Tiny hostile block sizes must not allocate gigabytes.
                if self.verification.len() > 10_000
                    || self
                        .verification
                        .values()
                        .map(|(count, _)| *count)
                        .sum::<usize>()
                        > 1_048_576
                {
                    return Err(RepairError::InvalidMetadata);
                }
            }
            b"PAR 2.0\0Creator\0" => {}
            // Unknown filename extensions (including UniFileN) are rejected,
            // rather than allowing the external tool to interpret unchecked paths.
            _ => return Err(RepairError::UnsupportedPacket),
        }
        Ok(())
    }
    fn protected(&self, cfg: &RepairConfig) -> Result<Vec<Description>, RepairError> {
        if self.main.is_none() {
            return Err(RepairError::NoParity);
        }
        if self
            .recovery
            .values()
            .any(|(len, _)| *len != self.block_size)
        {
            return Err(RepairError::InvalidMetadata);
        }
        let files: Vec<_> = self
            .ids
            .iter()
            .map(|id| {
                self.descriptions
                    .get(id)
                    .cloned()
                    .ok_or(RepairError::InvalidMetadata)
            })
            .collect::<Result<_, _>>()?;
        let total = files
            .iter()
            .try_fold(0u64, |n, f| n.checked_add(f.size))
            .ok_or(RepairError::FileBudget)?;
        for file in &files {
            let blocks = file.size.div_ceil(self.block_size);
            if blocks > 1_048_576
                || self
                    .verification
                    .get(&file.id)
                    .is_none_or(|(count, _)| *count as u64 != blocks)
            {
                return Err(RepairError::InvalidMetadata);
            }
        }
        if total == 0 || total > cfg.max_job_bytes {
            return Err(RepairError::FileBudget);
        }
        // All descriptions, including optional unprotected files, are also bounded.
        if self
            .descriptions
            .values()
            .any(|f| f.size > cfg.max_job_bytes)
        {
            return Err(RepairError::FileBudget);
        }
        Ok(files)
    }
}
async fn parse_parity(path: &Path, metadata: &mut Metadata) -> Result<(), RepairError> {
    let mut file = fs::File::open(path).await?;
    let size = file.metadata().await?.len();
    let mut pos = 0u64;
    while pos < size {
        let mut header = [0u8; 64];
        file.read_exact(&mut header)
            .await
            .map_err(|_| RepairError::InvalidMetadata)?;
        let len = u64::from_le_bytes(header[8..16].try_into().unwrap());
        if &header[..8] != b"PAR2\0PKT"
            || len < 64
            || len % 4 != 0
            || pos.checked_add(len).filter(|end| *end <= size).is_none()
        {
            return Err(RepairError::InvalidMetadata);
        }
        let set: [u8; 16] = header[32..48].try_into().unwrap();
        if metadata.set.is_some_and(|old| old != set) {
            return Err(RepairError::InvalidMetadata);
        }
        let recovery = &header[48..64] == b"PAR 2.0\0RecvSlic";
        if len > (64 << 20) + 68 || (!recovery && len > 4 << 20) {
            return Err(RepairError::InvalidMetadata);
        }
        let mut hash = md5::Context::new();
        hash.consume(&header[32..]);
        let mut remaining = len - 64;
        let mut body = Vec::new();
        let mut buffer = vec![0u8; 64 * 1024];
        while remaining > 0 {
            let n = remaining.min(buffer.len() as u64) as usize;
            file.read_exact(&mut buffer[..n]).await?;
            hash.consume(&buffer[..n]);
            if !recovery {
                body.extend_from_slice(&buffer[..n]);
            } else if body.len() < 4 {
                body.extend_from_slice(&buffer[..n.min(4)]);
            }
            remaining -= n as u64;
        }
        if hash.compute().0 != header[16..32] {
            return Err(RepairError::InvalidMetadata);
        }
        if recovery {
            if len < 72 || (metadata.block_size != 0 && len - 68 != metadata.block_size) {
                return Err(RepairError::InvalidMetadata);
            }
            let exponent = u32::from_le_bytes(body[..4].try_into().unwrap());
            let value = (len - 68, header[16..32].try_into().unwrap());
            if exponent > 65535
                || metadata
                    .recovery
                    .get(&exponent)
                    .is_some_and(|old| old != &value)
            {
                return Err(RepairError::InvalidMetadata);
            }
            metadata.set = Some(set);
            metadata.recovery.insert(exponent, value);
        } else {
            metadata.packet(&header[48..64], &body, set)?;
        }
        pos += len;
    }
    Ok(())
}
async fn run_repair(inner: &Arc<Inner>, e: &Arc<Entry>) -> Result<Ready, RepairError> {
    if e.cancelled.load(Ordering::Acquire) {
        return Err(RepairError::Cancelled);
    }
    e.state.lock().await.phase = "downloading_parity";
    let mut parity_indices: Vec<_> = e
        .nzb
        .files
        .iter()
        .enumerate()
        .filter(|(_, f)| f.subject.to_ascii_lowercase().contains(".par2"))
        .map(|(i, f)| (i, f.total_bytes))
        .collect();
    if parity_indices.is_empty() {
        return Err(RepairError::NoParity);
    }
    parity_indices.sort_by_key(|(_, size)| *size);
    fs::create_dir(e.dir.join("staging")).await?;
    let mut metadata = Metadata::default();
    let mut parity_paths = Vec::new();
    let mut parity_bytes = 0u64;
    for (fi, _) in parity_indices {
        let mut complete = true;
        for si in 0..e.nzb.files[fi].segments.len() {
            if e.state
                .lock()
                .await
                .files
                .get(&fi)
                .is_some_and(|f| f.articles.contains_key(&si))
            {
                continue;
            }
            if let Some(seg) = fetch(inner, e, fi, si).await? {
                parity_bytes = parity_bytes
                    .checked_add(seg.data.len() as u64)
                    .ok_or(RepairError::ParityBudget)?;
                if parity_bytes > inner.cfg.max_parity_bytes {
                    return Err(RepairError::ParityBudget);
                }
                remember(inner, e, &e.nzb.files[fi].segments[si].message_id, &seg).await?;
            } else {
                complete = false;
                break;
            }
        }
        if !complete {
            continue;
        }
        let state = e.state.lock().await;
        let Some(file) = state.files.get(&fi) else {
            continue;
        };
        let mut end = 0u64;
        for r in file.articles.values() {
            if r.begin != end {
                complete = false;
                break;
            }
            end += r.len;
        }
        if end != file.size || !complete {
            continue;
        }
        drop(state);
        let path = e.dir.join("staging").join(format!("recovery-{fi:06}.par2"));
        copy_bounded(&input_path(e, fi), &path, e).await?;
        parse_parity(&path, &mut metadata).await?;
        parity_paths.push(path);
    }
    if parity_paths.is_empty() {
        return Err(RepairError::NoParity);
    }
    let descriptions = metadata.protected(&inner.cfg)?;
    if metadata.recovery.is_empty() {
        return Err(RepairError::InsufficientParity);
    }
    e.state.lock().await.phase = "fetching_supporting_data";
    // Join at most a small number of verified article fetches at once. The pool's
    // own background permits leave foreground playback connection capacity.
    let parity_set: HashSet<usize> = e
        .nzb
        .files
        .iter()
        .enumerate()
        .filter(|(_, f)| f.subject.to_ascii_lowercase().contains(".par2"))
        .map(|(i, _)| i)
        .collect();
    let work: Vec<_> = e
        .nzb
        .files
        .iter()
        .enumerate()
        .filter(|(fi, _)| !parity_set.contains(fi))
        .flat_map(|(fi, f)| (0..f.segments.len()).map(move |si| (fi, si)))
        .collect();
    use futures::{stream, StreamExt, TryStreamExt};
    stream::iter(work.into_iter().map(|(fi, si)| async move {
        if e.state
            .lock()
            .await
            .files
            .get(&fi)
            .is_some_and(|f| f.articles.contains_key(&si))
        {
            return Ok(());
        }
        if let Some(seg) = fetch(inner, e, fi, si).await? {
            remember(inner, e, &e.nzb.files[fi].segments[si].message_id, &seg).await?;
        }
        Ok::<(), RepairError>(())
    }))
    .buffer_unordered(inner.cfg.fetch_parallelism.clamp(1, 8))
    .try_collect::<Vec<_>>()
    .await?;
    let mut mapping = HashMap::new();
    let mut copies = Vec::new();
    {
        let state = e.state.lock().await;
        for description in &descriptions {
            let matching: Vec<_> = state
                .files
                .iter()
                .filter(|(fi, f)| !parity_set.contains(fi) && f.name == description.name)
                .collect();
            if matching.len() > 1 {
                return Err(RepairError::InvalidMetadata);
            }
            if let Some((&fi, file)) = matching.first() {
                if file.size != description.size {
                    return Err(RepairError::InvalidMetadata);
                }
                copies.push((
                    input_path(e, fi),
                    e.dir.join("staging").join(&description.name),
                ));
                mapping.insert(fi, description.clone());
            } else {
                // A wholly missing file can still be reconstructed, but we only
                // map it to the NZB when its quoted name is unambiguous.
                let matches: Vec<_> = e
                    .nzb
                    .files
                    .iter()
                    .enumerate()
                    .filter(|(fi, f)| {
                        !parity_set.contains(fi)
                            && subject_name(&f.subject) == Some(description.name.as_str())
                    })
                    .map(|(fi, _)| fi)
                    .collect();
                if matches.len() == 1 {
                    mapping.insert(matches[0], description.clone());
                }
                reserve(
                    inner,
                    e,
                    description
                        .size
                        .checked_mul(3)
                        .ok_or(RepairError::FileBudget)?,
                )?;
            }
        }
    }
    if mapping.is_empty() {
        return Err(RepairError::Unprotected);
    }
    // Large disk copies must not hold the cache mutex: foreground playback
    // can keep reading its verified buffer while staging the repair input.
    for (from, to) in copies {
        copy_bounded(&from, &to, e).await?;
    }
    e.state.lock().await.phase = "repairing";
    check_free(&e.dir, 0, &inner.cfg)?;
    let mut command = tokio::process::Command::new(&inner.cfg.par2_binary);
    command
        .arg("r")
        .arg("-q")
        .arg(format!("-m{}", inner.cfg.max_memory_mib.clamp(16, 2048)))
        .current_dir(e.dir.join("staging"))
        .kill_on_drop(true)
        .env_clear()
        .env("PATH", "/usr/local/bin:/usr/bin:/bin")
        .env("OMP_NUM_THREADS", "2")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(unix)]
    {
        let file_limit = inner.cfg.max_job_bytes;
        let cpu_limit = inner.cfg.max_job_seconds.max(1).saturating_add(1);
        #[cfg(target_os = "linux")]
        let address_space_limit = (inner.cfg.max_memory_mib.clamp(16, 2048) as u64 * 2 + 256) << 20;
        unsafe {
            command.pre_exec(move || {
                for (resource, limit) in [
                    (libc::RLIMIT_FSIZE, file_limit),
                    (libc::RLIMIT_CPU, cpu_limit),
                ] {
                    let value = libc::rlimit {
                        rlim_cur: limit as libc::rlim_t,
                        rlim_max: limit as libc::rlim_t,
                    };
                    if libc::setrlimit(resource, &value) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                #[cfg(target_os = "linux")]
                {
                    let value = libc::rlimit {
                        rlim_cur: address_space_limit as libc::rlim_t,
                        rlim_max: address_space_limit as libc::rlim_t,
                    };
                    if libc::setrlimit(libc::RLIMIT_AS, &value) != 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                Ok(())
            });
        }
    }
    // Explicit, generated basenames: never place an untrusted filename in an
    // option position, and never let the tool discover unrelated parity files.
    for path in &parity_paths {
        command.arg(format!("./{}", path.file_name().unwrap().to_string_lossy()));
    }
    let status = command
        .spawn()
        .map_err(|_| RepairError::Executable)?
        .wait()
        .await?;
    if !status.success() {
        return Err(RepairError::InsufficientParity);
    }
    e.state.lock().await.phase = "verifying";
    for description in &descriptions {
        verify_file(&e.dir.join("staging").join(&description.name), description).await?;
    }
    // Only verified source files survive publication. Backups and parity are
    // temporary; retained input articles remain available for ordinary seeks.
    fs::create_dir(e.dir.join("verified-next")).await?;
    for description in &descriptions {
        fs::rename(
            e.dir.join("staging").join(&description.name),
            e.dir.join("verified-next").join(&description.name),
        )
        .await?;
    }
    fs::rename(e.dir.join("verified-next"), e.dir.join("verified")).await?;
    fs::remove_dir_all(e.dir.join("staging")).await?;
    Ok(Ready {
        files: mapping
            .into_iter()
            .map(|(fi, d)| {
                (
                    fi,
                    ReadyFile {
                        path: e.dir.join("verified").join(&d.name),
                        name: d.name,
                        size: d.size,
                    },
                )
            })
            .collect(),
    })
}
fn subject_name(subject: &str) -> Option<&str> {
    let mut quotes = subject.split('"');
    quotes.next()?;
    let name = quotes.next()?;
    safe_name(name).then_some(name)
}
async fn verify_file(path: &Path, d: &Description) -> Result<(), RepairError> {
    let meta = fs::symlink_metadata(path).await?;
    if !meta.file_type().is_file() || meta.len() != d.size {
        return Err(RepairError::Verification);
    }
    let mut file = fs::File::open(path).await?;
    let mut hash = md5::Context::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        hash.consume(&buf[..n]);
    }
    if hash.compute().0 != d.hash {
        return Err(RepairError::Verification);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nzb::{NzbFile, Segment};
    struct Fixture {
        root: PathBuf,
        nzb: Arc<Nzb>,
        segments: Vec<(String, DecodedSegment)>,
        original: Vec<u8>,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    fn temporary() -> PathBuf {
        let mut bytes = [0u8; 12];
        getrandom::getrandom(&mut bytes).unwrap();
        let name: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("velvet-repair-test-{name}"));
        std::fs::create_dir(&path).unwrap();
        path
    }
    fn par2() -> Option<String> {
        std::env::var("VELVET_TEST_PAR2").ok().or_else(|| {
            [
                "/usr/bin/par2",
                "/usr/local/bin/par2",
                "/opt/homebrew/bin/par2",
            ]
            .into_iter()
            .find(|p| Path::new(p).exists())
            .map(str::to_owned)
        })
    }
    fn config(root: &Path) -> RepairConfig {
        RepairConfig {
            enabled: true,
            cache_dir: root.join("cache").display().to_string(),
            par2_binary: par2().unwrap_or_else(|| "par2".into()),
            max_job_bytes: 8 << 20,
            max_cache_bytes: 64 << 20,
            max_download_bytes: 16 << 20,
            max_parity_bytes: 8 << 20,
            min_free_bytes: 0,
            max_job_seconds: 20,
            ..Default::default()
        }
    }
    fn fixture() -> Option<Fixture> {
        let Some(binary) = par2() else {
            eprintln!(
                "real PAR2 test skipped: set VELVET_TEST_PAR2 to the official par2 executable"
            );
            return None;
        };
        let root = temporary();
        let original: Vec<u8> = (0..190_313u32)
            .map(|i| ((i.wrapping_mul(71) ^ (i >> 8) ^ (i >> 16)) % 251) as u8)
            .collect();
        std::fs::write(root.join("episode.mkv"), &original).unwrap();
        let support: Vec<u8> = (0..35_713u32)
            .map(|i| ((i * 31 + (i >> 9)) % 249) as u8)
            .collect();
        std::fs::write(root.join("archive.r00"), &support).unwrap();
        let status = std::process::Command::new(binary)
            .args([
                "c",
                "-q",
                "-s4096",
                "-c12",
                "-n1",
                "set.par2",
                "episode.mkv",
                "archive.r00",
            ])
            .current_dir(&root)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success());
        let mut names: Vec<_> = std::fs::read_dir(&root)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        let mut files = Vec::new();
        let mut segments = Vec::new();
        for name in names {
            let data = std::fs::read(root.join(&name)).unwrap();
            let mut offset = 0usize;
            let mut entries = Vec::new();
            let mut number = 1;
            while offset < data.len() {
                let len = (if name == "episode.mkv" {
                    match number % 3 {
                        0 => 9_771,
                        1 => 8_003,
                        _ => 12_099,
                    }
                } else {
                    24_000
                })
                .min(data.len() - offset);
                let id = format!("{name}-{number}@fixture.invalid");
                let part = DecodedSegment {
                    data: data[offset..offset + len].to_vec(),
                    part_begin: Some(offset as u64 + 1),
                    part_end: Some((offset + len) as u64),
                    total_size: Some(data.len() as u64),
                    name: Some(name.clone()),
                };
                entries.push(Segment {
                    number,
                    bytes: (len + 2048) as u64,
                    message_id: id.clone(),
                });
                segments.push((id, part));
                offset += len;
                number += 1;
            }
            files.push(NzbFile {
                subject: format!("\"{name}\" yEnc"),
                groups: vec!["fixture".into()],
                total_bytes: entries.iter().map(|s| s.bytes).sum(),
                segments: entries,
            });
        }
        Some(Fixture {
            root,
            nzb: Arc::new(Nzb { files }),
            segments,
            original,
        })
    }
    async fn remember_except(
        reg: &RepairRegistry,
        fixture: &Fixture,
        missing: &[&str],
        corrupt: Option<&str>,
    ) {
        reg.register("test", fixture.nzb.clone()).await.unwrap();
        for (id, seg) in &fixture.segments {
            if missing.contains(&id.as_str()) {
                continue;
            }
            let mut seg = seg.clone();
            if corrupt == Some(id.as_str()) {
                seg.data[100] ^= 0x55;
            }
            reg.remember("test", id, &seg).await.unwrap();
        }
    }
    #[tokio::test]
    async fn real_par2_repairs_exact_bytes_across_files_and_unequal_article_sizes() {
        let Some(f) = fixture() else {
            return;
        };
        let reg = RepairRegistry::new(config(&f.root), Pool::new(&[]));
        let missing = "episode.mkv-4@fixture.invalid";
        let corrupt = "archive.r00-1@fixture.invalid";
        remember_except(&reg, &f, &[missing], Some(corrupt)).await;
        let (a, b) = tokio::join!(reg.recover("test", missing), reg.recover("test", missing));
        let expected = &f.segments.iter().find(|(id, _)| id == missing).unwrap().1;
        assert_eq!(a.unwrap().data, expected.data);
        assert_eq!(b.unwrap().data, expected.data);
        let full = reg
            .read_range("test", missing, 0, f.original.len())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(full, f.original);
        assert_eq!(reg.status("test").await.unwrap().phase, "ready");
    }
    #[tokio::test]
    async fn consecutive_holes_require_exact_file_range_not_guessed_article_size() {
        let Some(f) = fixture() else {
            return;
        };
        let reg = RepairRegistry::new(config(&f.root), Pool::new(&[]));
        let id = "episode.mkv-4@fixture.invalid";
        remember_except(&reg, &f, &[id, "episode.mkv-5@fixture.invalid"], None).await;
        assert!(matches!(
            reg.recover("test", id).await,
            Err(RepairError::AmbiguousRange)
        ));
        assert_eq!(
            reg.read_range("test", id, 7_999, 30_127)
                .await
                .unwrap()
                .unwrap(),
            f.original[7_999..38_126]
        );
    }
    #[tokio::test]
    async fn insufficient_parity_never_publishes_sparse_zeros() {
        let Some(f) = fixture() else {
            return;
        };
        let reg = RepairRegistry::new(config(&f.root), Pool::new(&[]));
        reg.register("test", f.nzb.clone()).await.unwrap();
        for (id, seg) in &f.segments {
            if !id.starts_with("episode.mkv-") || id == "episode.mkv-1@fixture.invalid" {
                reg.remember("test", id, seg).await.unwrap();
            }
        }
        let id = "episode.mkv-4@fixture.invalid";
        assert!(matches!(
            reg.recover_file("test", id).await,
            Err(RepairError::InsufficientParity)
        ));
        assert!(reg.read_range("test", id, 0, 8).await.unwrap().is_none());
    }
    #[tokio::test]
    async fn executable_success_is_not_trusted_without_full_file_verification() {
        use std::os::unix::fs::PermissionsExt;
        let Some(f) = fixture() else {
            return;
        };
        let fake = f.root.join("fake-par2");
        std::fs::write(&fake, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut cfg = config(&f.root);
        cfg.par2_binary = fake.display().to_string();
        let reg = RepairRegistry::new(cfg, Pool::new(&[]));
        let id = "episode.mkv-4@fixture.invalid";
        remember_except(&reg, &f, &[id], None).await;
        assert!(matches!(
            reg.recover_file("test", id).await,
            Err(RepairError::Verification)
        ));
        assert!(reg.read_range("test", id, 0, 8).await.unwrap().is_none());
    }
    #[tokio::test]
    async fn deadline_and_cancellation_stop_repair_without_publishing() {
        use std::os::unix::fs::PermissionsExt;
        let Some(f) = fixture() else {
            return;
        };
        let fake = f.root.join("slow-par2");
        std::fs::write(&fake, "#!/bin/sh\nexec sleep 30\n").unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut cfg = config(&f.root);
        cfg.par2_binary = fake.display().to_string();
        cfg.max_job_seconds = 1;
        let reg = RepairRegistry::new(cfg, Pool::new(&[]));
        let id = "episode.mkv-4@fixture.invalid";
        remember_except(&reg, &f, &[id], None).await;
        assert!(matches!(
            reg.recover_file("test", id).await,
            Err(RepairError::Timeout)
        ));
        assert!(reg.read_range("test", id, 0, 8).await.unwrap().is_none());
        reg.cancel("test").await;
        assert!(reg.status("test").await.is_none());
        remember_except(&reg, &f, &[id], None).await;
        let r = reg.clone();
        let task = tokio::spawn(async move { r.recover_file("test", id).await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        reg.cancel("test").await;
        assert!(matches!(task.await.unwrap(), Err(RepairError::Cancelled)));
    }
    #[tokio::test]
    async fn cache_disk_and_size_limits_are_checked_before_retaining_data() {
        let root = temporary();
        let segment = DecodedSegment {
            data: vec![1; 32],
            part_begin: Some(1),
            part_end: Some(32),
            total_size: Some(32),
            name: Some("movie.mkv".into()),
        };
        let nzb = Arc::new(Nzb {
            files: vec![NzbFile {
                subject: "movie.mkv".into(),
                groups: vec![],
                segments: vec![Segment {
                    number: 1,
                    bytes: 100,
                    message_id: "a".into(),
                }],
                total_bytes: 100,
            }],
        });
        for (index, expected) in [
            RepairError::CacheBudget,
            RepairError::LowDisk,
            RepairError::FileBudget,
        ]
        .into_iter()
        .enumerate()
        {
            let mut cfg = config(&root);
            cfg.cache_dir = root.join(format!("cache{index}")).display().to_string();
            if index == 0 {
                cfg.max_cache_bytes = 1;
            } else if index == 1 {
                cfg.min_free_bytes = u64::MAX;
            } else {
                cfg.max_job_bytes = 16;
            }
            let reg = RepairRegistry::new(cfg, Pool::new(&[]));
            reg.register("test", nzb.clone()).await.unwrap();
            assert_eq!(
                reg.remember("test", "a", &segment).await.unwrap_err(),
                expected
            );
            assert!(reg.read("test", "a").await.is_none());
        }
        let _ = std::fs::remove_dir_all(root);
    }
    #[tokio::test]
    async fn no_parity_is_explicit_and_cancellation_releases_cache_reservation() {
        let root = temporary();
        let reg = RepairRegistry::new(config(&root), Pool::new(&[]));
        let nzb = Arc::new(Nzb {
            files: vec![NzbFile {
                subject: "movie.mkv".into(),
                groups: vec![],
                segments: vec![Segment {
                    number: 1,
                    bytes: 100,
                    message_id: "a".into(),
                }],
                total_bytes: 100,
            }],
        });
        reg.register("test", nzb).await.unwrap();
        let seg = DecodedSegment {
            data: vec![1; 32],
            part_begin: Some(1),
            part_end: Some(32),
            total_size: Some(32),
            name: Some("movie.mkv".into()),
        };
        reg.remember("test", "a", &seg).await.unwrap();
        assert!(matches!(
            reg.recover_file("test", "a").await,
            Err(RepairError::NoParity)
        ));
        assert_eq!(reg.inner.reserved.load(Ordering::Relaxed), 96);
        reg.cancel("test").await;
        tokio::task::yield_now().await;
        assert_eq!(reg.inner.reserved.load(Ordering::Relaxed), 0);
        drop(reg);
        let _ = std::fs::remove_dir_all(root);
    }
    #[test]
    fn unsafe_names_and_unicode_extension_packets_fail_closed() {
        for name in [
            "../escape",
            "/tmp/escape",
            "C:\\escape",
            "movie/part",
            "movie\\part",
            ".hidden",
            "movie\0x",
            "name\n",
            "movie.",
            "",
        ] {
            assert!(!safe_name(name), "{name:?}");
        }
        assert!(safe_name("Café episode.mkv"));
        let mut meta = Metadata::default();
        assert_eq!(
            meta.packet(b"PAR 2.0\0UniFileN", b"unchecked Unicode filename", [0; 16])
                .unwrap_err(),
            RepairError::UnsupportedPacket
        );
    }
    #[tokio::test]
    async fn packet_corruption_and_truncation_are_rejected_before_external_tool() {
        let Some(f) = fixture() else {
            return;
        };
        let path = f.root.join("set.par2");
        let original = fs::read(&path).await.unwrap();
        let mut changed = original.clone();
        changed[100] ^= 1;
        fs::write(&path, &changed).await.unwrap();
        assert_eq!(
            parse_parity(&path, &mut Metadata::default())
                .await
                .unwrap_err(),
            RepairError::InvalidMetadata
        );
        fs::write(&path, &original[..original.len() - 3])
            .await
            .unwrap();
        assert_eq!(
            parse_parity(&path, &mut Metadata::default())
                .await
                .unwrap_err(),
            RepairError::InvalidMetadata
        );
    }
    #[tokio::test]
    async fn exclusive_cache_owner_reaps_only_its_crash_leftovers() {
        let root = temporary();
        let cfg = config(&root);
        std::fs::create_dir_all(&cfg.cache_dir).unwrap();
        let old = Path::new(&cfg.cache_dir).join("job-00000000000000000000000000000000");
        std::fs::create_dir(&old).unwrap();
        let keep = Path::new(&cfg.cache_dir).join("unrelated");
        std::fs::create_dir(&keep).unwrap();
        let first = RepairRegistry::new(cfg.clone(), Pool::new(&[]));
        assert!(!old.exists());
        assert!(keep.exists());
        let second = RepairRegistry::new(cfg, Pool::new(&[]));
        assert_eq!(
            second
                .register("test", Arc::new(Nzb { files: vec![] }))
                .await
                .unwrap_err(),
            RepairError::CacheBudget
        );
        drop(first);
        drop(second);
        let _ = std::fs::remove_dir_all(root);
    }
}
