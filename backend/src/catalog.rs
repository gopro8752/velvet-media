//! Episode-level rails. Curated names are checked against TMDB before returning
//! a PlayTarget: never guess an episode number or substitute a show's pilot.
use std::{collections::HashSet, sync::Arc, time::{Duration, Instant}};
use axum::{extract::{DefaultBodyLimit, Request, State}, http::StatusCode, middleware::{self, Next}, response::{IntoResponse, Response}, routing::{delete, get, post}, Json, Router};
use futures::{stream, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CategoryItem {
    pub media_id: u64,
    pub r#type: String,
    pub title: String,
    pub year: Option<String>,
    pub rating: Option<f64>,
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub imdb_id: Option<String>,
    pub season: Option<u64>,
    pub episode: Option<u64>,
    pub episode_title: Option<String>,
    pub still_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Category {
    pub id: String,
    pub title: String,
    pub items: Vec<CategoryItem>,
}

pub struct CatalogState {
    pub http: reqwest::Client,
    token: String,
    halloween: Mutex<Option<(Instant, Category)>>,
    pub ai: crate::categories::Generator,
    pub queue: crate::category_queue::QueuePlanner,
    pub browse: crate::catalog_browse::BrowseCache,
    pub db: crate::db::Db,
}

pub fn router(http: reqwest::Client, token: String, ai: crate::config::CategoryAi, db: crate::db::Db) -> Router {
    let state = Arc::new(CatalogState { http, token, halloween: Mutex::new(None), ai: crate::categories::Generator::new(ai), queue: crate::category_queue::QueuePlanner::new(), browse: crate::catalog_browse::BrowseCache::new(), db });
    Router::new()
        .route("/catalog/halloween", get(halloween))
        .route("/catalog/home", get(crate::catalog_browse::home))
        .route("/catalog/search", get(crate::catalog_browse::search))
        .route("/catalog/rows/:id", get(crate::catalog_browse::row))
        .route("/catalog/:kind/:id", get(crate::catalog_browse::details))
        .route("/catalog/show/:id/seasons/:season", get(crate::catalog_browse::season))
        .route("/categories/generate", post(crate::categories::generate))
        .route("/categories/queue", post(crate::category_queue::prepare))
        .route("/categories/saved", get(crate::saved_categories::list).post(crate::saved_categories::put)
            .layer(DefaultBodyLimit::max(crate::saved_categories::MAX_REQUEST_BYTES)))
        .route("/categories/saved/:id", delete(crate::saved_categories::delete))
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        .with_state(state)
}

async fn auth(State(st): State<Arc<CatalogState>>, req: Request, next: Next) -> Response {
    let authorized = st.token.is_empty() || req.headers().get("authorization")
        .and_then(|v| v.to_str().ok()).is_some_and(|v| v == format!("Bearer {}", st.token));
    if authorized { next.run(req).await } else { error(StatusCode::UNAUTHORIZED, "unauthorized") }
}

pub fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({"error": message}))).into_response()
}

pub(crate) fn normalized(value: &str) -> String {
    value.to_lowercase().replace('&', "and").chars().filter(|c| c.is_alphanumeric()).collect()
}

pub(crate) async fn tmdb(http: &reqwest::Client, path: &str, query: &[(&str, String)]) -> anyhow::Result<Value> {
    let api_key = crate::resolver::tmdb_key();
    anyhow::ensure!(!api_key.is_empty(), "Set VELVET_TMDB_KEY to enable metadata lookups");
    // Do not propagate reqwest errors to callers/logs: their URL may contain a key.
    http.get(format!("https://api.themoviedb.org/3/{path}"))
        .query(&[("api_key", api_key)]).query(query)
        .timeout(Duration::from_secs(12)).send().await
        .map_err(|_| anyhow::anyhow!("TMDB connection failed"))?
        .error_for_status().map_err(|_| anyhow::anyhow!("TMDB request failed"))?
        .json().await.map_err(|_| anyhow::anyhow!("Invalid TMDB response"))
}

fn image(v: &Value, field: &str, size: &str) -> Option<String> {
    v[field].as_str().filter(|p| p.starts_with('/') && !p.contains(".."))
        .map(|p| format!("https://image.tmdb.org/t/p/{size}{p}"))
}

pub(crate) fn media_item(v: &Value, kind: &str) -> Option<CategoryItem> {
    let title_key = if kind == "show" { "name" } else { "title" };
    let date_key = if kind == "show" { "first_air_date" } else { "release_date" };
    Some(CategoryItem {
        media_id: v["id"].as_u64()?, r#type: kind.into(), title: v[title_key].as_str()?.into(),
        year: v[date_key].as_str().and_then(|d| d.get(..4)).map(str::to_string),
        rating: v["vote_average"].as_f64(),
        poster_url: image(v, "poster_path", "w500"), backdrop_url: image(v, "backdrop_path", "w1280"),
        imdb_id: v["external_ids"]["imdb_id"].as_str().filter(|s| s.starts_with("tt")).map(str::to_string),
        season: None, episode: None, episode_title: None, still_url: None,
    })
}

/// Canonical playback coordinates come only from a verified season response.
pub(crate) fn episode_target(show: &Value, season: u64, episode: &Value) -> Option<CategoryItem> {
    if episode["season_number"].as_u64().is_some_and(|actual| actual != season)
        || episode["show_id"].as_u64().is_some_and(|id| Some(id) != show["id"].as_u64()) { return None; }
    let mut item = media_item(show, "show")?;
    item.season = Some(season);
    item.episode = Some(episode["episode_number"].as_u64().filter(|number| *number > 0)?);
    item.episode_title = Some(episode["name"].as_str().filter(|name| !normalized(name).is_empty())?.to_string());
    item.still_url = image(episode, "still_path", "w780");
    Some(item)
}

