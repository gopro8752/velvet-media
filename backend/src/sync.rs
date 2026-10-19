//! watch-state sync — a faithful Rust port of the Python `velvet-sync/server.py`
//! (v1.2). Preserves the wire protocol byte-for-byte because three shipped client
//! apps (Android TV + iOS) depend on it exactly.
//!
//! A tiny last-write-wins store over SQLite. Clients push rows whenever local
//! state mutates and pull rows newer than their cursor. Deletions travel as
//! tombstones (deleted=1). Progress/watched/mylist rows carry a profile_id in
//! their key; profiles themselves are a globally-synced table.
//!
//! Endpoints (JSON):
//!   GET  /health                 -> {"ok": true}
//!   GET  /state?since=<ms>        -> {"serverNow", "profiles", "progress",
//!                                     "watched", "mylist"} (received_at > since)
//!   POST /push                    -> {"serverNow", "applied": n} (LWW per row)
//!   POST /report_play             -> {"ok": true}
//!   GET  /segments?imdb=&season=  -> {"episodes": {"5": {"startMs","endMs"}}}
//!   POST /segments                -> {"written": n}
//!   GET  /intro_work              -> {"jobs": [...]}
//!   POST /handoff                 -> {"id": n}
//!   GET  /handoff/pending?profileId= -> {"handoff": {...}|null}
//!   POST /handoff/claim           -> {"claimed": bool}
//!
//! Auth: a bearer-token gate. If the token is empty the server is open. GET
//! /health is always unauthed.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    body::Bytes,
    extract::{Query, Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use rusqlite::{params, params_from_iter, Connection, OptionalExtension};
use serde_json::{json, Map, Value};

use crate::db::Db;

/// A handoff nobody claims within this window is dead — the target TV wasn't on.
const HANDOFF_TTL_MS: i64 = 60_000;

/// One synced table's key + value columns, each paired with its camelCase wire
/// name (the Python `camel()` of the snake_case column). Wire order is keys,
/// then values, then `updatedAt`, then `deleted`.
struct TableSpec {
    name: &'static str,
    keys: &'static [(&'static str, &'static str)],
    values: &'static [(&'static str, &'static str)],
}

/// Iteration order matches the Python `TABLES` dict: profiles, progress,
/// watched, mylist.
const TABLES: [TableSpec; 4] = [
    TableSpec {
        name: "profiles",
        keys: &[("id", "id")],
        values: &[("name", "name"), ("color", "color"), ("created_at", "createdAt")],
    },
    TableSpec {
        name: "progress",
        keys: &[
            ("profile_id", "profileId"),
            ("media_id", "mediaId"),
            ("type", "type"),
        ],
        values: &[
            ("imdb_id", "imdbId"),
            ("title", "title"),
            ("poster_url", "posterUrl"),
            ("backdrop_url", "backdropUrl"),
            ("season", "season"),
            ("episode", "episode"),
            ("episode_title", "episodeTitle"),
            ("position_ms", "positionMs"),
            ("duration_ms", "durationMs"),
            ("year", "year"),
            ("rating", "rating"),
        ],
    },
    TableSpec {
        name: "watched",
        keys: &[
            ("profile_id", "profileId"),
            ("media_id", "mediaId"),
            ("season", "season"),
            ("episode", "episode"),
        ],
        values: &[("watched_at", "watchedAt")],
    },
    TableSpec {
        name: "mylist",
        keys: &[
            ("profile_id", "profileId"),
            ("media_id", "mediaId"),
            ("type", "type"),
        ],
        values: &[
            ("title", "title"),
            ("poster_url", "posterUrl"),
            ("backdrop_url", "backdropUrl"),
            ("year", "year"),
            ("rating", "rating"),
            ("added_at", "addedAt"),
        ],
    },
];

/// Creates every table + index idempotently. Fresh-DB only — no pre-profiles
/// legacy migration is needed here (this crate starts clean).
pub fn migrate(conn: &Connection) -> anyhow::Result<()> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS profiles (
          id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
          color TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
          received_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS progress (
          profile_id TEXT NOT NULL DEFAULT 'default',
          media_id INTEGER NOT NULL, type TEXT NOT NULL, imdb_id TEXT, title TEXT,
          poster_url TEXT, backdrop_url TEXT, season INTEGER, episode INTEGER,
          episode_title TEXT, position_ms INTEGER NOT NULL DEFAULT 0,
          duration_ms INTEGER NOT NULL DEFAULT 0, year TEXT, rating REAL,
          updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
          received_at INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (profile_id, media_id, type)
        );
        CREATE TABLE IF NOT EXISTS watched (
          profile_id TEXT NOT NULL DEFAULT 'default',
          media_id INTEGER NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL,
          watched_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
          received_at INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (profile_id, media_id, season, episode)
        );
        CREATE TABLE IF NOT EXISTS mylist (
          profile_id TEXT NOT NULL DEFAULT 'default',
          media_id INTEGER NOT NULL, type TEXT NOT NULL, title TEXT,
          poster_url TEXT, backdrop_url TEXT, year TEXT, rating REAL,
          added_at INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
          received_at INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (profile_id, media_id, type)
        );
        CREATE INDEX IF NOT EXISTS idx_profiles_received ON profiles(received_at);
        CREATE INDEX IF NOT EXISTS idx_progress_received ON progress(received_at);
        CREATE INDEX IF NOT EXISTS idx_watched_received ON watched(received_at);
        CREATE INDEX IF NOT EXISTS idx_mylist_received ON mylist(received_at);
        CREATE TABLE IF NOT EXISTS play_reports (
          imdb TEXT NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL,
          url TEXT NOT NULL, reported_at INTEGER NOT NULL,
          PRIMARY KEY (imdb, season, episode)
        );
        CREATE TABLE IF NOT EXISTS segments (
          imdb TEXT NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL,
          start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
          source TEXT NOT NULL DEFAULT 'fingerprint', updated_at INTEGER NOT NULL,
          PRIMARY KEY (imdb, season, episode)
        );
        CREATE TABLE IF NOT EXISTS handoffs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          profile_id TEXT NOT NULL, payload TEXT NOT NULL,
          created_at INTEGER NOT NULL, claimed_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS stream_registrations (
          sid TEXT PRIMARY KEY, nzb_url TEXT NOT NULL, touched_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS stream_registrations_age ON stream_registrations(touched_at);
        CREATE TABLE IF NOT EXISTS bad_releases (
          sid TEXT PRIMARY KEY, nzb_url TEXT NOT NULL,
          reason TEXT NOT NULL, found_at INTEGER NOT NULL
        );
        "#,
    )?;
    Ok(())
}

struct AppState {
    db: Db,
    token: String,
    /// When present, report_play forwards a next-episode pre-warm request.
    warm_tx: Option<crate::warm::WarmTx>,
}

/// Builds the sync router. Handlers are gated by a bearer-token middleware that
/// always lets `/health` through; an empty token opens the whole server.
pub fn router(db: Db, token: String, warm_tx: Option<crate::warm::WarmTx>, streams: crate::stream::StreamState, stream_base_url: String) -> Router {
    let state = Arc::new(AppState { db, token, warm_tx });
    Router::new()
        .route("/health", get(health))
        .route("/state", get(get_state))
        .route("/push", post(post_push))
        .route("/report_play", post(post_report_play))
        .route("/segments", get(get_segments).post(post_segments))
        .route("/intro_work", get(get_intro_work))
        .route("/handoff", post(post_handoff))
        .route("/handoff/pending", get(get_handoff_pending))
        .route("/handoff/claim", post(post_handoff_claim))
        .fallback(not_found)
        .with_state(state.clone())
        .merge(crate::handoff::router(streams, stream_base_url))
        .layer(middleware::from_fn_with_state(state, auth_mw))
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// JSON -> SQLite bind value. Mirrors how Python's sqlite3 binds native types.
fn json_to_sql(v: &Value) -> rusqlite::types::Value {
    use rusqlite::types::Value as SV;
    match v {
        Value::Null => SV::Null,
        Value::Bool(b) => SV::Integer(*b as i64),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                SV::Integer(i)
            } else if let Some(u) = n.as_u64() {
                SV::Integer(u as i64)
            } else {
                SV::Real(n.as_f64().unwrap_or(0.0))
            }
        }
        Value::String(s) => SV::Text(s.clone()),
        other => SV::Text(other.to_string()),
    }
}

