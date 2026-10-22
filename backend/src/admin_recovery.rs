//! Recovery reporting is deliberately separate from provider capacity accounting.
//! Client counters describe observed playback; server events describe exact work.
use rusqlite::{params, types::ValueRef, Connection, OptionalExtension, ToSql, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

const DAY: i64 = 86_400_000;
const MINUTE: i64 = 60_000;

pub struct Proxy {
    origin: reqwest::Url,
    token: String,
    client: reqwest::Client,
}
impl Proxy {
    pub fn from_env() -> anyhow::Result<Option<Self>> {
        let url = std::env::var("VELVET_RECOVERY_REPORT_URL")
            .ok()
            .filter(|v| !v.trim().is_empty());
        let token = std::env::var("VELVET_RECOVERY_REPORT_TOKEN")
            .ok()
            .filter(|v| !v.trim().is_empty());
        match (url, token) {
            (None, None) => Ok(None),
            (Some(url), Some(token)) => Ok(Some(Self::new(&url, token)?)),
            _ => anyhow::bail!("recovery report origin and token must both be configured"),
        }
    }
    fn new(url: &str, token: String) -> anyhow::Result<Self> {
        let origin = reqwest::Url::parse(url)?;
        anyhow::ensure!(
            matches!(origin.scheme(), "http" | "https")
                && origin.host_str().is_some()
                && origin.username().is_empty()
                && origin.password().is_none()
                && origin.query().is_none()
                && origin.fragment().is_none()
                && matches!(origin.path(), "" | "/"),
            "recovery report URL must be a bare HTTP(S) origin"
        );
        anyhow::ensure!(
            token.trim().len() >= 24,
            "recovery report token is too short"
        );
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(12))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            origin,
            token,
            client,
        })
    }
    pub async fn fetch(&self, days: u32, export: bool) -> anyhow::Result<Vec<u8>> {
        let mut url = self.origin.clone();
        url.set_path(if export {
            "/admin/api/recovery/export"
        } else {
            "/admin/api/recovery"
        });
        url.query_pairs_mut().append_pair("days", &days.to_string());
        let mut response = self
            .client
            .get(url)
            .bearer_auth(&self.token)
            .header("X-Velvet-Recovery-Proxy", "1")
            .send()
            .await?;
        anyhow::ensure!(response.status().is_success(), "beta report unavailable");
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            anyhow::ensure!(
                bytes.len() + chunk.len() <= 4 * 1024 * 1024,
                "beta report exceeds size limit"
            );
            bytes.extend_from_slice(&chunk);
        }
        Ok(bytes)
    }
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientCounters {
    pub build_channel: Option<String>,
    pub telemetry_version: Option<u32>,
    pub source_switch_attempts: Option<u64>,
    pub automatic_switch_attempts: Option<u64>,
    pub manual_switch_attempts: Option<u64>,
    pub successful_source_switches: Option<u64>,
    pub automatic_source_switches: Option<u64>,
    pub manual_source_switches: Option<u64>,
    pub rebuffer_count: Option<u64>,
    pub rebuffered_ms: Option<u64>,
    pub max_rebuffer_ms: Option<u64>,
    pub seek_count: Option<u64>,
}
impl ClientCounters {
    fn cohort(&self) -> (&str, u32) {
        (
            self.build_channel.as_deref().unwrap_or("legacy"),
            self.telemetry_version.unwrap_or(1),
        )
    }
    pub fn supported(&self) -> bool {
        self.build_channel.as_deref() == Some("beta") && self.telemetry_version == Some(2)
    }
    pub fn validate(&self, switches: u64) -> bool {
        if self
            .build_channel
            .as_deref()
            .is_some_and(|v| !matches!(v, "stable" | "beta"))
        {
            return false;
        }
        if self.telemetry_version.is_some_and(|v| v != 2) {
            return false;
        }
        if !self.supported() {
            return self.telemetry_version.is_none();
        }
        let values = [
            self.source_switch_attempts,
            self.automatic_switch_attempts,
            self.manual_switch_attempts,
            self.successful_source_switches,
            self.automatic_source_switches,
            self.manual_source_switches,
            self.rebuffer_count,
        ];
        if values.iter().any(|v| v.is_none_or(|n| n > 100_000))
            || self.rebuffered_ms.is_none_or(|n| n > 31_536_000_000)
            || self
                .max_rebuffer_ms
                .is_some_and(|n| n > self.rebuffered_ms.unwrap_or(0))
            || self.seek_count.is_some_and(|n| n > 100_000)
        {
            return false;
        }
        self.automatic_switch_attempts.unwrap() + self.manual_switch_attempts.unwrap()
            == self.source_switch_attempts.unwrap()
            && self.automatic_source_switches.unwrap() + self.manual_source_switches.unwrap()
                == switches
            && self.successful_source_switches == Some(switches)
            && self.automatic_source_switches <= self.automatic_switch_attempts
            && self.manual_source_switches <= self.manual_switch_attempts
    }
}
/// A session cannot be relabeled halfway through a watch. Sessions recorded
/// before this registry existed are legacy v1, never retroactively beta v2.
pub fn validate_cohort(
    c: &Connection,
    id: &str,
    e: &ClientCounters,
    existing_session: bool,
) -> anyhow::Result<()> {
    let prior: Option<(String, u32)> = c
        .query_row(
            "SELECT channel,telemetry_version FROM admin_recovery_playback WHERE session_id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((channel, version)) =
        prior.or_else(|| existing_session.then(|| ("legacy".to_owned(), 1)))
    {
        anyhow::ensure!(
            (channel.as_str(), version) == e.cohort(),
            "session telemetry cohort changed"
        );
    }
    Ok(())
}
pub fn migrate(c: &Connection) -> anyhow::Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS admin_recovery_playback(
        session_id TEXT PRIMARY KEY,channel TEXT NOT NULL,telemetry_version INTEGER NOT NULL,counters TEXT NOT NULL,updated_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS admin_recovery_usage(
        bucket INTEGER NOT NULL,session_id TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,
        automatic_attempts INTEGER NOT NULL DEFAULT 0,manual_attempts INTEGER NOT NULL DEFAULT 0,
        automatic_switches INTEGER NOT NULL DEFAULT 0,manual_switches INTEGER NOT NULL DEFAULT 0,
        rebuffer_count INTEGER NOT NULL DEFAULT 0,rebuffered_ms INTEGER NOT NULL DEFAULT 0,seek_count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(bucket,session_id));
      CREATE INDEX IF NOT EXISTS admin_recovery_usage_session ON admin_recovery_usage(session_id,bucket);")?;
    Ok(())
}
pub fn record_client(
    tx: &Transaction,
    id: &str,
    e: &ClientCounters,
    now: i64,
    buffered: u64,
    intervals: &[(i64, u64)],
) -> anyhow::Result<()> {
    validate_cohort(tx, id, e, false)?;
    if !e.supported() {
        // Keep the original cohort even for clients without recovery counters;
        // report queries continue to select only channel=beta/version=2.
        let (channel, version) = e.cohort();
        tx.execute(
            "INSERT INTO admin_recovery_playback VALUES(?1,?2,?3,?4,?5)
          ON CONFLICT(session_id) DO UPDATE SET updated_at=excluded.updated_at",
            params![id, channel, version, serde_json::to_string(e)?, now],
        )?;
        return Ok(());
    }
    let prior: Option<String> = tx
        .query_row(
            "SELECT counters FROM admin_recovery_playback WHERE session_id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    let old: ClientCounters = prior
        .map(|v| serde_json::from_str(&v))
        .transpose()?
        .unwrap_or_default();
    fn delta(new: Option<u64>, old: Option<u64>) -> anyhow::Result<u64> {
        let (a, b) = (new.unwrap_or(0), old.unwrap_or(0));
        anyhow::ensure!(a >= b, "recovery counters moved backwards");
        Ok(a - b)
    }
    let attempts = delta(e.source_switch_attempts, old.source_switch_attempts)?;
    let auto_attempts = delta(e.automatic_switch_attempts, old.automatic_switch_attempts)?;
    let manual_attempts = delta(e.manual_switch_attempts, old.manual_switch_attempts)?;
    let auto = delta(e.automatic_source_switches, old.automatic_source_switches)?;
    let manual = delta(e.manual_source_switches, old.manual_source_switches)?;
    let stalls = delta(e.rebuffer_count, old.rebuffer_count)?;
    let rebuffer = delta(e.rebuffered_ms, old.rebuffered_ms)?.min(buffered);
    let seeks = delta(e.seek_count, old.seek_count)?;
    delta(e.max_rebuffer_ms, old.max_rebuffer_ms)?;
    // The base playback ledger caps a heartbeat at 1,000 switch events. Reject
    // an impossible beta jump rather than clipping one ledger but not the other.
    anyhow::ensure!(
        auto + manual <= 1_000 && attempts <= 1_000,
        "recovery switch delta exceeds limit"
    );
    tx.execute("INSERT INTO admin_recovery_playback VALUES(?1,'beta',2,?2,?3)
      ON CONFLICT(session_id) DO UPDATE SET counters=excluded.counters,updated_at=excluded.updated_at",params![id,serde_json::to_string(e)?,now])?;
    tx.execute("INSERT INTO admin_recovery_usage(bucket,session_id,attempts,automatic_attempts,manual_attempts,automatic_switches,manual_switches,rebuffer_count,seek_count)
      VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(bucket,session_id) DO UPDATE SET
      attempts=attempts+excluded.attempts,automatic_attempts=automatic_attempts+excluded.automatic_attempts,
      manual_attempts=manual_attempts+excluded.manual_attempts,automatic_switches=automatic_switches+excluded.automatic_switches,
      manual_switches=manual_switches+excluded.manual_switches,rebuffer_count=rebuffer_count+excluded.rebuffer_count,seek_count=seek_count+excluded.seek_count",
      params![now.div_euclid(MINUTE)*MINUTE,id,attempts,auto_attempts,manual_attempts,auto,manual,stalls,seeks])?;
    // Use the same wall-time budget and day boundaries as the base playback report.
    let mut remaining = rebuffer;
    for (index, (bucket, b)) in intervals.iter().enumerate() {
        let n = if index + 1 == intervals.len() {
            remaining
        } else {
            (rebuffer as u128 * *b as u128 / buffered.max(1) as u128) as u64
        }
        .min(remaining);
        remaining -= n;
        tx.execute("INSERT INTO admin_recovery_usage(bucket,session_id,rebuffered_ms) VALUES(?1,?2,?3)
          ON CONFLICT(bucket,session_id) DO UPDATE SET rebuffered_ms=rebuffered_ms+excluded.rebuffered_ms",params![bucket,id,n])?;
    }
    Ok(())
}
pub fn prune(c: &Connection, before: i64) -> anyhow::Result<()> {
    c.execute("DELETE FROM admin_recovery_usage WHERE bucket<?1", [before])?;
    c.execute(
        "DELETE FROM admin_recovery_playback WHERE updated_at<?1",
        [before],
    )?;
    Ok(())
}
fn rows(c: &Connection, sql: &str, args: &[&dyn ToSql]) -> anyhow::Result<Vec<Value>> {
    let mut q = c.prepare(sql)?;
    let names = q
        .column_names()
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();
    let result = q
        .query_map(args, |r| {
            let mut value = Map::new();
            for (i, name) in names.iter().enumerate() {
                value.insert(
                    name.clone(),
                    match r.get_ref(i)? {
                        ValueRef::Null | ValueRef::Blob(_) => Value::Null,
                        ValueRef::Integer(n) => json!(n),
                        ValueRef::Real(n) => json!(n),
                        ValueRef::Text(s) => json!(String::from_utf8_lossy(s)),
                    },
                );
            }
            Ok(Value::Object(value))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(result)
}
fn one(c: &Connection, sql: &str, args: &[&dyn ToSql]) -> anyhow::Result<Value> {
    Ok(rows(c, sql, args)?
        .into_iter()
        .next()
        .unwrap_or_else(|| json!({})))
}
fn number(v: &Value, key: &str) -> f64 {
    v[key].as_f64().unwrap_or(0.0)
}
fn integer(v: &Value, key: &str) -> i64 {
    v[key].as_i64().unwrap_or(0)
}
fn fraction(n: f64, d: f64) -> Value {
    if d > 0.0 {
        json!(n / d)
    } else {
        Value::Null
    }
}
fn table_exists(c: &Connection, name: &str) -> bool {
    c.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1",
        [name],
        |r| r.get::<_, i64>(0),
    )
    .unwrap_or(0)
        > 0
}
// One row per watch, irrespective of the number of telemetry heartbeats or sources.
const WATCH_CTE:&str="WITH u AS (SELECT session_id,sum(played_ms) AS played,sum(buffered_ms) AS buffered,sum(switches) AS switches FROM admin_usage WHERE bucket>=?1 AND bucket<=?2 GROUP BY session_id),
 r AS (SELECT session_id,sum(attempts) AS attempts,sum(automatic_attempts) AS aa,sum(manual_attempts) AS ma,sum(automatic_switches) AS a,sum(manual_switches) AS m,sum(rebuffer_count) AS rc,sum(rebuffered_ms) AS rb,sum(seek_count) AS seeks FROM admin_recovery_usage WHERE bucket>=?1 AND bucket<=?2 GROUP BY session_id),
 w AS (SELECT s.*,coalesce(u.played,0) AS p,coalesce(u.buffered,0) AS b,coalesce(u.switches,0) AS sw,
 coalesce(r.attempts,0) AS attempts,coalesce(r.aa,0) AS aa,coalesce(r.ma,0) AS ma,coalesce(r.a,0) AS a,coalesce(r.m,0) AS m,coalesce(r.rc,0) AS rc,coalesce(r.rb,0) AS rb,coalesce(r.seeks,0) AS seeks
 FROM admin_sessions s JOIN admin_recovery_playback cp ON cp.session_id=s.id AND cp.channel='beta' AND cp.telemetry_version=2
 LEFT JOIN u ON u.session_id=s.id LEFT JOIN r ON r.session_id=s.id WHERE s.kind IN ('tv','movie') AND s.last_seen>=?1 AND s.first_seen<=?2) ";
fn percentile(c: &Connection, sql: &str, args: &[&dyn ToSql], q: f64) -> anyhow::Result<Value> {
    let count: i64 = c.query_row(&format!("SELECT count(*) FROM ({sql})"), args, |r| r.get(0))?;
    if count == 0 {
        return Ok(Value::Null);
    }
    let offset = ((count as f64 * q).ceil() as i64 - 1).max(0);
    Ok(json!(c.query_row(
        &format!("SELECT value FROM ({sql}) ORDER BY value LIMIT 1 OFFSET {offset}"),
        args,
        |r| r.get::<_, f64>(0)
    )?))
}

pub fn report(c: &Connection, days: u32, now: i64) -> anyhow::Result<Value> {
    anyhow::ensure!((1..=90).contains(&days), "invalid reporting period");
    if !table_exists(c, "recovery_events") {
        return Ok(
            json!({"available":false,"scope":"beta","message":"Recovery reporting is not configured on this server."}),
        );
    }
    let start = now.div_euclid(DAY) * DAY - (days as i64 - 1) * DAY;
    let collected: Option<i64> = c
        .query_row(
            "SELECT value FROM recovery_metrics_meta WHERE key='collected_at'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    let args: [&dyn ToSql; 2] = [&start, &now];
    let mut summary=one(c,&format!("{WATCH_CTE} SELECT count(*) AS watches,coalesce(sum(p),0) AS watchedMs,
      coalesce(sum(sw),0) AS sourceSwitches,coalesce(sum(a),0) AS automaticSwitches,coalesce(sum(m),0) AS manualSwitches,
      coalesce(sum(attempts),0) AS sourceSwitchAttempts,coalesce(sum(aa),0) AS automaticSwitchAttempts,coalesce(sum(ma),0) AS manualSwitchAttempts,
      coalesce(sum(CASE WHEN sw=0 THEN 1 ELSE 0 END),0) AS zeroSwitchWatches,coalesce(sum(rb),0) AS rebufferedMs,
      coalesce(sum(b),0) AS bufferedMs,coalesce(sum(rc),0) AS rebufferCount,coalesce(sum(seeks),0) AS seekCount FROM w WHERE p>0"),&args)?;
    summary["avgSwitchesPerWatch"] = fraction(
        number(&summary, "sourceSwitches"),
        number(&summary, "watches"),
    );
    summary["unclassifiedSwitches"] = json!((integer(&summary, "sourceSwitches")
        - integer(&summary, "automaticSwitches")
        - integer(&summary, "manualSwitches"))
    .max(0));
    summary["bufferRatioPct"] = fraction(
        number(&summary, "rebufferedMs") * 100.,
        number(&summary, "watchedMs") + number(&summary, "rebufferedMs"),
    );
    summary["bufferEvents"] = summary["rebufferCount"].clone();
    let startup_sql=format!("{WATCH_CTE} SELECT startup_ms*1.0 AS value FROM w WHERE p>0 AND first_seen>=?1 AND startup_ms IS NOT NULL");
    summary["startupP50Ms"] = percentile(c, &startup_sql, &args, 0.5)?;
    summary["startupP95Ms"] = percentile(c, &startup_sql, &args, 0.95)?;
    let event_stats=one(c,"SELECT
      count(DISTINCT CASE WHEN kind IN ('repair_job_started','repair_job') THEN job_id END) AS par2Jobs,
      coalesce(sum(kind='repair_job' AND json_extract(payload,'$.outcome')='success'),0) AS par2Succeeded,
      coalesce(sum(kind='repair_job' AND json_extract(payload,'$.outcome') IN ('failed','deadline','quota')),0) AS par2Failed,
      coalesce(sum(kind='repair_job' AND json_extract(payload,'$.outcome')='cancelled'),0) AS par2Cancelled,
      coalesce(sum(kind='repair_job' AND json_extract(payload,'$.outcome')='deadline'),0) AS deadlineMisses,
      coalesce(sum(kind='provider_rescue'),0) AS providerRescuedArticles,
      coalesce(sum(CASE WHEN kind='provider_rescue' THEN coalesce(json_extract(payload,'$.recoveredBytes'),json_extract(payload,'$.bytesServed'),0) ELSE 0 END),0) AS providerRescuedBytes,
      coalesce(sum(CASE WHEN kind='repair_job' AND json_extract(payload,'$.outcome')='success' THEN json_extract(payload,'$.recoveredBytes') ELSE 0 END),0) AS par2RecoveredBytes,
      coalesce(sum(CASE WHEN kind='repair_job' THEN json_extract(payload,'$.chargedDownloadBytes') ELSE 0 END),0) AS repairDownloadBytes,
      coalesce(sum(kind='repair_job' AND json_extract(payload,'$.outcome')='success' AND json_extract(payload,'$.trigger')='ahead'),0) AS aheadCompletedJobs,
      coalesce(sum(kind='repair_job' AND json_extract(payload,'$.outcome')='success' AND json_extract(payload,'$.trigger')='foreground'),0) AS foregroundCompletedJobs,
      coalesce(sum(kind='stream_read_failed'),0) AS failedViewerReads
      FROM recovery_events WHERE occurred_at>=?1 AND occurred_at<=?2",&args)?;
    for (k, v) in event_stats.as_object().unwrap() {
        summary[k] = v.clone();
    }
    summary["par2Pending"]=one(c,"SELECT count(DISTINCT e.job_id) AS n FROM recovery_events e WHERE e.kind='repair_job_started' AND e.occurred_at>=?1 AND e.occurred_at<=?2 AND NOT EXISTS(SELECT 1 FROM recovery_events t WHERE t.job_id=e.job_id AND t.kind='repair_job')",&args)?["n"].clone();
    summary["preparedOnlyJobs"]=one(c,"SELECT count(*) AS n FROM recovery_events e WHERE e.kind='repair_job' AND json_extract(e.payload,'$.outcome')='success' AND e.occurred_at>=?1 AND e.occurred_at<=?2 AND NOT EXISTS(SELECT 1 FROM recovery_events r WHERE r.job_id=e.job_id AND r.kind='repaired_read')",&args)?["n"].clone();
    summary["playbacksUsingRepairedBytes"]=one(c,&format!("{WATCH_CTE} SELECT count(DISTINCT w.id) AS n FROM w JOIN recovery_events e ON e.playback_session_id=w.id WHERE w.p>0 AND e.kind='repaired_read' AND e.occurred_at>=?1 AND e.occurred_at<=?2"),&args)?["n"].clone();
    summary["playbacksUsingProviderRescue"]=one(c,&format!("{WATCH_CTE} SELECT count(DISTINCT w.id) AS n FROM w JOIN recovery_events e ON e.playback_session_id=w.id WHERE w.p>0 AND e.kind='provider_rescue_read' AND e.occurred_at>=?1 AND e.occurred_at<=?2"),&args)?["n"].clone();
    let duration_sql="SELECT json_extract(payload,'$.durationMs')*1.0 AS value FROM recovery_events WHERE kind='repair_job' AND json_extract(payload,'$.outcome')='success' AND occurred_at>=?1 AND occurred_at<=?2 AND json_extract(payload,'$.durationMs') IS NOT NULL";
    summary["repairP50Ms"] = percentile(c, duration_sql, &args, 0.5)?;
    summary["repairP95Ms"] = percentile(c, duration_sql, &args, 0.95)?;
    let reasons=rows(c,"SELECT coalesce(json_extract(payload,'$.reason'),'unknown') AS reason,count(*) AS count FROM recovery_events WHERE kind='repair_job' AND json_extract(payload,'$.outcome') IN ('failed','deadline','quota') AND occurred_at>=?1 AND occurred_at<=?2 GROUP BY reason ORDER BY count DESC",&args)?;
    let daily_events=rows(c,"SELECT occurred_at/86400000 AS day,sum(kind='provider_rescue') AS providerRescuedArticles,sum(kind='repair_job' AND json_extract(payload,'$.outcome')='success') AS par2Succeeded,sum(kind='repair_job' AND json_extract(payload,'$.outcome') IN ('failed','deadline','quota')) AS par2Failed FROM recovery_events WHERE occurred_at>=?1 AND occurred_at<=?2 GROUP BY day",&args)?;
    let daily_usage=rows(c,"SELECT u.bucket/86400000 AS day,count(DISTINCT CASE WHEN u.played_ms>0 THEN u.session_id END) AS watches,sum(u.switches) AS sourceSwitches
      FROM admin_usage u JOIN admin_recovery_playback r ON r.session_id=u.session_id AND r.channel='beta' AND r.telemetry_version=2
      JOIN admin_sessions s ON s.id=u.session_id AND s.kind IN ('movie','tv') WHERE u.bucket>=?1 AND u.bucket<=?2 GROUP BY day",&args)?;
    let mut daily = Vec::new();
    for offset in 0..days {
        let day = start / DAY + offset as i64;
        let e = daily_events.iter().find(|v| integer(v, "day") == day);
        let u = daily_usage.iter().find(|v| integer(v, "day") == day);
        let value = |row: Option<&Value>, key: &str| row.map(|v| integer(v, key)).unwrap_or(0);
        daily.push(json!({"date":chrono::DateTime::from_timestamp_millis(day*DAY).unwrap().format("%Y-%m-%d").to_string(),"observed":collected.is_some_and(|t|t<(day+1)*DAY),"providerRescuedArticles":value(e,"providerRescuedArticles"),"par2Succeeded":value(e,"par2Succeeded"),"par2Failed":value(e,"par2Failed"),"sourceSwitches":value(u,"sourceSwitches"),"watches":value(u,"watches")}));
    }
    let mut titles=rows(c,&format!("{WATCH_CTE} SELECT media_id AS id,title,kind,season,episode,count(*) AS watches,sum(p) AS playedMs,sum(sw) AS sourceSwitches,sum(a) AS automaticSwitches,sum(m) AS manualSwitches,sum(attempts) AS sourceSwitchAttempts,sum(rb) AS rebufferedMs,sum(b) AS bufferedMs FROM w WHERE p>0 GROUP BY media_id,title,kind,season,episode ORDER BY playedMs DESC LIMIT 50"),&args)?;
    for title in &mut titles {
        title["avgSwitchesPerWatch"] =
            fraction(number(title, "sourceSwitches"), number(title, "watches"));
        title["bufferRatioPct"] = fraction(
            number(title, "rebufferedMs") * 100.,
            number(title, "playedMs") + number(title, "rebufferedMs"),
        );
        let id = title["id"].as_str().unwrap_or("");
        let kind = title["kind"].as_str().unwrap_or("");
        let season = title["season"].as_i64();
        let episode = title["episode"].as_i64();
        let scope=format!("{WATCH_CTE}, selected AS(SELECT id FROM w WHERE p>0 AND media_id=?3 AND kind=?4 AND season IS ?5 AND episode IS ?6)");
        let a: [&dyn ToSql; 6] = [&start, &now, &id, &kind, &season, &episode];
        let stats = association_stats(c, &scope, &a)?;
        for (k, v) in stats.as_object().unwrap() {
            title[k] = v.clone();
        }
    }
    let mut sessions = watch_rows(c, start, now, 200)?;
    for session in &mut sessions {
        let id = session["id"].as_str().unwrap_or("").to_owned();
        let scope = "WITH selected AS(SELECT ?3 AS id)";
        let a: [&dyn ToSql; 3] = [&start, &now, &id];
        let stats = association_stats(c, scope, &a)?;
        for (k, v) in stats.as_object().unwrap() {
            session[k] = v.clone();
        }
        session["usedRepairedBytes"] = json!(integer(&stats, "playbacksUsingRepairedBytes") > 0);
        let events=rows(c,"SELECT event_id AS id,occurred_at AS timestamp,kind AS type,json_extract(payload,'$.outcome') AS outcome,json_extract(payload,'$.reason') AS reason,coalesce(json_extract(payload,'$.recoveredBytes'),json_extract(payload,'$.bytesServed')) AS bytes,json_extract(payload,'$.durationMs') AS durationMs
          FROM recovery_events WHERE occurred_at>=?1 AND occurred_at<=?2 AND (playback_session_id=?3 OR (kind='repair_job' AND job_id IN (SELECT job_id FROM recovery_events WHERE playback_session_id=?3 AND job_id IS NOT NULL))) ORDER BY occurred_at DESC LIMIT 80",&a)?;
        session["events"] = json!(events.into_iter().map(normalize_event).collect::<Vec<_>>());
    }
    let meta=one(c,"SELECT min(occurred_at) AS firstEventAt,max(occurred_at) AS lastEventAt,count(*) AS retainedEvents FROM recovery_events",&[])?;
    let dropped: i64 = c.query_row(
        "SELECT coalesce((SELECT value FROM recovery_metrics_meta WHERE key='dropped_events'),0)",
        [],
        |r| r.get(0),
    )?;
    Ok(
        json!({"available":true,"scope":"beta","generatedAt":now,"periodStart":start,"periodEnd":now,
      "collectionStartedAt":collected,"firstEventAt":meta["firstEventAt"],"lastEventAt":meta["lastEventAt"],"summary":summary,
      "reasons":reasons,"daily":daily,"titles":titles,"sessions":sessions,"coverage":{"droppedEvents":dropped,"retainedEvents":meta["retainedEvents"],"retentionDays":90,"eventLimit":250000,"sessionLimit":200,"titleLimit":50,
      "message":"Watches are beta movie/episode sessions with measured playing time in this period. Successful source starts and attempts are separate. Delivery of repaired bytes is observed at the server; it is not proof that every frame was displayed. Repairs include speculative work. Events are retained for up to 90 days or 250,000 records."}}),
    )
}
fn association_stats(c: &Connection, scope: &str, args: &[&dyn ToSql]) -> anyhow::Result<Value> {
    one(c,&format!("{scope}, links AS(SELECT DISTINCT job_id FROM recovery_events WHERE playback_session_id IN(SELECT id FROM selected) AND job_id IS NOT NULL),
      jobs AS(SELECT e.* FROM recovery_events e JOIN links ON links.job_id=e.job_id WHERE e.kind='repair_job' AND e.occurred_at>=?1 AND e.occurred_at<=?2)
      SELECT (SELECT count(DISTINCT playback_session_id) FROM recovery_events WHERE playback_session_id IN(SELECT id FROM selected) AND kind='repaired_read' AND occurred_at>=?1 AND occurred_at<=?2) AS playbacksUsingRepairedBytes,
      (SELECT count(*) FROM recovery_events WHERE playback_session_id IN(SELECT id FROM selected) AND kind='provider_rescue_read' AND occurred_at>=?1 AND occurred_at<=?2) AS providerRescuedArticles,
      (SELECT count(*) FROM jobs WHERE json_extract(payload,'$.outcome')='success') AS par2Succeeded,
      (SELECT count(*) FROM jobs WHERE json_extract(payload,'$.outcome') IN ('failed','deadline','quota')) AS par2Failed"),args)
}
fn normalize_event(mut event: Value) -> Value {
    let typ = match event["type"].as_str().unwrap_or("") {
        "repair_job" => match event["outcome"].as_str() {
            Some("success") => "par2_succeeded",
            Some("cancelled") => "par2_cancelled",
            Some("deadline") => "deadline_missed",
            _ => "par2_failed",
        },
        "repaired_read" => "repaired_bytes_served",
        "provider_rescue_read" => "provider_rescue",
        other => other,
    }
    .to_string();
    event["type"] = json!(typ);
    event
}
fn watch_rows(c: &Connection, start: i64, now: i64, limit: usize) -> anyhow::Result<Vec<Value>> {
    rows(c,&format!("{WATCH_CTE} SELECT id,title,kind,media_id AS mediaId,season,episode,profile_name AS profileName,device_name AS deviceName,first_seen AS startedAt,last_seen AS lastSeen,state,p AS playedMs,b AS bufferedMs,rb AS rebufferedMs,rc AS rebufferCount,startup_ms AS startupMs,sw AS sourceSwitches,a AS automaticSwitches,m AS manualSwitches,attempts AS sourceSwitchAttempts,aa AS automaticSwitchAttempts,ma AS manualSwitchAttempts FROM w ORDER BY last_seen DESC LIMIT {}",limit.min(5000)),&[&start,&now])
}
pub fn export(c: &Connection, days: u32, now: i64) -> anyhow::Result<String> {
    let start = now.div_euclid(DAY) * DAY - (days as i64 - 1) * DAY;
    let keys = [
        "id",
        "title",
        "kind",
        "season",
        "episode",
        "profileName",
        "deviceName",
        "startedAt",
        "state",
        "playedMs",
        "sourceSwitches",
        "automaticSwitches",
        "manualSwitches",
        "sourceSwitchAttempts",
        "rebufferCount",
        "rebufferedMs",
    ];
    let mut out = keys.join(",");
    out.push_str("\r\n");
    for row in watch_rows(c, start, now, 5000)? {
        let values = keys
            .iter()
            .map(|k| {
                let v = &row[*k];
                let mut s = v.as_str().map(str::to_owned).unwrap_or_else(|| {
                    if v.is_null() {
                        String::new()
                    } else {
                        v.to_string()
                    }
                });
                if s.starts_with(['=', '+', '-', '@', '\t', '\r']) {
                    s.insert(0, '\'');
                }
                format!("\"{}\"", s.replace('"', "\"\""))
            })
            .collect::<Vec<_>>();
        out.push_str(&values.join(","));
        out.push_str("\r\n");
    }
    Ok(out)
}

#[cfg(test)]
#[path = "admin_recovery_report_tests.rs"]
mod report_tests;
