//! Native-client discovery. Only fixed TMDB recipes are exposed; credentials and
//! arbitrary upstream URLs never enter the client contract.
use crate::catalog::{self, CatalogState};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use chrono::{Datelike, Days, NaiveDate, Utc};
use futures::{stream, StreamExt};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, Semaphore};

const CACHE_LIMIT: usize = 96;
const BODY_LIMIT: usize = 2 * 1024 * 1024;
const FRESH: Duration = Duration::from_secs(15 * 60);
const STALE: Duration = Duration::from_secs(4 * 3600);
type Cached = Arc<Mutex<Option<(Instant, Value)>>>;
type Params = Vec<(&'static str, String)>;
type BrowseResult<T> = Result<T, BrowseError>;

pub struct BrowseCache {
    entries: Mutex<HashMap<String, (Instant, Cached)>>,
    requests: Semaphore,
}
impl BrowseCache {
    pub fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            requests: Semaphore::new(4),
        }
    }

    async fn get(
        &self,
        http: &reqwest::Client,
        path: &str,
        query: &Params,
    ) -> BrowseResult<(Value, bool)> {
        // The key contains only validated, non-secret query data.
        let key = format!(
            "{path}:{}",
            serde_json::to_string(query).unwrap_or_default()
        );
        let cell = {
            let mut entries = self.entries.lock().await;
            entries.retain(|_, (at, cell)| at.elapsed() < STALE || Arc::strong_count(cell) > 1);
            if !entries.contains_key(&key) && entries.len() >= CACHE_LIMIT {
                let oldest = entries
                    .iter()
                    .filter(|(_, (_, cell))| Arc::strong_count(cell) == 1)
                    .min_by_key(|(_, (at, _))| *at)
                    .map(|(key, _)| key.clone());
                if let Some(oldest) = oldest {
                    entries.remove(&oldest);
                } else {
                    return Err(BrowseError::busy());
                }
            }
            let entry = entries
                .entry(key)
                .or_insert_with(|| (Instant::now(), Arc::new(Mutex::new(None))));
            entry.0 = Instant::now();
            entry.1.clone()
        };
        // Single-flight per URL; callers cannot queue indefinitely behind a
        // slow lookup. The outer bound includes lock/permit/body time.
        tokio::time::timeout(Duration::from_secs(14), async {
            let mut cached = cell.lock().await;
            if let Some((_, value)) = cached.as_ref().filter(|(at, _)| at.elapsed() < FRESH) {
                return Ok((value.clone(), false));
            }
            let result = match self.requests.try_acquire() {
                Ok(_permit) => fetch(http, path, query).await,
                Err(_) => Err(BrowseError::busy()),
            };
            match result {
                Ok(value) => {
                    *cached = Some((Instant::now(), value.clone()));
                    Ok((value, false))
                }
                Err(error) => match cached.as_ref().filter(|(at, _)| at.elapsed() < STALE) {
                    Some((_, value)) => Ok((value.clone(), true)),
                    None => Err(error),
                },
            }
        })
        .await
        .map_err(|_| BrowseError::unavailable())?
    }
}