/// SQLite stored value -> JSON, matching Python sqlite3.Row native types.
fn sql_to_json(v: rusqlite::types::Value) -> Value {
    use rusqlite::types::Value as SV;
    match v {
        SV::Null => Value::Null,
        SV::Integer(i) => Value::from(i),
        SV::Real(f) => serde_json::Number::from_f64(f)
            .map(Value::Number)
            .unwrap_or(Value::Null),
        SV::Text(s) => Value::String(s),
        SV::Blob(_) => Value::Null,
    }
}

/// Emulates Python `int(x)` over a JSON scalar: numbers truncate toward zero,
/// integer-literal strings parse, bools map to 0/1, everything else fails.
fn to_i64_py(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::String(s) => s.trim().parse::<i64>().ok(),
        Value::Bool(b) => Some(*b as i64),
        _ => None,
    }
}

/// Emulates Python truthiness for `item.get(key)`.
fn truthy(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().map(|f| f != 0.0).unwrap_or(true),
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(o)) => !o.is_empty(),
    }
}

/// Emulates Python `str(payload.get(key) or "").strip()`.
fn str_field(payload: &Value, key: &str) -> String {
    match payload.get(key) {
        Some(v) if truthy(Some(v)) => match v {
            Value::String(s) => s.trim().to_string(),
            Value::Number(n) => n.to_string(),
            Value::Bool(b) => if *b { "True" } else { "False" }.to_string(),
            other => other.to_string().trim().to_string(),
        },
        _ => String::new(),
    }
}

