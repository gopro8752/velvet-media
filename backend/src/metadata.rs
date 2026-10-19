//! The native apps use their backend's metadata credentials. This is a read-only
//! subset of TMDB v3, never an arbitrary URL or account API proxy.
use axum::{
    extract::{Path, RawQuery, Request, State},
    http::{header, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde_json::{json, Value};
use std::{collections::HashSet, sync::Arc, time::Duration};
use tokio::sync::Semaphore;

const UPSTREAM: &str = "https://api.themoviedb.org/3/";
const BODY_LIMIT: usize = 2 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(14);

struct MetadataState {
    http: reqwest::Client,
    app_token: String,
    api_key: String,
    upstream: reqwest::Url,
    requests: Semaphore,
}

pub fn router(app_token: String) -> anyhow::Result<Router> {
    build_router(app_token, crate::resolver::tmdb_key(), UPSTREAM)
}

fn build_router(app_token: String, api_key: String, upstream: &str) -> anyhow::Result<Router> {
    let state = Arc::new(MetadataState {
        // Do not follow even same-host redirects with a credential-bearing URL.
        http: reqwest::Client::builder()
            .user_agent("velvet-backend/metadata")
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(12))
            .build()?,
        app_token,
        api_key,
        upstream: reqwest::Url::parse(upstream)?,
        requests: Semaphore::new(32),
    });
    Ok(Router::new()
        .route("/metadata/tmdb/*path", get(metadata))
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        .with_state(state))
}

async fn auth(State(state): State<Arc<MetadataState>>, request: Request, next: Next) -> Response {
    let authorized = crate::catalog::authorized(&state.app_token, request.headers());
    let mut response = if authorized {
        next.run(request).await
    } else {
        failure(StatusCode::UNAUTHORIZED, "unauthorized")
    };
    // Authentication runs for every call. Shared intermediaries must never cache
    // a response and serve it to a caller lacking the app's bearer token.
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
        .headers_mut()
        .insert(header::VARY, HeaderValue::from_static("Authorization"));
    response
}

async fn metadata(
    State(state): State<Arc<MetadataState>>,
    Path(path): Path<String>,
    RawQuery(raw): RawQuery,
) -> Response {
    let query = match validated_query(&path, raw.as_deref().unwrap_or("")) {
        Ok(query) => query,
        Err(()) => {
            return failure(
                StatusCode::BAD_REQUEST,
                "Unsupported metadata path or query.",
            )
        }
    };
    if state.api_key.is_empty() {
        return failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "Metadata is not configured. Set VELVET_TMDB_KEY on the backend.",
        );
    }
    match tokio::time::timeout(REQUEST_TIMEOUT, fetch(&state, &path, &query)).await {
        Ok(response) => response,
        Err(_) => failure(
            StatusCode::GATEWAY_TIMEOUT,
            "Metadata request timed out. Try again.",
        ),
    }
}