// TMDB names and season placement verified 2026-10-02. Episode numbers are
// deliberately resolved at runtime, because providers disagree on numbering.
// Only actual Halloween specials/October spooky-event episodes, not a keyword
// search over every supernatural episode. Includes the era's rerun staples.
const HALLOWEEN: &[(u64, &[(u64, &str)])] = &[
    (5371, &[(1, "iScream on Halloween")]),
    (34573, &[(1, "MutANT Farm"), (2, "mutANT farm 2"), (3, "mutANT farm 3.0")]),
    (3498, &[(3, "Halloween")]),
    (4605, &[(1, "Ghost of 613")]),
    (15079, &[(3, "The Ghost and Mr. Martin")]),
    (4610, &[(1, "Torn Between Two Hannahs")]),
    (21641, &[(2, "Scary Had a Little Lamb"), (3, "Le Halloween"), (4, "Fright Night")]),
    (38974, &[(2, "The Whining"), (3, "Ghost Bummers"), (3, "The Runaway Bride of Frankenstein")]),
    (35279, &[(2, "Costumes & Courage"), (3, "Horror Stories & Halloween Scares")]),
    (33213, &[(2, "Beam It Up"), (3, "Haunt It Up")]),
    (1877, &[(1, "One Good Scare Ought to Do It!"), (1, "The Monster of Phineas-n-Ferbenstein"), (3, "That's the Spirit"), (4, "Terrifying Tri-State Trilogy of Terror")]),
    (31356, &[(2, "Big Time Halloween")]),
    (1778, &[(2, "Haunted House")]),
    (387, &[(1, "Scaredy Pants")]),
    (2129, &[(2, "Nightmare in Retroville")]),
    (4630, &[(2, "Scary Godparents")]),
    (2309, &[(1, "Fright Night")]),
    (3793, &[(1, "Halloween Spectacular of Spooky Doom")]),
];

fn episode_item(show: &Value, season: u64, name: &str) -> Option<CategoryItem> {
    let episodes = show[format!("season/{season}")]["episodes"].as_array()?;
    let matches: Vec<_> = episodes.iter().filter(|e| normalized(e["name"].as_str().unwrap_or("")) == normalized(name)).collect();
    if matches.len() != 1 { return None; }
    episode_target(show, season, matches[0])
}

pub async fn load_halloween(http: &reqwest::Client) -> Category {
    let tasks: Vec<_> = HALLOWEEN.iter().copied().map(|(id, seeds)| {
        let http = http.clone();
        async move {
        let mut seasons: Vec<_> = seeds.iter().map(|(s, _)| *s).collect();
        seasons.sort_unstable(); seasons.dedup();
        let append = std::iter::once("external_ids".to_string()).chain(seasons.iter().map(|s| format!("season/{s}"))).collect::<Vec<_>>().join(",");
        let Ok(show) = tmdb(&http, &format!("tv/{id}"), &[("append_to_response", append)]).await else { return Vec::new(); };
        seeds.iter().filter_map(|(season, title)| episode_item(&show, *season, title)).collect::<Vec<_>>()
        }
    }).collect();
    let groups = stream::iter(tasks).buffered(4).collect::<Vec<_>>().await;
    let mut seen = HashSet::new();
    let items = groups.into_iter().flatten().filter(|i| seen.insert((i.media_id, i.season, i.episode))).collect();
    Category { id: "halloween-nostalgia".into(), title: "Monstober & Nick Halloween".into(), items }
}

async fn halloween(State(st): State<Arc<CatalogState>>) -> Response {
    // One concurrent refresh, preserve last good data on transient TMDB failures.
    let mut cache = st.halloween.lock().await;
    if let Some((_, row)) = cache.as_ref().filter(|(at, _)| at.elapsed() < Duration::from_secs(86400)) {
        return Json(row.clone()).into_response();
    }
    let row = load_halloween(&st.http).await;
    let expected: usize = HALLOWEEN.iter().map(|(_, e)| e.len()).sum();
    if row.items.len() < expected {
        if let Some((_, previous)) = cache.as_ref() { return Json(previous.clone()).into_response(); }
        // Return a partial first result, but do not cache it for a whole day.
        if row.items.is_empty() { return error(StatusCode::BAD_GATEWAY, "Halloween episodes could not load. Try again shortly."); }
        return Json(row).into_response();
    }
    *cache = Some((Instant::now(), row.clone()));
    Json(row).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn named_episode_uses_metadata_number_not_assumed_slot() {
        let show = json!({"id":5371,"name":"iCarly","season/1":{"episodes":[{"name":"Pilot","episode_number":1},{"name":"iScream on Halloween","episode_number":7}]}});
        let item = episode_item(&show, 1, "iScream on Halloween").unwrap();
        assert_eq!(item.episode, Some(7));
        assert!(episode_item(&show, 1, "another episode").is_none());
    }
    #[test]
    fn ambiguous_names_do_not_silently_choose() {
        let show = json!({"id":1,"name":"Show","season/1":{"episodes":[{"name":"Halloween","episode_number":1},{"name":"Halloween!","episode_number":2}]}});
        assert!(episode_item(&show, 1, "Halloween").is_none());
    }
}