/// Emulates Python `int(payload.get(key))`: None if absent/null/not intable.
fn int_field(payload: &Value, key: &str) -> Option<i64> {
    payload.get(key).and_then(to_i64_py)
}

fn parse_body(body: &Bytes) -> Result<Value, Response> {
    let slice: &[u8] = if body.is_empty() { b"{}" } else { &body[..] };
    serde_json::from_slice(slice).map_err(|_| bad_json())
}

fn bad_request(msg: &str) -> Response {
    (StatusCode::BAD_REQUEST, Json(json!({ "error": msg }))).into_response()
}

fn bad_json() -> Response {
    (StatusCode::BAD_REQUEST, Json(json!({ "error": "bad json" }))).into_response()
}

fn internal_error() -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({ "error": "internal" })),
    )
        .into_response()
}

async fn not_found() -> Response {
    (StatusCode::NOT_FOUND, Json(json!({ "error": "not found" }))).into_response()
}

async fn auth_mw(State(st): State<Arc<AppState>>, req: Request, next: Next) -> Response {
    if req.uri().path() == "/health" || st.token.is_empty() {
        return next.run(req).await;
    }
    let expected = format!("Bearer {}", st.token);
    let ok = req
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .map(|v| v == expected)
        .unwrap_or(false);
    if ok {
        next.run(req).await
    } else {
        (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "unauthorized" })),
        )
            .into_response()
    }
}

// ---------------------------------------------------------------------------
// row <-> wire + LWW
// ---------------------------------------------------------------------------

fn row_to_wire(spec: &TableSpec, row: &rusqlite::Row) -> rusqlite::Result<Value> {
    let mut map = Map::new();
    for (snake, camel) in spec.keys.iter().chain(spec.values.iter()) {
        let v: rusqlite::types::Value = row.get(*snake)?;
        map.insert((*camel).to_string(), sql_to_json(v));
    }
    let updated_at: i64 = row.get("updated_at")?;
    map.insert("updatedAt".to_string(), Value::from(updated_at));
    let deleted: i64 = row.get("deleted")?;
    map.insert("deleted".to_string(), Value::Bool(deleted != 0));
    Ok(Value::Object(map))
}

fn select_rows(conn: &Connection, spec: &TableSpec, since: i64) -> rusqlite::Result<Vec<Value>> {
    let sql = format!("SELECT * FROM {} WHERE received_at > ?1", spec.name);
    let mut stmt = conn.prepare(&sql)?;
    let mut rows = stmt.query([since])?;
    let mut out = Vec::new();
    while let Some(r) = rows.next()? {
        out.push(row_to_wire(spec, r)?);
    }
    Ok(out)
}