async fn fetch(state: &MetadataState, path: &str, query: &[(String, String)]) -> Response {
    let Ok(_permit) = state.requests.acquire().await else {
        return failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "Metadata is busy. Try again.",
        );
    };
    // Path segments and query keys have already been allowlisted. Never use an
    // incoming host, upstream Authorization header, or API credential.
    let Ok(url) = state.upstream.join(path) else {
        return failure(
            StatusCode::BAD_REQUEST,
            "Unsupported metadata path or query.",
        );
    };
    let result = state
        .http
        .get(url)
        .query(query)
        .query(&[("api_key", &state.api_key)])
        .header(header::ACCEPT, "application/json")
        .send()
        .await;
    let mut upstream = match result {
        Ok(response) => response,
        Err(error) => {
            // reqwest errors contain their URL, including api_key. Never return
            // or log the error itself, or an upstream body/Location header.
            return if error.is_timeout() {
                failure(
                    StatusCode::GATEWAY_TIMEOUT,
                    "Metadata request timed out. Try again.",
                )
            } else {
                failure(
                    StatusCode::BAD_GATEWAY,
                    "Metadata could not be loaded. Try again.",
                )
            };
        }
    };
    if !upstream.status().is_success() {
        return match upstream.status() {
            StatusCode::NOT_FOUND => {
                failure(StatusCode::NOT_FOUND, "This metadata item is unavailable.")
            }
            StatusCode::TOO_MANY_REQUESTS => failure(
                StatusCode::TOO_MANY_REQUESTS,
                "Metadata is busy. Try again shortly.",
            ),
            _ => failure(
                StatusCode::BAD_GATEWAY,
                "Metadata could not be loaded. Try again.",
            ),
        };
    }
    if upstream
        .content_length()
        .is_some_and(|size| size > BODY_LIMIT as u64)
    {
        return failure(StatusCode::BAD_GATEWAY, "Invalid metadata response.");
    }
    let mut bytes = Vec::new();
    loop {
        match upstream.chunk().await {
            Ok(Some(chunk)) if bytes.len().saturating_add(chunk.len()) <= BODY_LIMIT => {
                bytes.extend_from_slice(&chunk)
            }
            Ok(None) => break,
            _ => return failure(StatusCode::BAD_GATEWAY, "Invalid metadata response."),
        }
    }
    let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
        return failure(StatusCode::BAD_GATEWAY, "Invalid metadata response.");
    };
    // Fail closed if a provider ever echoes credentials, even in a 200 response.
    // Checking after decoding also catches JSON-escaped copies of the key.
    if !value.is_object()
        || value.get("success") == Some(&Value::Bool(false))
        || value.to_string().contains(&state.api_key)
    {
        return failure(StatusCode::BAD_GATEWAY, "Invalid metadata response.");
    }
    Json(value).into_response()
}

fn failure(status: StatusCode, message: &'static str) -> Response {
    (
        status,
        Json(json!({"success": false, "error": message, "status_message": message})),
    )
        .into_response()
}

fn positive_id(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|c| c.is_ascii_digit())
        && value.parse::<u32>().is_ok_and(|id| id > 0)
}

fn allowed_path(path: &str) -> bool {
    if path.len() > 120 {
        return false;
    }
    let segments = path.split('/').collect::<Vec<_>>();
    match segments.as_slice() {
        ["discover", "movie" | "tv"] | ["search", "multi" | "movie" | "tv"] => true,
        ["trending", "all" | "movie" | "tv", "day" | "week"] => true,
        ["movie", "now_playing" | "upcoming"] => true,
        ["movie" | "tv", id] => positive_id(id),
        ["tv", id, "season", season] => {
            positive_id(id)
                && !season.is_empty()
                && season.bytes().all(|c| c.is_ascii_digit())
                && season.parse::<u16>().is_ok_and(|v| v <= 1000)
        }
        ["find", id] => id
            .strip_prefix("tt")
            .is_some_and(|number| number.len() <= 12 && positive_id(number)),
        _ => false,
    }
}

fn validated_query(path: &str, raw: &str) -> Result<Vec<(String, String)>, ()> {
    if !allowed_path(path) || raw.len() > 4096 {
        return Err(());
    }
    let mut url = reqwest::Url::parse(UPSTREAM).map_err(|_| ())?;
    url.set_query(Some(raw));
    let mut seen = HashSet::new();
    let mut query = Vec::new();
    for (key, value) in url.query_pairs() {
        if query.len() >= 32
            || !seen.insert(key.to_string())
            || value.len() > 500
            || value.chars().any(char::is_control)
            || !allowed_parameter(path, &key, &value)
        {
            return Err(());
        }
        query.push((key.into_owned(), value.into_owned()));
    }
    Ok(query)
}

