//! Private administration and bounded, best-effort playback accounting.
//! Analytics use their own WAL database so reporting cannot hold the watch-state lock.
use crate::{db::Db, pool::Pool};
use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Query, Request, State},
    http::{header, HeaderMap, StatusCode},
    middleware::{self, Next},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, RwLock},
    time::{Duration, Instant},
};

const DAY: i64 = 86_400_000;
const MINUTE: i64 = 60_000;
const COOKIE: &str = "velvet_admin";
const SESSION_TTL: i64 = 7 * DAY;
const RETENTION: i64 = 90 * DAY;
const HEARTBEAT_TTL: i64 = 45_000;

#[derive(Clone)]
pub struct AdminState(Arc<AdminInner>);
struct AdminInner {
    db: Db,
    profiles_db: Db,
    pool: Arc<Pool>,
    storage_path: PathBuf,
    key: String,
    app_token: String,
    sessions: Mutex<HashMap<String, i64>>,
    login_attempts: Mutex<VecDeque<i64>>,
    ingest_attempts: Mutex<VecDeque<i64>>,
    latest: RwLock<Value>,
    collected_at: i64,
    recovery_proxy: Option<crate::admin_recovery::Proxy>,
}
#[derive(Deserialize)]
pub struct ReportQuery {
    #[serde(default = "default_days")]
    pub days: u32,
    #[serde(rename = "type", default)]
    pub export_type: String,
}
fn default_days() -> u32 {
    7
}
pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
fn random_key() -> anyhow::Result<String> {
    let mut b = [0u8; 32];
    getrandom::getrandom(&mut b).map_err(|e| anyhow::anyhow!("secure randomness: {e}"))?;
    Ok(b.iter().map(|n| format!("{n:02x}")).collect())
}
fn constant_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.bytes().zip(b.bytes()).fold(0u8, |v, (a, b)| v | (a ^ b)) == 0
}
fn load_key(dir: &Path) -> anyhow::Result<String> {
    if let Ok(key) = std::env::var("VELVET_ADMIN_TOKEN") {
        anyhow::ensure!(
            key.trim().len() >= 24,
            "VELVET_ADMIN_TOKEN must contain at least 24 characters"
        );
        return Ok(key.trim().into());
    }
    let path = dir.join("velvet-admin-key");
    match std::fs::read_to_string(&path) {
        Ok(key) => return validate_key_file(key),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    let key = random_key()?;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    use std::io::Write;
    match options.open(&path) {
        Ok(mut f) => {
            writeln!(f, "{key}")?;
            f.sync_all()?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            return validate_key_file(std::fs::read_to_string(&path)?)
        }
        Err(e) => return Err(e.into()),
    }
    tracing::info!(
        "Admin portal enabled at /admin; private access key saved to {}",
        path.display()
    );
    Ok(key)
}

fn validate_key_file(key: String) -> anyhow::Result<String> {
    anyhow::ensure!(key.trim().len() >= 24, "admin access key file is invalid");
    Ok(key.trim().into())
}

pub fn router(
    cfg: &crate::config::Config,
    pool: Arc<Pool>,
    profiles_db: Db,
) -> anyhow::Result<Router> {
    let dir = Path::new(&cfg.db_path)
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let path = std::env::var("VELVET_ANALYTICS_DB")
        .map(PathBuf::from)
        .unwrap_or_else(|_| dir.join("velvet-analytics.db"));
    let db = crate::db::open(
        path.to_str()
            .ok_or_else(|| anyhow::anyhow!("invalid analytics path"))?,
    )?;
    let collected_at = {
        let conn = db.lock().unwrap();
        migrate(&conn)?;
        conn.query_row(
            "SELECT value FROM admin_meta WHERE key='collected_at'",
            [],
            |r| r.get::<_, String>(0),
        )?
        .parse::<i64>()?
    };
    let st = AdminState(Arc::new(AdminInner {
        db,
        profiles_db,
        pool,
        storage_path: dir.into(),
        key: load_key(dir)?,
        app_token: cfg.token.clone(),
        sessions: Mutex::new(HashMap::new()),
        login_attempts: Mutex::new(VecDeque::new()),
        ingest_attempts: Mutex::new(VecDeque::new()),
        latest: RwLock::new(Value::Null),
        collected_at,
        recovery_proxy: crate::admin_recovery::Proxy::from_env()?,
    }));
    tokio::spawn(sample_loop(st.clone()));
    Ok(routes(st))
}
fn routes(st: AdminState) -> Router {
    let private = Router::new()
        .route("/admin/api/report", get(report))
        .route("/admin/api/live", get(live))
        .route("/admin/api/export", get(export))
        .route("/admin/api/recovery", get(recovery_report))
        .route("/admin/api/recovery/export", get(recovery_export))
        .route("/admin/api/logout", post(logout))
        .route_layer(middleware::from_fn_with_state(st.clone(), require_admin));
    Router::new()
        .merge(private)
        .route("/admin", get(index))
        .route("/admin/", get(index))
        .route("/admin/admin.css", get(css))
        .route("/admin/admin.js", get(js))
        .route("/admin/api/login", post(login))
        .route("/telemetry/playback", post(telemetry))
        .layer(DefaultBodyLimit::max(16 * 1024))
        .layer(middleware::from_fn(security_headers))
        .with_state(st)
}
async fn index() -> Html<&'static str> {
    Html(include_str!("../admin/index.html"))
}
async fn css() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
        include_str!("../admin/admin.css"),
    )
}
async fn js() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        include_str!("../admin/admin.js"),
    )
}
async fn security_headers(req: Request, next: Next) -> Response {
    let mut response = next.run(req).await;
    for (k,v) in [("cache-control","no-store"),("x-content-type-options","nosniff"),("referrer-policy","no-referrer"),("x-frame-options","DENY"),("content-security-policy","default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")] {
        response.headers_mut().insert(axum::http::HeaderName::from_static(k), axum::http::HeaderValue::from_static(v));
    }
    response
}
fn cookie(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|s| s.trim().strip_prefix("velvet_admin="))
}
fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}
fn same_origin(headers: &HeaderMap) -> bool {
    let Some(origin) = headers.get(header::ORIGIN) else {
        return true;
    };
    let Some(host) = headers.get(header::HOST).and_then(|v| v.to_str().ok()) else {
        return false;
    };
    let Ok(url) = reqwest::Url::parse(origin.to_str().unwrap_or("")) else {
        return false;
    };
    let authority = match url.port() {
        Some(p) => format!("{}:{p}", url.host_str().unwrap_or("")),
        None => url.host_str().unwrap_or("").into(),
    };
    matches!(url.scheme(), "https" | "http") && authority.eq_ignore_ascii_case(host)
}
async fn require_admin(State(st): State<AdminState>, req: Request, next: Next) -> Response {
    let now = now_ms();
    let valid = bearer(req.headers()).is_some_and(|v| constant_eq(v, &st.0.key))
        || cookie(req.headers()).is_some_and(|c| {
            let mut sessions = st.0.sessions.lock().unwrap();
            sessions.retain(|_, expires| *expires > now);
            sessions.get(c).is_some()
        });
    if !valid {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"Admin sign-in required"})),
        )
            .into_response();
    }
    if req.method() != axum::http::Method::GET && !same_origin(req.headers()) {
        return StatusCode::FORBIDDEN.into_response();
    }
    next.run(req).await
}
#[derive(Deserialize)]
struct Login {
    token: String,
}
async fn login(
    State(st): State<AdminState>,
    headers: HeaderMap,
    Json(input): Json<Login>,
) -> Response {
    if !same_origin(&headers) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let now = now_ms();
    {
        let mut attempts = st.0.login_attempts.lock().unwrap();
        attempts.retain(|t| now - *t < MINUTE);
        if attempts.len() >= 20 {
            return (
                StatusCode::TOO_MANY_REQUESTS,
                Json(json!({"error":"Too many attempts. Try again in a minute."})),
            )
                .into_response();
        }
        attempts.push_back(now);
    }
    if !constant_eq(input.token.trim(), &st.0.key) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"That access key was not recognized."})),
        )
            .into_response();
    }
    let Ok(key) = random_key() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    {
        let mut sessions = st.0.sessions.lock().unwrap();
        sessions.retain(|_, v| *v > now);
        if sessions.len() >= 32 {
            sessions.clear();
        }
        sessions.insert(key.clone(), now + SESSION_TTL);
    }
    // Secure cookies for every deployment except explicit loopback development.
    let local = headers
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|h| {
            h == "localhost" || h.starts_with("localhost:") || h.starts_with("127.0.0.1:")
        });
    let value = format!(
        "{COOKIE}={key}; Path=/admin; HttpOnly; SameSite=Strict; Max-Age={}{}",
        SESSION_TTL / 1000,
        if local { "" } else { "; Secure" }
    );
    ([(header::SET_COOKIE, value)], Json(json!({"ok":true}))).into_response()
}
async fn logout(State(st): State<AdminState>, headers: HeaderMap) -> Response {
    if let Some(key) = cookie(&headers) {
        st.0.sessions.lock().unwrap().remove(key);
    }
    (
        [(
            header::SET_COOKIE,
            format!("{COOKIE}=; Path=/admin; HttpOnly; SameSite=Strict; Secure; Max-Age=0"),
        )],
        Json(json!({"ok":true})),
    )
        .into_response()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackEvent {
    session_id: String,
    sequence: u64,
    device_id: String,
    #[serde(default)]
    device_name: String,
    platform: String,
    #[serde(default)]
    app_version: String,
    profile_id: String,
    #[serde(default)]
    profile_name: Option<String>,
    kind: String,
    media_id: String,
    title: String,
    #[serde(default)]
    season: Option<u32>,
    #[serde(default)]
    episode: Option<u32>,
    state: String,
    played_ms: u64,
    #[serde(default)]
    buffered_ms: u64,
    #[serde(default)]
    position_ms: Option<u64>,
    #[serde(default)]
    startup_ms: Option<u64>,
    #[serde(default)]
    error_count: u64,
    #[serde(default)]
    source_switches: u64,
    #[serde(flatten)]
    recovery: crate::admin_recovery::ClientCounters,
}
fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.:".contains(&c))
}
fn clean_text(s: &str, max: usize) -> bool {
    s.chars().count() <= max && !s.chars().any(|c| c.is_control())
}
impl PlaybackEvent {
    fn validate(&self) -> bool {
        valid_id(&self.session_id)
            && valid_id(&self.device_id)
            && valid_id(&self.profile_id)
            && clean_text(&self.media_id, 128)
            && !self.media_id.is_empty()
            && matches!(self.platform.as_str(), "android" | "ios" | "roku")
            && matches!(
                self.kind.as_str(),
                "movie" | "tv" | "live_tv" | "live_sports"
            )
            && matches!(
                self.state.as_str(),
                "playing" | "paused" | "buffering" | "ended" | "error"
            )
            && clean_text(&self.title, 500)
            && clean_text(&self.device_name, 120)
            && clean_text(&self.app_version, 40)
            && self
                .profile_name
                .as_ref()
                .is_none_or(|s| clean_text(s, 120))
            && self.sequence < i64::MAX as u64
            && self.played_ms < 31_536_000_000
            && self.buffered_ms < 31_536_000_000
            && self.error_count <= 100_000
            && self.source_switches <= 100_000
            && self.recovery.validate(self.source_switches)
            && self.startup_ms.is_none_or(|s| s <= 3_600_000)
            && self.position_ms.is_none_or(|s| s < 31_536_000_000)
            && self.season.is_none_or(|n| n < 10000)
            && self.episode.is_none_or(|n| n < 100000)
    }
}
async fn telemetry(State(st): State<AdminState>, headers: HeaderMap, body: Bytes) -> Response {
    if !st.0.app_token.is_empty()
        && !bearer(&headers).is_some_and(|v| constant_eq(v, &st.0.app_token))
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let now = now_ms();
    {
        let mut attempts = st.0.ingest_attempts.lock().unwrap();
        attempts.retain(|t| now - *t < MINUTE);
        if attempts.len() >= 1200 {
            return StatusCode::TOO_MANY_REQUESTS.into_response();
        }
        attempts.push_back(now);
    }
    let mut event: PlaybackEvent = match serde_json::from_slice(&body) {
        Ok(e) => e,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error":"Invalid playback report"})),
            )
                .into_response()
        }
    };
    if !event.validate() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"Invalid playback report"})),
        )
            .into_response();
    }
    let db = st.0.db.clone();
    let profiles_db = st.0.profiles_db.clone();
    match tokio::task::spawn_blocking(move || {
        // Canonical names are already synced; clients need only send the profile ID.
        // Release the watch-state lock before touching the separate analytics database.
        enrich_profile(&profiles_db.lock().unwrap(), &mut event);
        ingest(&mut db.lock().unwrap(), &event, now)
    })
    .await
    {
        Ok(Ok(applied)) => Json(json!({"ok":true,"applied":applied})).into_response(),
        _ => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}