/// Applies one pushed row under last-write-wins. Returns true if it was stored
/// (i.e. its `updatedAt` strictly beat any existing row). A missing key column
/// or a missing/unparseable `updatedAt` makes the row a no-op, matching the
/// Python `apply_row`.
fn apply_row(conn: &Connection, spec: &TableSpec, item: &Map<String, Value>) -> bool {
    let mut key_vals: Vec<rusqlite::types::Value> = Vec::with_capacity(spec.keys.len());
    for (_snake, camel) in spec.keys {
        match item.get(*camel) {
            Some(v) => key_vals.push(json_to_sql(v)),
            None => return false,
        }
    }
    let updated_at = match item.get("updatedAt").and_then(to_i64_py) {
        Some(n) => n,
        None => return false,
    };
    let deleted: i64 = if truthy(item.get("deleted")) { 1 } else { 0 };

    let where_clause = spec
        .keys
        .iter()
        .map(|(s, _)| format!("{} = ?", s))
        .collect::<Vec<_>>()
        .join(" AND ");
    let sel = format!("SELECT updated_at FROM {} WHERE {}", spec.name, where_clause);
    let existing: Option<i64> = conn
        .query_row(&sel, params_from_iter(key_vals.iter()), |r| r.get::<_, i64>(0))
        .optional()
        .unwrap_or(None);
    if let Some(e) = existing {
        if e >= updated_at {
            return false; // stored row is newer or same — LWW keeps it
        }
    }

    let mut cols: Vec<&str> = Vec::new();
    for (s, _) in spec.keys {
        cols.push(s);
    }
    for (s, _) in spec.values {
        cols.push(s);
    }
    cols.push("updated_at");
    cols.push("deleted");
    cols.push("received_at");

    let mut vals: Vec<rusqlite::types::Value> = key_vals.clone();
    for (_s, camel) in spec.values {
        vals.push(
            item.get(*camel)
                .map(json_to_sql)
                .unwrap_or(rusqlite::types::Value::Null),
        );
    }
    vals.push(rusqlite::types::Value::Integer(updated_at));
    vals.push(rusqlite::types::Value::Integer(deleted));
    vals.push(rusqlite::types::Value::Integer(now_ms()));

    let placeholders = vec!["?"; cols.len()].join(", ");
    let ins = format!(
        "INSERT OR REPLACE INTO {} ({}) VALUES ({})",
        spec.name,
        cols.join(", "),
        placeholders
    );
    conn.execute(&ins, params_from_iter(vals.iter())).is_ok()
}

// ---------------------------------------------------------------------------
// handlers
// ---------------------------------------------------------------------------

async fn health() -> Response {
    Json(json!({ "ok": true })).into_response()
}

async fn get_state(
    State(st): State<Arc<AppState>>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let since: i64 = q
        .get("since")
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(0);
    let now = now_ms();
    let built: rusqlite::Result<Map<String, Value>> = {
        let conn = st.db.lock().unwrap();
        let mut out = Map::new();
        out.insert("serverNow".to_string(), Value::from(now));
        let mut err = None;
        for spec in TABLES.iter() {
            match select_rows(&conn, spec, since) {
                Ok(rows) => {
                    out.insert(spec.name.to_string(), Value::Array(rows));
                }
                Err(e) => {
                    err = Some(e);
                    break;
                }
            }
        }
        match err {
            Some(e) => Err(e),
            None => Ok(out),
        }
    };
    match built {
        Ok(out) => Json(Value::Object(out)).into_response(),
        Err(_) => internal_error(),
    }
}

async fn post_push(State(st): State<Arc<AppState>>, body: Bytes) -> Response {
    let payload = match parse_body(&body) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let applied = {
        let conn = st.db.lock().unwrap();
        let mut n: i64 = 0;
        for spec in TABLES.iter() {
            if let Some(Value::Array(items)) = payload.get(spec.name) {
                for item in items {
                    if let Value::Object(map) = item {
                        if apply_row(&conn, spec, map) {
                            n += 1;
                        }
                    }
                }
            }
        }
        n
    };
    Json(json!({ "serverNow": now_ms(), "applied": applied })).into_response()
}