fn allowed_parameter(path: &str, key: &str, value: &str) -> bool {
    match key {
        "language" => language(value),
        "page" => value
            .parse::<u16>()
            .is_ok_and(|page| (1..=500).contains(&page)),
        "query" => path.starts_with("search/") && !value.trim().is_empty(),
        "include_adult" => matches!(value, "true" | "false"),
        "region" | "with_origin_country" => {
            value.len() == 2 && value.bytes().all(|c| c.is_ascii_uppercase())
        }
        "with_original_language" => {
            value.len() == 2 && value.bytes().all(|c| c.is_ascii_lowercase())
        }
        "include_image_language" => value.split(',').all(|v| v == "null" || language(v)),
        "append_to_response" => {
            let parts = path.split('/').collect::<Vec<_>>();
            matches!(parts.as_slice(), ["movie" | "tv", id] if positive_id(id))
                && value.split(',').all(|v| {
                    matches!(
                        v,
                        "external_ids"
                            | "images"
                            | "credits"
                            | "release_dates"
                            | "content_ratings"
                            | "similar"
                    )
                })
        }
        "external_source" => path.starts_with("find/") && value == "imdb_id",
        "sort_by" => {
            path.starts_with("discover/")
                && matches!(
                    value,
                    "popularity.desc"
                        | "popularity.asc"
                        | "vote_average.desc"
                        | "vote_average.asc"
                        | "primary_release_date.desc"
                        | "primary_release_date.asc"
                        | "first_air_date.desc"
                        | "first_air_date.asc"
                )
        }
        "with_genres" | "with_keywords" | "with_release_type" => {
            path.starts_with("discover/") && value.split([',', '|']).all(positive_id)
        }
        "vote_count.gte" | "vote_count.lte" => {
            path.starts_with("discover/") && value.parse::<u32>().is_ok()
        }
        "vote_average.gte" | "vote_average.lte" => {
            path.starts_with("discover/")
                && value
                    .parse::<f32>()
                    .is_ok_and(|v| (0.0..=10.0).contains(&v))
        }
        "air_date.gte"
        | "air_date.lte"
        | "release_date.gte"
        | "release_date.lte"
        | "primary_release_date.gte"
        | "primary_release_date.lte" => {
            path.starts_with("discover/")
                && value.len() == 10
                && chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d").is_ok()
        }
        // Includes api_key, session_id, access_token, callback, arbitrary URLs,
        // and unrecognized future TMDB options: none can cross this boundary.
        _ => false,
    }
}