fn enrich_profile(c: &Connection, event: &mut PlaybackEvent) {
    let name = c
        .query_row(
            "SELECT name FROM profiles WHERE id=?1 AND deleted=0",
            [&event.profile_id],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .ok()
        .flatten();
    if let Some(name) = name.filter(|n| !n.trim().is_empty()) {
        event.profile_name = Some(name.chars().filter(|c| !c.is_control()).take(120).collect());
    } else if event.profile_name.is_none() && event.profile_id == "default" {
        event.profile_name = Some("Default profile".into());
    }
}

pub fn migrate(c: &Connection) -> anyhow::Result<()> {
    crate::admin_recovery::migrate(c)?;
    c.execute_batch("CREATE TABLE IF NOT EXISTS admin_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS admin_sessions(
      id TEXT PRIMARY KEY,device_id TEXT NOT NULL,device_name TEXT NOT NULL,platform TEXT NOT NULL,app_version TEXT NOT NULL,
      profile_id TEXT NOT NULL,profile_name TEXT NOT NULL,kind TEXT NOT NULL,media_id TEXT NOT NULL,title TEXT NOT NULL,season INTEGER,episode INTEGER,
      first_seen INTEGER NOT NULL,last_seen INTEGER NOT NULL,sequence INTEGER NOT NULL,state TEXT NOT NULL,
      played_counter INTEGER NOT NULL,buffer_counter INTEGER NOT NULL,played_ms INTEGER NOT NULL,buffered_ms INTEGER NOT NULL,
      position_ms INTEGER,startup_ms INTEGER,error_count INTEGER NOT NULL,switches INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS admin_sessions_seen ON admin_sessions(last_seen);
    CREATE INDEX IF NOT EXISTS admin_sessions_first ON admin_sessions(first_seen);
    CREATE TABLE IF NOT EXISTS admin_usage(bucket INTEGER NOT NULL,session_id TEXT NOT NULL,played_ms INTEGER NOT NULL DEFAULT 0,buffered_ms INTEGER NOT NULL DEFAULT 0,errors INTEGER NOT NULL DEFAULT 0,switches INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(bucket,session_id));
    CREATE INDEX IF NOT EXISTS admin_usage_session ON admin_usage(session_id,bucket);
    CREATE TABLE IF NOT EXISTS admin_capacity(
      ts INTEGER PRIMARY KEY,interval_ms INTEGER NOT NULL,capacity INTEGER,busy INTEGER,open INTEGER,idle INTEGER,free INTEGER,waiters INTEGER,active_sessions INTEGER,
      bytes_delta INTEGER,wait_us_delta INTEGER,wait_count_delta INTEGER,errors_delta INTEGER,missing_delta INTEGER,found_delta INTEGER,fallback_delta INTEGER,
      cpu_percent REAL,rss_bytes INTEGER,memory_limit_bytes INTEGER,disk_free_bytes INTEGER,disk_total_bytes INTEGER);
    CREATE TABLE IF NOT EXISTS admin_providers(
      ts INTEGER NOT NULL,id TEXT NOT NULL,name TEXT NOT NULL,capacity INTEGER,busy INTEGER,open INTEGER,idle INTEGER,free INTEGER,waiters INTEGER,
      bytes_delta INTEGER,wait_us_delta INTEGER,wait_count_delta INTEGER,errors_delta INTEGER,missing_delta INTEGER,found_delta INTEGER,fallback_delta INTEGER,PRIMARY KEY(ts,id));
    CREATE INDEX IF NOT EXISTS admin_providers_id ON admin_providers(id,ts);")?;
    c.execute(
        "INSERT OR IGNORE INTO admin_meta(key,value) VALUES('collected_at',?1)",
        [now_ms().to_string()],
    )?;
    Ok(())
}

fn ingest(c: &mut Connection, e: &PlaybackEvent, now: i64) -> anyhow::Result<bool> {
    type Prior = (
        u64,
        i64,
        u64,
        u64,
        u64,
        u64,
        String,
        String,
        String,
        String,
        String,
        String,
        Option<u32>,
        Option<u32>,
    );
    let prior:Option<Prior>=c.query_row("SELECT sequence,last_seen,played_counter,buffer_counter,error_count,switches,device_id,profile_id,kind,media_id,state,platform,season,episode FROM admin_sessions WHERE id=?1",[&e.session_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?,r.get(9)?,r.get(10)?,r.get(11)?,r.get(12)?,r.get(13)?))).optional()?;
    let (elapsed, played, buffered, errors, switches) = if let Some((
        seq,
        last,
        p,
        b,
        err,
        sw,
        device,
        profile,
        kind,
        media,
        state,
        platform,
        season,
        episode,
    )) = prior
    {
        if e.sequence <= seq {
            return Ok(false);
        }
        anyhow::ensure!(
            e.device_id == device
                && e.profile_id == profile
                && e.kind == kind
                && e.media_id == media
                && e.platform == platform
                && e.season == season
                && e.episode == episode,
            "session identity changed"
        );
        if state == "ended" {
            return Ok(false);
        }
        crate::admin_recovery::validate_cohort(c, &e.session_id, &e.recovery, true)?;
        anyhow::ensure!(
            e.played_ms >= p
                && e.buffered_ms >= b
                && e.error_count >= err
                && e.source_switches >= sw,
            "counters moved backwards"
        );
        // Bound an offline jump; position and untrusted client timestamps never create watch time.
        (
            (now - last).clamp(0, 120_000) as u64,
            e.played_ms - p,
            e.buffered_ms - b,
            e.error_count - err,
            e.source_switches - sw,
        )
    } else {
        let recent: i64 = c.query_row(
            "SELECT count(*) FROM admin_sessions WHERE first_seen>=?1",
            [now - DAY],
            |r| r.get(0),
        )?;
        anyhow::ensure!(recent < 20_000, "new session daily limit reached");
        (
            30_000,
            e.played_ms,
            e.buffered_ms,
            e.error_count,
            e.source_switches,
        )
    };
    anyhow::ensure!(
        !e.recovery.supported() || switches <= 1_000,
        "recovery switch delta exceeds limit"
    );
    // Small clock jitter tolerance, never a wall-clock seek delta.
    let budget = (elapsed + 1000).min(120_000);
    let total = played.saturating_add(buffered);
    let accepted = total.min(budget);
    let played = if total > budget && total > 0 {
        (played as u128 * accepted as u128 / total as u128) as u64
    } else {
        played
    };
    let buffered = accepted.saturating_sub(played);
    let profile = e
        .profile_name
        .as_deref()
        .filter(|s| !s.is_empty())
        .unwrap_or(&e.profile_id);
    let tx = c.transaction()?;
    tx.execute("INSERT INTO admin_sessions(id,device_id,device_name,platform,app_version,profile_id,profile_name,kind,media_id,title,season,episode,first_seen,last_seen,sequence,state,played_counter,buffer_counter,played_ms,buffered_ms,position_ms,startup_ms,error_count,switches)
      VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23)
      ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen,sequence=excluded.sequence,state=excluded.state,played_counter=excluded.played_counter,buffer_counter=excluded.buffer_counter,
      played_ms=admin_sessions.played_ms+excluded.played_ms,buffered_ms=admin_sessions.buffered_ms+excluded.buffered_ms,position_ms=excluded.position_ms,startup_ms=coalesce(admin_sessions.startup_ms,excluded.startup_ms),error_count=excluded.error_count,switches=excluded.switches,device_name=excluded.device_name,app_version=excluded.app_version,profile_name=excluded.profile_name",
      params![e.session_id,e.device_id,e.device_name,e.platform,e.app_version,e.profile_id,profile,e.kind,e.media_id,e.title,e.season,e.episode,now,e.sequence,e.state,e.played_ms,e.buffered_ms,played,buffered,e.position_ms,e.startup_ms,e.error_count,e.source_switches])?;
    // Split intervals across minute/day boundaries instead of assigning midnight playback to the wrong day.
    let span = accepted as i64;
    let mut t = now - span;
    let mut left_p = played;
    let mut left_b = buffered;
    let mut buffered_intervals = Vec::new();
    while t < now {
        let end = ((t.div_euclid(MINUTE) + 1) * MINUTE).min(now);
        let duration = (end - t) as u64;
        let p = if end == now {
            left_p
        } else {
            played * duration / (span as u64).max(1)
        };
        let b = if end == now {
            left_b
        } else {
            buffered * duration / (span as u64).max(1)
        };
        left_p -= p;
        left_b -= b;
        buffered_intervals.push((t.div_euclid(MINUTE) * MINUTE, b));
        tx.execute("INSERT INTO admin_usage(bucket,session_id,played_ms,buffered_ms) VALUES(?1,?2,?3,?4) ON CONFLICT(bucket,session_id) DO UPDATE SET played_ms=played_ms+excluded.played_ms,buffered_ms=buffered_ms+excluded.buffered_ms",params![t.div_euclid(MINUTE)*MINUTE,e.session_id,p,b])?;
        t = end;
    }
    tx.execute("INSERT INTO admin_usage(bucket,session_id,errors,switches) VALUES(?1,?2,?3,?4) ON CONFLICT(bucket,session_id) DO UPDATE SET errors=errors+excluded.errors,switches=switches+excluded.switches",params![now.div_euclid(MINUTE)*MINUTE,e.session_id,errors.min(1000),switches.min(1000)])?;
    crate::admin_recovery::record_client(
        &tx,
        &e.session_id,
        &e.recovery,
        now,
        buffered,
        &buffered_intervals,
    )?;
    tx.commit()?;
    Ok(true)
}