async fn post_report_play(State(st): State<Arc<AppState>>, body: Bytes) -> Response {
    let payload = match parse_body(&body) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let imdb = str_field(&payload, "imdbId");
    let season = match int_field(&payload, "season") {
        Some(n) => n,
        None => return bad_request("season/episode required"),
    };
    let episode = match int_field(&payload, "episode") {
        Some(n) => n,
        None => return bad_request("season/episode required"),
    };
    let play_url = str_field(&payload, "url");
    if imdb.is_empty() || play_url.is_empty() {
        return bad_request("imdbId and url required");
    }
    {
        let conn = st.db.lock().unwrap();
        let _ = conn.execute(
            "INSERT OR REPLACE INTO play_reports (imdb, season, episode, url, reported_at) \
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![imdb, season, episode, play_url, now_ms()],
        );
    }
    // Zero-wait binge: starting S(n)E(m) pre-warms S(n)E(m+1) — the whole
    // episode's runtime is available for the warm to finish.
    if let Some(tx) = &st.warm_tx {
        if season > 0 && episode >= 0 {
            let _ = tx.send(crate::warm::WarmReq {
                kind: crate::warm::WarmKind::Series,
                imdb: imdb.clone(),
                season: season as u32,
                episode: episode as u32 + 1,
                fraction: None,
            });
        }
    }
    Json(json!({ "ok": true })).into_response()
}

async fn get_segments(
    State(st): State<Arc<AppState>>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let imdb = q
        .get("imdb")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let season: i64 = q
        .get("season")
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(-1);
    if imdb.is_empty() || season < 0 {
        return bad_request("imdb and season required");
    }
    let episodes: Map<String, Value> = {
        let conn = st.db.lock().unwrap();
        let mut m = Map::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT episode, start_ms, end_ms FROM segments \
             WHERE imdb = ?1 AND season = ?2 AND source != 'none'",
        ) {
            if let Ok(rows) = stmt.query_map(params![imdb, season], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?))
            }) {
                for (ep, start, end) in rows.flatten() {
                    m.insert(ep.to_string(), json!({ "startMs": start, "endMs": end }));
                }
            }
        }
        m
    };
    Json(json!({ "episodes": episodes })).into_response()
}

async fn post_segments(State(st): State<Arc<AppState>>, body: Bytes) -> Response {
    let payload = match parse_body(&body) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let imdb = str_field(&payload, "imdbId");
    let season = match int_field(&payload, "season") {
        Some(n) => n,
        None => return bad_request("season required"),
    };
    if imdb.is_empty() {
        return bad_request("imdbId required");
    }
    let written = {
        let conn = st.db.lock().unwrap();
        let mut w: i64 = 0;
        if let Some(Value::Array(results)) = payload.get("results") {
            for r in results {
                // int(r["episode"]) — missing/non-intable skips this result.
                let episode = match r.get("episode").and_then(to_i64_py) {
                    Some(e) => e,
                    None => continue,
                };
                // int(r.get("startMs") or 0) — falsy defaults to 0; a truthy but
                // non-intable value skips the whole result (Python ValueError).
                let start_ms = match py_int_or(r, "startMs", 0) {
                    Some(v) => v,
                    None => continue,
                };
                let end_ms = match py_int_or(r, "endMs", 0) {
                    Some(v) => v,
                    None => continue,
                };
                let source = match r.get("source") {
                    Some(v) if truthy(Some(v)) => match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    },
                    _ => "fingerprint".to_string(),
                };
                if conn
                    .execute(
                        "INSERT OR REPLACE INTO segments \
                         (imdb, season, episode, start_ms, end_ms, source, updated_at) \
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                        params![imdb, season, episode, start_ms, end_ms, source, now_ms()],
                    )
                    .is_ok()
                {
                    w += 1;
                }
            }
        }
        w
    };
    Json(json!({ "written": written })).into_response()
}

/// Emulates Python `int(r.get(key) or default)`: falsy -> default, otherwise
/// `int()` of the value (None => the whole result is skipped by the caller).
fn py_int_or(r: &Value, key: &str, default: i64) -> Option<i64> {
    match r.get(key) {
        Some(v) if truthy(Some(v)) => to_i64_py(v),
        _ => Some(default),
    }
}

