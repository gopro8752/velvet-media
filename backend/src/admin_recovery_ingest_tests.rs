//! Ingest regressions are separate from report/proxy tests: rejected telemetry
//! must leave both the base playback and beta outcome ledgers unchanged.
use super::*;

fn legacy() -> PlaybackEvent {
    serde_json::from_value(
        json!({"sessionId":"watch-1","sequence":1,"deviceId":"shield-1",
        "deviceName":"Test Shield","platform":"android","appVersion":"test","profileId":"profile-1",
        "kind":"tv","mediaId":"123","title":"Test show","season":1,"episode":1,
        "state":"playing","playedMs":0,"bufferedMs":0}),
    )
    .unwrap()
}

fn beta() -> PlaybackEvent {
    let mut e = legacy();
    e.recovery = serde_json::from_value(json!({"buildChannel":"beta","telemetryVersion":2,
        "sourceSwitchAttempts":0,"automaticSwitchAttempts":0,"manualSwitchAttempts":0,
        "successfulSourceSwitches":0,"automaticSourceSwitches":0,"manualSourceSwitches":0,
        "rebufferCount":0,"rebufferedMs":0,"maxRebufferMs":0,"seekCount":0}))
    .unwrap();
    e
}

#[test]
fn stable_v2_watch_preserves_channel_and_records_recovery_counters() {
    let mut c = db();
    let mut e = beta();
    e.recovery.build_channel = Some("stable".into());
    assert!(e.validate());
    ingest(&mut c, &e, 100_000).unwrap();
    e.sequence = 2;
    e.played_ms = 1000;
    set_switches(&mut e, 1);
    assert!(ingest(&mut c, &e, 101_000).unwrap());
    assert_eq!(saved(&c), (2, 1, 1000));
    let channel: String = c
        .query_row("SELECT channel FROM admin_recovery_playback", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(channel, "stable");
    let counters: (u64, u64) = c
        .query_row(
            "SELECT sum(attempts),sum(automatic_switches) FROM admin_recovery_usage",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(counters, (1, 1));
    e.sequence = 3;
    e.recovery.build_channel = Some("beta".into());
    assert!(
        ingest(&mut c, &e, 102_000).is_err(),
        "a watch cannot change channel while active"
    );
    assert_eq!(saved(&c), (2, 1, 1000));
}

fn db() -> Connection {
    let c = Connection::open_in_memory().unwrap();
    migrate(&c).unwrap();
    c
}

fn set_switches(e: &mut PlaybackEvent, n: u64) {
    e.source_switches = n;
    e.recovery.source_switch_attempts = Some(n);
    e.recovery.automatic_switch_attempts = Some(n);
    e.recovery.successful_source_switches = Some(n);
    e.recovery.automatic_source_switches = Some(n);
}

fn saved(c: &Connection) -> (u64, u64, u64) {
    c.query_row(
        "SELECT sequence,switches,played_ms FROM admin_sessions WHERE id='watch-1'",
        [],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )
    .unwrap()
}

#[test]
fn pre_migration_session_stays_legacy_without_backfilling_beta_counters() {
    let mut c = db();
    let mut first = legacy();
    first.played_ms = 1000;
    ingest(&mut c, &first, 100_000).unwrap();
    // A watch already present before cohort collection has no registry entry.
    c.execute("DELETE FROM admin_recovery_playback", [])
        .unwrap();
    let mut upgraded = beta();
    upgraded.sequence = 2;
    upgraded.played_ms = 2000;
    set_switches(&mut upgraded, 5);
    assert!(upgraded.validate());
    assert!(ingest(&mut c, &upgraded, 101_000).is_err());
    assert_eq!(saved(&c), (1, 0, 1000));
    assert_eq!(
        c.query_row("SELECT count(*) FROM admin_recovery_usage", [], |r| r
            .get::<_, u64>(0))
            .unwrap(),
        0
    );
    first.sequence = 2;
    first.played_ms = 2000;
    assert!(ingest(&mut c, &first, 101_000).unwrap());
    assert_eq!(
        c.query_row("SELECT channel FROM admin_recovery_playback", [], |r| {
            r.get::<_, String>(0)
        })
        .unwrap(),
        "legacy"
    );
}

#[test]
fn beta_watch_cannot_downgrade_telemetry_or_change_channel() {
    let mut c = db();
    let mut initial = beta();
    initial.played_ms = 1000;
    ingest(&mut c, &initial, 100_000).unwrap();
    for channel in [None, Some("stable"), Some("beta")] {
        let mut downgraded = legacy();
        downgraded.sequence = 2;
        downgraded.played_ms = 2000;
        downgraded.recovery.build_channel = channel.map(str::to_owned);
        assert!(downgraded.validate());
        assert!(ingest(&mut c, &downgraded, 101_000).is_err());
        assert_eq!(saved(&c), (1, 0, 1000));
    }
    initial.sequence = 2;
    initial.played_ms = 2000;
    assert!(ingest(&mut c, &initial, 101_000).unwrap());
}

#[test]
fn new_legacy_sessions_also_keep_their_original_channel() {
    let mut c = db();
    let mut e = legacy();
    e.recovery.build_channel = Some("stable".into());
    ingest(&mut c, &e, 100_000).unwrap();
    e.sequence = 2;
    for channel in [None, Some("beta")] {
        e.recovery.build_channel = channel.map(str::to_owned);
        assert!(ingest(&mut c, &e, 101_000).is_err());
    }
    e.recovery.build_channel = Some("stable".into());
    assert!(ingest(&mut c, &e, 101_000).unwrap());
}

#[test]
fn oversized_switch_delta_is_rejected_instead_of_diverging_between_ledgers() {
    let mut c = db();
    let mut e = beta();
    set_switches(&mut e, 1001);
    assert!(e.validate());
    assert!(ingest(&mut c, &e, 100_000).is_err());
    assert_eq!(
        c.query_row("SELECT count(*) FROM admin_sessions", [], |r| r
            .get::<_, u64>(0))
            .unwrap(),
        0
    );
    set_switches(&mut e, 0);
    ingest(&mut c, &e, 100_000).unwrap();
    e.sequence = 2;
    e.played_ms = 1000;
    set_switches(&mut e, 1000);
    assert!(ingest(&mut c, &e, 101_000).unwrap());
    e.sequence = 3;
    e.played_ms = 2000;
    set_switches(&mut e, 2001);
    assert!(ingest(&mut c, &e, 102_000).is_err());
    assert_eq!(saved(&c), (2, 1000, 1000));
    set_switches(&mut e, 2000);
    assert!(ingest(&mut c, &e, 102_000).unwrap());
    assert!(!ingest(&mut c, &e, 102_100).unwrap()); // Retried heartbeat cannot duplicate either ledger.
    let base: u64 = c
        .query_row("SELECT sum(switches) FROM admin_usage", [], |r| r.get(0))
        .unwrap();
    let classified: u64 = c
        .query_row(
            "SELECT sum(automatic_switches+manual_switches) FROM admin_recovery_usage",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(base, 2000);
    assert_eq!(classified, base);
}

#[test]
fn oversized_attempt_jump_rolls_back_base_session_and_usage_too() {
    let mut c = db();
    let mut e = beta();
    ingest(&mut c, &e, 100_000).unwrap();
    e.sequence = 2;
    e.played_ms = 1000;
    e.recovery.source_switch_attempts = Some(1001);
    e.recovery.automatic_switch_attempts = Some(1001);
    assert!(e.validate());
    assert!(ingest(&mut c, &e, 101_000).is_err());
    assert_eq!(saved(&c), (1, 0, 0));
    let played: u64 = c
        .query_row(
            "SELECT coalesce(sum(played_ms),0) FROM admin_usage",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(played, 0);
    e.recovery.source_switch_attempts = Some(1000);
    e.recovery.automatic_switch_attempts = Some(1000);
    assert!(ingest(&mut c, &e, 101_000).unwrap());
}

#[test]
fn longest_rebuffer_cannot_exceed_total_or_regress() {
    let mut c = db();
    let mut e = beta();
    e.buffered_ms = 1000;
    e.recovery.rebuffer_count = Some(1);
    e.recovery.rebuffered_ms = Some(1000);
    e.recovery.max_rebuffer_ms = Some(1001);
    assert!(!e.validate());
    e.recovery.max_rebuffer_ms = Some(900);
    assert!(e.validate());
    ingest(&mut c, &e, 100_000).unwrap();
    e.sequence = 2;
    e.buffered_ms = 2000;
    e.recovery.rebuffered_ms = Some(2000);
    e.recovery.max_rebuffer_ms = Some(800);
    assert!(e.validate());
    assert!(ingest(&mut c, &e, 101_000).is_err());
    assert_eq!(saved(&c), (1, 0, 0));
    e.recovery.max_rebuffer_ms = None;
    assert!(ingest(&mut c, &e, 101_000).is_err());
    e.recovery.max_rebuffer_ms = Some(1000);
    assert!(ingest(&mut c, &e, 101_000).unwrap());
}