fn n(v: &Value, key: &str) -> i64 {
    v.get(key)
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .min(i64::MAX as u64) as i64
}
fn delta(v: &Value, old: &Value, key: &str) -> i64 {
    if old.is_null() {
        0
    } else {
        (n(v, key) - n(old, key)).max(0)
    }
}
fn resolved_waits(m: &Value, old: &Value) -> i64 {
    delta(m, old, "queue_wait_completed") + delta(m, old, "queue_wait_cancelled")
}
fn normalized_cpu(host: &Value, old: &Value, ms: i64) -> Option<f64> {
    if ms <= 0 || ms > 45_000 {
        return None;
    }
    let key = if host["cgroup_cpu_seconds"].is_number() {
        "cgroup_cpu_seconds"
    } else {
        "cpu_seconds"
    };
    let available = host["cpu_available_cores"].as_f64().filter(|n| *n > 0.0)?;
    let cores = host["cpu_limit_cores"]
        .as_f64()
        .filter(|n| *n > 0.0)
        .map(|n| n.min(available))
        .unwrap_or(available);
    host[key]
        .as_f64()
        .zip(old[key].as_f64())
        .filter(|(a, b)| a >= b)
        .map(|(a, b)| ((a - b) * 100_000.0 / ms as f64 / cores).clamp(0.0, 100.0))
}
fn memory_used(host: &Value) -> Option<i64> {
    host["cgroup_memory_bytes"]
        .as_i64()
        .or(host["rss_bytes"].as_i64())
}
fn metric(m: &Value, old: &Value, ms: i64) -> Value {
    let capacity = n(m, "capacity");
    let busy = n(m, "busy_connections");
    json!({"capacity":capacity,"open":n(m,"open_connections"),"idle":n(m,"idle_connections"),"busy":busy,"free":n(m,"free_connections"),"unused":n(m,"unused_slots"),"waiters":n(m,"waiters"),"utilizationPct":if capacity>0 {busy as f64/capacity as f64*100.0}else{0.0},"downloadBps":delta(m,old,"bytes_downloaded") as f64*1000.0/ms.max(1) as f64,"queueWaitMs":if resolved_waits(m,old)>0 {Some(delta(m,old,"queue_wait_micros") as f64/1000.0/resolved_waits(m,old) as f64)}else{None},"errors":n(m,"connection_errors")+n(m,"article_errors"),"missing":n(m,"articles_missing"),"found":n(m,"articles_found"),"fallbackSuccesses":n(m,"fallback_successes")})
}
async fn sample_loop(st: AdminState) {
    let mut ticker = tokio::time::interval(Duration::from_secs(15));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut previous = Value::Null;
    let mut old_host = Value::Null;
    let mut last = Instant::now();
    let mut count = 0u64;
    loop {
        ticker.tick().await;
        let now = now_ms();
        let ms = last.elapsed().as_millis().min(i64::MAX as u128) as i64;
        last = Instant::now();
        let snap = serde_json::to_value(st.0.pool.metrics_snapshot().await).unwrap_or(Value::Null);
        let host = serde_json::to_value(crate::capacity::host_metrics_snapshot(&st.0.storage_path))
            .unwrap_or(Value::Null);
        // A long scheduler pause is missing coverage, not a fast burst of traffic.
        if ms > 45_000 {
            previous = Value::Null;
            old_host = Value::Null;
        }
        let cpu = normalized_cpu(&host, &old_host, ms);
        let memory = host["memory_limit_bytes"]
            .as_u64()
            .or(host["memory_total_bytes"].as_u64());
        let live_host = json!({"cpuPercent":cpu,"rssBytes":memory_used(&host),"memoryLimitBytes":memory,"cpuScope":if host["cgroup_cpu_seconds"].is_number(){"container"}else{"process"},"memoryScope":if host["cgroup_memory_bytes"].is_number(){"container"}else{"process"},"diskFreeBytes":host["disk_free_bytes"],"diskTotalBytes":host["disk_total_bytes"]});
        let mut total = metric(&snap["total"], &previous["total"], ms);
        let providers: Vec<Value> = snap["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|p| {
                let old = previous["providers"]
                    .as_array()
                    .and_then(|all| all.iter().find(|o| o["id"] == p["id"]))
                    .cloned()
                    .unwrap_or(Value::Null);
                let mut row = metric(&p["metrics"], &old["metrics"], ms);
                row["id"] = p["id"].clone();
                row["name"] = p["name"].clone();
                row
            })
            .collect();
        total["providers"] = json!(providers);
        *st.0.latest.write().unwrap() = json!({"generatedAt":now,"collectionStartedAt":st.0.collected_at,"capacity":total,"host":live_host,"coverage":{"message":"Playback totals require updated Velvet apps. Capacity includes playback, prewarming and availability checks. Idle open connections are reusable; provider limits describe this backend’s configured budgets."}});
        let db = st.0.db.clone();
        let current = snap.clone();
        let old = previous.clone();
        let host_copy = host.clone();
        count += 1;
        if let Err(e) = tokio::task::spawn_blocking(move || {
            let mut conn = db.lock().unwrap();
            save_sample(&mut conn, now, ms, &current, &old, &host_copy, cpu)?;
            if count % 240 == 0 {
                crate::admin_recovery::prune(&conn, now - RETENTION)?;
                conn.execute("DELETE FROM admin_capacity WHERE ts<?1", [now - RETENTION])?;
                conn.execute("DELETE FROM admin_providers WHERE ts<?1", [now - RETENTION])?;
                conn.execute("DELETE FROM admin_usage WHERE bucket<?1", [now - RETENTION])?;
                conn.execute(
                    "DELETE FROM admin_sessions WHERE last_seen<?1",
                    [now - RETENTION],
                )?;
            }
            Ok::<_, anyhow::Error>(())
        })
        .await
        .unwrap_or_else(|e| Err(e.into()))
        {
            tracing::warn!("analytics sampling unavailable: {e}");
        }
        previous = snap;
        old_host = host;
    }
}
fn save_sample(
    c: &mut Connection,
    now: i64,
    ms: i64,
    snap: &Value,
    old: &Value,
    host: &Value,
    cpu: Option<f64>,
) -> anyhow::Result<()> {
    let m = &snap["total"];
    let p = &old["total"];
    let tx = c.transaction()?;
    let active: i64 = tx.query_row(
        "SELECT count(*) FROM admin_sessions WHERE last_seen>?1 AND state='playing'",
        [now - HEARTBEAT_TTL],
        |r| r.get(0),
    )?;
    tx.execute("INSERT OR REPLACE INTO admin_capacity VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)",params![now,if old.is_null(){0}else{ms},n(m,"capacity"),n(m,"busy_connections"),n(m,"open_connections"),n(m,"idle_connections"),n(m,"free_connections"),n(m,"waiters"),active,delta(m,p,"bytes_downloaded"),delta(m,p,"queue_wait_micros"),resolved_waits(m,p),delta(m,p,"connection_errors")+delta(m,p,"article_errors"),delta(m,p,"articles_missing"),delta(m,p,"articles_found"),delta(m,p,"fallback_successes"),cpu,memory_used(host),host["memory_limit_bytes"].as_i64().or(host["memory_total_bytes"].as_i64()),host["disk_free_bytes"].as_i64(),host["disk_total_bytes"].as_i64()])?;
    for row in snap["providers"].as_array().into_iter().flatten() {
        let prev = old["providers"]
            .as_array()
            .and_then(|all| all.iter().find(|o| o["id"] == row["id"]))
            .cloned()
            .unwrap_or(Value::Null);
        let m = &row["metrics"];
        let p = &prev["metrics"];
        tx.execute("INSERT OR REPLACE INTO admin_providers VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",params![now,row["id"].as_str().unwrap_or("provider"),row["name"].as_str().unwrap_or("Provider"),n(m,"capacity"),n(m,"busy_connections"),n(m,"open_connections"),n(m,"idle_connections"),n(m,"free_connections"),n(m,"waiters"),delta(m,p,"bytes_downloaded"),delta(m,p,"queue_wait_micros"),resolved_waits(m,p),delta(m,p,"connection_errors")+delta(m,p,"article_errors"),delta(m,p,"articles_missing"),delta(m,p,"articles_found"),delta(m,p,"fallback_successes")])?;
    }
    tx.commit()?;
    Ok(())
}
async fn live(State(st): State<AdminState>) -> Response {
    let mut result = st.0.latest.read().unwrap().clone();
    if result.is_null() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"Collecting the first capacity sample"})),
        )
            .into_response();
    }
    let db = st.0.db.clone();
    match tokio::task::spawn_blocking(move || {
        crate::admin_report::active_sessions(&db.lock().unwrap(), now_ms())
    })
    .await
    {
        Ok(Ok(sessions)) => {
            result["activeSessions"] = json!(sessions);
            Json(result).into_response()
        }
        _ => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}