fn language(value: &str) -> bool {
    let parts = value.split('-').collect::<Vec<_>>();
    matches!(parts.as_slice(), [lang] if lang.len() == 2 && lang.bytes().all(|c| c.is_ascii_lowercase()))
        || matches!(parts.as_slice(), [lang, region] if lang.len() == 2 && lang.bytes().all(|c| c.is_ascii_lowercase())
            && region.len() == 2 && region.bytes().all(|c| c.is_ascii_uppercase()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::OriginalUri, http::HeaderMap};
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn only_native_read_paths_and_queries_are_allowed() {
        for path in [
            "discover/movie",
            "discover/tv",
            "search/multi",
            "trending/all/day",
            "trending/tv/week",
            "movie/now_playing",
            "movie/upcoming",
            "movie/550",
            "tv/1434",
            "tv/1434/season/0",
            "find/tt0137523",
        ] {
            assert!(allowed_path(path), "{path}");
        }
        for path in [
            "https://evil.test/movie/1",
            "//evil.test",
            "../account",
            "movie/1/../../account",
            "movie/%2e%2e",
            "movie/1/rating",
            "account/1",
            "authentication/token/new",
            "movie/0",
            "movie/-1",
            "tv/1/season/-1",
            "movie/1/",
        ] {
            assert!(!allowed_path(path), "{path}");
        }
        assert!(validated_query("discover/movie", "page=3&language=en-US&sort_by=popularity.desc&with_genres=28%7C12&vote_count.gte=50&release_date.lte=2026-10-19&include_adult=false").is_ok());
        assert!(validated_query("movie/550", "append_to_response=external_ids,images,credits,release_dates,similar&include_image_language=en,null").is_ok());
        assert!(validated_query(
            "tv/1434",
            "append_to_response=external_ids,images,credits,content_ratings,similar"
        )
        .is_ok());
        assert!(validated_query("find/tt0137523", "external_source=imdb_id").is_ok());
        assert!(validated_query(
            "search/multi",
            "query=A%26B+movie&include_adult=false&page=1"
        )
        .is_ok());
        for query in [
            "api_key=client-secret",
            "%61pi_key=client-secret",
            "access_token=secret",
            "session_id=secret",
            "callback=evil",
            "page=1&page=2",
            "page=0",
            "page=501",
            "url=https://evil.test",
            "append_to_response=account_states",
            "query=%0Asecret",
        ] {
            assert!(validated_query("movie/550", query).is_err(), "{query}");
        }
    }

    async fn serve(app: Router) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (base, task)
    }

    #[tokio::test]
    async fn routes_authenticate_every_call_and_keep_upstream_credentials_private() {
        const KEY: &str = "server-only-test-metadata-credential";
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = calls.clone();
        let upstream = Router::new().route(
            "/*path",
            get(move |OriginalUri(uri): OriginalUri, headers: HeaderMap| {
                let counter = counter.clone();
                async move {
                    counter.fetch_add(1, Ordering::SeqCst);
                    assert!(!headers.contains_key(header::AUTHORIZATION));
                    assert!(!headers.contains_key(header::COOKIE));
                    let url = reqwest::Url::parse(&format!("http://fixture{uri}")).unwrap();
                    let pairs = url.query_pairs().collect::<Vec<_>>();
                    assert_eq!(pairs.iter().filter(|(key, _)| key == "api_key").count(), 1);
                    assert_eq!(
                        pairs.iter().find(|(key, _)| key == "api_key").unwrap().1,
                        KEY
                    );
                    match uri.path() {
                        "/movie/404" => (StatusCode::NOT_FOUND, format!("request failed: {KEY}"))
                            .into_response(),
                        "/movie/401" => (
                            StatusCode::UNAUTHORIZED,
                            format!("invalid URL api_key={KEY}"),
                        )
                            .into_response(),
                        "/movie/302" => (
                            StatusCode::FOUND,
                            [(header::LOCATION, "/movie/550")],
                            "redirect",
                        )
                            .into_response(),
                        "/movie/999" => Json(json!({"id":999,"unexpected":KEY})).into_response(),
                        "/movie/998" => Json(json!({"success":false})).into_response(),
                        _ => Json(json!({"id":550,"title":"Fixture", "images":{"logos":[]}}))
                            .into_response(),
                    }
                }
            }),
        );
        let (upstream_base, upstream_task) = serve(upstream).await;
        let (base, task) =
            serve(build_router("app-test-token".into(), KEY.into(), &upstream_base).unwrap()).await;
        let client = reqwest::Client::new();
        let url = format!("{base}metadata/tmdb/movie/550?language=en-US");
        for token in [None, Some("wrong")] {
            let mut request = client.get(&url);
            if let Some(token) = token {
                request = request.bearer_auth(token);
            }
            let response = request.send().await.unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
            assert_eq!(
                response.headers()[header::CACHE_CONTROL],
                "private, no-store"
            );
        }
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        let response = client
            .get(&url)
            .bearer_auth("app-test-token")
            .header(header::COOKIE, "not-upstream=1")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[header::VARY], "Authorization");
        assert_eq!(response.json::<Value>().await.unwrap()["title"], "Fixture");
        assert_eq!(
            client.get(&url).send().await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        for suffix in [
            "movie/550?api_key=secret",
            "account/1",
            "movie/550?append_to_response=account_states",
            "movie/550?callback=evil",
        ] {
            let response = client
                .get(format!("{base}metadata/tmdb/{suffix}"))
                .bearer_auth("app-test-token")
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{suffix}");
        }
        assert_eq!(
            client
                .post(&url)
                .bearer_auth("app-test-token")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::METHOD_NOT_ALLOWED
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        for (id, status) in [
            (404, StatusCode::NOT_FOUND),
            (401, StatusCode::BAD_GATEWAY),
            (302, StatusCode::BAD_GATEWAY),
            (999, StatusCode::BAD_GATEWAY),
            (998, StatusCode::BAD_GATEWAY),
        ] {
            let response = client
                .get(format!("{base}metadata/tmdb/movie/{id}"))
                .bearer_auth("app-test-token")
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), status);
            assert!(!response.headers().contains_key(header::LOCATION));
            let body = response.text().await.unwrap();
            assert!(!body.contains(KEY));
            assert!(!body.contains("api_key="));
        }
        assert_eq!(calls.load(Ordering::SeqCst), 6); // the redirect was not followed
        task.abort();
        upstream_task.abort();
    }

    #[tokio::test]
    async fn missing_key_has_a_clear_backend_configuration_error() {
        let (base, task) =
            serve(build_router("".into(), "".into(), "http://127.0.0.1:9/").unwrap()).await;
        let response = reqwest::get(format!("{base}metadata/tmdb/movie/550"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert!(response
            .text()
            .await
            .unwrap()
            .contains("Set VELVET_TMDB_KEY on the backend"));
        task.abort();
    }
}
