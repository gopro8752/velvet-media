//! Fixtures are independent of the beta repair engine, so the authenticated
//! report/proxy can be tested unchanged in the stable backend backport.
use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const NOW: i64 = 20 * DAY + DAY / 2;

fn fixture() -> Connection {
    let c = Connection::open_in_memory().unwrap();
    crate::admin::migrate(&c).unwrap();
    c.execute_batch("CREATE TABLE recovery_events(event_id TEXT PRIMARY KEY,occurred_at INTEGER NOT NULL,kind TEXT NOT NULL,stream_id TEXT NOT NULL,job_id TEXT,playback_session_id TEXT,payload TEXT NOT NULL);
        CREATE TABLE recovery_metrics_meta(key TEXT PRIMARY KEY,value INTEGER NOT NULL);").unwrap();
    c.execute(
        "INSERT INTO recovery_metrics_meta VALUES('collected_at',?1)",
        [NOW - DAY / 2],
    )
    .unwrap();
    c
}

fn watch(c: &Connection, id: &str, title: &str, played: i64, switches: i64, beta: bool) {
    c.execute("INSERT INTO admin_sessions(id,device_id,device_name,platform,app_version,profile_id,profile_name,kind,media_id,title,season,episode,first_seen,last_seen,sequence,state,played_counter,buffer_counter,played_ms,buffered_ms,position_ms,startup_ms,error_count,switches)
      VALUES(?1,'device','Shield','android','fixture','profile','Viewer','tv','tt-fixture',?2,1,1,?3,?4,100,?5,999999,99999,999999,99999,60000,1200,0,999)",
      params![id,title,NOW-60_000,NOW,if played > 0 {"playing"} else {"failed"}]).unwrap();
    c.execute(
        "INSERT INTO admin_recovery_playback VALUES(?1,?2,?3,?4,?5)",
        params![
            id,
            if beta { "beta" } else { "legacy" },
            if beta { 2 } else { 1 },
            "{\"sourceSwitchAttempts\":999,\"successfulSourceSwitches\":999}",
            NOW
        ],
    )
    .unwrap();
    usage(c, id, NOW.div_euclid(MINUTE) * MINUTE, played, switches);
}

fn usage(c: &Connection, id: &str, bucket: i64, played: i64, switches: i64) {
    c.execute("INSERT INTO admin_usage(bucket,session_id,played_ms,buffered_ms,errors,switches) VALUES(?1,?2,?3,0,0,?4)",params![bucket,id,played,switches]).unwrap();
    c.execute("INSERT INTO admin_recovery_usage(bucket,session_id,attempts,automatic_attempts,manual_attempts,automatic_switches,manual_switches,rebuffer_count,rebuffered_ms,seek_count)
        VALUES(?1,?2,?3,?3,0,?4,0,0,0,0)",params![bucket,id,if switches > 0 {switches+1} else {0},switches]).unwrap();
}

fn event(
    c: &Connection,
    id: &str,
    kind: &str,
    job: Option<&str>,
    session: Option<&str>,
    extra: Value,
) {
    let mut payload = json!({"eventId":id,"occurredAt":NOW-1000,"kind":kind,"streamId":"stream","trigger":"ahead"});
    if let Some(job) = job {
        payload["jobId"] = json!(job);
    }
    if let Some(session) = session {
        payload["playbackSessionId"] = json!(session);
    }
    for (k, v) in extra.as_object().unwrap() {
        payload[k] = v.clone();
    }
    c.execute(
        "INSERT INTO recovery_events VALUES(?1,?2,?3,'stream',?4,?5,?6)",
        params![id, NOW - 1000, kind, job, session, payload.to_string()],
    )
    .unwrap();
}

#[test]
fn switch_average_includes_zero_switch_watches_excludes_failed_starts_and_legacy() {
    let c = fixture();
    watch(&c, "smooth", "Episode", 60_000, 0, true);
    watch(&c, "switched", "Episode", 60_000, 4, true);
    watch(&c, "failed-start", "Episode", 0, 8, true);
    watch(&c, "legacy", "Episode", 60_000, 100, false);
    let result = report(&c, 1, NOW).unwrap();
    let s = &result["summary"];
    assert_eq!(s["watches"], 2);
    assert_eq!(s["sourceSwitches"], 4);
    assert_eq!(s["automaticSwitches"], 4);
    assert_eq!(s["manualSwitches"], 0);
    assert_eq!(s["avgSwitchesPerWatch"], 2.0);
    assert_eq!(s["zeroSwitchWatches"], 1);
    assert_eq!(s["sourceSwitchAttempts"], 5);
    assert_eq!(result["titles"][0]["watches"], 2);
    assert_eq!(result["titles"][0]["avgSwitchesPerWatch"], 2.0);
    let sessions = result["sessions"].as_array().unwrap();
    assert_eq!(
        sessions.len(),
        3,
        "failed starts remain inspectable; legacy cohort does not enter beta reporting"
    );
    assert!(sessions
        .iter()
        .any(|s| s["id"] == "failed-start" && s["playedMs"] == 0));
}

#[test]
fn reporting_period_uses_usage_deltas_instead_of_lifetime_counters() {
    let c = fixture();
    watch(&c, "spanning", "Episode", 60_000, 2, true);
    usage(&c, "spanning", NOW - DAY, 600_000, 40);
    let today = report(&c, 1, NOW).unwrap();
    assert_eq!(today["summary"]["sourceSwitches"], 2);
    assert_eq!(today["summary"]["sourceSwitchAttempts"], 3);
    assert_eq!(today["summary"]["watchedMs"], 60_000);
    assert_eq!(today["sessions"][0]["sourceSwitches"], 2);
    let both = report(&c, 2, NOW).unwrap();
    assert_eq!(both["summary"]["sourceSwitches"], 42);
    assert_eq!(both["summary"]["watchedMs"], 660_000);
    assert_eq!(
        both["summary"]["watches"], 1,
        "a watch spanning reporting days remains one watch"
    );
}

#[test]
fn shared_repair_counts_server_work_once_and_delivered_watch_benefits_separately() {
    let c = fixture();
    watch(&c, "a", "Episode", 60_000, 0, true);
    watch(&c, "b", "Episode", 60_000, 0, true);
    event(
        &c,
        "start-shared",
        "repair_job_started",
        Some("shared"),
        None,
        json!({}),
    );
    event(
        &c,
        "done-shared",
        "repair_job",
        Some("shared"),
        None,
        json!({"outcome":"success","recoveredBytes":128,"chargedDownloadBytes":1024,"durationMs":100}),
    );
    event(
        &c,
        "served-a",
        "repaired_read",
        Some("shared"),
        Some("a"),
        json!({"outcome":"delivered"}),
    );
    event(
        &c,
        "served-b",
        "repaired_read",
        Some("shared"),
        Some("b"),
        json!({"outcome":"delivered"}),
    );
    let shared = report(&c, 1, NOW).unwrap();
    assert_eq!(shared["summary"]["par2Jobs"], 1);
    assert_eq!(shared["summary"]["par2Succeeded"], 1);
    assert_eq!(shared["summary"]["playbacksUsingRepairedBytes"], 2);
    assert_eq!(shared["summary"]["par2RecoveredBytes"], 128);
    assert_eq!(shared["summary"]["preparedOnlyJobs"], 0);
    assert_eq!(
        shared["titles"][0]["par2Succeeded"], 1,
        "shared job is not multiplied by its two watch associations"
    );
    assert_eq!(shared["titles"][0]["playbacksUsingRepairedBytes"], 2);
    for session in shared["sessions"].as_array().unwrap() {
        assert_eq!(session["usedRepairedBytes"], true);
        assert!(session["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["type"] == "par2_succeeded"));
    }
    // Successful speculative work that never enters a viewer response remains
    // prepared-only, while a speculative failure is never a viewer failure.
    event(
        &c,
        "prepared",
        "repair_job",
        Some("prepared"),
        None,
        json!({"outcome":"success","recoveredBytes":256}),
    );
    event(
        &c,
        "spec-failed",
        "repair_job",
        Some("failed"),
        None,
        json!({"outcome":"failed","reason":"no_parity"}),
    );
    let all = report(&c, 1, NOW).unwrap();
    assert_eq!(all["summary"]["par2Jobs"], 3);
    assert_eq!(all["summary"]["par2Succeeded"], 2);
    assert_eq!(all["summary"]["par2Failed"], 1);
    assert_eq!(all["summary"]["failedViewerReads"], 0);
    assert_eq!(all["summary"]["preparedOnlyJobs"], 1);
    assert_eq!(all["summary"]["playbacksUsingRepairedBytes"], 2);
    assert_eq!(all["reasons"][0]["reason"], "no_parity");
}

#[test]
fn empty_reporting_is_unknown_for_averages_and_marks_days_before_collection_unobserved() {
    let c = fixture();
    let r = report(&c, 3, NOW).unwrap();
    assert_eq!(r["summary"]["watches"], 0);
    assert!(r["summary"]["avgSwitchesPerWatch"].is_null());
    assert!(r["summary"]["bufferRatioPct"].is_null());
    assert!(r["summary"]["startupP50Ms"].is_null());
    assert!(r["summary"]["repairP50Ms"].is_null());
    assert_eq!(r["daily"][0]["observed"], false);
    assert_eq!(r["daily"][1]["observed"], false);
    assert_eq!(r["daily"][2]["observed"], true);
}

#[test]
fn csv_neutralizes_formula_text_and_preserves_failed_start_rows() {
    let c = fixture();
    for (i, prefix) in ["=", "+", "-", "@", "\t", "\r"].iter().enumerate() {
        watch(
            &c,
            &format!("watch-{i}"),
            &format!("{prefix}formula,\"quoted\""),
            if i == 0 { 0 } else { 60_000 },
            0,
            true,
        );
    }
    c.execute(
        "UPDATE admin_sessions SET profile_name='=profile',device_name='@device'",
        [],
    )
    .unwrap();
    let output = export(&c, 1, NOW).unwrap();
    for prefix in ["=", "+", "-", "@", "\t", "\r"] {
        assert!(
            output.contains(&format!("\"'{prefix}formula,\"\"quoted\"\"\"")),
            "unsafe prefix {prefix:?}"
        );
    }
    assert!(output.contains("\"'=profile\""));
    assert!(output.contains("\"'@device\""));
    assert!(output.contains("\"watch-0\""));
    assert!(output.contains("\"failed\",\"0\""));
}

#[test]
fn proxy_rejects_destinations_that_could_leak_the_admin_token() {
    let token = "fixture-admin-token-not-a-secret".to_owned();
    for url in [
        "http://localhost/path",
        "https://user@example.invalid",
        "https://user:pass@example.invalid",
        "https://example.invalid?x=1",
        "https://example.invalid#fragment",
        "ftp://example.invalid",
        "file:///tmp/report",
    ] {
        assert!(Proxy::new(url, token.clone()).is_err(), "accepted {url}");
    }
    assert!(Proxy::new("http://127.0.0.1:9999", token.clone()).is_ok());
    assert!(Proxy::new("https://example.invalid/", token).is_ok());
    assert!(Proxy::new("http://localhost", "short".into()).is_err());
}

async fn request_head(socket: &mut tokio::net::TcpStream) -> String {
    let mut bytes = Vec::new();
    let mut chunk = [0; 1024];
    while !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = socket.read(&mut chunk).await.unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&chunk[..n]);
        assert!(bytes.len() < 16384);
    }
    String::from_utf8(bytes).unwrap()
}

#[tokio::test]
async fn proxy_sends_only_expected_path_query_admin_auth_and_loop_marker() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        for path in [
            "/admin/api/recovery?days=7",
            "/admin/api/recovery/export?days=30",
        ] {
            let (mut socket, _) = listener.accept().await.unwrap();
            let head = request_head(&mut socket).await.to_ascii_lowercase();
            assert!(head.starts_with(&format!("get {path} http/1.1\r\n")));
            assert!(head.contains("\r\nauthorization: bearer fixture-admin-token-not-a-secret\r\n"));
            assert!(head.contains("\r\nx-velvet-recovery-proxy: 1\r\n"));
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
                .await
                .unwrap();
        }
    });
    let proxy = Proxy::new(&origin, "fixture-admin-token-not-a-secret".into()).unwrap();
    assert_eq!(proxy.fetch(7, false).await.unwrap(), b"{}");
    assert_eq!(proxy.fetch(30, true).await.unwrap(), b"{}");
    tokio::time::timeout(std::time::Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn proxy_never_follows_redirects_with_admin_credentials() {
    let target = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let location = format!("http://{}/leak", target.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        request_head(&mut socket).await;
        socket.write_all(format!("HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
    });
    let proxy = Proxy::new(&origin, "fixture-admin-token-not-a-secret".into()).unwrap();
    assert!(proxy.fetch(7, false).await.is_err());
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(150), target.accept())
            .await
            .is_err(),
        "redirect destination must never receive a connection"
    );
    server.await.unwrap();
}

#[tokio::test]
async fn proxy_rejects_body_larger_than_four_mib() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        request_head(&mut socket).await;
        let n = 4 * 1024 * 1024 + 1;
        socket
            .write_all(
                format!("HTTP/1.1 200 OK\r\nContent-Length: {n}\r\nConnection: close\r\n\r\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
        let _ = socket.write_all(&vec![b'x'; n]).await;
    });
    let proxy = Proxy::new(&origin, "fixture-admin-token-not-a-secret".into()).unwrap();
    assert!(proxy
        .fetch(7, false)
        .await
        .unwrap_err()
        .to_string()
        .contains("size limit"));
    server.await.unwrap();
}
