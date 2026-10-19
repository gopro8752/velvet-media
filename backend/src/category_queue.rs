//! Turn a category into concrete playback targets before starting a session.
//! Show cards expand to aired normal-season episodes; explicit episode cards
//! never expand to the rest of their show. No model call or subscription usage.
use std::{collections::{BTreeSet, HashMap, HashSet}, hash::{BuildHasher, Hash, Hasher}, sync::{Arc, atomic::{AtomicU64, AtomicUsize, Ordering}}, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};
use axum::{extract::State, http::StatusCode, response::{IntoResponse, Response}, Json};
use futures::{stream, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::{Mutex, Semaphore};
use crate::catalog::{self, CatalogState, Category, CategoryItem};

const MAX_SEEDS: usize = 64;
const MAX_EPISODES: usize = 10_000;
const CACHE_TTL: Duration = Duration::from_secs(15 * 60);

pub struct QueuePlanner {
    gate: Semaphore,
    requests: Semaphore,
    cache: Mutex<HashMap<String, (Instant, Vec<CategoryItem>)>>,
}
impl QueuePlanner {
    pub fn new() -> Self {
        Self { gate: Semaphore::new(2), requests: Semaphore::new(8), cache: Mutex::new(HashMap::new()) }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub struct Seed {
    media_id: u64,
    r#type: String,
    #[serde(default)]
    season: Option<u64>,
    #[serde(default)]
    episode: Option<u64>,
}

#[derive(Deserialize)]
pub struct QueueRequest {
    title: String,
    items: Vec<Seed>,
    #[serde(default)]
    shuffle: bool,
}

impl QueueRequest {
    fn validate(&self) -> Result<(), &'static str> {
        if self.title.trim().is_empty() || self.title.chars().count() > 80 || self.items.is_empty() || self.items.len() > MAX_SEEDS {
            return Err("Choose a category containing 1–64 titles or episodes.");
        }
        for item in &self.items {
            let episode_valid = match (item.season, item.episode) {
                (None, None) => true,
                (Some(season), Some(episode)) => item.r#type == "show" && season <= 1000 && (1..=10000).contains(&episode),
                _ => false,
            };
            if item.media_id == 0 || item.media_id > i32::MAX as u64 || !matches!(item.r#type.as_str(), "show" | "movie") || !episode_valid {
                return Err("The category contains an invalid playback target. Reload it and try again.");
            }
        }
        Ok(())
    }
}

pub async fn prepare(State(st): State<Arc<CatalogState>>, Json(request): Json<QueueRequest>) -> Response {
    if let Err(message) = request.validate() { return catalog::error(StatusCode::BAD_REQUEST, message); }
    let key = serde_json::to_string(&request.items).unwrap();
    let cached = st.queue.cache.lock().await.get(&key)
        .filter(|(at, _)| at.elapsed() < CACHE_TTL).map(|(_, items)| items.clone());
    let mut items = if let Some(items) = cached { items } else {
        let Ok(_permit) = st.queue.gate.try_acquire() else {
            return catalog::error(StatusCode::TOO_MANY_REQUESTS, "Other categories are being prepared. Try again shortly.");
        };
        let result = tokio::time::timeout(Duration::from_secs(120), expand(&st, &request.items, Date::today())).await;
        let items = match result {
            Ok(Ok(items)) => items,
            Ok(Err(message)) => return catalog::error(StatusCode::BAD_GATEWAY, message),
            Err(_) => return catalog::error(StatusCode::GATEWAY_TIMEOUT, "Preparing every episode took too long. Try again or choose a smaller category."),
        };
        let mut cache = st.queue.cache.lock().await;
        if cache.len() >= 8 {
            if let Some(oldest) = cache.iter().min_by_key(|(_, (at, _))| *at).map(|(key, _)| key.clone()) { cache.remove(&oldest); }
        }
        cache.insert(key, (Instant::now(), items.clone()));
        items
    };
    if request.shuffle { shuffle(&mut items, random_seed()); }
    static IDS: AtomicU64 = AtomicU64::new(0);
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    Json(Category {
        id: format!("queue-{now}-{}", IDS.fetch_add(1, Ordering::Relaxed)),
        title: request.title.trim().into(), items,
    }).into_response()
}

#[derive(Clone)]
struct EpisodeEntry { item: CategoryItem, aired: bool }
struct ShowCatalog { item: CategoryItem, episodes: Vec<EpisodeEntry> }

async fn metadata(st: &CatalogState, path: &str, query: &[(&str, String)]) -> Result<Value, &'static str> {
    let _permit = st.queue.requests.acquire().await.map_err(|_| "Episode catalog is unavailable.")?;
    catalog::tmdb(&st.http, path, query).await.map_err(|_| "Some episode metadata could not load. Try again; your queue has not started.")
}

async fn load_show(st: Arc<CatalogState>, seeds: Vec<Seed>, today: Date, budget: Arc<AtomicUsize>) -> Result<ShowCatalog, &'static str> {
    let seed = &seeds[0];
    let kind = if seed.r#type == "show" { "tv" } else { "movie" };
    let details = metadata(&st, &format!("{kind}/{}", seed.media_id), &[("append_to_response", "external_ids".into())]).await?;
    let item = catalog::media_item(&details, &seed.r#type).ok_or("A title's metadata is incomplete. Reload the category and try again.")?;
    if item.media_id != seed.media_id { return Err("A title's metadata did not match the category."); }
    if kind == "movie" {
        if !movie_has_released(&details) { return Err("A selected movie has no confirmed past release date. Choose another movie or try again after its release."); }
        reserve_target(&budget)?;
        return Ok(ShowCatalog { item, episodes: vec![] });
    }
    let include_regular = seeds.iter().any(|s| s.season.is_none());
    let explicit: HashSet<_> = seeds.iter().filter_map(|s| s.season.zip(s.episode)).collect();
    let mut seasons: BTreeSet<u64> = seeds.iter().filter_map(|s| s.season).collect();
    if include_regular {
        let available = details["seasons"].as_array().ok_or("A show's season list is unavailable. Try again.")?;
        // Do not gate on season air_date: completed older seasons often omit it.
        for season in available {
            if let Some(number) = season["season_number"].as_u64().filter(|n| *n > 0) { seasons.insert(number); }
        }
    }
    if seasons.len() > 150 { return Err("That show has too many seasons for one queue. Choose a smaller category."); }
    let tasks: Vec<_> = seasons.into_iter().map(|season| {
        let st = st.clone();
        let item = item.clone();
        let budget = budget.clone();
        let explicit = explicit.clone();
        async move {
            let value = metadata(&st, &format!("tv/{}/season/{season}", item.media_id), &[]).await?;
            let source = value["episodes"].as_array().ok_or("A season's episode list is unavailable. Try again.")?;
            let mut episodes = Vec::new();
            let mut seen = HashSet::new();
            for ep in source {
                let aired = ep["air_date"].as_str().and_then(Date::parse).is_some_and(|d| d <= today);
                if !aired { continue; }
                let number = ep["episode_number"].as_u64().filter(|n| *n > 0)
                    .ok_or("An aired episode has incomplete metadata. Try again later.")?;
                if !(include_regular && season > 0) && !explicit.contains(&(season, number)) { continue; }
                if !seen.insert(number) { continue; }
                reserve_target(&budget)?;
                let title = ep["name"].as_str().filter(|s| !s.trim().is_empty()).map(str::to_string)
                    .unwrap_or_else(|| format!("Episode {number}"));
                if ep["season_number"].as_u64().is_some_and(|n| n != season) { return Err("A season's metadata contains mismatched episodes."); }
                let mut target = item.clone();
                target.season = Some(season); target.episode = Some(number); target.episode_title = Some(title);
                target.still_url = ep["still_path"].as_str().filter(|p| p.starts_with('/') && !p.contains(".."))
                    .map(|p| format!("https://image.tmdb.org/t/p/w780{p}"));
                episodes.push(EpisodeEntry { item: target, aired: true });
            }
            episodes.sort_by_key(|e| e.item.episode);
            Ok::<_, &'static str>(episodes)
        }
    }).collect();
    let mut pending = stream::iter(tasks).buffered(4);
    let mut episodes = Vec::new();
    while let Some(result) = pending.next().await {
        episodes.extend(result?);
        if episodes.len() > MAX_EPISODES { return Err("This category is too large for one queue. Choose fewer shows."); }
    }
    Ok(ShowCatalog { item, episodes })
}

fn select_targets(seed: &Seed, catalog: &ShowCatalog) -> Result<Vec<CategoryItem>, &'static str> {
    if seed.r#type == "movie" { return Ok(vec![catalog.item.clone()]); }
    let targets: Vec<_> = catalog.episodes.iter().filter(|e| {
        e.aired && match (seed.season, seed.episode) {
            (Some(season), Some(episode)) => e.item.season == Some(season) && e.item.episode == Some(episode),
            _ => e.item.season.is_some_and(|s| s > 0),
        }
    }).map(|e| e.item.clone()).collect();
    if targets.is_empty() { return Err("A selected show or episode has no confirmed aired episodes. Reload the category or choose another one."); }
    Ok(targets)
}

