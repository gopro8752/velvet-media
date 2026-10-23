//! Multi-provider NNTP connection pool.
//!
//! Each provider gets a semaphore whose permits ARE its live connections, so the
//! total open sockets can never exceed `max_connections` (a permit travels with
//! a connection for its whole life — idle or in-use — and is released only when
//! the connection is dropped). Connections are reused from an idle stack.
//!
//! `fetch` walks providers in config order: a segment that's `Missing` on one
//! provider is retried on the next, and only a segment missing EVERYWHERE returns
//! `Missing` to the caller (who can reject the incomplete release). This is the
//! reliability story — no queue, no wedge, and every provider adds both
//! redundancy and throughput.

use std::future::Future;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Instant;

use serde::Serialize;

use tokio::sync::{Mutex, Notify, OwnedSemaphorePermit, Semaphore};

use crate::config::Provider;
use crate::nntp::{ArticleBody, NntpConn};

/// Shared byte budget for a repair job, including every provider retry. A BODY
/// reserves its maximum possible wire payload first. Complete reads refund the
/// unused reservation; interrupted attempts retain it conservatively.
pub struct FetchBudget {
    limit: u64,
    remaining: std::sync::atomic::AtomicU64,
}
#[derive(Debug)]
pub struct FetchBudgetExceeded;
impl FetchBudget {
    pub fn new(limit: u64) -> Self {
        Self {
            limit,
            remaining: std::sync::atomic::AtomicU64::new(limit),
        }
    }
    pub fn used(&self) -> u64 {
        self.limit
            .saturating_sub(self.remaining.load(std::sync::atomic::Ordering::Relaxed))
    }
    fn reserve(&self) -> Result<usize, FetchBudgetExceeded> {
        self.remaining
            .fetch_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |left| {
                    if left == 0 {
                        None
                    } else {
                        Some(left.saturating_sub(crate::nntp::MAX_ARTICLE_BYTES as u64))
                    }
                },
            )
            .map(|left| left.min(crate::nntp::MAX_ARTICLE_BYTES as u64) as usize)
            .map_err(|_| FetchBudgetExceeded)
    }
    fn finish(&self, reserved: usize, used: usize) {
        self.remaining.fetch_add(
            reserved.saturating_sub(used) as u64,
            std::sync::atomic::Ordering::Relaxed,
        );
    }
}

/// Cumulative counters are scoped to this Pool's lifetime. `free_connections`
/// includes reusable idle sockets; `unused_slots` counts only unopened slots.
/// Opening/authenticating connections consume a busy slot but are not connected
/// until NNTP authentication succeeds. Article bytes exclude NNTP/TLS overhead
/// and partial bodies from failed/cancelled requests.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ProviderMetrics {
    pub capacity: u64,
    pub open_connections: u64,
    pub connected_connections: u64,
    pub opening_connections: u64,
    pub idle_connections: u64,
    pub busy_connections: u64,
    pub free_connections: u64,
    pub unused_slots: u64,
    pub waiters: u64,
    pub queue_wait_count: u64,
    pub queue_wait_completed: u64,
    pub queue_wait_cancelled: u64,
    pub queue_wait_micros: u64,
    pub connection_attempts: u64,
    pub connection_errors: u64,
    pub articles_found: u64,
    pub articles_missing: u64,
    pub article_errors: u64,
    pub bytes_downloaded: u64,
    pub fallback_attempts: u64,
    pub fallback_successes: u64,
    pub stat_found: u64,
    pub stat_missing: u64,
    pub stat_errors: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ProviderMetricsSnapshot {
    /// Stable across capacity changes and provider reordering. Exact duplicate
    /// entries are disambiguated by their ordinal among those duplicates.
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub tls: bool,
    pub metrics: ProviderMetrics,
}

#[derive(Debug, Clone, Serialize)]
pub struct PoolMetricsSnapshot {
    pub uptime_seconds: f64,
    pub total: ProviderMetrics,
    pub providers: Vec<ProviderMetricsSnapshot>,
}

impl ProviderMetrics {
    fn refresh_capacity(&mut self) {
        self.free_connections = self.capacity.saturating_sub(self.busy_connections);
        self.unused_slots = self.capacity.saturating_sub(self.open_connections);
    }

    fn add(&mut self, other: &Self) {
        macro_rules! sum { ($($field:ident),+ $(,)?) => { $(self.$field = self.$field.saturating_add(other.$field);)+ }; }
        sum!(
            capacity,
            open_connections,
            connected_connections,
            opening_connections,
            idle_connections,
            busy_connections,
            free_connections,
            unused_slots,
            waiters,
            queue_wait_count,
            queue_wait_completed,
            queue_wait_cancelled,
            queue_wait_micros,
            connection_attempts,
            connection_errors,
            articles_found,
            articles_missing,
            article_errors,
            bytes_downloaded,
            fallback_attempts,
            fallback_successes,
            stat_found,
            stat_missing,
            stat_errors
        );
    }
}

/// A short synchronous lock makes each provider snapshot internally consistent.
/// Never hold it across an await or while acquiring the idle-stack lock.
struct Metrics(StdMutex<ProviderMetrics>);

