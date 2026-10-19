//! Durable category rails for small native clients. Independent of watch-state
//! sync: older clients and the /state wire protocol are unchanged.
use crate::{
    catalog::{self, CatalogState, Category},
    db::Db,
};
use axum::{
    body::Bytes,
    extract::{rejection::BytesRejection, Path, Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};

pub const MAX_REQUEST_BYTES: usize = 256 * 1024;
const MAX_CATEGORIES: i64 = 20;

pub fn migrate(conn: &Connection) -> anyhow::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS saved_categories (
           profile_id TEXT NOT NULL,
           category_id TEXT NOT NULL,
           payload TEXT NOT NULL,
           updated_at INTEGER NOT NULL,
           PRIMARY KEY (profile_id, category_id)
         );
         CREATE INDEX IF NOT EXISTS saved_categories_order
           ON saved_categories(profile_id, updated_at DESC);",
    )?;
    Ok(())
}

#[derive(Debug)]
struct SavedError(StatusCode, &'static str);
impl SavedError {
    fn invalid() -> Self {
        Self(StatusCode::BAD_REQUEST, "Invalid saved category request.")
    }
    fn profile() -> Self {
        Self(StatusCode::NOT_FOUND, "Choose an available profile first.")
    }
    fn storage() -> Self {
        Self(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Saved categories are unavailable. Try again.",
        )
    }
    fn limit() -> Self {
        Self(
            StatusCode::CONFLICT,
            "This profile has 20 saved categories. Delete one before saving another.",
        )
    }
    fn too_large() -> Self {
        Self(
            StatusCode::PAYLOAD_TOO_LARGE,
            "This category is too large to save.",
        )
    }
}
impl IntoResponse for SavedError {
    fn into_response(self) -> Response {
        no_store(catalog::error(self.0, self.1))
    }
}
type SavedResult<T> = Result<T, SavedError>;
fn no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, "no-store, private".parse().unwrap());
    response
}
fn respond(result: SavedResult<Value>) -> Response {
    match result {
        Ok(value) => no_store(Json(value).into_response()),
        Err(error) => error.into_response(),
    }
}
fn identifier(raw: &str) -> bool {
    !raw.is_empty()
        && raw.len() <= 128
        && raw
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}
fn query_profile(query: &HashMap<String, String>) -> SavedResult<&str> {
    query
        .get("profileId")
        .map(String::as_str)
        .filter(|profile| identifier(profile))
        .ok_or_else(SavedError::invalid)
}
fn has_profile(conn: &Connection, profile: &str) -> SavedResult<()> {
    if !identifier(profile) {
        return Err(SavedError::invalid());
    }
    let deleted: Option<i64> = conn
        .query_row(
            "SELECT deleted FROM profiles WHERE id=?1",
            [profile],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| SavedError::storage())?;
    // Pre-profile clients use "default" even before a profile row is synced.
    if deleted == Some(0) || (profile == "default" && deleted.is_none()) {
        Ok(())
    } else {
        Err(SavedError::profile())
    }
}
fn bounded_text(raw: &str, limit: usize) -> bool {
    !raw.trim().is_empty() && raw.chars().count() <= limit && !raw.chars().any(char::is_control)
}
fn optional_text(value: &Option<String>, limit: usize) -> bool {
    value.as_ref().is_none_or(|raw| bounded_text(raw, limit))
}
fn artwork(value: &Option<String>) -> bool {
    value.as_ref().is_none_or(|raw| {
        if raw.len() > 1024 || raw.contains("..") {
            return false;
        }
        let Ok(url) = reqwest::Url::parse(raw) else {
            return false;
        };
        url.scheme() == "https"
            && url.host_str() == Some("image.tmdb.org")
            && url.username().is_empty()
            && url.password().is_none()
            && url.port().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path().starts_with("/t/p/")
            && url
                .path()
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"/._-".contains(&b))
    })
}
fn validate(category: &Category) -> SavedResult<()> {
    if !identifier(&category.id)
        || !bounded_text(&category.title, 80)
        || category.items.is_empty()
        || category.items.len() > 64
    {
        return Err(SavedError::invalid());
    }
    let mut seen = HashSet::new();
    for item in &category.items {
        let coordinates = match (item.season, item.episode) {
            (None, None) => true,
            (Some(s), Some(e)) => item.r#type == "show" && s <= 1000 && (1..=10000).contains(&e),
            _ => false,
        };
        let imdb = item.imdb_id.as_ref().is_none_or(|id| {
            id.len() > 2
                && id.len() <= 20
                && id.starts_with("tt")
                && id[2..].bytes().all(|b| b.is_ascii_digit())
        });
        if !(1..=i32::MAX as u64).contains(&item.media_id)
            || !matches!(item.r#type.as_str(), "movie" | "show")
            || !coordinates
            || !bounded_text(&item.title, 400)
            || !optional_text(&item.year, 32)
            || !optional_text(&item.episode_title, 400)
            || item
                .rating
                .is_some_and(|n| !n.is_finite() || !(0.0..=10.0).contains(&n))
            || !imdb
            || !artwork(&item.poster_url)
            || !artwork(&item.backdrop_url)
            || !artwork(&item.still_url)
            || !seen.insert((&item.r#type, item.media_id, item.season, item.episode))
        {
            return Err(SavedError::invalid());
        }
    }
    Ok(())
}
fn only_keys(value: &Value, allowed: &[&str]) -> bool {
    value
        .as_object()
        .is_some_and(|map| map.keys().all(|key| allowed.contains(&key.as_str())))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SaveRequest {
    profile_id: String,
    category: Category,
}
fn parse(body: &[u8]) -> SavedResult<SaveRequest> {
    if body.len() > MAX_REQUEST_BYTES {
        return Err(SavedError::too_large());
    }
    let value: Value = serde_json::from_slice(body).map_err(|_| SavedError::invalid())?;
    if !only_keys(&value["category"], &["id", "title", "items"])
        || !value["category"]["items"].as_array().is_some_and(|items| {
            items.iter().all(|item| {
                only_keys(
                    item,
                    &[
                        "mediaId",
                        "type",
                        "title",
                        "year",
                        "rating",
                        "posterUrl",
                        "backdropUrl",
                        "imdbId",
                        "season",
                        "episode",
                        "episodeTitle",
                        "stillUrl",
                    ],
                )
            })
        })
    {
        return Err(SavedError::invalid());
    }
    let mut request: SaveRequest =
        serde_json::from_value(value).map_err(|_| SavedError::invalid())?;
    if !identifier(&request.profile_id) {
        return Err(SavedError::invalid());
    }
    validate(&request.category)?;
    request.category.title = request.category.title.trim().to_owned();
    for item in &mut request.category.items {
        item.title = item.title.trim().to_owned();
        item.episode_title = item
            .episode_title
            .take()
            .map(|value| value.trim().to_owned());
        item.year = item.year.take().map(|value| value.trim().to_owned());
    }
    Ok(request)
}

fn load(db: &Db, profile: &str) -> SavedResult<Vec<Category>> {
    let conn = db.lock().map_err(|_| SavedError::storage())?;
    has_profile(&conn, profile)?;
    let mut statement = conn.prepare(
        "SELECT payload FROM saved_categories WHERE profile_id=?1 ORDER BY updated_at DESC, category_id ASC LIMIT 20"
    ).map_err(|_|SavedError::storage())?;
    let rows = statement
        .query_map([profile], |row| row.get::<_, String>(0))
        .map_err(|_| SavedError::storage())?;
    let mut result = Vec::new();
    for raw in rows {
        let raw = raw.map_err(|_| SavedError::storage())?;
        if raw.len() > MAX_REQUEST_BYTES {
            return Err(SavedError::storage());
        }
        let category: Category = serde_json::from_str(&raw).map_err(|_| SavedError::storage())?;
        validate(&category).map_err(|_| SavedError::storage())?;
        result.push(category);
    }
    Ok(result)
}
fn save(db: &Db, profile: &str, category: &Category) -> SavedResult<()> {
    validate(category)?;
    let payload = serde_json::to_string(category).map_err(|_| SavedError::invalid())?;
    if payload.len() > MAX_REQUEST_BYTES {
        return Err(SavedError::too_large());
    }
    let mut conn = db.lock().map_err(|_| SavedError::storage())?;
    let transaction = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| SavedError::storage())?;
    has_profile(&transaction, profile)?;
    let exists: bool = transaction
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM saved_categories WHERE profile_id=?1 AND category_id=?2)",
            params![profile, category.id],
            |row| row.get(0),
        )
        .map_err(|_| SavedError::storage())?;
    let count: i64 = transaction
        .query_row(
            "SELECT COUNT(*) FROM saved_categories WHERE profile_id=?1",
            [profile],
            |row| row.get(0),
        )
        .map_err(|_| SavedError::storage())?;
    if !exists && count >= MAX_CATEGORIES {
        return Err(SavedError::limit());
    }
    let now = chrono::Utc::now().timestamp_millis();
    transaction.execute(
        "INSERT INTO saved_categories(profile_id,category_id,payload,updated_at) VALUES(?1,?2,?3,?4)
         ON CONFLICT(profile_id,category_id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at",
        params![profile,category.id,payload,now]).map_err(|_|SavedError::storage())?;
    transaction.commit().map_err(|_| SavedError::storage())
}
fn remove(db: &Db, profile: &str, id: &str) -> SavedResult<()> {
    if !identifier(id) {
        return Err(SavedError::invalid());
    }
    let conn = db.lock().map_err(|_| SavedError::storage())?;
    has_profile(&conn, profile)?;
    conn.execute(
        "DELETE FROM saved_categories WHERE profile_id=?1 AND category_id=?2",
        params![profile, id],
    )
    .map_err(|_| SavedError::storage())?;
    Ok(())
}
pub async fn list(
    State(st): State<Arc<CatalogState>>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    respond(
        query_profile(&query)
            .and_then(|profile| load(&st.db, profile))
            .map(|categories| json!({"categories":categories})),
    )
}
pub async fn put(
    State(st): State<Arc<CatalogState>>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let result = (|| {
        let body = body.map_err(|error| {
            if error.status() == StatusCode::PAYLOAD_TOO_LARGE {
                SavedError::too_large()
            } else {
                SavedError::invalid()
            }
        })?;
        let request = parse(&body)?;
        save(&st.db, &request.profile_id, &request.category)?;
        serde_json::to_value(request.category).map_err(|_| SavedError::storage())
    })();
    respond(result)
}
pub async fn delete(
    State(st): State<Arc<CatalogState>>,
    Path(id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    respond(
        query_profile(&query)
            .and_then(|profile| remove(&st.db, profile, &id))
            .map(|_| json!({"ok":true})),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn database() -> Db {
        let db = crate::db::open(":memory:").unwrap();
        setup(&db);
        db
    }
    fn setup(db: &Db) {
        let conn = db.lock().unwrap();
        crate::sync::migrate(&conn).unwrap();
        migrate(&conn).unwrap();
        for id in ["alice", "bob"] {
            conn.execute(
                "INSERT OR IGNORE INTO profiles(id,updated_at) VALUES(?1,1)",
                [id],
            )
            .unwrap();
        }
    }
    fn category(id: &str) -> Category {
        serde_json::from_value(json!({"id":id,"title":"Halloween","items":[
            {"mediaId":5371,"type":"show","title":"iCarly","season":1,"episode":7,
                "posterUrl":"https://image.tmdb.org/t/p/w500/poster.jpg"},
            {"mediaId":11,"type":"movie","title":"Star Wars"}
        ]}))
        .unwrap()
    }
    #[test]
    fn categories_survive_database_reopen_with_profile_isolation_and_idempotent_delete() {
        let path = std::env::temp_dir().join(format!(
            "velvet-categories-{}-{}.sqlite",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        {
            let db = crate::db::open(path.to_str().unwrap()).unwrap();
            setup(&db);
            save(&db, "alice", &category("ai-same")).unwrap();
            let mut other = category("ai-same");
            other.title = "Bob's category".into();
            save(&db, "bob", &other).unwrap();
        }
        {
            let db = crate::db::open(path.to_str().unwrap()).unwrap();
            assert_eq!(load(&db, "alice").unwrap()[0].title, "Halloween");
            assert_eq!(load(&db, "bob").unwrap()[0].title, "Bob's category");
            remove(&db, "alice", "ai-same").unwrap();
            remove(&db, "alice", "ai-same").unwrap();
            assert!(load(&db, "alice").unwrap().is_empty());
            assert_eq!(load(&db, "bob").unwrap().len(), 1);
        }
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn twenty_category_limit_allows_replacement_and_does_not_affect_other_profiles() {
        let db = database();
        for n in 0..20 {
            save(&db, "alice", &category(&format!("ai-{n}"))).unwrap();
        }
        assert_eq!(
            save(&db, "alice", &category("overflow")).unwrap_err().0,
            StatusCode::CONFLICT
        );
        let mut revised = category("ai-0");
        revised.title = "Revised".into();
        save(&db, "alice", &revised).unwrap();
        assert_eq!(load(&db, "alice").unwrap().len(), 20);
        save(&db, "bob", &category("overflow")).unwrap();
        remove(&db, "alice", "ai-0").unwrap();
        save(&db, "alice", &category("replacement")).unwrap();
    }
    #[test]
    fn invalid_or_deleted_profiles_and_invalid_categories_never_write() {
        let db = database();
        for profile in ["", "../alice", "not-synced"] {
            assert!(save(&db, profile, &category("ai-1")).is_err());
        }
        db.lock()
            .unwrap()
            .execute("UPDATE profiles SET deleted=1 WHERE id='bob'", [])
            .unwrap();
        assert!(save(&db, "bob", &category("ai-1")).is_err());
        assert!(load(&db, "bob").is_err());
        assert!(load(&db, "alice").unwrap().is_empty());
        save(&db, "default", &category("legacy")).unwrap();
        let mut invalid = category("ai-1");
        invalid.items[0].episode = None;
        assert!(save(&db, "alice", &invalid).is_err());
        invalid = category("ai-1");
        invalid.items[0].poster_url = Some("http://127.0.0.1/private".into());
        assert!(save(&db, "alice", &invalid).is_err());
        invalid = category("ai-1");
        invalid.items = (0..65)
            .map(|n| {
                let mut item = invalid.items[0].clone();
                item.media_id = n + 1;
                item
            })
            .collect();
        assert!(save(&db, "alice", &invalid).is_err());
        assert!(load(&db, "alice").unwrap().is_empty());
    }
    #[test]
    fn body_parser_rejects_unknown_fields_duplicate_seeds_bad_ids_and_oversize_input() {
        let mut value = json!({"profileId":"alice","category":category("ai-1")});
        assert!(parse(value.to_string().as_bytes()).is_ok());
        value["category"]["items"][0]["url"] = json!("https://evil.invalid/movie");
        assert!(parse(value.to_string().as_bytes()).is_err());
        value = json!({"profileId":"alice","category":category("ai-1")});
        value["category"]["items"][1] = value["category"]["items"][0].clone();
        assert!(parse(value.to_string().as_bytes()).is_err());
        value["category"]["id"] = json!("../bad");
        assert!(parse(value.to_string().as_bytes()).is_err());
        assert_eq!(
            parse(&vec![b' '; MAX_REQUEST_BYTES + 1]).err().unwrap().0,
            StatusCode::PAYLOAD_TOO_LARGE
        );
    }
    #[tokio::test]
    async fn saved_routes_require_auth_enforce_payload_limit_and_roundtrip_canonical_category() {
        let app = catalog::router(
            reqwest::Client::new(),
            "test-only-token".into(),
            crate::config::CategoryAi::default(),
            database(),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let client = reqwest::Client::new();
        for method in [
            reqwest::Method::GET,
            reqwest::Method::POST,
            reqwest::Method::DELETE,
        ] {
            let path = if method == reqwest::Method::DELETE {
                "/categories/saved/ai-1?profileId=alice"
            } else {
                "/categories/saved?profileId=alice"
            };
            assert_eq!(
                client
                    .request(method, format!("{base}{path}"))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                StatusCode::UNAUTHORIZED
            );
        }
        let endpoint = format!("{base}/categories/saved");
        let request = json!({"profileId":"alice","category":category("ai-1")});
        let response = client
            .post(&endpoint)
            .bearer_auth("test-only-token")
            .json(&request)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.json::<Value>().await.unwrap()["id"], "ai-1");
        let response = client
            .get(format!("{endpoint}?profileId=alice"))
            .bearer_auth("test-only-token")
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.headers()[header::CACHE_CONTROL],
            "no-store, private"
        );
        assert_eq!(
            response.json::<Value>().await.unwrap()["categories"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let response = client
            .post(&endpoint)
            .bearer_auth("test-only-token")
            .body(vec![b' '; MAX_REQUEST_BYTES + 1])
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert!(response.json::<Value>().await.unwrap()["error"].is_string());
        assert_eq!(
            client
                .delete(format!("{endpoint}/ai-1?profileId=bob"))
                .bearer_auth("test-only-token")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        let response = client
            .get(format!("{endpoint}?profileId=alice"))
            .bearer_auth("test-only-token")
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.json::<Value>().await.unwrap()["categories"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            client
                .delete(format!("{endpoint}/ai-1?profileId=alice"))
                .bearer_auth("test-only-token")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        let response = client
            .get(format!("{endpoint}?profileId=alice"))
            .bearer_auth("test-only-token")
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.json::<Value>().await.unwrap()["categories"],
            json!([])
        );
        server.abort();
    }
}