async fn report(State(st): State<AdminState>, Query(q): Query<ReportQuery>) -> Response {
    if !(1..=90).contains(&q.days) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error":"Choose between 1 and 90 days"})),
        )
            .into_response();
    }
    let db = st.0.db.clone();
    let started = st.0.collected_at;
    let live = st.0.latest.read().unwrap().clone();
    match tokio::task::spawn_blocking(move || {
        crate::admin_report::report(&db.lock().unwrap(), q.days, started, now_ms(), &live)
    })
    .await
    {
        Ok(Ok(v)) => Json(v).into_response(),
        Ok(Err(e)) => {
            tracing::warn!("admin report: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
        _ => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}
async fn export(State(st): State<AdminState>, Query(q): Query<ReportQuery>) -> Response {
    if !(1..=90).contains(&q.days) || !matches!(q.export_type.as_str(), "playback" | "capacity") {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let db = st.0.db.clone();
    let name = format!("velvet-{}-{}days.csv", q.export_type, q.days);
    match tokio::task::spawn_blocking(move || {
        crate::admin_report::export(&db.lock().unwrap(), q.days, &q.export_type, now_ms())
    })
    .await
    {
        Ok(Ok(csv)) => (
            [
                (header::CONTENT_TYPE, "text/csv; charset=utf-8"),
                (
                    header::CONTENT_DISPOSITION,
                    &format!("attachment; filename=\"{name}\""),
                ),
            ],
            csv,
        )
            .into_response(),
        _ => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn recovery_report(
    State(st): State<AdminState>,
    headers: HeaderMap,
    Query(q): Query<ReportQuery>,
) -> Response {
    if !(1..=90).contains(&q.days) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    if let Some(proxy) = &st.0.recovery_proxy {
        if headers.contains_key("X-Velvet-Recovery-Proxy") {
            return StatusCode::BAD_GATEWAY.into_response();
        }
        return match proxy.fetch(q.days,false).await {
            Ok(bytes)=>match serde_json::from_slice::<Value>(&bytes){Ok(v) if v.is_object()=>Json(v).into_response(),_=>StatusCode::BAD_GATEWAY.into_response()},
            Err(_)=>(StatusCode::SERVICE_UNAVAILABLE,Json(json!({"available":false,"scope":"beta","message":"The beta backend is unavailable. Existing server reporting is unaffected."}))).into_response(),
        };
    }
    let db = st.0.db.clone();
    match tokio::task::spawn_blocking(move || {
        crate::admin_recovery::report(&db.lock().unwrap(), q.days, now_ms())
    })
    .await
    {
        Ok(Ok(value)) => Json(value).into_response(),
        Ok(Err(e)) => {
            tracing::warn!("recovery report: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
        _ => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}
async fn recovery_export(
    State(st): State<AdminState>,
    headers: HeaderMap,
    Query(q): Query<ReportQuery>,
) -> Response {
    if !(1..=90).contains(&q.days) {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let bytes = if let Some(proxy) = &st.0.recovery_proxy {
        if headers.contains_key("X-Velvet-Recovery-Proxy") {
            return StatusCode::BAD_GATEWAY.into_response();
        }
        proxy.fetch(q.days, true).await.ok()
    } else {
        let db = st.0.db.clone();
        tokio::task::spawn_blocking(move || {
            crate::admin_recovery::export(&db.lock().unwrap(), q.days, now_ms())
        })
        .await
        .ok()
        .and_then(Result::ok)
        .map(String::into_bytes)
    };
    match bytes {
        Some(value) => (
            [
                (header::CONTENT_TYPE, "text/csv; charset=utf-8"),
                (
                    header::CONTENT_DISPOSITION,
                    "attachment; filename=\"velvet-beta-watches.csv\"",
                ),
            ],
            value,
        )
            .into_response(),
        None => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}

#[cfg(test)]
#[path = "admin_recovery_ingest_tests.rs"]
mod recovery_ingest_tests;

#[cfg(test)]
mod tests {
    use super::*;
    fn event() -> PlaybackEvent {
        serde_json::from_value(json!({"sessionId":"test-session","sequence":1,"deviceId":"device-1","deviceName":"Shield","platform":"android","appVersion":"1","profileId":"profile-2","profileName":"Sam","kind":"tv","mediaId":"123","title":"Example","state":"playing","playedMs":0,"bufferedMs":0})).unwrap()
    }
    #[test]
    fn counts_actual_deltas_once_and_ignores_position() {
        let mut c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        let mut e = event();
        ingest(&mut c, &e, 100_000).unwrap();
        e.sequence = 2;
        e.played_ms = 15_000;
        e.position_ms = Some(500_000);
        assert!(ingest(&mut c, &e, 115_000).unwrap());
        assert!(!ingest(&mut c, &e, 115_001).unwrap());
        let p: i64 = c
            .query_row("SELECT sum(played_ms) FROM admin_usage", [], |r| r.get(0))
            .unwrap();
        assert_eq!(p, 15000);
        e.sequence = 3;
        e.state = "paused".into();
        e.position_ms = Some(999_000);
        ingest(&mut c, &e, 130_000).unwrap();
        let p: i64 = c
            .query_row("SELECT played_ms FROM admin_sessions", [], |r| r.get(0))
            .unwrap();
        assert_eq!(p, 15000);
    }
    #[test]
    fn splits_midnight_and_bounds_untrusted_counter_jumps() {
        let mut c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        let mut e = event();
        ingest(&mut c, &e, DAY - 10_000).unwrap();
        e.sequence = 2;
        e.played_ms = 20_000;
        ingest(&mut c, &e, DAY + 10_000).unwrap();
        let before: i64 = c
            .query_row(
                "SELECT sum(played_ms) FROM admin_usage WHERE bucket<?1",
                [DAY],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(before, 10000);
        e.sequence = 3;
        e.played_ms = 1_000_000;
        ingest(&mut c, &e, DAY + 11_000).unwrap();
        let all: i64 = c
            .query_row("SELECT sum(played_ms) FROM admin_usage", [], |r| r.get(0))
            .unwrap();
        assert_eq!(all, 22000);
    }
    #[test]
    fn ended_sessions_cannot_resurrect_or_change_identity() {
        let mut c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        let mut e = event();
        ingest(&mut c, &e, 1000).unwrap();
        e.sequence = 2;
        e.profile_id = "other".into();
        assert!(ingest(&mut c, &e, 2000).is_err());
        e.profile_id = "profile-2".into();
        e.state = "ended".into();
        ingest(&mut c, &e, 2000).unwrap();
        e.sequence = 3;
        e.state = "playing".into();
        assert!(!ingest(&mut c, &e, 3000).unwrap());
    }
    #[test]
    fn rejects_invalid_payloads() {
        let mut e = event();
        assert!(e.validate());
        e.kind = "other".into();
        assert!(!e.validate());
        e.kind = "tv".into();
        e.device_id = "bad\n".into();
        assert!(!e.validate());
    }
    #[test]
    fn cookie_and_origin_are_scoped() {
        let mut h = HeaderMap::new();
        h.insert(
            header::COOKIE,
            "other=abc; velvet_admin=secret; x=2".parse().unwrap(),
        );
        assert_eq!(cookie(&h), Some("secret"));
        h.insert(header::HOST, "velvet.example".parse().unwrap());
        h.insert(header::ORIGIN, "https://attacker.example".parse().unwrap());
        assert!(!same_origin(&h));
        h.insert(header::ORIGIN, "https://velvet.example".parse().unwrap());
        assert!(same_origin(&h));
        assert!(!constant_eq("aaa", "aab"));
    }
    #[test]
    fn episode_identity_and_cancelled_queue_time_are_preserved() {
        let mut c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        let mut e = event();
        e.season = Some(1);
        e.episode = Some(2);
        ingest(&mut c, &e, 1_000).unwrap();
        e.sequence = 2;
        e.episode = Some(3);
        assert!(ingest(&mut c, &e, 2_000).is_err());
        let old =
            json!({"queue_wait_completed":2,"queue_wait_cancelled":1,"queue_wait_micros":1000});
        let current =
            json!({"queue_wait_completed":3,"queue_wait_cancelled":2,"queue_wait_micros":5000});
        assert_eq!(resolved_waits(&current, &old), 2);
        assert_eq!(metric(&current, &old, 15_000)["queueWaitMs"], 2.0);
        assert_eq!(delta(&old, &current, "queue_wait_micros"), 0);
        assert_eq!(delta(&current, &Value::Null, "queue_wait_micros"), 0);
    }
    #[test]
    fn container_cpu_is_normalized_and_missing_intervals_stay_unknown() {
        let old = json!({"cgroup_cpu_seconds":100.0,"cpu_seconds":1.0});
        let current = json!({"cgroup_cpu_seconds":110.0,"cpu_seconds":2.0,"cpu_available_cores":8,"cpu_limit_cores":2.0});
        assert_eq!(normalized_cpu(&current, &old, 10_000), Some(50.0));
        assert_eq!(normalized_cpu(&current, &old, 120_000), None);
        assert_eq!(normalized_cpu(&current, &Value::Null, 15_000), None);
        assert_eq!(
            memory_used(&json!({"cgroup_memory_bytes":500,"rss_bytes":100})),
            Some(500)
        );
    }
    #[tokio::test]
    async fn http_admin_auth_cookie_origin_exports_and_ingest_are_isolated() {
        let db = crate::db::open(":memory:").unwrap();
        migrate(&db.lock().unwrap()).unwrap();
        let state = AdminState(Arc::new(AdminInner {
            db: db.clone(),
            profiles_db: db.clone(),
            pool: Pool::new(&[]),
            storage_path: std::env::temp_dir(),
            key: "private-admin-key-for-tests-only".into(),
            app_token: "separate-app-token".into(),
            sessions: Mutex::new(HashMap::new()),
            login_attempts: Mutex::new(VecDeque::new()),
            ingest_attempts: Mutex::new(VecDeque::new()),
            latest: RwLock::new(json!({})),
            collected_at: now_ms(),
            recovery_proxy: None,
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let url = format!("http://{address}");
        let task = tokio::spawn(async move {
            axum::serve(listener, routes(state)).await.unwrap();
        });
        let client = reqwest::Client::new();
        for route in [
            "/admin/api/report",
            "/admin/api/live",
            "/admin/api/export?type=playback",
            "/admin/api/recovery",
            "/admin/api/recovery/export",
        ] {
            assert_eq!(
                client
                    .get(format!("{url}{route}"))
                    .bearer_auth("separate-app-token")
                    .send()
                    .await
                    .unwrap()
                    .status(),
                401
            );
        }
        assert_eq!(
            client
                .post(format!("{url}/admin/api/login"))
                .header("Origin", "https://hostile.example")
                .json(&json!({"token":"private-admin-key-for-tests-only"}))
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        let login = client
            .post(format!("{url}/admin/api/login"))
            .header("Host", "velvet.example")
            .header("Origin", "https://velvet.example")
            .json(&json!({"token":"private-admin-key-for-tests-only"}))
            .send()
            .await
            .unwrap();
        assert_eq!(login.status(), 200);
        let full_cookie = login.headers()["set-cookie"].to_str().unwrap().to_owned();
        for expected in ["HttpOnly", "SameSite=Strict", "Path=/admin", "Secure"] {
            assert!(full_cookie.contains(expected));
        }
        let cookie = full_cookie.split(';').next().unwrap();
        let report = client
            .get(format!("{url}/admin/api/report?days=7"))
            .header("Cookie", cookie)
            .send()
            .await
            .unwrap();
        assert_eq!(report.status(), 200);
        assert_eq!(report.headers()["cache-control"], "no-store");
        assert!(report
            .json::<Value>()
            .await
            .unwrap()
            .get("summary")
            .is_some());
        let recovery = client
            .get(format!("{url}/admin/api/recovery?days=7"))
            .header("Cookie", cookie)
            .send()
            .await
            .unwrap();
        assert_eq!(recovery.status(), 200);
        assert_eq!(recovery.headers()["cache-control"], "no-store");
        let recovery = recovery.json::<Value>().await.unwrap();
        assert_eq!(recovery["available"], false);
        assert_eq!(recovery["scope"], "beta");
        for route in ["/admin/api/recovery", "/admin/api/recovery/export"] {
            for days in [0, 91] {
                assert_eq!(
                    client
                        .get(format!("{url}{route}?days={days}"))
                        .header("Cookie", cookie)
                        .send()
                        .await
                        .unwrap()
                        .status(),
                    400
                );
            }
        }
        let recovery_csv = client
            .get(format!("{url}/admin/api/recovery/export?days=7"))
            .header("Cookie", cookie)
            .send()
            .await
            .unwrap();
        assert_eq!(recovery_csv.status(), 200);
        assert!(recovery_csv.headers()["content-type"]
            .to_str()
            .unwrap()
            .contains("text/csv"));
        assert_eq!(
            client
                .get(format!("{url}/admin/api/report?days=9999"))
                .header("Cookie", cookie)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
        let csv = client
            .get(format!("{url}/admin/api/export?days=7&type=playback"))
            .header("Cookie", cookie)
            .send()
            .await
            .unwrap();
        assert_eq!(csv.status(), 200);
        assert!(csv.headers()["content-type"]
            .to_str()
            .unwrap()
            .contains("text/csv"));
        assert_eq!(
            client
                .post(format!("{url}/admin/api/logout"))
                .header("Cookie", cookie)
                .header("Origin", "https://hostile.example")
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
        let payload = json!({"sessionId":"http-test","sequence":1,"deviceId":"d","platform":"android","profileId":"p","kind":"tv","mediaId":"1","title":"Test","state":"playing","playedMs":0});
        assert_eq!(
            client
                .post(format!("{url}/telemetry/playback"))
                .bearer_auth("private-admin-key-for-tests-only")
                .json(&payload)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        for applied in [true, false] {
            let response = client
                .post(format!("{url}/telemetry/playback"))
                .bearer_auth("separate-app-token")
                .json(&payload)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), 200);
            assert_eq!(response.json::<Value>().await.unwrap()["applied"], applied);
        }
        assert_eq!(
            client
                .post(format!("{url}/admin/api/logout"))
                .header("Cookie", cookie)
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        assert_eq!(
            client
                .get(format!("{url}/admin/api/report"))
                .header("Cookie", cookie)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        task.abort();
    }
    #[test]
    fn native_clients_with_only_profile_ids_get_canonical_names() {
        let c = Connection::open_in_memory().unwrap();
        crate::sync::migrate(&c).unwrap();
        c.execute(
            "INSERT INTO profiles(id,name,updated_at) VALUES('profile-2','Sam',1)",
            [],
        )
        .unwrap();
        let mut e = event();
        e.profile_name = None;
        enrich_profile(&c, &mut e);
        assert_eq!(e.profile_name.as_deref(), Some("Sam"));
        c.execute("UPDATE profiles SET name='Dad' WHERE id='profile-2'", [])
            .unwrap();
        enrich_profile(&c, &mut e);
        assert_eq!(e.profile_name.as_deref(), Some("Dad"));
        e.title = "A".repeat(500);
        assert!(e.validate());
        e.title.push('A');
        assert!(!e.validate());
    }
}