async fn get_intro_work(State(st): State<Arc<AppState>>) -> Response {
    let jobs: Vec<Value> = {
        let conn = st.db.lock().unwrap();
        let mut jobs = Vec::new();
        let seasons: Vec<(String, i64)> = match conn
            .prepare("SELECT DISTINCT imdb, season FROM play_reports")
        {
            Ok(mut stmt) => match stmt
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
            {
                Ok(rows) => rows.flatten().collect(),
                Err(_) => Vec::new(),
            },
            Err(_) => Vec::new(),
        };
        for (imdb, season) in &seasons {
            let eps: Vec<(i64, String)> = match conn.prepare(
                "SELECT episode, url FROM play_reports WHERE imdb = ?1 AND season = ?2 \
                 ORDER BY episode",
            ) {
                Ok(mut stmt) => match stmt.query_map(params![imdb, season], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
                }) {
                    Ok(rows) => rows.flatten().collect(),
                    Err(_) => Vec::new(),
                },
                Err(_) => Vec::new(),
            };
            let done: std::collections::HashSet<i64> = match conn
                .prepare("SELECT episode FROM segments WHERE imdb = ?1 AND season = ?2")
            {
                Ok(mut stmt) => match stmt.query_map(params![imdb, season], |r| r.get::<_, i64>(0)) {
                    Ok(rows) => rows.flatten().collect(),
                    Err(_) => std::collections::HashSet::new(),
                },
                Err(_) => std::collections::HashSet::new(),
            };
            let missing: Vec<i64> = eps
                .iter()
                .filter(|(ep, _)| !done.contains(ep))
                .map(|(ep, _)| *ep)
                .collect();
            if !missing.is_empty() {
                let episodes: Vec<Value> = eps
                    .iter()
                    .map(|(ep, url)| json!({ "episode": ep, "url": url }))
                    .collect();
                jobs.push(json!({
                    "imdbId": imdb,
                    "season": season,
                    "episodes": episodes,
                    "missing": missing,
                }));
            }
        }
        jobs
    };
    Json(json!({ "jobs": jobs })).into_response()
}

async fn post_handoff(State(st): State<Arc<AppState>>, body: Bytes) -> Response {
    let payload = match parse_body(&body) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let profile = str_field(&payload, "profileId");
    if profile.is_empty() {
        return bad_request("profileId required");
    }
    let id = {
        let conn = st.db.lock().unwrap();
        let payload_str = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
        let _ = conn.execute(
            "INSERT INTO handoffs (profile_id, payload, created_at) VALUES (?1, ?2, ?3)",
            params![profile, payload_str, now_ms()],
        );
        let id = conn.last_insert_rowid();
        // Opportunistic cleanup — expired/claimed rows have no readers.
        let _ = conn.execute(
            "DELETE FROM handoffs WHERE created_at < ?1",
            params![now_ms() - 24 * 3600 * 1000],
        );
        id
    };
    Json(json!({ "id": id })).into_response()
}