async fn expand(st: &Arc<CatalogState>, seeds: &[Seed], today: Date) -> Result<Vec<CategoryItem>, &'static str> {
    let mut groups: HashMap<(String, u64), Vec<Seed>> = HashMap::new();
    for seed in seeds { groups.entry((seed.r#type.clone(), seed.media_id)).or_default().push(seed.clone()); }
    let budget = Arc::new(AtomicUsize::new(0));
    let tasks: Vec<_> = groups.into_iter().map(|(key, group)| {
        let st = st.clone();
        let budget = budget.clone();
        async move { Ok::<_, &'static str>((key, load_show(st, group, today, budget).await?)) }
    }).collect();
    let mut pending = stream::iter(tasks).buffered(4);
    let mut catalogs = HashMap::new();
    while let Some(result) = pending.next().await { let (key, catalog) = result?; catalogs.insert(key, catalog); }
    merge_targets(seeds, &catalogs)
}

fn reserve_target(budget: &AtomicUsize) -> Result<(), &'static str> {
    if budget.fetch_add(1, Ordering::Relaxed) >= MAX_EPISODES {
        Err("This category is too large for one queue. Choose fewer shows.")
    } else { Ok(()) }
}

fn merge_targets(seeds: &[Seed], catalogs: &HashMap<(String, u64), ShowCatalog>) -> Result<Vec<CategoryItem>, &'static str> {
    let mut seen = HashSet::new();
    let mut items = Vec::new();
    // Preserve row order, then season/episode order within each show.
    for seed in seeds {
        let catalog = catalogs.get(&(seed.r#type.clone(), seed.media_id)).ok_or("A title could not load.")?;
        for item in select_targets(seed, catalog)? {
            if seen.insert((item.r#type.clone(), item.media_id, item.season, item.episode)) { items.push(item); }
            if items.len() > MAX_EPISODES { return Err("This category is too large for one queue. Choose fewer shows."); }
        }
    }
    Ok(items)
}

fn random_seed() -> u64 {
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    SystemTime::now().hash(&mut hasher);
    hasher.finish().max(1)
}

// Fisher–Yates; an item is consumed once per session, never randomly sampled
// again at each episode transition. PRNG is for ordering, not credentials.
fn shuffle<T>(items: &mut [T], mut state: u64) {
    state = state.max(1);
    for i in (1..items.len()).rev() {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17;
        items.swap(i, (state % (i as u64 + 1)) as usize);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Date { year: i64, month: u32, day: u32 }

pub(crate) fn episode_has_aired(episode: &Value) -> bool {
    episode["air_date"].as_str().and_then(Date::parse).is_some_and(|date| date <= Date::today())
}

pub(crate) fn movie_has_released(movie: &Value) -> bool {
    movie["release_date"].as_str().and_then(Date::parse).is_some_and(|date| date <= Date::today())
}

pub(crate) fn current_catalog_date() -> String {
    let date = Date::today();
    format!("{:04}-{:02}-{:02}", date.year, date.month, date.day)
}

impl Date {
    fn parse(value: &str) -> Option<Self> {
        let bytes = value.as_bytes();
        if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' || !bytes.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit()) { return None; }
        let year = value[..4].parse().ok()?;
        let month: u32 = value[5..7].parse().ok()?;
        let day: u32 = value[8..].parse().ok()?;
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
        let days = match month { 2 if leap => 29, 2 => 28, 4 | 6 | 9 | 11 => 30, 1..=12 => 31, _ => return None };
        if year < 1800 || !(1..=days).contains(&day) { return None; }
        Some(Self { year, month, day })
    }
    fn today() -> Self {
        let days = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() / 86400;
        Self::from_epoch_days(days as i64)
    }
    fn from_epoch_days(days: i64) -> Self {
        // Gregorian civil date from the UTC Unix day count.
        let z = days + 719468;
        let era = z.div_euclid(146097);
        let doe = z - era * 146097;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let mut year = yoe + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = doy - (153 * mp + 2) / 5 + 1;
        let month = mp + if mp < 10 { 3 } else { -9 };
        year += i64::from(month <= 2);
        Self { year, month: month as u32, day: day as u32 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn seed(season: Option<u64>, episode: Option<u64>) -> Seed { Seed { media_id: 5371, r#type: "show".into(), season, episode } }
    fn fixture() -> ShowCatalog {
        let base = catalog::media_item(&serde_json::json!({"id":5371,"name":"iCarly"}), "show").unwrap();
        let episodes = [(0, 1, true), (1, 1, true), (1, 7, true), (2, 1, false)].into_iter().map(|(s, e, aired)| {
            let mut item = base.clone(); item.season = Some(s); item.episode = Some(e);
            EpisodeEntry { item, aired }
        }).collect();
        ShowCatalog { item: base, episodes }
    }
    #[test]
    fn halloween_explicit_episode_never_expands_to_ordinary_show() {
        let selected = select_targets(&seed(Some(1), Some(7)), &fixture()).unwrap();
        assert_eq!(selected.len(), 1); assert_eq!(selected[0].episode, Some(7));
    }
    #[test]
    fn shows_expand_to_aired_regular_episodes_only() {
        let selected = select_targets(&seed(None, None), &fixture()).unwrap();
        assert_eq!(selected.iter().map(|e| (e.season, e.episode)).collect::<Vec<_>>(), vec![(Some(1), Some(1)), (Some(1), Some(7))]);
        assert!(select_targets(&seed(Some(2), Some(1)), &fixture()).is_err());
    }
    #[test]
    fn shuffle_is_a_permutation_without_repeats() {
        let mut values: Vec<_> = (0..100).collect(); let original = values.clone();
        shuffle(&mut values, 42); assert_ne!(values, original);
        values.sort(); assert_eq!(values, original);
        shuffle::<u32>(&mut [], 0); let mut one = [1]; shuffle(&mut one, 0); assert_eq!(one, [1]);
    }
    #[test]
    fn invalid_dates_and_future_dates_are_excluded() {
        assert!(Date::parse("2025-02-29").is_none()); assert!(Date::parse("2024-02-29").is_some());
        assert!(Date::parse("2026-13-01").is_none()); assert!(Date::parse("2026-01-00").is_none());
        assert!(Date::parse("unknown").is_none()); assert!(Date::parse("2026-10-03") > Date::parse("2026-10-02"));
        assert_eq!(Date::from_epoch_days(0), Date::parse("1970-01-01").unwrap());
        assert_eq!(Date::from_epoch_days(20728), Date::parse("2026-10-02").unwrap());
    }
    #[test]
    fn rejects_unpaired_episode_targets_and_invalid_ids() {
        let mut request = QueueRequest { title: "Halloween".into(), items: vec![seed(Some(1), None)], shuffle: true };
        assert!(request.validate().is_err()); request.items = vec![seed(Some(1), Some(7))]; assert!(request.validate().is_ok());
        request.items[0].media_id = 0; assert!(request.validate().is_err());
    }

    fn fixture_for(media_id: u64) -> ShowCatalog {
        let mut show = fixture();
        show.item.media_id = media_id;
        for episode in &mut show.episodes { episode.item.media_id = media_id; }
        show
    }

    #[test]
    fn overlap_deduplicates_only_the_same_show_and_episode() {
        let explicit = seed(Some(1), Some(7));
        let whole = seed(None, None);
        let other = Seed { media_id: 34573, ..explicit.clone() };
        let catalogs = HashMap::from([
            (("show".into(), 5371), fixture()),
            (("show".into(), 34573), fixture_for(34573)),
        ]);
        let merged = merge_targets(&[explicit.clone(), whole, other, explicit], &catalogs).unwrap();
        let identities: Vec<_> = merged.iter().map(|item| (item.media_id, item.season, item.episode)).collect();
        assert_eq!(identities, vec![
            (5371, Some(1), Some(7)),
            (5371, Some(1), Some(1)),
            (34573, Some(1), Some(7)),
        ]);
    }

    #[test]
    fn movie_and_show_numeric_id_collision_keeps_both_media_types() {
        let movie = catalog::media_item(&serde_json::json!({"id":5371,"title":"Different movie"}), "movie").unwrap();
        let movie_seed = Seed { media_id: 5371, r#type: "movie".into(), season: None, episode: None };
        let catalogs = HashMap::from([
            (("show".into(), 5371), fixture()),
            (("movie".into(), 5371), ShowCatalog { item: movie, episodes: vec![] }),
        ]);
        let merged = merge_targets(&[seed(None, None), movie_seed.clone(), movie_seed], &catalogs).unwrap();
        assert_eq!(merged.len(), 3);
        assert_eq!(merged.iter().filter(|item| item.r#type == "show").count(), 2);
        assert_eq!(merged[2].r#type, "movie");
        assert_eq!(merged[2].title, "Different movie");
        assert_eq!((merged[2].season, merged[2].episode), (None, None));
    }

    #[test]
    fn missing_catalog_or_selected_episode_rejects_the_entire_merge() {
        let catalogs = HashMap::from([(("show".into(), 5371), fixture())]);
        let missing_show = Seed { media_id: 99999, ..seed(None, None) };
        assert!(merge_targets(&[seed(None, None), missing_show], &catalogs).is_err());
        // Valid targets encountered first cannot turn an unavailable selection
        // into a successful but silently incomplete category.
        assert!(merge_targets(&[seed(None, None), seed(Some(1), Some(999))], &catalogs).is_err());
        assert!(merge_targets(&[seed(None, None), seed(Some(2), Some(1))], &catalogs).is_err());
    }

    #[test]
    fn merged_queue_limit_counts_unique_targets_across_shows() {
        let base = fixture().item;
        let episodes = (1..=MAX_EPISODES).map(|number| {
            let mut item = base.clone();
            item.season = Some(1); item.episode = Some(number as u64);
            EpisodeEntry { item, aired: true }
        }).collect();
        let catalogs = HashMap::from([
            (("show".into(), 5371), ShowCatalog { item: base, episodes }),
            (("show".into(), 34573), fixture_for(34573)),
        ]);
        let whole = seed(None, None);
        let duplicate_seeds = [whole.clone(), seed(Some(1), Some(7)), whole.clone()];
        assert_eq!(merge_targets(&duplicate_seeds, &catalogs).unwrap().len(), MAX_EPISODES);
        let additional = Seed { media_id: 34573, ..seed(Some(1), Some(7)) };
        assert!(merge_targets(&[whole, additional], &catalogs).is_err());
    }

    #[test]
    fn shared_reservation_budget_cannot_admit_too_many_parallel_targets() {
        let budget = Arc::new(AtomicUsize::new(MAX_EPISODES - 3));
        let accepted = std::thread::scope(|scope| {
            let workers: Vec<_> = (0..12).map(|_| {
                let budget = budget.clone();
                scope.spawn(move || reserve_target(&budget).is_ok())
            }).collect();
            workers.into_iter().map(|worker| usize::from(worker.join().unwrap())).sum::<usize>()
        });
        assert_eq!(accepted, 3);
        assert!(reserve_target(&budget).is_err());
    }

    #[test]
    fn untrusted_seed_display_fields_cannot_supply_playback_sources() {
        let request: QueueRequest = serde_json::from_value(serde_json::json!({
            "title":"My category", "shuffle":true,
            "items":[{"mediaId":5371,"type":"show","season":1,"episode":7,
                "title":"Spoofed title","url":"https://untrusted.invalid/video",
                "imdbId":"tt-wrong","headers":{"Authorization":"untrusted"}}]
        })).unwrap();
        assert!(request.validate().is_ok());
        let serialized = serde_json::to_value(&request.items[0]).unwrap();
        assert!(serialized.get("url").is_none());
        assert!(serialized.get("title").is_none());
        assert!(serialized.get("imdbId").is_none());
        assert!(serialized.get("headers").is_none());
        let catalogs = HashMap::from([(("show".into(), 5371), fixture())]);
        let merged = merge_targets(&request.items, &catalogs).unwrap();
        assert_eq!(merged[0].title, "iCarly");
    }

    #[test]
    fn validates_request_boundaries_before_metadata_lookup() {
        let mut request = QueueRequest { title: "Queue".into(), items: vec![seed(None, None); MAX_SEEDS], shuffle: false };
        assert!(request.validate().is_ok());
        request.items.push(seed(None, None)); assert!(request.validate().is_err());
        request.items.clear(); assert!(request.validate().is_err());
        request.items = vec![seed(Some(1), Some(7))];
        request.items[0].r#type = "movie".into(); assert!(request.validate().is_err());
        request.items[0] = Seed { media_id: i32::MAX as u64 + 1, ..seed(None, None) };
        assert!(request.validate().is_err());
        request.items[0] = seed(None, None);
        request.title = " ".into(); assert!(request.validate().is_err());
        request.title = "x".repeat(81); assert!(request.validate().is_err());
        assert!(serde_json::from_value::<QueueRequest>(serde_json::json!({
            "title":"Queue","items":[{"mediaId":-1,"type":"show"}]
        })).is_err());
    }

    #[test]
    fn movie_release_dates_use_the_same_strict_date_policy() {
        for date in [Value::Null, serde_json::json!(""), serde_json::json!("unknown"),
            serde_json::json!("2025-02-29"), serde_json::json!("2100-12-25")] {
            assert!(!movie_has_released(&serde_json::json!({"release_date":date})));
        }
        assert!(movie_has_released(&serde_json::json!({"release_date":"1977-05-25"})));
    }

    #[test]
    fn ordered_movie_queue_keeps_requested_story_sequence() {
        let movies = [(1893, "Prequel", "1999-05-19"), (11, "Original", "1977-05-25"), (140607, "Sequel", "2015-12-18")];
        let seeds: Vec<_> = movies.iter().map(|(id, _, _)| Seed {
            media_id: *id, r#type: "movie".into(), season: None, episode: None,
        }).collect();
        let catalogs = movies.into_iter().rev().map(|(id, title, release_date)| {
            let item = catalog::media_item(&serde_json::json!({"id":id,"title":title,"release_date":release_date}), "movie").unwrap();
            (("movie".into(), id), ShowCatalog { item, episodes: vec![] })
        }).collect();
        let items = merge_targets(&seeds, &catalogs).unwrap();
        assert_eq!(items.iter().map(|item| item.media_id).collect::<Vec<_>>(), vec![1893, 11, 140607]);
        assert!(items.iter().all(|item| item.season.is_none() && item.episode.is_none()));
    }
}