async fn fetch(http: &reqwest::Client, path: &str, query: &Params) -> BrowseResult<Value> {
    let api_key = crate::resolver::tmdb_key();
    if api_key.is_empty() { return Err(BrowseError::unavailable()); }
    let mut response = http
        .get(format!("https://api.themoviedb.org/3/{path}"))
        .query(&[("api_key", api_key)])
        .query(query)
        .timeout(Duration::from_secs(12))
        .send()
        .await
        .map_err(|_| BrowseError::unavailable())?;
    if response.status() == StatusCode::NOT_FOUND {
        return Err(BrowseError::not_found());
    }
    if !response.status().is_success() {
        return Err(BrowseError::unavailable());
    }
    if response
        .content_length()
        .is_some_and(|size| size > BODY_LIMIT as u64)
    {
        return Err(BrowseError::unavailable());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| BrowseError::unavailable())?
    {
        if bytes.len().saturating_add(chunk.len()) > BODY_LIMIT {
            return Err(BrowseError::unavailable());
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| BrowseError::unavailable())?;
    // A successful HTTP status with an error/malformed payload must not poison
    // the good-response cache for the next 15 minutes.
    if !valid_payload(path, &value) {
        return Err(BrowseError::unavailable());
    }
    Ok(value)
}

fn valid_payload(path: &str, value: &Value) -> bool {
    if path.starts_with("discover/") || path.starts_with("search/") || path.starts_with("trending/")
    {
        value["results"].is_array()
    } else if path.contains("/season/") {
        value["episodes"].is_array() && value["season_number"].is_u64()
    } else {
        value["id"].as_u64().is_some_and(|id| id > 0)
    }
}

#[derive(Debug)]
struct BrowseError(StatusCode, &'static str);
impl BrowseError {
    fn invalid() -> Self {
        Self(StatusCode::BAD_REQUEST, "Invalid catalog request.")
    }
    fn not_found() -> Self {
        Self(StatusCode::NOT_FOUND, "This catalog item is unavailable.")
    }
    fn unavailable() -> Self {
        Self(
            StatusCode::BAD_GATEWAY,
            "The catalog could not be loaded. Try again.",
        )
    }
    fn busy() -> Self {
        Self(
            StatusCode::SERVICE_UNAVAILABLE,
            "The catalog is busy. Try again shortly.",
        )
    }
}
impl IntoResponse for BrowseError {
    fn into_response(self) -> Response {
        catalog::error(self.0, self.1)
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Media {
    media_id: u64,
    r#type: &'static str,
    title: String,
    year: Option<String>,
    rating: Option<f64>,
    poster_url: Option<String>,
    backdrop_url: Option<String>,
    logo_url: Option<String>,
    overview: Option<String>,
    genres: Vec<String>,
    runtime_minutes: Option<u64>,
    imdb_id: Option<String>,
}
fn text(v: &Value, max: usize) -> Option<String> {
    v.as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(max).collect())
}
fn image(v: &Value, field: &str, size: &str) -> Option<String> {
    let path = v[field].as_str()?;
    (path.len() <= 256
        && path.starts_with('/')
        && !path.contains("..")
        && path
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/._-".contains(&b)))
    .then(|| format!("https://image.tmdb.org/t/p/{size}{path}"))
}
fn items(v: &Value) -> &[Value] {
    v.as_array().map(Vec::as_slice).unwrap_or_default()
}
fn date_value(v: &Value) -> Option<NaiveDate> {
    let raw = v.as_str()?.get(..10)?;
    let day = NaiveDate::parse_from_str(raw, "%Y-%m-%d").ok()?;
    (day.format("%Y-%m-%d").to_string() == raw).then_some(day)
}
fn media(v: &Value, kind: Option<&str>) -> Option<Media> {
    if v["adult"].as_bool() == Some(true) {
        return None;
    }
    let kind = match kind.or_else(|| v["media_type"].as_str())? {
        "movie" => "movie",
        "show" | "tv" => "show",
        _ => return None,
    };
    let id = v["id"]
        .as_u64()
        .filter(|id| (1..=i32::MAX as u64).contains(id))?;
    let title_field = if kind == "movie" { "title" } else { "name" };
    let title =
        text(&v[title_field], 400).or_else(|| text(&v[format!("original_{title_field}")], 400))?;
    let first = date_value(
        &v[if kind == "movie" {
            "release_date"
        } else {
            "first_air_date"
        }],
    );
    let mut year = first.map(|day| day.year().to_string());
    if kind == "show" && matches!(v["status"].as_str(), Some("Ended" | "Canceled")) {
        if let (Some(first), Some(last)) = (first, date_value(&v["last_air_date"])) {
            if last.year() > first.year() {
                year = Some(format!("{}–{}", first.year(), last.year()));
            }
        }
    }
    let logos = items(&v["images"]["logos"]);
    let logo = logos
        .iter()
        .filter(|l| l["iso_639_1"] == "en" || l["iso_639_1"].is_null())
        .min_by_key(|l| {
            (
                l["iso_639_1"] != "en",
                !l["file_path"]
                    .as_str()
                    .unwrap_or_default()
                    .ends_with(".png"),
            )
        });
    let imdb = v["external_ids"]["imdb_id"]
        .as_str()
        .or_else(|| v["imdb_id"].as_str())
        .filter(|s| {
            s.len() <= 20
                && s.starts_with("tt")
                && s.len() > 2
                && s[2..].bytes().all(|b| b.is_ascii_digit())
        });
    Some(Media {
        media_id: id,
        r#type: kind,
        title,
        year,
        rating: v["vote_average"]
            .as_f64()
            .filter(|n| *n > 0.0 && *n <= 10.0),
        poster_url: image(v, "poster_path", "w500"),
        backdrop_url: image(v, "backdrop_path", "w1280"),
        logo_url: logo.and_then(|l| image(l, "file_path", "w500")),
        overview: text(&v["overview"], 12_000),
        genres: items(&v["genres"])
            .iter()
            .filter_map(|g| text(&g["name"], 80))
            .take(20)
            .collect(),
        runtime_minutes: v["runtime"].as_u64().filter(|n| *n > 0).or_else(|| {
            items(&v["episode_run_time"])
                .iter()
                .filter_map(Value::as_u64)
                .find(|n| *n > 0)
        }),
        imdb_id: imdb.map(str::to_owned),
    })
}
fn media_list(value: &Value, kind: Option<&str>) -> BrowseResult<Vec<Media>> {
    let results = value["results"]
        .as_array()
        .ok_or_else(BrowseError::unavailable)?;
    let mut seen = HashSet::new();
    Ok(results
        .iter()
        .filter_map(|v| media(v, kind))
        .filter(|v| seen.insert((v.r#type, v.media_id)))
        .take(20)
        .collect())
}
fn positive(raw: &str) -> BrowseResult<u64> {
    raw.parse::<u64>()
        .ok()
        .filter(|n| (1..=i32::MAX as u64).contains(n))
        .filter(|n| n.to_string() == raw)
        .ok_or_else(BrowseError::invalid)
}
fn request_date(q: &HashMap<String, String>) -> BrowseResult<NaiveDate> {
    match q.get("date") {
        None => Ok(Utc::now().date_naive()),
        Some(raw) => {
            let value = Value::String(raw.clone());
            date_value(&value)
                .filter(|d| raw.len() == 10 && (2000..=2100).contains(&d.year()))
                .ok_or_else(BrowseError::invalid)
        }
    }
}
fn page(q: &HashMap<String, String>) -> BrowseResult<u64> {
    q.get("page")
        .map(|raw| {
            positive(raw).and_then(|p| {
                if p <= 20 {
                    Ok(p)
                } else {
                    Err(BrowseError::invalid())
                }
            })
        })
        .unwrap_or(Ok(1))
}
fn kind(raw: &str) -> BrowseResult<&'static str> {
    match raw {
        "movie" => Ok("movie"),
        "show" => Ok("show"),
        _ => Err(BrowseError::not_found()),
    }
}
fn total_pages(v: &Value) -> u64 {
    v["total_pages"].as_u64().unwrap_or(1).min(20)
}

#[derive(Clone, Copy)]
struct Row {
    id: &'static str,
    title: &'static str,
    style: &'static str,
}
const ROWS: &[Row] = &[
    Row {
        id: "holiday_halloween",
        title: "Halloween Movies",
        style: "poster",
    },
    Row {
        id: "holiday_thanksgiving",
        title: "Thanksgiving Movies",
        style: "poster",
    },
    Row {
        id: "holiday_christmas",
        title: "Christmas Movies",
        style: "poster",
    },
    Row {
        id: "holiday_newyear",
        title: "New Year's Movies",
        style: "poster",
    },
    Row {
        id: "holiday_valentines",
        title: "Valentine's Movies",
        style: "poster",
    },
    Row {
        id: "popular_now",
        title: "Popular Now",
        style: "landscape",
    },
    Row {
        id: "trending_shows",
        title: "Trending Shows",
        style: "landscape",
    },
    Row {
        id: "new_to_stream",
        title: "New to Stream",
        style: "poster",
    },
    Row {
        id: "bingeworthy",
        title: "Bingeworthy Shows",
        style: "poster",
    },
    Row {
        id: "acclaimed",
        title: "Critically Acclaimed",
        style: "poster",
    },
    Row {
        id: "action",
        title: "Action & Adrenaline",
        style: "poster",
    },
    Row {
        id: "animation_family",
        title: "Animation & Family",
        style: "poster",
    },
];
fn active(row: Row, date: NaiveDate) -> bool {
    let md = date.month() * 100 + date.day();
    match row.id {
        "holiday_halloween" => (801..=1031).contains(&md),
        "holiday_thanksgiving" => (1101..=1130).contains(&md),
        "holiday_christmas" => (1115..=1231).contains(&md),
        "holiday_newyear" => md >= 1226 || md <= 105,
        "holiday_valentines" => (201..=215).contains(&md),
        _ => true,
    }
}
fn recipe(row: Row, page: u64, date: NaiveDate) -> (&'static str, &'static str, Params) {
    let mut query = vec![
        ("page", page.to_string()),
        ("include_adult", "false".into()),
        ("language", "en-US".into()),
        ("sort_by", "popularity.desc".into()),
    ];
    let show = matches!(row.id, "trending_shows" | "bingeworthy");
    if show {
        query.push(("first_air_date.lte", date.to_string()));
        query.push(("with_original_language", "en".into()));
        if row.id == "bingeworthy" {
            query.extend([
                ("vote_count.gte", "1000".into()),
                ("vote_average.gte", "7.5".into()),
            ]);
        }
    } else {
        // Region and a release_date bound are both required for TMDB to apply
        // the digital/physical type filter. Primary release date alone is not enough.
        query.extend([
            ("with_release_type", "4|5".into()),
            ("region", "US".into()),
            ("release_date.lte", date.to_string()),
        ]);
        match row.id {
            "popular_now" => query.push(("vote_count.gte", "50".into())),
            "new_to_stream" => query.extend([
                (
                    "release_date.gte",
                    date.checked_sub_days(Days::new(75))
                        .unwrap_or(date)
                        .to_string(),
                ),
                ("with_original_language", "en".into()),
            ]),
            "acclaimed" => query.extend([
                ("vote_count.gte", "1500".into()),
                ("vote_average.gte", "7.8".into()),
                ("with_original_language", "en".into()),
            ]),
            "action" | "animation_family" => query.extend([
                (
                    "with_genres",
                    if row.id == "action" {
                        "28|12"
                    } else {
                        "16|10751"
                    }
                    .into(),
                ),
                ("vote_count.gte", "300".into()),
                ("vote_average.gte", "6.3".into()),
                ("with_original_language", "en".into()),
            ]),
            _ => {
                let keyword = match row.id {
                    "holiday_halloween" => "3335",
                    "holiday_thanksgiving" => "4543",
                    "holiday_christmas" => "207317",
                    "holiday_newyear" => "252123",
                    "holiday_valentines" => "160404",
                    _ => unreachable!(),
                };
                query.extend([
                    ("with_keywords", keyword.into()),
                    ("vote_count.gte", "25".into()),
                ]);
                if row.id == "holiday_christmas" {
                    query.push(("with_genres", "10751|35|10749".into()));
                }
            }
        }
    }
    (
        if row.id == "trending_shows" {
            "trending/tv/week"
        } else if show {
            "discover/tv"
        } else {
            "discover/movie"
        },
        if show { "show" } else { "movie" },
        query,
    )
}
async fn load_row(st: &CatalogState, row: Row, p: u64, day: NaiveDate) -> BrowseResult<Value> {
    if !active(row, day) {
        return Ok(
            json!({"id":row.id,"title":row.title,"style":row.style,"items":[],"page":p,"totalPages":0,"stale":false}),
        );
    }
    let (path, kind, query) = recipe(row, p, day);
    let (mut value, stale) = st.browse.get(&st.http, path, &query).await?;
    if row.id == "trending_shows" {
        // The trending API ignores discover's first-air-date filter.
        if let Some(results) = value["results"].as_array_mut() {
            results.retain(|v| date_value(&v["first_air_date"]).is_some_and(|date| date <= day));
        }
    }
    let cards = media_list(&value, Some(kind))?;
    Ok(
        json!({"id":row.id,"title":row.title,"style":row.style,"items":cards,
        "page":p,"totalPages":total_pages(&value),"stale":stale}),
    )
}

pub async fn home(
    State(st): State<Arc<CatalogState>>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let day = match request_date(&q) {
        Ok(day) => day,
        Err(e) => return e.into_response(),
    };
    let requested: Vec<_> = ROWS
        .iter()
        .copied()
        .filter(|r| active(*r, day))
        .take(8)
        .collect();
    let results: Vec<_> = stream::iter(requested.into_iter().map(|row| {
        let st = st.clone();
        async move { (row.id, load_row(&st, row, 1, day).await) }
    }))
    .buffered(4)
    .collect()
    .await;
    home_response(results)
}
fn home_response(results: Vec<(&str, BrowseResult<Value>)>) -> Response {
    let mut rows = Vec::new();
    let mut failed = Vec::new();
    for (id, result) in results {
        match result {
            Ok(row) => rows.push(row),
            Err(_) => failed.push(id.to_owned()),
        }
    }
    if rows.is_empty() && !failed.is_empty() {
        return BrowseError::unavailable().into_response();
    }
    let message = if failed.is_empty() {
        None
    } else {
        Some("Some rows could not be loaded. Try again.")
    };
    Json(json!({"rows":rows,"failedRows":failed,"message":message})).into_response()
}
pub async fn row(
    State(st): State<Arc<CatalogState>>,
    Path(id): Path<String>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let result = async {
        let row = ROWS
            .iter()
            .find(|r| r.id == id)
            .copied()
            .ok_or_else(BrowseError::not_found)?;
        load_row(&st, row, page(&q)?, request_date(&q)?).await
    }
    .await;
    respond(result)
}
pub async fn search(
    State(st): State<Arc<CatalogState>>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let result = async {
        let query = q.get("q").map(|s| s.trim()).filter(|s| !s.is_empty() && s.chars().count() <= 200)
            .ok_or_else(BrowseError::invalid)?;
        let p = page(&q)?;
        let (value, stale) = st.browse.get(&st.http, "search/multi", &vec![
            ("query", query.into()), ("page", p.to_string()), ("include_adult", "false".into()),
            ("language", "en-US".into())]).await?;
        Ok(json!({"items":media_list(&value,None)?,"page":p,"totalPages":total_pages(&value),"stale":stale}))
    }.await;
    respond(result)
}
fn digitally_available(v: &Value, day: NaiveDate) -> bool {
    let cutoff = day.checked_sub_days(Days::new(100)).unwrap_or(day);
    let releases: Vec<_> = items(&v["release_dates"]["results"])
        .iter()
        .flat_map(|r| items(&r["release_dates"]))
        .collect();
    if releases.is_empty() {
        return date_value(&v["release_date"]).is_some_and(|d| d <= cutoff);
    }
    releases.into_iter().any(|r| {
        date_value(&r["release_date"]).is_some_and(|d| {
            (matches!(r["type"].as_u64(), Some(4..=6)) && d <= day)
                || (matches!(r["type"].as_u64(), Some(1..=3)) && d <= cutoff)
        })
    })
}
fn details_value(
    value: &Value,
    kind: &str,
    id: u64,
    day: NaiveDate,
    stale: bool,
) -> BrowseResult<Value> {
    let item = media(value, Some(kind))
        .filter(|item| item.media_id == id)
        .ok_or_else(BrowseError::not_found)?;
    let certification = if kind == "movie" {
        items(&value["release_dates"]["results"])
            .iter()
            .find(|r| r["iso_3166_1"] == "US")
            .and_then(|r| {
                items(&r["release_dates"])
                    .iter()
                    .find_map(|d| text(&d["certification"], 40))
            })
    } else {
        items(&value["content_ratings"]["results"])
            .iter()
            .find(|r| r["iso_3166_1"] == "US")
            .and_then(|r| text(&r["rating"], 40))
    };
    let cast: Vec<_> = items(&value["credits"]["cast"])
        .iter()
        .filter_map(|person| {
            Some(
                json!({"name":text(&person["name"],200)?,"role":text(&person["character"],200),
            "profileUrl":image(person,"profile_path","w185")}),
            )
        })
        .take(24)
        .collect();
    let mut seasons: Vec<_> = if kind == "show" {
        let mut seen = HashSet::new();
        items(&value["seasons"]).iter().filter_map(|season| {
            let n = season["season_number"].as_u64().filter(|n| (1..=1000).contains(n))?;
            if !seen.insert(n) { return None; }
            Some(json!({"number":n,"name":text(&season["name"],200).unwrap_or_else(||format!("Season {n}")),
                "episodeCount":season["episode_count"].as_u64().unwrap_or(0).min(10000),
                "posterUrl":image(season,"poster_path","w500").or_else(||item.poster_url.clone())}))
        }).take(1000).collect()
    } else {
        Vec::new()
    };
    seasons.sort_by_key(|s| s["number"].as_u64().unwrap_or(0));
    let similar = if value["similar"]["results"].is_array() {
        media_list(&value["similar"], Some(kind))?
    } else {
        Vec::new()
    };
    Ok(
        json!({"item":item,"tagline":text(&value["tagline"],500),"certification":certification,
        "cast":cast,"seasons":seasons,"similar":similar,"digitallyAvailable":
            kind == "show" || digitally_available(value,day),"stale":stale}),
    )
}
pub async fn details(
    State(st): State<Arc<CatalogState>>,
    Path((raw_kind, raw_id)): Path<(String, String)>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    let result = async {
        let kind = kind(&raw_kind)?;
        let id = positive(&raw_id)?;
        let day = request_date(&q)?;
        let path = format!("{}/{id}", if kind == "show" { "tv" } else { "movie" });
        let append = if kind == "show" {
            "external_ids,images,credits,content_ratings,similar"
        } else {
            "external_ids,images,credits,release_dates,similar"
        };
        let (value, stale) = st
            .browse
            .get(
                &st.http,
                &path,
                &vec![
                    ("append_to_response", append.into()),
                    ("include_image_language", "en,null".into()),
                    ("language", "en-US".into()),
                ],
            )
            .await?;
        details_value(&value, kind, id, day, stale)
    }
    .await;
    respond(result)
}
fn season_value(value: &Value, id: u64, season: u64, stale: bool) -> BrowseResult<Value> {
    if value["season_number"].as_u64() != Some(season)
        || value["show_id"].as_u64().is_some_and(|show| show != id)
    {
        return Err(BrowseError::unavailable());
    }
    let episodes = value["episodes"]
        .as_array()
        .ok_or_else(BrowseError::unavailable)?;
    let mut seen = HashSet::new();
    let mut episodes: Vec<_> = episodes.iter().filter_map(|ep| {
        if ep["season_number"].as_u64() != Some(season) ||
            ep["show_id"].as_u64().is_some_and(|show| show != id) { return None; }
        let number = ep["episode_number"].as_u64().filter(|n| (1..=10000).contains(n))?;
        if !seen.insert(number) { return None; }
        Some(json!({"season":season,"number":number,"title":text(&ep["name"],400)
            .unwrap_or_else(||format!("Episode {number}")),"overview":text(&ep["overview"],12000),
            "stillUrl":image(ep,"still_path","w780"),"runtimeMinutes":ep["runtime"].as_u64().filter(|n|*n>0),
            "airDate":date_value(&ep["air_date"]).map(|d|d.to_string())}))
    }).take(10000).collect();
    episodes.sort_by_key(|ep| ep["number"].as_u64().unwrap_or(0));
    Ok(json!({"mediaId":id,"season":season,"episodes":episodes,"stale":stale}))
}
pub async fn season(
    State(st): State<Arc<CatalogState>>,
    Path((raw_id, raw_season)): Path<(String, String)>,
) -> Response {
    let result = async {
        let id = positive(&raw_id)?;
        let season = raw_season
            .parse::<u64>()
            .ok()
            .filter(|n| *n <= 1000 && n.to_string() == raw_season)
            .ok_or_else(BrowseError::invalid)?;
        let (value, stale) = st
            .browse
            .get(
                &st.http,
                &format!("tv/{id}/season/{season}"),
                &vec![("language", "en-US".into())],
            )
            .await?;
        season_value(&value, id, season, stale)
    }
    .await;
    respond(result)
}
fn respond(result: BrowseResult<Value>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(error) => error.into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn day(raw: &str) -> NaiveDate {
        NaiveDate::parse_from_str(raw, "%Y-%m-%d").unwrap()
    }
    fn query(values: &[(&str, &str)]) -> HashMap<String, String> {
        values
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }
    async fn body(response: Response) -> Value {
        serde_json::from_slice(
            &axum::body::to_bytes(response.into_body(), BODY_LIMIT)
                .await
                .unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn request_validation_rejects_paths_unbounded_pages_and_noncanonical_dates() {
        for id in ["0", "-1", "01", "2147483648", "1/credits", "https://host"] {
            assert!(positive(id).is_err());
        }
        assert_eq!(positive("5371").ok(), Some(5371));
        assert!(kind("tv").is_err());
        for p in ["0", "21", "1.5", "01"] {
            assert!(page(&query(&[("page", p)])).is_err());
        }
        for d in ["2026-02-30", "2026-2-01", "2026-10-18junk", "1999-12-31"] {
            assert!(request_date(&query(&[("date", d)])).is_err());
        }
    }

    #[test]
    fn every_movie_home_recipe_keeps_the_region_scoped_digital_gate() {
        for row in ROWS {
            let (path, kind, q) = recipe(*row, 2, day("2026-10-18"));
            let q: HashMap<_, _> = q.into_iter().collect();
            assert_eq!(q["page"], "2");
            assert_eq!(q["include_adult"], "false");
            if kind == "movie" {
                assert_eq!(path, "discover/movie");
                assert_eq!(q["with_release_type"], "4|5");
                assert_eq!(q["region"], "US");
                assert_eq!(q["release_date.lte"], "2026-10-18");
            } else {
                assert_eq!(q["first_air_date.lte"], "2026-10-18");
            }
        }
    }

    #[test]
    fn seasonal_windows_handle_overlap_year_boundary_and_inactive_rows() {
        let row = |id| *ROWS.iter().find(|r| r.id == id).unwrap();
        assert!(!active(row("holiday_halloween"), day("2026-07-31")));
        assert!(active(row("holiday_halloween"), day("2026-08-01")));
        assert!(!active(row("holiday_halloween"), day("2026-11-01")));
        assert!(active(row("holiday_christmas"), day("2026-11-15")));
        assert!(active(row("holiday_thanksgiving"), day("2026-11-15")));
        for date in ["2026-12-26", "2027-01-05"] {
            assert!(active(row("holiday_newyear"), day(date)));
        }
        assert!(!active(row("holiday_newyear"), day("2027-01-06")));
    }

    #[test]
    fn cards_keep_identity_and_reject_people_adult_duplicates_and_unsafe_art() {
        let value = json!({"results":[
            {"id":7,"media_type":"tv","name":"Example","first_air_date":"2020-01-02","backdrop_path":"/fine.jpg"},
            {"id":7,"media_type":"tv","name":"Duplicate"},
            {"id":7,"media_type":"movie","title":"Distinct movie","poster_path":"/../secret"},
            {"id":8,"media_type":"person","name":"Person"},
            {"id":9,"media_type":"movie","title":"Adult","adult":true}
        ]});
        let result = media_list(&value, None).unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].r#type, "show");
        assert_eq!(result[0].media_id, 7);
        assert_eq!(result[0].year.as_deref(), Some("2020"));
        assert_eq!(result[1].poster_url, None);
        assert!(media_list(&json!({"status_message":"failure"}), None).is_err());
    }

    #[test]
    fn details_map_imdb_logo_sorted_regular_seasons_and_digital_availability() {
        let value = json!({"id":7,"name":"Example","first_air_date":"2020-01-02","last_air_date":"2023-01-01",
            "status":"Ended","external_ids":{"imdb_id":"tt123"},"poster_path":"/show.jpg",
            "images":{"logos":[{"iso_639_1":"en","file_path":"/logo.png"}]},
            "seasons":[{"season_number":2,"episode_count":8},{"season_number":0},{"season_number":1}],
            "content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-14"}]}});
        let result = details_value(&value, "show", 7, day("2026-10-18"), false).unwrap();
        assert_eq!(result["item"]["mediaId"], 7);
        assert_eq!(result["item"]["imdbId"], "tt123");
        assert_eq!(result["item"]["year"], "2020–2023");
        assert_eq!(result["seasons"][0]["number"], 1);
        assert_eq!(result["seasons"].as_array().unwrap().len(), 2);
        assert_eq!(result["certification"], "TV-14");
        assert!(details_value(&value, "show", 8, day("2026-10-18"), false).is_err());
        assert!(!digitally_available(
            &json!({"release_date":"2026-10-01"}),
            day("2026-10-18")
        ));
        assert!(digitally_available(
            &json!({"release_date":"2025-10-01"}),
            day("2026-10-18")
        ));
        assert!(digitally_available(
            &json!({"release_dates":{"results":[{"release_dates":[
            {"type":4,"release_date":"2026-10-18T00:00:00.000Z"}]}]}}),
            day("2026-10-18")
        ));
    }

    #[test]
    fn season_coordinates_are_verified_and_sorted_without_invented_episodes() {
        let value = json!({"season_number":2,"episodes":[
            {"season_number":2,"episode_number":4,"name":"Four","air_date":"2026-10-01"},
            {"season_number":1,"episode_number":1,"name":"Wrong season"},
            {"season_number":2,"episode_number":3,"name":"Three","show_id":7},
            {"season_number":2,"episode_number":5,"name":"Wrong show","show_id":8},
            {"season_number":2,"episode_number":4,"name":"Duplicate"}
        ]});
        let result = season_value(&value, 7, 2, false).unwrap();
        assert_eq!(result["episodes"].as_array().unwrap().len(), 2);
        assert_eq!(result["episodes"][0]["number"], 3);
        assert!(season_value(&value, 7, 1, false).is_err());
        assert!(season_value(&json!({"season_number":2}), 7, 2, false).is_err());
    }

    #[tokio::test]
    async fn home_preserves_successful_rows_and_reports_partial_failure() {
        let response = home_response(vec![
            ("popular_now", Ok(json!({"id":"popular_now","items":[]}))),
            ("trending_shows", Err(BrowseError::unavailable())),
        ]);
        assert_eq!(response.status(), StatusCode::OK);
        let value = body(response).await;
        assert_eq!(value["rows"].as_array().unwrap().len(), 1);
        assert_eq!(value["failedRows"], json!(["trending_shows"]));
        assert_eq!(
            home_response(vec![("popular_now", Err(BrowseError::unavailable()))]).status(),
            StatusCode::BAD_GATEWAY
        );
    }

    #[test]
    fn malformed_success_payloads_do_not_enter_the_cache() {
        assert!(!valid_payload("discover/movie", &json!({"success":false})));
        assert!(!valid_payload("tv/7/season/2", &json!({"season_number":2})));
        assert!(!valid_payload("movie/7", &json!({"id":0})));
        assert!(valid_payload("search/multi", &json!({"results":[]})));
    }

    #[tokio::test]
    async fn catalog_routes_share_auth_and_reject_invalid_input_before_upstream_access() {
        let app = catalog::router(
            reqwest::Client::new(),
            "test-only-secret".into(),
            crate::config::CategoryAi::default(),
            crate::db::open(":memory:").unwrap(),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let client = reqwest::Client::new();
        for path in [
            "/catalog/home",
            "/catalog/search?q=hello",
            "/catalog/rows/popular_now",
            "/catalog/movie/7",
            "/catalog/show/7/seasons/1",
        ] {
            let response = client.get(format!("{base}{path}")).send().await.unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "{path}");
        }
        for (path, status) in [
            ("/catalog/home?date=broken", StatusCode::BAD_REQUEST),
            ("/catalog/search?q=", StatusCode::BAD_REQUEST),
            ("/catalog/rows/not_a_row", StatusCode::NOT_FOUND),
            (
                "/catalog/rows/popular_now?page=999",
                StatusCode::BAD_REQUEST,
            ),
            ("/catalog/person/7", StatusCode::NOT_FOUND),
            ("/catalog/movie/0", StatusCode::BAD_REQUEST),
            ("/catalog/show/7/seasons/-1", StatusCode::BAD_REQUEST),
        ] {
            let response = client
                .get(format!("{base}{path}"))
                .bearer_auth("test-only-secret")
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), status, "{path}");
        }
        let response = client
            .get(format!(
                "{base}/catalog/rows/holiday_christmas?date=2026-07-04"
            ))
            .bearer_auth("test-only-secret")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.json::<Value>().await.unwrap()["items"], json!([]));
        server.abort();
    }
}