async fn get_handoff_pending(
    State(st): State<Arc<AppState>>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let profile = q
        .get("profileId")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if profile.is_empty() {
        return bad_request("profileId required");
    }
    let cutoff = now_ms() - HANDOFF_TTL_MS;
    let row: Option<(i64, String)> = {
        let conn = st.db.lock().unwrap();
        conn.query_row(
            "SELECT id, payload FROM handoffs WHERE profile_id = ?1 AND claimed_at IS NULL \
             AND created_at > ?2 ORDER BY id DESC LIMIT 1",
            params![profile, cutoff],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
        .unwrap_or(None)
    };
    match row {
        None => Json(json!({ "handoff": Value::Null })).into_response(),
        Some((id, payload_str)) => {
            let mut payload: Value =
                serde_json::from_str(&payload_str).unwrap_or_else(|_| Value::Object(Map::new()));
            if !payload.is_object() {
                payload = Value::Object(Map::new());
            }
            if let Value::Object(ref mut m) = payload {
                m.insert("id".to_string(), Value::from(id));
            }
            Json(json!({ "handoff": payload })).into_response()
        }
    }
}

async fn post_handoff_claim(State(st): State<Arc<AppState>>, body: Bytes) -> Response {
    let payload = match parse_body(&body) {
        Ok(v) => v,
        Err(r) => return r,
    };
    let hid = match int_field(&payload, "id") {
        Some(n) => n,
        None => return bad_request("id required"),
    };
    let cutoff = now_ms() - HANDOFF_TTL_MS;
    let changed = {
        let conn = st.db.lock().unwrap();
        conn.execute(
            "UPDATE handoffs SET claimed_at = ?1 \
             WHERE id = ?2 AND claimed_at IS NULL AND created_at > ?3",
            params![now_ms(), hid, cutoff],
        )
        .unwrap_or(0)
    };
    Json(json!({ "claimed": changed > 0 })).into_response()
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    use std::sync::Mutex;

    fn test_state() -> Arc<AppState> {
        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();
        Arc::new(AppState {
            db: Arc::new(Mutex::new(conn)),
            token: String::new(),
            warm_tx: None,
        })
    }

    async fn body_json(resp: Response) -> Value {
        let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    fn qmap(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[tokio::test]
    async fn health_ok() {
        let j = body_json(health().await).await;
        assert_eq!(j["ok"], true);
    }

    #[tokio::test]
    async fn push_and_state_roundtrip() {
        let st = test_state();
        let push_body = json!({
            "progress": [{
                "profileId": "default", "mediaId": 100, "type": "movie",
                "imdbId": "tt100", "title": "Inception", "posterUrl": "p", "backdropUrl": "b",
                "season": null, "episode": null, "episodeTitle": null,
                "positionMs": 1234, "durationMs": 9999, "year": "2010", "rating": 8.8,
                "updatedAt": 1000, "deleted": false
            }]
        });
        let r = post_push(State(st.clone()), Bytes::from(push_body.to_string())).await;
        assert_eq!(body_json(r).await["applied"], 1);

        let r = get_state(State(st.clone()), Query(qmap(&[("since", "0")]))).await;
        let j = body_json(r).await;
        let prog = j["progress"].as_array().unwrap();
        assert_eq!(prog.len(), 1);
        let row = &prog[0];
        // exact camelCase keys + value types
        assert_eq!(row["profileId"], "default");
        assert_eq!(row["mediaId"], 100);
        assert_eq!(row["type"], "movie");
        assert_eq!(row["imdbId"], "tt100");
        assert_eq!(row["title"], "Inception");
        assert_eq!(row["posterUrl"], "p");
        assert_eq!(row["backdropUrl"], "b");
        assert!(row["season"].is_null());
        assert!(row["episode"].is_null());
        assert!(row["episodeTitle"].is_null());
        assert_eq!(row["positionMs"], 1234);
        assert_eq!(row["durationMs"], 9999);
        assert_eq!(row["year"], "2010");
        assert_eq!(row["rating"], 8.8);
        assert_eq!(row["updatedAt"], 1000);
        assert_eq!(row["deleted"], false);
        // profiles/watched/mylist present and empty
        assert_eq!(j["profiles"].as_array().unwrap().len(), 0);
        assert_eq!(j["watched"].as_array().unwrap().len(), 0);
        assert_eq!(j["mylist"].as_array().unwrap().len(), 0);
        assert!(j["serverNow"].as_i64().unwrap() > 0);
    }

    #[tokio::test]
    async fn lww_rejects_older_and_equal() {
        let st = test_state();
        let mk = |updated: i64, pos: i64| {
            json!({"progress":[{
                "profileId":"default","mediaId":1,"type":"movie",
                "updatedAt":updated,"positionMs":pos
            }]})
            .to_string()
        };
        // first write
        let r = post_push(State(st.clone()), Bytes::from(mk(5000, 50))).await;
        assert_eq!(body_json(r).await["applied"], 1);
        // strictly older -> rejected
        let r = post_push(State(st.clone()), Bytes::from(mk(4000, 10))).await;
        assert_eq!(body_json(r).await["applied"], 0);
        // equal updatedAt -> rejected (>= keeps stored)
        let r = post_push(State(st.clone()), Bytes::from(mk(5000, 11))).await;
        assert_eq!(body_json(r).await["applied"], 0);
        // strictly newer -> applied
        let r = post_push(State(st.clone()), Bytes::from(mk(6000, 99))).await;
        assert_eq!(body_json(r).await["applied"], 1);
        // stored value is from the newest write
        let r = get_state(State(st.clone()), Query(qmap(&[("since", "0")]))).await;
        let j = body_json(r).await;
        assert_eq!(j["progress"][0]["positionMs"], 99);
        assert_eq!(j["progress"][0]["updatedAt"], 6000);
    }

    #[tokio::test]
    async fn handoff_flow() {
        let st = test_state();
        let hb = json!({
            "profileId":"p1","mediaId":7,"type":"series",
            "season":1,"episode":2,"positionMs":345,"title":"X"
        });
        let r = post_handoff(State(st.clone()), Bytes::from(hb.to_string())).await;
        let id = body_json(r).await["id"].as_i64().unwrap();
        assert!(id > 0);

        // pending returns the payload + id
        let r = get_handoff_pending(State(st.clone()), Query(qmap(&[("profileId", "p1")]))).await;
        let j = body_json(r).await;
        assert_eq!(j["handoff"]["id"], id);
        assert_eq!(j["handoff"]["mediaId"], 7);
        assert_eq!(j["handoff"]["title"], "X");

        // first claim wins
        let r = post_handoff_claim(State(st.clone()), Bytes::from(json!({"id":id}).to_string())).await;
        assert_eq!(body_json(r).await["claimed"], true);
        // second claim loses
        let r = post_handoff_claim(State(st.clone()), Bytes::from(json!({"id":id}).to_string())).await;
        assert_eq!(body_json(r).await["claimed"], false);
        // pending now null (claimed)
        let r = get_handoff_pending(State(st.clone()), Query(qmap(&[("profileId", "p1")]))).await;
        assert!(body_json(r).await["handoff"].is_null());
    }

    #[tokio::test]
    async fn intro_work_and_segments() {
        let st = test_state();
        for ep in [1, 2] {
            let rb = json!({"imdbId":"tt9","season":1,"episode":ep,"url":format!("http://u/{ep}")});
            let r = post_report_play(State(st.clone()), Bytes::from(rb.to_string())).await;
            assert_eq!(body_json(r).await["ok"], true);
        }

        // both episodes missing
        let r = get_intro_work(State(st.clone())).await;
        let j = body_json(r).await;
        let jobs = j["jobs"].as_array().unwrap();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0]["imdbId"], "tt9");
        assert_eq!(jobs[0]["season"], 1);
        let missing: Vec<i64> = jobs[0]["missing"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_i64().unwrap())
            .collect();
        assert_eq!(missing, vec![1, 2]);
        assert_eq!(jobs[0]["episodes"].as_array().unwrap().len(), 2);

        // ep1 gets a real segment; ep2 recorded as 'none' (analyzed, no intro)
        let sb = json!({"imdbId":"tt9","season":1,"results":[
            {"episode":1,"startMs":1000,"endMs":90000,"source":"fingerprint"},
            {"episode":2,"startMs":0,"endMs":0,"source":"none"}
        ]});
        let r = post_segments(State(st.clone()), Bytes::from(sb.to_string())).await;
        assert_eq!(body_json(r).await["written"], 2);

        // both now have a segment row (incl 'none') -> no intro_work job
        let r = get_intro_work(State(st.clone())).await;
        assert_eq!(body_json(r).await["jobs"].as_array().unwrap().len(), 0);

        // GET /segments shows only ep1 (source != 'none')
        let r = get_segments(
            State(st.clone()),
            Query(qmap(&[("imdb", "tt9"), ("season", "1")])),
        )
        .await;
        let j = body_json(r).await;
        let eps = j["episodes"].as_object().unwrap();
        assert_eq!(eps.len(), 1);
        assert_eq!(eps["1"]["startMs"], 1000);
        assert_eq!(eps["1"]["endMs"], 90000);
        assert!(eps.get("2").is_none());
    }

    #[tokio::test]
    async fn report_play_validation() {
        let st = test_state();
        // missing url -> 400
        let r = post_report_play(
            State(st.clone()),
            Bytes::from(json!({"imdbId":"tt1","season":1,"episode":1}).to_string()),
        )
        .await;
        assert_eq!(r.status(), StatusCode::BAD_REQUEST);
        // missing season -> 400
        let r = post_report_play(
            State(st.clone()),
            Bytes::from(json!({"imdbId":"tt1","episode":1,"url":"u"}).to_string()),
        )
        .await;
        assert_eq!(r.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn state_since_filters_by_arrival() {
        let st = test_state();
        // push a row; then a since in the far future returns nothing
        let r = post_push(
            State(st.clone()),
            Bytes::from(
                json!({"mylist":[{"profileId":"default","mediaId":5,"type":"movie","updatedAt":1}]})
                    .to_string(),
            ),
        )
        .await;
        assert_eq!(body_json(r).await["applied"], 1);
        let future = now_ms() + 60_000;
        let r = get_state(
            State(st.clone()),
            Query(qmap(&[("since", &future.to_string())])),
        )
        .await;
        let j = body_json(r).await;
        assert_eq!(j["mylist"].as_array().unwrap().len(), 0);
        // since=0 returns it
        let r = get_state(State(st.clone()), Query(qmap(&[("since", "0")]))).await;
        assert_eq!(body_json(r).await["mylist"].as_array().unwrap().len(), 1);
    }
}
