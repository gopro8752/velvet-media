//! Authoritative recovery observations. No URL, article id, provider credential,
//! release name or client-supplied title is retained here. A bounded nonblocking
//! queue keeps SQLite latency out of the streaming path; losses are explicit.
use crate::db::Db;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveryEvent {
    pub event_id: String,
    pub occurred_at: i64,
    pub kind: String,
    pub stream_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub playback_session_id: Option<String>,
    pub trigger: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub charged_download_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovered_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes_served: Option<u64>,
}
impl RecoveryEvent {
    pub fn new(kind: &str, sid: &str, key: &str, trigger: &str) -> Self {
        Self {
            event_id: format!("{kind}:{}", digest(key)),
            occurred_at: now_ms(),
            kind: kind.into(),
            stream_id: sid.into(),
            job_id: None,
            playback_session_id: None,
            trigger: trigger.into(),
            outcome: None,
            reason: None,
            duration_ms: None,
            charged_download_bytes: None,
            recovered_bytes: None,
            bytes_served: None,
        }
    }
}
pub fn digest(text: &str) -> String {
    format!("{:x}", md5::compute(text.as_bytes()))
}
pub fn valid_session(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 100
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

pub fn init(db: &Db) -> anyhow::Result<()> {
    db.lock().unwrap().execute_batch("
      CREATE TABLE IF NOT EXISTS recovery_events (
        event_id TEXT PRIMARY KEY, occurred_at INTEGER NOT NULL, kind TEXT NOT NULL,
        stream_id TEXT NOT NULL, job_id TEXT, playback_session_id TEXT, payload TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS recovery_events_time ON recovery_events(occurred_at);
      CREATE INDEX IF NOT EXISTS recovery_events_session ON recovery_events(playback_session_id,occurred_at);
      CREATE INDEX IF NOT EXISTS recovery_events_job ON recovery_events(job_id);
      CREATE TABLE IF NOT EXISTS recovery_metrics_meta (key TEXT PRIMARY KEY,value INTEGER NOT NULL);
    ")?;
    db.lock().unwrap().execute(
        "INSERT OR IGNORE INTO recovery_metrics_meta(key,value) VALUES('collected_at',?1)",
        [now_ms()],
    )?;
    Ok(())
}

#[derive(Clone)]
pub struct Recorder {
    tx: std::sync::mpsc::SyncSender<RecoveryEvent>,
    dropped: Arc<AtomicU64>,
    seen: Arc<
        std::sync::Mutex<(
            std::collections::HashSet<String>,
            std::collections::VecDeque<String>,
        )>,
    >,
}
impl Recorder {
    pub fn new(db: Db) -> anyhow::Result<Self> {
        init(&db)?;
        // An in-memory repair cannot survive a backend restart. Preserve that
        // uncertainty as cancellation, never invent success or leave an old job
        // permanently shown as active. There is one recorder per backend.
        {
            let mut conn = db.lock().unwrap();
            let pending: Vec<String> = {
                let mut statement = conn.prepare("SELECT payload FROM recovery_events s WHERE kind='repair_job_started' AND NOT EXISTS(SELECT 1 FROM recovery_events t WHERE t.kind='repair_job' AND t.job_id=s.job_id)")?;
                let rows = statement.query_map([], |row| row.get(0))?;
                rows.collect::<Result<_, _>>()?
            };
            let tx = conn.transaction()?;
            for payload in pending {
                let Ok(started) = serde_json::from_str::<RecoveryEvent>(&payload) else {
                    continue;
                };
                let Some(job) = started.job_id else {
                    continue;
                };
                let mut event =
                    RecoveryEvent::new("repair_job", &started.stream_id, &job, &started.trigger);
                event.job_id = Some(job);
                event.outcome = Some("cancelled".into());
                event.reason = Some("backend_restart".into());
                tx.execute("INSERT OR IGNORE INTO recovery_events(event_id,occurred_at,kind,stream_id,job_id,playback_session_id,payload) VALUES(?1,?2,?3,?4,?5,NULL,?6)", params![event.event_id,event.occurred_at,event.kind,event.stream_id,event.job_id,serde_json::to_string(&event)?])?;
            }
            tx.commit()?;
        }
        let (tx, rx) = std::sync::mpsc::sync_channel::<RecoveryEvent>(4096);
        let dropped = Arc::new(AtomicU64::new(0));
        let lost = dropped.clone();
        std::thread::Builder::new().name("recovery-metrics".into()).spawn(move || {
            let mut last_prune = std::time::Instant::now();
            let mut failures = 0u64;
            let mut since_prune = 0usize;
            loop {
                let first = rx.recv_timeout(std::time::Duration::from_secs(5));
                let stopped = matches!(first, Err(std::sync::mpsc::RecvTimeoutError::Disconnected));
                let mut batch = Vec::with_capacity(128);
                if let Ok(event) = first { batch.push(event); }
                while batch.len() < 128 {
                    match rx.try_recv() { Ok(event) => batch.push(event), Err(_) => break }
                }
                let mut conn = db.lock().unwrap_or_else(|p| p.into_inner());
                let losses = lost.swap(0, Ordering::Relaxed).saturating_add(failures);
                let result = (|| -> anyhow::Result<()> {
                    let tx = conn.transaction()?;
                    for e in &batch {
                        tx.execute("INSERT OR IGNORE INTO recovery_events(event_id,occurred_at,kind,stream_id,job_id,playback_session_id,payload) VALUES(?1,?2,?3,?4,?5,?6,?7)",
                          params![e.event_id,e.occurred_at,e.kind,e.stream_id,e.job_id,e.playback_session_id,serde_json::to_string(e)?])?;
                    }
                    if losses > 0 {
                        if let Err(e) = tx.execute("INSERT INTO recovery_metrics_meta(key,value) VALUES('dropped_events',?1) ON CONFLICT(key) DO UPDATE SET value=value+excluded.value", [losses.min(i64::MAX as u64) as i64]) {
                            return Err(e.into());
                        }
                    }
                    tx.commit()?;
                    failures = 0;
                    Ok(())
                })();
                if result.is_err() { failures = losses.saturating_add(batch.len() as u64); }
                since_prune += batch.len();
                if last_prune.elapsed().as_secs() >= 3600 || since_prune >= 10000 {
                    // Periodic row pruning bounds unusually busy clients as
                    // well as old history; at most one 10k batch crosses the cap.
                    let _ = conn.execute("DELETE FROM recovery_events WHERE occurred_at<?1 OR event_id IN (SELECT event_id FROM recovery_events ORDER BY occurred_at DESC LIMIT -1 OFFSET 250000)", [now_ms()-90*86400*1000]);
                    last_prune = std::time::Instant::now();
                    since_prune = 0;
                }
                if stopped { break; }
            }
        })?;
        Ok(Self {
            tx,
            dropped,
            seen: Arc::new(std::sync::Mutex::new(Default::default())),
        })
    }
    pub fn record(&self, event: RecoveryEvent) {
        let mut seen = self.seen.lock().unwrap_or_else(|p| p.into_inner());
        if seen.0.contains(&event.event_id) {
            return;
        }
        let id = event.event_id.clone();
        if self.tx.try_send(event).is_err() {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return;
        }
        if seen.0.len() >= 65536 {
            if let Some(old) = seen.1.pop_front() {
                seen.0.remove(&old);
            }
        }
        seen.0.insert(id.clone());
        seen.1.push_back(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duplicate_events_are_durable_once_and_never_include_raw_article_ids() {
        let db = Arc::new(std::sync::Mutex::new(
            rusqlite::Connection::open_in_memory().unwrap(),
        ));
        let recorder = Recorder::new(db.clone()).unwrap();
        let event = RecoveryEvent::new(
            "provider_rescue",
            "abcdef",
            "secret-article@server",
            "ahead",
        );
        assert!(!event.event_id.contains("secret"));
        for _ in 0..10 {
            recorder.record(event.clone());
        }
        for _ in 0..100 {
            if db
                .lock()
                .unwrap()
                .query_row("SELECT count(*) FROM recovery_events", [], |r| {
                    r.get::<_, i64>(0)
                })
                .unwrap()
                == 1
            {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(
            db.lock()
                .unwrap()
                .query_row("SELECT count(*) FROM recovery_events", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    #[test]
    fn interrupted_job_is_cancelled_on_restart_without_claiming_success_or_duration() {
        let db = Arc::new(std::sync::Mutex::new(
            rusqlite::Connection::open_in_memory().unwrap(),
        ));
        init(&db).unwrap();
        let mut event = RecoveryEvent::new("repair_job_started", "source", "job", "ahead");
        event.job_id = Some("job".into());
        db.lock().unwrap().execute("INSERT INTO recovery_events(event_id,occurred_at,kind,stream_id,job_id,payload) VALUES(?1,?2,?3,?4,?5,?6)",params![event.event_id,event.occurred_at,event.kind,event.stream_id,event.job_id,serde_json::to_string(&event).unwrap()]).unwrap();
        let _recorder = Recorder::new(db.clone()).unwrap();
        let payload: String = db
            .lock()
            .unwrap()
            .query_row(
                "SELECT payload FROM recovery_events WHERE kind='repair_job'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let terminal: RecoveryEvent = serde_json::from_str(&payload).unwrap();
        assert_eq!(terminal.outcome.as_deref(), Some("cancelled"));
        assert_eq!(terminal.reason.as_deref(), Some("backend_restart"));
        assert_eq!(terminal.duration_ms, None);
        assert_eq!(terminal.recovered_bytes, None);
    }
    #[test]
    fn session_identity_is_bounded_and_not_an_arbitrary_header() {
        assert!(valid_session("test-session-123"));
        assert!(!valid_session(""));
        assert!(!valid_session("http://token"));
        assert!(!valid_session(&"a".repeat(101)));
    }
}