impl Metrics {
    fn new(capacity: usize) -> Arc<Self> {
        let mut value = ProviderMetrics {
            capacity: capacity as u64,
            ..Default::default()
        };
        value.refresh_capacity();
        Arc::new(Self(StdMutex::new(value)))
    }

    fn update(&self, update: impl FnOnce(&mut ProviderMetrics)) {
        let mut value = self.0.lock().unwrap_or_else(|e| e.into_inner());
        update(&mut value);
        value.refresh_capacity();
    }

    fn snapshot(&self) -> ProviderMetrics {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

#[derive(Clone, Copy)]
enum SlotState {
    Opening,
    Busy,
    Idle,
}

/// Follows the socket through connect, checkout, handback, errors and task
/// cancellation. Dropping an in-flight request therefore cannot leak a gauge.
struct SlotMetrics {
    metrics: Arc<Metrics>,
    state: SlotState,
}

impl SlotMetrics {
    fn opening(metrics: &Arc<Metrics>) -> Self {
        metrics.update(|m| {
            m.open_connections += 1;
            m.opening_connections += 1;
            m.busy_connections += 1;
            m.connection_attempts += 1;
        });
        Self {
            metrics: metrics.clone(),
            state: SlotState::Opening,
        }
    }

    fn connected(&mut self) {
        debug_assert!(matches!(self.state, SlotState::Opening));
        self.metrics.update(|m| {
            m.opening_connections -= 1;
            m.connected_connections += 1;
        });
        self.state = SlotState::Busy;
    }

    fn checkout(&mut self) {
        debug_assert!(matches!(self.state, SlotState::Idle));
        self.metrics.update(|m| {
            m.idle_connections -= 1;
            m.busy_connections += 1;
        });
        self.state = SlotState::Busy;
    }

    fn checkin(&mut self) {
        debug_assert!(matches!(self.state, SlotState::Busy));
        self.metrics.update(|m| {
            m.busy_connections -= 1;
            m.idle_connections += 1;
        });
        self.state = SlotState::Idle;
    }
}

impl Drop for SlotMetrics {
    fn drop(&mut self) {
        self.metrics.update(|m| {
            m.open_connections -= 1;
            match self.state {
                SlotState::Opening => {
                    m.opening_connections -= 1;
                    m.busy_connections -= 1;
                }
                SlotState::Busy => {
                    m.connected_connections -= 1;
                    m.busy_connections -= 1;
                }
                SlotState::Idle => {
                    m.connected_connections -= 1;
                    m.idle_connections -= 1;
                }
            }
        });
    }
}

/// Queueing starts only if acquiring a new slot actually polls Pending. It
/// survives notification/retry loops and completes before connecting, so socket
/// setup latency is not incorrectly reported as queue pressure.
struct QueueWait {
    metrics: Arc<Metrics>,
    started: Option<Instant>,
}

impl QueueWait {
    fn new(metrics: &Arc<Metrics>) -> Self {
        Self {
            metrics: metrics.clone(),
            started: None,
        }
    }

    fn pending(&mut self) {
        if self.started.is_none() {
            self.started = Some(Instant::now());
            self.metrics.update(|m| {
                m.waiters += 1;
                m.queue_wait_count += 1;
            });
        }
    }

    fn finish(&mut self, cancelled: bool) {
        if let Some(started) = self.started.take() {
            let micros = started.elapsed().as_micros().min(u64::MAX as u128) as u64;
            self.metrics.update(|m| {
                m.waiters -= 1;
                m.queue_wait_micros = m.queue_wait_micros.saturating_add(micros);
                if cancelled {
                    m.queue_wait_cancelled += 1;
                } else {
                    m.queue_wait_completed += 1;
                }
            });
        }
    }
}

impl Drop for QueueWait {
    fn drop(&mut self) {
        self.finish(true);
    }
}

/// A live connection carrying its provider-slot permit; dropping it frees the slot.
struct PooledConn {
    inner: NntpConn,
    _metrics: SlotMetrics,
    _permit: OwnedSemaphorePermit,
}

struct ProviderPool {
    provider: Provider,
    sem: Arc<Semaphore>,
    idle: Mutex<Vec<PooledConn>>,
    available: Notify,
    metrics: Arc<Metrics>,
}

impl ProviderPool {
    fn new(provider: Provider) -> Self {
        let sem = Arc::new(Semaphore::new(provider.max_connections.max(1)));
        let metrics = Metrics::new(provider.max_connections.max(1));
        ProviderPool {
            provider,
            sem,
            idle: Mutex::new(Vec::new()),
            available: Notify::new(),
            metrics,
        }
    }

    fn metrics_identity(&self) -> u64 {
        // Stable FNV-1a identifier over public provider metadata only. Unlike a
        // process-random hasher, it remains usable in persisted history.
        let mut hash = 0xcbf29ce484222325u64;
        let identity = format!(
            "{}\0{}\0{}\0{}",
            self.provider.name,
            self.provider.host.to_ascii_lowercase(),
            self.provider.port,
            self.provider.tls
        );
        for byte in identity.bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        hash
    }

    /// Get a connection: reuse an idle one, else open a new one under a permit.
    async fn checkout(&self) -> Result<PooledConn, crate::nntp::NntpError> {
        let mut wait = QueueWait::new(&self.metrics);
        loop {
            // A checked-in socket keeps its semaphore permit. Waiting only for
            // a new permit deadlocked when every connection had been opened.
            // Register before inspecting idle to avoid missing a handback.
            let available = self.available.notified();
            tokio::pin!(available);
            available.as_mut().enable();
            if let Some(mut c) = self.idle.lock().await.pop() {
                c._metrics.checkout();
                wait.finish(false);
                return Ok(c);
            }
            let acquire = self.sem.clone().acquire_owned();
            tokio::pin!(acquire);
            let acquire = futures::future::poll_fn(|cx| {
                let result = acquire.as_mut().poll(cx);
                if result.is_pending() {
                    wait.pending();
                }
                result
            });
            tokio::select! {
                biased;
                _ = &mut available => continue,
                permit = acquire => {
                    let permit = permit.expect("semaphore closed");
                    wait.finish(false);
                    let mut metrics = SlotMetrics::opening(&self.metrics);
                    let inner = match NntpConn::connect(&self.provider).await {
                        Ok(inner) => inner,
                        Err(error) => {
                            self.metrics.update(|m| m.connection_errors += 1);
                            return Err(error);
                        }
                    };
                    metrics.connected();
                    return Ok(PooledConn { inner, _metrics: metrics, _permit: permit });
                }
            }
        }
    }

    async fn checkin(&self, mut conn: PooledConn) {
        let mut idle = self.idle.lock().await;
        // Bound idle retention near the connection cap; extra ones drop (freeing slots).
        if idle.len() < self.provider.max_connections.max(1) {
            conn._metrics.checkin();
            idle.push(conn);
            self.available.notify_one();
        }
    }

    /// STAT one segment on THIS provider: Some(true)=present, Some(false)=missing
    /// (confirmed 430), None=couldn't check (connection/timeout). STAT is by
    /// message-id and needs no GROUP. Retries transient errors before giving up.
    async fn stat(&self, message_id: &str) -> Option<bool> {
        // Two tries: a reused pooled socket can be half-dead; a fresh one usually
        // works. More than that just churns connections and slows the sweep.
        for _ in 0..2 {
            let mut conn = match self.checkout().await {
                Ok(c) => c,
                Err(_) => return None,
            };
            match conn.inner.stat(message_id).await {
                Ok(present) => {
                    self.metrics.update(|m| {
                        if present {
                            m.stat_found += 1;
                        } else {
                            m.stat_missing += 1;
                        }
                    });
                    self.checkin(conn).await;
                    return Some(present);
                }
                Err(_) => {
                    self.metrics.update(|m| m.stat_errors += 1);
                    continue; // drop the broken conn, retry fresh
                }
            }
        }
        None
    }

    /// Try to fetch one segment from THIS provider. Reconnects once on an I/O
    /// error (a stale pooled socket), then gives up (caller tries next provider).
    async fn fetch(&self, group: &str, message_id: &str) -> ProviderOutcome {
        self.fetch_budgeted(group, message_id, None)
            .await
            .unwrap_or(ProviderOutcome::ProviderDown)
    }

    async fn fetch_budgeted(
        &self,
        group: &str,
        message_id: &str,
        budget: Option<&FetchBudget>,
    ) -> Result<ProviderOutcome, FetchBudgetExceeded> {
        for attempt in 0..2 {
            let mut conn = match self.checkout().await {
                Ok(c) => c,
                Err(_) => return Ok(ProviderOutcome::ProviderDown),
            };
            if !group.is_empty() {
                if let Err(_) = conn.inner.group(group).await {
                    self.metrics.update(|m| m.article_errors += 1);
                    // Broken socket — drop it (frees the slot) and retry fresh once.
                    if attempt == 0 {
                        continue;
                    }
                    return Ok(ProviderOutcome::ProviderDown);
                }
            }
            let reserved = match budget {
                Some(budget) => budget.reserve()?,
                None => crate::nntp::MAX_ARTICLE_BYTES,
            };
            // Bound the entire article, not just each line: a trickling peer
            // cannot keep a foreground request alive indefinitely.
            let body = tokio::time::timeout(
                std::time::Duration::from_secs(20),
                conn.inner.body_with_limit(message_id, reserved),
            )
            .await
            .unwrap_or(Err(crate::nntp::NntpError::Timeout));
            match body {
                Ok(ArticleBody::Found(raw)) => {
                    if let Some(budget) = budget {
                        budget.finish(reserved, conn.inner.body_wire_bytes());
                    }
                    self.metrics.update(|m| {
                        m.articles_found += 1;
                        m.bytes_downloaded = m.bytes_downloaded.saturating_add(raw.len() as u64);
                    });
                    self.checkin(conn).await;
                    return Ok(ProviderOutcome::Found(raw));
                }
                Ok(ArticleBody::Missing) => {
                    if let Some(budget) = budget {
                        budget.finish(reserved, 0);
                    }
                    self.metrics.update(|m| m.articles_missing += 1);
                    self.checkin(conn).await;
                    return Ok(ProviderOutcome::Missing);
                }
                Err(_) => {
                    self.metrics.update(|m| m.article_errors += 1);
                    // Drop the broken conn; retry once with a fresh one.
                    if attempt == 0 {
                        continue;
                    }
                    return Ok(ProviderOutcome::ProviderDown);
                }
            }
        }
        Ok(ProviderOutcome::ProviderDown)
    }
}

enum ProviderOutcome {
    Found(Vec<u8>),
    Missing,
    ProviderDown,
}

pub struct Pool {
    providers: Vec<ProviderPool>,
    /// Shared across every verification sweep, rather than a limit per title.
    background: Semaphore,
    started: Instant,
    strict: bool,
}

/// Result of fetching a segment across all providers.
pub enum Fetched {
    /// Raw article body (dot-unstuffed) ready for `yenc::decode`.
    Found(Vec<u8>),
    /// No provider returned this article (legacy archive-reader interface).
    Missing,
}

/// Streaming must distinguish confirmed holes from a temporarily offline
/// provider. Only the former belong in the bad-release ledger.
pub enum CheckedFetch {
    Found(Vec<u8>),
    Missing,
    Unavailable,
}

/// Validated beta media fetch. A corrupt BODY is retried on the next provider,
/// rather than selecting a different release or caching damaged bytes.
#[derive(Debug)]
pub enum DecodedFetch {
    Found(crate::yenc::DecodedSegment),
    Missing,
    Corrupt,
    Unavailable,
}

impl Pool {
    pub fn new(providers: &[Provider]) -> Arc<Pool> {
        Self::new_verified(providers, false)
    }

    pub fn new_verified(providers: &[Provider], strict: bool) -> Arc<Pool> {
        Arc::new(Pool {
            strict,
            providers: providers.iter().cloned().map(ProviderPool::new).collect(),
            background: Semaphore::new(background_capacity(providers)),
            started: Instant::now(),
        })
    }

    pub fn total_capacity(&self) -> usize {
        self.providers
            .iter()
            .map(|p| p.provider.max_connections.max(1))
            .sum()
    }

    /// Safe to sample during traffic. Provider gauges are individually atomic;
    /// the aggregate is their sum, sampled without holding a lock across I/O.
    pub async fn metrics_snapshot(&self) -> PoolMetricsSnapshot {
        let mut total = ProviderMetrics::default();
        let providers = self
            .providers
            .iter()
            .enumerate()
            .map(|(index, pp)| {
                let metrics = pp.metrics.snapshot();
                total.add(&metrics);
                let identity = pp.metrics_identity();
                let duplicate = self.providers[..index]
                    .iter()
                    .filter(|prior| prior.metrics_identity() == identity)
                    .count();
                ProviderMetricsSnapshot {
                    id: format!("provider-{identity:016x}-{duplicate}"),
                    name: pp.provider.name.clone(),
                    host: pp.provider.host.clone(),
                    port: pp.provider.port,
                    tls: pp.provider.tls,
                    metrics,
                }
            })
            .collect();
        PoolMetricsSnapshot {
            uptime_seconds: self.started.elapsed().as_secs_f64(),
            total,
            providers,
        }
    }

    /// Fetch a segment, trying every provider before declaring it missing.
    pub async fn fetch(&self, group: &str, message_id: &str) -> Fetched {
        match self.fetch_checked(group, message_id).await {
            CheckedFetch::Found(raw) => Fetched::Found(raw),
            CheckedFetch::Missing | CheckedFetch::Unavailable => Fetched::Missing,
        }
    }

    pub async fn fetch_checked(&self, group: &str, message_id: &str) -> CheckedFetch {
        let mut all_missing = !self.providers.is_empty();
        for (index, pp) in self.providers.iter().enumerate() {
            if index > 0 {
                pp.metrics.update(|m| m.fallback_attempts += 1);
            }
            match pp.fetch(group, message_id).await {
                ProviderOutcome::Found(raw) => {
                    if self.strict && crate::yenc::decode_verified(&raw).is_err() {
                        pp.metrics.update(|m| m.article_errors += 1);
                        continue;
                    }
                    if index > 0 {
                        pp.metrics.update(|m| m.fallback_successes += 1);
                    }
                    return CheckedFetch::Found(raw);
                }
                ProviderOutcome::Missing => { /* try next provider */ }
                ProviderOutcome::ProviderDown => {
                    all_missing = false;
                }
            }
        }
        if all_missing {
            CheckedFetch::Missing
        } else {
            CheckedFetch::Unavailable
        }
    }

    pub async fn fetch_decoded(&self, group: &str, message_id: &str) -> DecodedFetch {
        self.fetch_decoded_observed(group, message_id).await.0
    }

    /// Whether another provider rescued this exact validated article. Kept per
    /// request rather than inferred by subtracting shared concurrent counters.
    pub async fn fetch_decoded_observed(
        &self,
        group: &str,
        message_id: &str,
    ) -> (DecodedFetch, bool) {
        self.fetch_decoded_inner(group, message_id, None)
            .await
            .unwrap_or((DecodedFetch::Unavailable, false))
    }

    pub async fn fetch_decoded_budgeted(
        &self,
        group: &str,
        message_id: &str,
        budget: &FetchBudget,
    ) -> Result<DecodedFetch, FetchBudgetExceeded> {
        self.fetch_decoded_budgeted_observed(group, message_id, budget)
            .await
            .map(|r| r.0)
    }

    pub async fn fetch_decoded_budgeted_observed(
        &self,
        group: &str,
        message_id: &str,
        budget: &FetchBudget,
    ) -> Result<(DecodedFetch, bool), FetchBudgetExceeded> {
        self.fetch_decoded_inner(group, message_id, Some(budget))
            .await
    }

    async fn fetch_decoded_inner(
        &self,
        group: &str,
        message_id: &str,
        budget: Option<&FetchBudget>,
    ) -> Result<(DecodedFetch, bool), FetchBudgetExceeded> {
        let mut unavailable = self.providers.is_empty();
        let mut corrupt = false;
        for (index, pp) in self.providers.iter().enumerate() {
            if index > 0 {
                pp.metrics.update(|m| m.fallback_attempts += 1);
            }
            match pp.fetch_budgeted(group, message_id, budget).await? {
                ProviderOutcome::Found(raw) => match crate::yenc::decode_verified(&raw) {
                    Ok(decoded) => {
                        if index > 0 {
                            pp.metrics.update(|m| m.fallback_successes += 1);
                        }
                        return Ok((DecodedFetch::Found(decoded), index > 0));
                    }
                    Err(_) => {
                        corrupt = true;
                        pp.metrics.update(|m| m.article_errors += 1);
                    }
                },
                ProviderOutcome::Missing => {}
                ProviderOutcome::ProviderDown => unavailable = true,
            }
        }
        if unavailable {
            Ok((DecodedFetch::Unavailable, false))
        } else if corrupt {
            Ok((DecodedFetch::Corrupt, false))
        } else {
            Ok((DecodedFetch::Missing, false))
        }
    }

    pub async fn background_permit(&self) -> tokio::sync::SemaphorePermit<'_> {
        self.background.acquire().await.expect("semaphore closed")
    }

    /// Present if any provider confirms it, missing only if ALL providers
    /// confirm absence. A provider outage leaves the answer unknown.
    pub async fn present_anywhere(&self, message_id: &str) -> Option<bool> {
        let _background = self.background_permit().await;
        let mut all_missing = !self.providers.is_empty();
        for pp in &self.providers {
            match pp.stat(message_id).await {
                Some(true) => return Some(true),
                Some(false) => {}
                None => all_missing = false,
            }
        }
        if all_missing {
            Some(false)
        } else {
            None
        }
    }

    /// STAT every segment to verify the whole file is present before playback.
    /// Moderate fan-out leaves connection headroom for active streams.
    pub async fn completeness(self: &Arc<Self>, message_ids: &[String]) -> Completeness {
        // Moderate fan-out: enough to verify a ~1700-segment file in a second or two
        // on warm connections, while leaving the rest of the budget for playback.
        let concurrency = (self.total_capacity() / 4).clamp(1, 12);
        self.stat_many(message_ids.to_vec(), concurrency).await
    }

    /// STAT a set of ids at the given concurrency; count how many are present.
    async fn stat_many(self: &Arc<Self>, ids: Vec<String>, concurrency: usize) -> Completeness {
        use futures::stream::StreamExt;
        let total = ids.len();
        let outcomes = futures::stream::iter(ids)
            .map(|id| {
                let this = Arc::clone(self);
                async move { this.present_anywhere(&id).await }
            })
            .buffer_unordered(concurrency.max(1))
            .collect::<Vec<_>>()
            .await;
        Completeness {
            total,
            present: outcomes.iter().filter(|v| **v == Some(true)).count(),
            missing: outcomes.iter().filter(|v| **v == Some(false)).count(),
        }
    }
}

/// Result of a completeness check.
pub struct Completeness {
    pub total: usize,
    pub present: usize,
    pub missing: usize,
}

fn background_capacity(providers: &[Provider]) -> usize {
    // Most requests first hit the primary provider, so reserve headroom there
    // rather than sizing against the sum of unrelated provider budgets.
    (providers.first().map(|p| p.max_connections).unwrap_or(1) / 4).clamp(1, 12)
}

impl Completeness {
    pub fn is_complete(&self) -> bool {
        self.total > 0 && self.present == self.total
    }
    pub fn fraction(&self) -> f64 {
        if self.total == 0 {
            0.0
        } else {
            self.present as f64 / self.total as f64
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    /// Real local NNTP sockets exercise pooling/handback and protocol status
    /// handling without contacting configured providers or reading credentials.
    pub(crate) async fn fake_provider(code: u16) -> (Provider, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut socket = BufReader::new(socket);
                    socket.get_mut().write_all(b"200 test\r\n").await.unwrap();
                    loop {
                        let mut line = String::new();
                        if socket.read_line(&mut line).await.unwrap_or(0) == 0 {
                            break;
                        }
                        let response = if line.starts_with("AUTHINFO") {
                            "281 accepted\r\n".to_string()
                        } else if line.starts_with("GROUP") {
                            "211 test group\r\n".to_string()
                        } else if line.starts_with("BODY") && code == 223 {
                            // An article can pass STAT but contain invalid yEnc.
                            "222 body\r\ninvalid media\r\n.\r\n".to_string()
                        } else {
                            format!("{code} fixture\r\n")
                        };
                        if socket
                            .get_mut()
                            .write_all(response.as_bytes())
                            .await
                            .is_err()
                        {
                            break;
                        }
                    }
                });
            }
        });
        (
            Provider {
                name: "fixture".into(),
                host: "127.0.0.1".into(),
                port,
                tls: false,
                username: "fixture".into(),
                password: "fixture".into(),
                max_connections: 1,
            },
            server,
        )
    }

    #[tokio::test]
    async fn saturated_checkout_wakes_when_connection_returns_idle() {
        let (provider, server) = fake_provider(223).await;
        let pool = Arc::new(ProviderPool::new(provider));
        let connection = pool.checkout().await.unwrap();
        let waiting_pool = pool.clone();
        let mut waiter = tokio::spawn(async move { waiting_pool.checkout().await });
        assert!(tokio::time::timeout(Duration::from_millis(20), &mut waiter)
            .await
            .is_err());
        pool.checkin(connection).await;
        let reused = tokio::time::timeout(Duration::from_secs(1), waiter)
            .await
            .expect("idle handback must wake the blocked checkout")
            .unwrap()
            .unwrap();
        assert_eq!(
            pool.sem.available_permits(),
            0,
            "the socket still owns its permit"
        );
        pool.checkin(reused).await;
        server.abort();
    }

    #[tokio::test]
    async fn provider_history_identity_survives_reordering_and_capacity_changes() {
        let (first, server) = fake_provider(223).await;
        let mut second = first.clone();
        second.name = "backup".into();
        let before = Pool::new(&[first.clone(), second.clone(), first.clone()])
            .metrics_snapshot()
            .await;
        let mut larger = first;
        larger.max_connections = 50;
        let after = Pool::new(&[second, larger]).metrics_snapshot().await;
        assert_eq!(before.providers[0].id, after.providers[1].id);
        assert_eq!(before.providers[1].id, after.providers[0].id);
        assert_ne!(
            before.providers[0].id, before.providers[2].id,
            "duplicate endpoints still need distinct sample keys"
        );
        server.abort();
    }

    #[tokio::test]
    async fn idle_sockets_are_free_capacity_and_drop_releases_busy_slots() {
        let (provider, server) = fake_provider(223).await;
        let pool = Pool::new(&[provider]);
        let pp = &pool.providers[0];
        let conn = pp.checkout().await.unwrap();
        let busy = pool.metrics_snapshot().await.total;
        assert_eq!(
            (
                busy.capacity,
                busy.open_connections,
                busy.connected_connections
            ),
            (1, 1, 1)
        );
        assert_eq!(
            (
                busy.busy_connections,
                busy.idle_connections,
                busy.free_connections,
                busy.unused_slots
            ),
            (1, 0, 0, 0)
        );
        assert_eq!(
            busy.queue_wait_count, 0,
            "an immediately acquired slot did not queue"
        );
        pp.checkin(conn).await;
        let idle = pool.metrics_snapshot().await.total;
        assert_eq!(
            (
                idle.busy_connections,
                idle.idle_connections,
                idle.free_connections,
                idle.unused_slots
            ),
            (0, 1, 1, 0)
        );
        assert_eq!(
            pp.sem.available_permits(),
            0,
            "retained sockets still consume open permits"
        );
        let conn = pp.checkout().await.unwrap();
        assert_eq!(
            pool.metrics_snapshot().await.total.connection_attempts,
            1,
            "reuse must not count as a new connection"
        );
        drop(conn);
        let dropped = pool.metrics_snapshot().await.total;
        assert_eq!(
            (
                dropped.open_connections,
                dropped.connected_connections,
                dropped.busy_connections,
                dropped.free_connections,
                dropped.unused_slots
            ),
            (0, 0, 0, 1, 1)
        );
        server.abort();
    }

    #[tokio::test]
    async fn queued_checkout_cancellation_and_handback_leave_accurate_counters() {
        let (provider, server) = fake_provider(223).await;
        let pool = Pool::new(&[provider]);
        let conn = pool.providers[0].checkout().await.unwrap();
        let other = pool.clone();
        let waiter = tokio::spawn(async move { other.providers[0].checkout().await });
        tokio::time::timeout(Duration::from_secs(1), async {
            while pool.metrics_snapshot().await.total.waiters != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        waiter.abort();
        let _ = waiter.await;
        let cancelled = pool.metrics_snapshot().await.total;
        assert_eq!(
            (
                cancelled.waiters,
                cancelled.queue_wait_count,
                cancelled.queue_wait_cancelled,
                cancelled.queue_wait_completed
            ),
            (0, 1, 1, 0)
        );
        assert_eq!(
            cancelled.busy_connections, 1,
            "cancelling a waiter cannot release someone else's socket"
        );
        let other = pool.clone();
        let waiter = tokio::spawn(async move { other.providers[0].checkout().await });
        tokio::time::timeout(Duration::from_secs(1), async {
            while pool.metrics_snapshot().await.total.waiters != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        pool.providers[0].checkin(conn).await;
        let reused = tokio::time::timeout(Duration::from_secs(1), waiter)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let completed = pool.metrics_snapshot().await.total;
        assert_eq!(
            (
                completed.waiters,
                completed.queue_wait_count,
                completed.queue_wait_cancelled,
                completed.queue_wait_completed
            ),
            (0, 2, 1, 1)
        );
        drop(reused);
        assert_eq!(pool.metrics_snapshot().await.total.free_connections, 1);
        server.abort();
    }

    #[tokio::test]
    async fn cancelled_connection_handshake_releases_opening_and_busy_gauges() {
        let (mut provider, server) = fake_provider(223).await;
        server.abort();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        provider.port = listener.local_addr().unwrap().port();
        let pool = Pool::new(&[provider]);
        let other = pool.clone();
        let checkout = tokio::spawn(async move { other.providers[0].checkout().await });
        let (_socket, _) = listener.accept().await.unwrap(); // Hold greeting, keeping NNTP setup pending.
        let opening = pool.metrics_snapshot().await.total;
        assert_eq!(
            (
                opening.open_connections,
                opening.opening_connections,
                opening.connected_connections,
                opening.busy_connections
            ),
            (1, 1, 0, 1)
        );
        checkout.abort();
        let _ = checkout.await;
        let cancelled = pool.metrics_snapshot().await.total;
        assert_eq!(
            (
                cancelled.open_connections,
                cancelled.opening_connections,
                cancelled.busy_connections,
                cancelled.free_connections
            ),
            (0, 0, 0, 1)
        );
        assert_eq!(
            (cancelled.connection_attempts, cancelled.connection_errors),
            (1, 0),
            "caller cancellation is not a provider failure"
        );
    }

    #[tokio::test]
    async fn failed_handshake_counts_connection_error_and_frees_capacity() {
        let (mut provider, original_server) = fake_provider(223).await;
        original_server.abort();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        provider.port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            socket.write_all(b"400 unavailable\r\n").await.unwrap();
        });
        let pool = Pool::new(&[provider]);
        assert!(pool.providers[0].checkout().await.is_err());
        let failed = pool.metrics_snapshot().await.total;
        assert_eq!(
            (failed.connection_attempts, failed.connection_errors),
            (1, 1)
        );
        assert_eq!(
            (
                failed.open_connections,
                failed.opening_connections,
                failed.busy_connections,
                failed.free_connections
            ),
            (0, 0, 0, 1)
        );
        assert_eq!(
            failed.articles_missing, 0,
            "an unavailable server is not a missing article"
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn article_and_fallback_counters_record_actual_provider_outcomes() {
        let (missing, missing_server) = fake_provider(430).await;
        let (present, present_server) = fake_provider(223).await;
        let pool = Pool::new(&[missing, present]);
        let raw = match pool.fetch_checked("", "segment").await {
            CheckedFetch::Found(raw) => raw,
            _ => panic!("fallback provider should have returned the article"),
        };
        assert_eq!(pool.present_anywhere("segment").await, Some(true));
        let snapshot = pool.metrics_snapshot().await;
        assert_eq!(
            (
                snapshot.total.articles_missing,
                snapshot.total.articles_found,
                snapshot.total.bytes_downloaded
            ),
            (1, 1, raw.len() as u64)
        );
        assert_eq!(
            (snapshot.total.stat_missing, snapshot.total.stat_found),
            (1, 1)
        );
        assert_eq!(
            (
                snapshot.providers[0].metrics.fallback_attempts,
                snapshot.providers[1].metrics.fallback_attempts,
                snapshot.providers[1].metrics.fallback_successes
            ),
            (0, 1, 1)
        );
        assert_eq!(
            (
                snapshot.total.capacity,
                snapshot.total.busy_connections,
                snapshot.total.idle_connections,
                snapshot.total.free_connections
            ),
            (2, 0, 2, 2)
        );
        let serialized = serde_json::to_string(&snapshot).unwrap();
        assert!(!serialized.contains("password") && !serialized.contains("username"));
        missing_server.abort();
        present_server.abort();
    }

    #[tokio::test]
    async fn provider_protocol_failures_count_retries_without_leaking_connections() {
        let (provider, server) = fake_provider(451).await;
        let pool = Pool::new(&[provider]);
        assert!(matches!(
            pool.fetch_checked("", "segment").await,
            CheckedFetch::Unavailable
        ));
        assert_eq!(pool.present_anywhere("segment").await, None);
        let failed = pool.metrics_snapshot().await.total;
        assert_eq!(
            (
                failed.article_errors,
                failed.stat_errors,
                failed.connection_attempts
            ),
            (2, 2, 4)
        );
        assert_eq!(
            (
                failed.articles_missing,
                failed.open_connections,
                failed.busy_connections,
                failed.free_connections
            ),
            (0, 0, 0, 1)
        );
        server.abort();
    }

    #[tokio::test]
    async fn transient_status_does_not_condemn_a_mixed_provider_result() {
        let (missing, missing_server) = fake_provider(430).await;
        let (temporary, temporary_server) = fake_provider(451).await;
        let (present, present_server) = fake_provider(223).await;
        let mixed = Pool::new(&[missing.clone(), temporary.clone()]);
        assert_eq!(mixed.present_anywhere("segment").await, None);
        assert!(matches!(
            mixed.fetch_checked("", "segment").await,
            CheckedFetch::Unavailable
        ));
        let health = mixed.completeness(&["segment".into()]).await;
        assert_eq!(health.missing, 0);
        assert!(!health.is_complete());
        let absent = Pool::new(&[missing]);
        assert_eq!(absent.present_anywhere("segment").await, Some(false));
        assert!(matches!(
            absent.fetch_checked("", "segment").await,
            CheckedFetch::Missing
        ));
        let available = Pool::new(&[temporary, present]);
        assert_eq!(available.present_anywhere("segment").await, Some(true));
        missing_server.abort();
        temporary_server.abort();
        present_server.abort();
    }
}

#[cfg(test)]
pub(crate) mod verified_fixtures {
    use super::*;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    pub(crate) fn article(data: &[u8], begin: u64, total: u64, number: usize) -> Vec<u8> {
        let mut body = format!("=ybegin part={number} line=128 size={total} name=fixture.mp4\r\n=ypart begin={begin} end={}\r\n", begin + data.len() as u64 - 1).into_bytes();
        body.extend(crate::yenc::encode_data(data, 128));
        body.extend(
            format!(
                "=yend size={} part={number} pcrc32={:08x}\r\n",
                data.len(),
                crate::yenc::crc32(data)
            )
            .as_bytes(),
        );
        // NNTP dot-stuffing is independent of yEnc escaping.
        let mut stuffed = Vec::new();
        for line in body.split_inclusive(|b| *b == b'\n') {
            if line.starts_with(b".") {
                stuffed.push(b'.');
            }
            stuffed.extend(line);
        }
        stuffed
    }

    pub(crate) async fn provider(
        bodies: std::collections::HashMap<String, Vec<u8>>,
    ) -> (Provider, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let bodies = Arc::new(bodies);
        let server = tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                let bodies = bodies.clone();
                tokio::spawn(async move {
                    let mut socket = BufReader::new(socket);
                    if socket
                        .get_mut()
                        .write_all(b"200 fixture\r\n")
                        .await
                        .is_err()
                    {
                        return;
                    }
                    loop {
                        let mut line = String::new();
                        if socket.read_line(&mut line).await.unwrap_or(0) == 0 {
                            break;
                        }
                        let id = line
                            .trim()
                            .split(' ')
                            .nth(1)
                            .unwrap_or("")
                            .trim_matches(['<', '>']);
                        let response = if line.starts_with("AUTHINFO") {
                            b"281 accepted\r\n".to_vec()
                        } else if line.starts_with("GROUP") {
                            b"211 test\r\n".to_vec()
                        } else if let Some(body) = bodies.get(id) {
                            if line.starts_with("BODY") {
                                [b"222 body\r\n".as_slice(), body, b".\r\n"].concat()
                            } else {
                                b"223 present\r\n".to_vec()
                            }
                        } else {
                            b"430 missing\r\n".to_vec()
                        };
                        if socket.get_mut().write_all(&response).await.is_err() {
                            break;
                        }
                    }
                });
            }
        });
        (
            Provider {
                name: "fixture".into(),
                host: "127.0.0.1".into(),
                port,
                tls: false,
                username: "fixture".into(),
                password: "fixture".into(),
                max_connections: 8,
            },
            server,
        )
    }

    #[tokio::test]
    async fn corrupt_primary_retries_secondary_before_returning_verified_original_bytes() {
        let (primary, pserver) = provider(std::collections::HashMap::from([(
            "part".into(),
            article(b"damaged", 1, 6, 1),
        )]))
        .await;
        let (secondary, sserver) = provider(std::collections::HashMap::from([(
            "part".into(),
            article(b"original", 1, 8, 1),
        )]))
        .await;
        let pool = Pool::new_verified(&[primary, secondary], true);
        // Primary body is internally consistent CRC but has an end-size/total
        // mismatch. Its successful NNTP reply must never be selected.
        let decoded = match pool.fetch_decoded("", "part").await {
            DecodedFetch::Found(d) => d,
            other => panic!("unexpected {other:?}"),
        };
        assert_eq!(decoded.data, b"original");
        let metrics = pool.metrics_snapshot().await;
        assert_eq!(metrics.providers[1].metrics.fallback_successes, 1);
        assert_eq!(metrics.providers[0].metrics.article_errors, 1);
        pserver.abort();
        sserver.abort();
    }
}

