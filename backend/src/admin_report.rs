//! Read-only report queries; range totals come from measured minute buckets, not media positions.
use chrono::{DateTime, Utc};
use rusqlite::{types::ValueRef, Connection, ToSql};
use serde_json::{json, Map, Value};
const DAY: i64 = 86_400_000;
const KINDS: [(&str, &str); 4] = [
    ("movie", "Movies"),
    ("tv", "TV episodes"),
    ("live_tv", "Live TV"),
    ("live_sports", "Live sports"),
];
fn rows(c: &Connection, sql: &str, args: &[&dyn ToSql]) -> anyhow::Result<Vec<Value>> {
    let mut q = c.prepare(sql)?;
    let names: Vec<String> = q.column_names().iter().map(|s| s.to_string()).collect();
    let result = q
        .query_map(args, |row| {
            let mut value = Map::new();
            for (i, name) in names.iter().enumerate() {
                let v = match row.get_ref(i)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(n) => json!(n),
                    ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                    ValueRef::Blob(_) => Value::Null,
                };
                value.insert(name.clone(), v);
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
fn num(v: &Value, k: &str) -> f64 {
    v[k].as_f64().unwrap_or(0.0)
}
fn count(v: &Value, k: &str) -> i64 {
    v[k].as_i64().unwrap_or(0)
}
fn date(ms: i64) -> String {
    DateTime::<Utc>::from_timestamp_millis(ms)
        .unwrap()
        .format("%Y-%m-%d")
        .to_string()
}
fn range(days: u32, now: i64) -> (i64, i64) {
    (now.div_euclid(DAY) * DAY - (days as i64 - 1) * DAY, now)
}
fn histogram_p95(c: &Connection, sql: &str, args: &[&dyn ToSql]) -> anyhow::Result<Option<f64>> {
    let buckets = rows(c, sql, args)?;
    let total: i64 = buckets.iter().map(|v| count(v, "count")).sum();
    if total == 0 {
        return Ok(None);
    }
    let target = (total as f64 * 0.95).ceil() as i64;
    let mut seen = 0;
    for row in buckets {
        seen += count(&row, "count");
        if seen >= target {
            return Ok(row["value"].as_f64());
        }
    }
    Ok(None)
}
fn session_sql() -> &'static str {
    "SELECT id,profile_id AS profileId,profile_name AS profileName,device_id AS deviceId,device_name AS deviceName,platform,app_version AS appVersion,kind,title,media_id AS mediaId,season,episode,first_seen AS startedAt,last_seen AS lastSeen,state,played_ms AS playedMs,buffered_ms AS bufferedMs,startup_ms AS startupMs,error_count AS errorCount,switches AS sourceSwitches FROM admin_sessions"
}
fn mark_stale(sessions: &mut [Value], now: i64) {
    for s in sessions {
        if count(s, "lastSeen") < now - 45_000
            && !matches!(s["state"].as_str(), Some("ended" | "error"))
        {
            s["state"] = json!("stale");
        }
    }
}
pub fn active_sessions(c: &Connection, now: i64) -> anyhow::Result<Vec<Value>> {
    rows(c,&format!("{} WHERE last_seen>?1 AND state IN ('playing','buffering','paused') ORDER BY last_seen DESC LIMIT 100",session_sql()),&[&(now-45_000)])
}
pub fn report(
    c: &Connection,
    days: u32,
    collected: i64,
    now: i64,
    live: &Value,
) -> anyhow::Result<Value> {
    let (start, end) = range(days, now);
    let observed_start = start.max(collected);
    let observed_days = ((now.div_euclid(DAY) - observed_start.div_euclid(DAY)) + 1).max(1);
    let period_args: [&dyn ToSql; 2] = [&start, &end];
    let usage=one(c,"SELECT coalesce(sum(played_ms),0) AS playedMs,coalesce(sum(buffered_ms),0) AS bufferedMs,coalesce(sum(errors),0) AS errorCount,coalesce(sum(switches),0) AS sourceSwitches FROM admin_usage WHERE bucket>=?1 AND bucket<=?2",&period_args)?;
    let identities=one(c,"SELECT count(*) AS sessions,count(DISTINCT profile_id) AS profiles,count(DISTINCT device_id) AS devices FROM admin_sessions WHERE last_seen>=?1 AND first_seen<=?2",&period_args)?;
    let capacity=one(c,"SELECT count(*) AS samples,coalesce(sum(interval_ms),0) AS sampledMs,
        sum(busy*interval_ms)*1.0/nullif(sum(interval_ms),0) AS avgBusy,
        max(busy) AS peakBusy,max(active_sessions) AS peakConcurrent,
        sum(CASE WHEN capacity>0 THEN busy*100.0/capacity*interval_ms ELSE 0 END)/nullif(sum(interval_ms),0) AS avgUtilization,
        coalesce(sum(CASE WHEN waiters>0 OR (capacity>0 AND busy>=capacity)
          OR EXISTS (SELECT 1 FROM admin_providers p WHERE p.ts=c.ts AND (p.waiters>0 OR (p.capacity>0 AND p.busy>=p.capacity)))
          THEN interval_ms ELSE 0 END),0)/1000.0 AS saturatedSeconds,
        coalesce(sum(bytes_delta),0) AS downloadedBytes,sum(bytes_delta)*1000.0/nullif(sum(interval_ms),0) AS avgDownloadBps,
        max(bytes_delta*1000.0/nullif(interval_ms,0)) AS peakDownloadBps
        FROM admin_capacity c WHERE ts>=?1 AND ts<=?2",&period_args)?;
    let p95=histogram_p95(c,"SELECT busy AS value,count(*) AS count FROM admin_capacity WHERE ts>=?1 AND ts<=?2 AND interval_ms>0 GROUP BY busy ORDER BY busy",&period_args)?;
    let summary = json!({"playedMs":usage["playedMs"],"avgDailyPlayedMs":num(&usage,"playedMs")/observed_days as f64,"sessions":identities["sessions"],"avgSessionMs":if count(&identities,"sessions")>0{Some(num(&usage,"playedMs")/num(&identities,"sessions"))}else{None},"profiles":identities["profiles"],"devices":identities["devices"],"peakConcurrent":capacity["peakConcurrent"],"avgBusyConnections":capacity["avgBusy"],"p95BusyConnections":p95,"peakBusyConnections":capacity["peakBusy"],"capacity":live["capacity"]["capacity"],"avgUtilizationPct":capacity["avgUtilization"],"saturatedSeconds":capacity["saturatedSeconds"],"downloadedBytes":capacity["downloadedBytes"],"avgDownloadBps":capacity["avgDownloadBps"],"peakDownloadBps":capacity["peakDownloadBps"]});
    let kind_rows=rows(c,"SELECT s.kind,coalesce(sum(u.played_ms),0) AS playedMs,count(DISTINCT s.id) AS sessions FROM admin_usage u JOIN admin_sessions s ON s.id=u.session_id WHERE u.bucket>=?1 AND u.bucket<=?2 GROUP BY s.kind",&period_args)?;
    let breakdown:Vec<Value>=KINDS.iter().map(|(kind,label)|{let row=kind_rows.iter().find(|v|v["kind"]==*kind);json!({"kind":kind,"label":label,"playedMs":row.map(|r|count(r,"playedMs")).unwrap_or(0),"sessions":row.map(|r|count(r,"sessions")).unwrap_or(0)})}).collect();
    let daily_usage=rows(c,"SELECT u.bucket/86400000 AS day,s.kind,sum(u.played_ms) AS playedMs,sum(u.buffered_ms) AS bufferedMs,count(DISTINCT s.id) AS sessions FROM admin_usage u JOIN admin_sessions s ON s.id=u.session_id WHERE u.bucket>=?1 AND u.bucket<=?2 GROUP BY day,s.kind",&period_args)?;
    let daily_capacity=rows(c,"SELECT ts/86400000 AS day,sum(busy*interval_ms)*1.0/nullif(sum(interval_ms),0) AS avgBusy,max(busy) AS peakBusy,sum(bytes_delta) AS downloadedBytes FROM admin_capacity WHERE ts>=?1 AND ts<=?2 GROUP BY day",&period_args)?;
    let mut daily = Vec::new();
    for offset in 0..days {
        let day = start / DAY + offset as i64;
        let us: Vec<&Value> = daily_usage
            .iter()
            .filter(|v| count(v, "day") == day)
            .collect();
        let cap = daily_capacity.iter().find(|v| count(v, "day") == day);
        let mut by_kind = json!({"movie":0,"tv":0,"live_tv":0,"live_sports":0});
        for r in &us {
            by_kind[r["kind"].as_str().unwrap_or("tv")] = r["playedMs"].clone();
        }
        let observed = day >= collected / DAY;
        daily.push(json!({"date":date(day*DAY),"observed":observed,"playedMs":if observed{Some(us.iter().map(|v|count(v,"playedMs")).sum::<i64>())}else{None},"bufferedMs":if observed{Some(us.iter().map(|v|count(v,"bufferedMs")).sum::<i64>())}else{None},"sessions":us.iter().map(|v|count(v,"sessions")).sum::<i64>(),"byKind":by_kind,"avgBusyConnections":cap.map(|v|v["avgBusy"].clone()).unwrap_or(Value::Null),"peakBusyConnections":cap.map(|v|v["peakBusy"].clone()).unwrap_or(Value::Null),"downloadedBytes":cap.map(|v|v["downloadedBytes"].clone()).unwrap_or(Value::Null)}));
    }
    let hourly=rows(c,"SELECT cast(strftime('%w',bucket/1000,'unixepoch') AS integer) AS weekday,cast(strftime('%H',bucket/1000,'unixepoch') AS integer) AS hour,sum(played_ms) AS playedMs FROM admin_usage WHERE bucket>=?1 AND bucket<=?2 GROUP BY weekday,hour",&period_args)?;
    let mut heatmap = Vec::new();
    for weekday in 0..7 {
        for hour in 0..24 {
            let total = hourly
                .iter()
                .find(|v| count(v, "weekday") == weekday && count(v, "hour") == hour)
                .map(|v| count(v, "playedMs"))
                .unwrap_or(0);
            heatmap.push(json!({"weekday":weekday,"hour":hour,"playedMs":total}));
        }
    }
    let rollup="WITH u AS (SELECT session_id,sum(played_ms) AS p,sum(buffered_ms) AS b FROM admin_usage WHERE bucket>=?1 AND bucket<=?2 GROUP BY session_id),
        scoped AS (SELECT * FROM admin_sessions WHERE last_seen>=?1 AND first_seen<=?2) ";
    // Names and versions are metadata from the latest report, not lexical maxima.
    // Ranking before joining the usage rollup keeps totals at one row per session.
    let mut profiles=rows(c,&format!("{rollup}, latest AS (
        SELECT profile_id,profile_name,row_number() OVER (PARTITION BY profile_id ORDER BY last_seen DESC,id DESC) AS rn FROM scoped)
        SELECT s.profile_id AS id,l.profile_name AS name,coalesce(sum(u.p),0) AS playedMs,count(*) AS sessions,max(s.last_seen) AS lastSeen,count(DISTINCT s.device_id) AS devices,coalesce(sum(u.p),0)*1.0/count(*) AS avgSessionMs
        FROM scoped s LEFT JOIN u ON s.id=u.session_id JOIN latest l ON l.profile_id=s.profile_id AND l.rn=1
        GROUP BY s.profile_id ORDER BY playedMs DESC LIMIT 1000"),&period_args)?;
    let profile_kinds=rows(c,"SELECT s.profile_id AS id,s.kind,sum(u.played_ms) AS playedMs FROM admin_usage u JOIN admin_sessions s ON s.id=u.session_id WHERE u.bucket>=?1 AND u.bucket<=?2 GROUP BY s.profile_id,s.kind",&period_args)?;
    for p in &mut profiles {
        let mut kinds = json!({"movie":0,"tv":0,"live_tv":0,"live_sports":0});
        for k in profile_kinds.iter().filter(|r| r["id"] == p["id"]) {
            kinds[k["kind"].as_str().unwrap_or("tv")] = k["playedMs"].clone();
        }
        p["byKind"] = kinds;
    }
    let devices=rows(c,&format!("{rollup}, latest AS (
        SELECT device_id,device_name,platform,app_version,row_number() OVER (PARTITION BY device_id ORDER BY last_seen DESC,id DESC) AS rn FROM scoped)
        SELECT s.device_id AS id,l.device_name AS name,l.platform AS platform,l.app_version AS appVersion,coalesce(sum(u.p),0) AS playedMs,count(*) AS sessions,max(s.last_seen) AS lastSeen
        FROM scoped s LEFT JOIN u ON s.id=u.session_id JOIN latest l ON l.device_id=s.device_id AND l.rn=1
        GROUP BY s.device_id ORDER BY playedMs DESC LIMIT 1000"),&period_args)?;
    let titles=rows(c,"SELECT s.media_id AS mediaId,s.title,s.kind,s.season,s.episode,sum(u.played_ms) AS playedMs,count(DISTINCT s.id) AS sessions,count(DISTINCT s.profile_id) AS profiles FROM admin_usage u JOIN admin_sessions s ON s.id=u.session_id WHERE u.bucket>=?1 AND u.bucket<=?2 GROUP BY s.media_id,s.title,s.kind,s.season,s.episode ORDER BY playedMs DESC LIMIT 50",&period_args)?;
    let mut sessions = rows(
        c,
        &format!(
            "{} WHERE last_seen>=?1 AND first_seen<=?2 ORDER BY last_seen DESC LIMIT 200",
            session_sql()
        ),
        &period_args,
    )?;
    mark_stale(&mut sessions, now);
    let bucket = if days <= 1 {
        300_000i64
    } else if days <= 7 {
        1_800_000
    } else if days <= 30 {
        7_200_000
    } else {
        21_600_000
    };
    let history=rows(c,"SELECT (ts/?3)*?3 AS timestamp,max(capacity) AS capacity,sum(busy*interval_ms)*1.0/nullif(sum(interval_ms),0) AS avgBusy,max(busy) AS peakBusy,sum(open*interval_ms)*1.0/nullif(sum(interval_ms),0) AS avgOpen,sum(idle*interval_ms)*1.0/nullif(sum(interval_ms),0) AS avgIdle,sum(free*interval_ms)*1.0/nullif(sum(interval_ms),0) AS avgFree,avg(waiters) AS avgWaiters,sum(bytes_delta)*1000.0/nullif(sum(interval_ms),0) AS downloadBps,sum(bytes_delta) AS downloadedBytes,avg(cpu_percent) AS cpuPercent,max(rss_bytes) AS rssBytes FROM admin_capacity WHERE ts>=?1 AND ts<=?2 GROUP BY timestamp ORDER BY timestamp",&[&start,&end,&bucket])?;
    let mut providers=rows(c,"SELECT p.id,
        (SELECT p2.name FROM admin_providers p2 WHERE p2.id=p.id AND p2.ts<=?2 ORDER BY p2.ts DESC LIMIT 1) AS name,
        (SELECT p2.capacity FROM admin_providers p2 WHERE p2.id=p.id AND p2.ts<=?2 ORDER BY p2.ts DESC LIMIT 1) AS capacity,
        sum(c.interval_ms) AS sampledMs,
        sum(CASE WHEN p.waiters>0 OR (p.capacity>0 AND p.busy>=p.capacity) THEN c.interval_ms ELSE 0 END)/1000.0 AS saturatedSeconds,sum(p.busy*c.interval_ms)*1.0/nullif(sum(c.interval_ms),0) AS avgBusy,max(p.busy) AS peakBusy,sum(p.open*c.interval_ms)*1.0/nullif(sum(c.interval_ms),0) AS avgOpen,sum(p.idle*c.interval_ms)*1.0/nullif(sum(c.interval_ms),0) AS avgIdle,sum(p.bytes_delta) AS bytesDownloaded,sum(p.errors_delta) AS errors,sum(p.missing_delta) AS missing,sum(p.found_delta) AS found,sum(p.fallback_delta) AS fallbackSuccesses,sum(p.wait_us_delta)/1000.0/nullif(sum(p.wait_count_delta),0) AS queueWaitMs,sum(p.wait_count_delta) AS queueWaitCount,sum(CASE WHEN p.capacity>0 THEN p.busy*100.0/p.capacity*c.interval_ms ELSE 0 END)/nullif(sum(c.interval_ms),0) AS utilizationPct FROM admin_providers p JOIN admin_capacity c ON c.ts=p.ts WHERE p.ts>=?1 AND p.ts<=?2 GROUP BY p.id ORDER BY p.id",&period_args)?;
    for p in &mut providers {
        let id = p["id"].as_str().unwrap_or("");
        let p95=histogram_p95(c,"SELECT p.busy AS value,count(*) AS count FROM admin_providers p JOIN admin_capacity c ON c.ts=p.ts WHERE p.ts>=?1 AND p.ts<=?2 AND p.id=?3 AND c.interval_ms>0 GROUP BY p.busy ORDER BY p.busy",&[&start,&end,&id])?;
        let current = live["capacity"]["providers"]
            .as_array()
            .and_then(|all| all.iter().find(|r| r["id"] == p["id"]));
        let free = current.map(|r| r["free"].clone()).unwrap_or(Value::Null);
        p["p95Busy"] = json!(p95);
        p["freeNow"] = free;
    }
    let startup_count:i64=c.query_row("SELECT count(*) FROM admin_sessions WHERE first_seen>=?1 AND first_seen<=?2 AND startup_ms IS NOT NULL",rusqlite::params![start,end],|r|r.get(0))?;
    let percentile = |q: f64| -> anyhow::Result<Option<f64>> {
        if startup_count == 0 {
            return Ok(None);
        }
        let offset = ((startup_count as f64 * q).ceil() as i64 - 1).max(0);
        Ok(Some(c.query_row("SELECT startup_ms FROM admin_sessions WHERE first_seen>=?1 AND first_seen<=?2 AND startup_ms IS NOT NULL ORDER BY startup_ms LIMIT 1 OFFSET ?3",rusqlite::params![start,end,offset],|r|r.get::<_,i64>(0))? as f64))
    };
    let error_sessions:i64=c.query_row("SELECT count(DISTINCT session_id) FROM admin_usage WHERE bucket>=?1 AND bucket<=?2 AND errors>0",rusqlite::params![start,end],|r|r.get(0))?;
    let total_time = num(&usage, "playedMs") + num(&usage, "bufferedMs");
    let quality = json!({"startupP50Ms":percentile(0.5)?,"startupP95Ms":percentile(0.95)?,"bufferedMs":usage["bufferedMs"],"bufferRatioPct":if total_time>0.0{Some(num(&usage,"bufferedMs")/total_time*100.0)}else{None},"errorCount":usage["errorCount"],"sourceSwitches":usage["sourceSwitches"],"sessionErrorRatePct":if count(&identities,"sessions")>0{Some(error_sessions as f64/num(&identities,"sessions")*100.0)}else{None}});
    let first_play: Option<i64> =
        c.query_row("SELECT min(first_seen) FROM admin_sessions", [], |r| {
            r.get(0)
        })?;
    let reported: i64 = c.query_row(
        "SELECT count(DISTINCT device_id) FROM admin_sessions",
        [],
        |r| r.get(0),
    )?;
    let sampled = count(&capacity, "sampledMs");
    let expected = (end - observed_start).max(0);
    let mut insights = Vec::new();
    if reported == 0 {
        insights.push(json!({"severity":"info","title":"Waiting for playback reports","detail":"Connection monitoring is live. Install the reporting-enabled apps to measure movies, episodes, live TV and live sports. Old watch progress cannot reconstruct viewing time."}));
    }
    if sampled < 3_600_000 {
        insights.push(json!({"severity":"info","title":"Building your baseline","detail":"Collect at least an hour, including a busy evening, before judging capacity. New profiles and older apps may not have reported yet."}));
    }
    let pressured: Vec<&Value> = providers
        .iter()
        .filter(|p| {
            num(p, "saturatedSeconds") >= 300.0
                || (count(p, "sampledMs") >= 3_600_000 && num(p, "utilizationPct") >= 80.0)
                || (num(p, "queueWaitMs") >= 250.0 && count(p, "queueWaitCount") >= 20)
        })
        .collect();
    if !pressured.is_empty() {
        let names = pressured
            .iter()
            .take(3)
            .map(|p| {
                p["name"]
                    .as_str()
                    .filter(|n| !n.is_empty())
                    .unwrap_or("Unnamed provider")
            })
            .collect::<Vec<_>>()
            .join(", ");
        insights.push(json!({"severity":"watch","title":"A provider is running short of headroom","detail":format!("Observed pressure on {names}. Idle backup capacity does not relieve a busy primary automatically. Compare these providers' waits, throughput and playback buffering before changing a connection budget or buying another service.")}));
    } else if num(&summary, "saturatedSeconds") >= 300.0
        || (sampled >= 3_600_000 && num(&summary, "avgUtilizationPct") >= 80.0)
    {
        insights.push(json!({"severity":"watch","title":"Connection pressure was observed","detail":"Busy slots or queued requests reduced headroom during this period. Compare provider-level waits, throughput and playback buffering; this alone does not establish that another Usenet subscription would improve playback."}));
    } else if sampled >= 3_600_000 {
        insights.push(json!({"severity":"info","title":"No sustained provider pressure in these samples","detail":"The sampled provider loads did not reach the pressure thresholds. Brief bursts between samples and usage in other apps are not measured. Keep watching per-provider waits and playback buffering as more households join."}));
    }
    let fallbacks: i64 = providers
        .iter()
        .map(|p| count(p, "fallbackSuccesses"))
        .sum();
    if fallbacks > 0 {
        insights.push(json!({"severity":"info","title":"Backup providers are recovering articles","detail":format!("{fallbacks} article fetches succeeded on fallback providers. This reflects coverage value; providers are tried in order, so their caps do not automatically add primary-stream throughput.")}));
    }
    if num(&quality, "bufferRatioPct") > 3.0 {
        insights.push(json!({"severity":"watch","title":"Buffering needs a closer look","detail":"Compare the playback timeline with connection waits, provider failures and server CPU. Buffering alone does not prove that more Usenet connections will help."}));
    }
    if expected > 3_600_000 && sampled as f64 / (expected as f64) < 0.8 {
        insights.push(json!({"severity":"watch","title":"Monitoring has gaps","detail":"The backend was not sampled throughout this range. Connection averages use observed time only; missing intervals are not treated as zero usage."}));
    }
    Ok(
        json!({"generatedAt":now,"range":{"days":days,"start":start,"end":end,"timezone":"UTC","observedDays":observed_days},"coverage":{"collectionStartedAt":collected,"playbackStartedAt":first_play,"capacitySampleCount":capacity["samples"],"reportedDevices":reported,"sampledMs":sampled,"expectedMs":expected,"retentionDays":90,"message":"Playback is measured only by reporting-enabled apps, including category playback. Older apps are not backfilled. All charts use UTC. Daily averages include zero-use days since monitoring began. Connection samples include playback, prewarming and probes; configured headroom does not include other apps sharing your Usenet account."},"summary":summary,"breakdown":breakdown,"daily":daily,"hourlyHeatmap":heatmap,"profiles":profiles,"devices":devices,"titles":titles,"sessions":sessions,"capacityHistory":history,"providers":providers,"quality":quality,"insights":insights}),
    )
}
fn csv_cell(value: &Value) -> String {
    let mut text = match value {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        _ => value.to_string(),
    };
    if text.trim_start().starts_with(['=', '+', '-', '@']) {
        text.insert(0, '\'');
    }
    format!("\"{}\"", text.replace('"', "\"\""))
}
pub fn export(c: &Connection, days: u32, kind: &str, now: i64) -> anyhow::Result<String> {
    let (start, end) = range(days, now);
    // Daily exports remain bounded even over the full retention window.
    let (headers, data) = if kind == "playback" {
        let data=rows(c,"SELECT strftime('%Y-%m-%d',u.bucket/1000,'unixepoch') AS dateUTC,s.profile_name AS profile,s.device_name AS device,s.platform,s.kind,s.title,s.season,s.episode,sum(u.played_ms) AS playedMs,sum(u.buffered_ms) AS bufferedMs,sum(u.errors) AS errors,sum(u.switches) AS sourceSwitches FROM admin_usage u JOIN admin_sessions s ON s.id=u.session_id WHERE u.bucket>=?1 AND u.bucket<=?2 GROUP BY dateUTC,s.profile_id,s.device_id,s.kind,s.media_id,s.title,s.season,s.episode ORDER BY dateUTC,s.profile_name LIMIT 100000",&[&start,&end])?;
        (
            vec![
                "dateUTC",
                "profile",
                "device",
                "platform",
                "kind",
                "title",
                "season",
                "episode",
                "playedMs",
                "bufferedMs",
                "errors",
                "sourceSwitches",
            ],
            data,
        )
    } else {
        let data=rows(c,"SELECT strftime('%Y-%m-%d %H:00',p.ts/1000,'unixepoch') AS hourUTC,p.name AS provider,max(p.capacity) AS capacity,sum(p.busy*c.interval_ms)*1.0/nullif(sum(c.interval_ms),0) AS averageBusy,max(p.busy) AS peakBusy,avg(p.open) AS averageOpen,avg(p.idle) AS averageIdle,sum(p.bytes_delta) AS downloadedBytes,sum(p.wait_us_delta)/1000.0 AS totalQueueWaitMs,sum(p.errors_delta) AS errors,sum(p.missing_delta) AS missingArticles,sum(p.fallback_delta) AS fallbackSuccesses FROM admin_providers p JOIN admin_capacity c ON c.ts=p.ts WHERE p.ts>=?1 AND p.ts<=?2 GROUP BY hourUTC,p.id ORDER BY hourUTC,p.id LIMIT 100000",&[&start,&end])?;
        (
            vec![
                "hourUTC",
                "provider",
                "capacity",
                "averageBusy",
                "peakBusy",
                "averageOpen",
                "averageIdle",
                "downloadedBytes",
                "totalQueueWaitMs",
                "errors",
                "missingArticles",
                "fallbackSuccesses",
            ],
            data,
        )
    };
    let mut text = headers.join(",");
    text.push_str("\r\n");
    for row in data {
        text.push_str(
            &headers
                .iter()
                .map(|h| csv_cell(&row[*h]))
                .collect::<Vec<_>>()
                .join(","),
        );
        text.push_str("\r\n");
    }
    Ok(text)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn empty_report_is_honest_and_has_full_range() {
        let c = Connection::open_in_memory().unwrap();
        crate::admin::migrate(&c).unwrap();
        let now = 5 * DAY + 3600000;
        let v = report(&c, 7, now, now, &json!({"capacity":{"capacity":50}})).unwrap();
        assert_eq!(v["summary"]["playedMs"], 0);
        assert!(v["summary"]["avgBusyConnections"].is_null());
        assert!(v["quality"]["startupP95Ms"].is_null());
        assert_eq!(v["daily"].as_array().unwrap().len(), 7);
        assert_eq!(v["range"]["observedDays"], 1);
        assert!(v["daily"][0]["playedMs"].is_null());
    }
    #[test]
    fn csv_defuses_formulas_and_quotes() {
        assert_eq!(
            csv_cell(&json!("=HYPERLINK(\"x\")")),
            "\"'=HYPERLINK(\"\"x\"\")\""
        );
        assert_eq!(csv_cell(&json!("Sam, Jr.")), "\"Sam, Jr.\"");
    }
    #[test]
    fn stale_is_not_live() {
        let c = Connection::open_in_memory().unwrap();
        crate::admin::migrate(&c).unwrap();
        assert!(active_sessions(&c, 100000).unwrap().is_empty());
        let mut s = vec![json!({"lastSeen":1000,"state":"playing"})];
        mark_stale(&mut s, 100000);
        assert_eq!(s[0]["state"], "stale");
    }
    fn fixture_session(
        c: &Connection,
        id: &str,
        seen: i64,
        profile_name: &str,
        device_name: &str,
        version: &str,
    ) {
        c.execute("INSERT INTO admin_sessions(id,device_id,device_name,platform,app_version,profile_id,profile_name,kind,media_id,title,season,episode,first_seen,last_seen,sequence,state,played_counter,buffer_counter,played_ms,buffered_ms,error_count,switches)
         VALUES(?1,'device',?2,'android',?3,'profile',?4,'tv','show-1','Example',1,1,?5,?5,1,'ended',0,0,0,0,0,0)",rusqlite::params![id,device_name,version,profile_name,seen]).unwrap();
    }
    fn fixture_capacity(c: &Connection, ts: i64, interval: i64, primary_busy: i64, bytes: i64) {
        c.execute("INSERT INTO admin_capacity(ts,interval_ms,capacity,busy,open,idle,free,waiters,active_sessions,bytes_delta,wait_us_delta,wait_count_delta,errors_delta,missing_delta,found_delta,fallback_delta)
         VALUES(?1,?2,100,?3,100,100-?3,100-?3,0,2,?4,0,0,0,0,0,0)",rusqlite::params![ts,interval,primary_busy,bytes]).unwrap();
        for (id, name, busy, downloaded) in [
            ("primary", "Primary", primary_busy, bytes),
            ("backup", "Backup", 0, 0),
        ] {
            c.execute("INSERT INTO admin_providers(ts,id,name,capacity,busy,open,idle,free,waiters,bytes_delta,wait_us_delta,wait_count_delta,errors_delta,missing_delta,found_delta,fallback_delta)
             VALUES(?1,?2,?3,50,?4,50,50-?4,50-?4,0,?5,0,0,0,0,0,0)",rusqlite::params![ts,id,name,busy,downloaded]).unwrap();
        }
    }
    #[test]
    fn latest_report_metadata_wins_without_multiplying_session_usage() {
        let c = Connection::open_in_memory().unwrap();
        crate::admin::migrate(&c).unwrap();
        let start = 9 * DAY;
        let now = 10 * DAY + 3_600_000;
        fixture_session(&c, "old", start + 60_000, "Z Grandpa", "Zulu TV", "1.9");
        fixture_session(&c, "new", 10 * DAY + 60_000, "Sam", "Bedroom TV", "1.10");
        for (bucket, id, played) in [
            (start, "old", 40_000),
            (start + 60_000, "old", 20_000),
            (10 * DAY, "new", 30_000),
        ] {
            c.execute(
                "INSERT INTO admin_usage(bucket,session_id,played_ms) VALUES(?1,?2,?3)",
                rusqlite::params![bucket, id, played],
            )
            .unwrap();
        }
        let v = report(&c, 2, start, now, &json!({"capacity":{"capacity":100}})).unwrap();
        assert_eq!(v["profiles"][0]["name"], "Sam");
        assert_eq!(v["devices"][0]["name"], "Bedroom TV");
        assert_eq!(v["devices"][0]["appVersion"], "1.10");
        for section in ["profiles", "devices"] {
            assert_eq!(v[section][0]["playedMs"], 90_000);
            assert_eq!(v[section][0]["sessions"], 2);
        }
        assert_eq!(v["summary"]["playedMs"], 90_000);
        assert_eq!(v["summary"]["avgDailyPlayedMs"], 45_000.0);
        assert_eq!(v["summary"]["avgSessionMs"], 45_000.0);
        assert_eq!(v["daily"][0]["playedMs"], 60_000);
        assert_eq!(v["daily"][1]["playedMs"], 30_000);
        assert_eq!(v["profiles"][0]["byKind"]["tv"], 90_000);
    }
    #[test]
    fn nonzero_capacity_is_time_weighted_and_idle_sockets_remain_available() {
        let c = Connection::open_in_memory().unwrap();
        crate::admin::migrate(&c).unwrap();
        let start = 10 * DAY;
        fixture_capacity(&c, start + 15_000, 15_000, 20, 15_000);
        fixture_capacity(&c, start + 60_000, 45_000, 40, 45_000);
        let v=report(&c,1,start,start+60_000,&json!({"capacity":{"capacity":100,"providers":[{"id":"backup","free":50},{"id":"primary","free":10}]}})).unwrap();
        assert_eq!(v["summary"]["avgBusyConnections"], 35.0);
        assert_eq!(v["summary"]["avgUtilizationPct"], 35.0);
        assert_eq!(v["summary"]["downloadedBytes"], 60_000);
        assert_eq!(v["summary"]["avgDownloadBps"], 1000.0);
        assert_eq!(v["summary"]["saturatedSeconds"], 0.0);
        assert_eq!(v["capacityHistory"][0]["avgFree"], 65.0);
        let providers = v["providers"].as_array().unwrap();
        let backup = providers.iter().find(|p| p["id"] == "backup").unwrap();
        assert_eq!(backup["avgOpen"], 50.0);
        assert_eq!(backup["avgIdle"], 50.0);
        assert_eq!(backup["freeNow"], 50);
        assert_eq!(backup["saturatedSeconds"], 0.0);
        let primary = providers.iter().find(|p| p["id"] == "primary").unwrap();
        assert_eq!(primary["avgBusy"], 35.0);
        assert_eq!(primary["utilizationPct"], 70.0);
    }
    #[test]
    fn saturated_primary_is_visible_even_with_idle_backup_capacity() {
        let c = Connection::open_in_memory().unwrap();
        crate::admin::migrate(&c).unwrap();
        let start = 10 * DAY;
        for index in 1..=240 {
            fixture_capacity(&c, start + index * 15_000, 15_000, 50, 1000);
        }
        let v = report(
            &c,
            1,
            start,
            start + 3_600_000,
            &json!({"capacity":{"capacity":100}}),
        )
        .unwrap();
        assert_eq!(v["summary"]["avgUtilizationPct"], 50.0);
        assert_eq!(v["summary"]["saturatedSeconds"], 3600.0);
        let insights = v["insights"].as_array().unwrap();
        let pressure = insights
            .iter()
            .find(|i| i["title"] == "A provider is running short of headroom")
            .expect("aggregate headroom must not mask a saturated primary");
        assert!(pressure["detail"].as_str().unwrap().contains("Primary"));
        assert!(!insights.iter().any(|i| i["title"]
            .as_str()
            .unwrap_or("")
            .starts_with("No sustained")));
        assert!(!v.to_string().contains("no capacity-based reason"));
    }
    #[test]
    fn gap_samples_cannot_raise_provider_p95_or_weighted_pressure() {
        let c = Connection::open_in_memory().unwrap();
        crate::admin::migrate(&c).unwrap();
        let start = 10 * DAY;
        fixture_capacity(&c, start + 15_000, 15_000, 5, 1000);
        fixture_capacity(&c, start + 3_600_000, 0, 50, 0);
        let v = report(
            &c,
            1,
            start,
            start + 3_600_000,
            &json!({"capacity":{"capacity":100}}),
        )
        .unwrap();
        assert_eq!(v["summary"]["avgBusyConnections"], 5.0);
        assert_eq!(v["summary"]["saturatedSeconds"], 0.0);
        let primary = v["providers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["id"] == "primary")
            .unwrap();
        assert_eq!(primary["p95Busy"], 5.0);
        assert_eq!(primary["utilizationPct"], 10.0);
    }
}