#[cfg(test)]
mod budget_tests {
    use super::*;
    #[tokio::test]
    async fn download_budget_charges_corrupt_retry_payloads_and_refunds_unused_reservations() {
        let mut bad = verified_fixtures::article(b"original", 1, 8, 1);
        let crc = bad.windows(7).position(|w| w == b"pcrc32=").unwrap() + 7;
        bad[crc..crc + 8].copy_from_slice(b"00000000");
        let good = verified_fixtures::article(b"original", 1, 8, 1);
        let expected = bad.len() as u64 + good.len() as u64 + 6; // Both NNTP terminators.
        let (primary, ps) =
            verified_fixtures::provider(std::collections::HashMap::from([("part".into(), bad)]))
                .await;
        let (secondary, ss) =
            verified_fixtures::provider(std::collections::HashMap::from([("part".into(), good)]))
                .await;
        let pool = Pool::new_verified(&[primary, secondary], true);
        let budget = FetchBudget::new(1024 * 1024);
        assert!(matches!(
            pool.fetch_decoded_budgeted("", "part", &budget)
                .await
                .unwrap(),
            DecodedFetch::Found(_)
        ));
        assert_eq!(budget.used(), expected);
        let tiny = FetchBudget::new(20);
        assert!(pool
            .fetch_decoded_budgeted("", "part", &tiny)
            .await
            .is_err());
        assert_eq!(
            tiny.used(),
            20,
            "a truncated attempt cannot refund bytes it might have consumed"
        );
        ps.abort();
        ss.abort();
    }
}
