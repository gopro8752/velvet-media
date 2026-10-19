//! Free XMLTV listings, matched to a reviewed exact station/feed identity only.
//! Downloads and gzip/XML parsing run in the background; no guide request can
//! tune a channel or write viewing history. Unmapped channels have empty guides.
use chrono::{DateTime, SecondsFormat, Utc};
use quick_xml::{events::Event, Reader};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    io::{self, BufRead, BufReader, Read},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const MAX_COMPRESSED: usize = 80 * 1024 * 1024;
const MAX_DECODED: u64 = 1024 * 1024 * 1024;
const MAX_TOKEN: usize = 512 * 1024;
const MAX_PROGRAMS: usize = 160;
const REFRESH: Duration = Duration::from_secs(6 * 3600);
const RETRY: Duration = Duration::from_secs(10 * 60);
const FEEDS: [&str; 2] = [
    "https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_US_LOCALS1.xml.gz",
];

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Mapping {
    channel_id: String,
    name: String,
    xmltv_id: String,
}
fn mappings() -> Vec<Mapping> {
    serde_json::from_str(include_str!("epg_mappings.json")).expect("reviewed XMLTV mapping")
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Program {
    pub id: String,
    pub title: String,
    pub start_time: String,
    pub end_time: String,
    pub description: Option<String>,
    pub episode_title: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChannelGuide {
    channel_id: String,
    programs: Vec<Program>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Guide {
    enabled: bool,
    source_name: String,
    updated_at: Option<String>,
    channels: Vec<ChannelGuide>,
    message: Option<String>,
}
#[derive(Default)]
struct FeedCache {
    attempted: Option<Instant>,
    success: Option<Instant>,
    updated: Option<DateTime<Utc>>,
    programs: HashMap<String, Vec<Program>>,
    failed: bool,
}
pub struct GuideService {
    enabled: bool,
    feeds: Mutex<Vec<FeedCache>>,
    mappings: Vec<Mapping>,
}
impl GuideService {
    pub fn new(enabled: bool) -> Arc<Self> {
        let state = Arc::new(Self {
            enabled,
            feeds: Mutex::new(vec![FeedCache::default(), FeedCache::default()]),
            mappings: mappings(),
        });
        if enabled {
            let weak = Arc::downgrade(&state);
            tokio::spawn(async move {
                let Ok(http) = reqwest::Client::builder()
                    .user_agent("Mozilla/5.0 Velvet XMLTV Guide")
                    .redirect(reqwest::redirect::Policy::none())
                    .connect_timeout(Duration::from_secs(5))
                    .timeout(Duration::from_secs(120))
                    .build()
                else {
                    return;
                };
                let mut timer = tokio::time::interval(Duration::from_secs(60));
                loop {
                    timer.tick().await;
                    let Some(state) = weak.upgrade() else { break };
                    for (index, url) in FEEDS.iter().enumerate() {
                        let due = {
                            let caches = state.feeds.lock().unwrap();
                            let cache = &caches[index];
                            !cache.success.is_some_and(|at| at.elapsed() < REFRESH)
                                && !cache.attempted.is_some_and(|at| at.elapsed() < RETRY)
                        };
                        if !due {
                            continue;
                        }
                        state.feeds.lock().unwrap()[index].attempted = Some(Instant::now());
                        let wanted: HashSet<String> = state
                            .mappings
                            .iter()
                            .filter(|m| {
                                m.xmltv_id.ends_with(if index == 0 {
                                    ".us2"
                                } else {
                                    ".us_locals1"
                                })
                            })
                            .map(|m| m.xmltv_id.clone())
                            .collect();
                        let fetched = download(&http, url).await;
                        let parsed = match fetched {
                            Ok(bytes) => tokio::task::spawn_blocking(move || {
                                parse_gzip(&bytes, &wanted, Utc::now())
                            })
                            .await
                            .unwrap_or_else(|_| Err("Guide parser unavailable")),
                            Err(e) => Err(e),
                        };
                        let mut caches = state.feeds.lock().unwrap();
                        let cache = &mut caches[index];
                        match parsed {
                            Ok(programs) => {
                                cache.programs = programs;
                                cache.success = Some(Instant::now());
                                cache.updated = Some(Utc::now());
                                cache.failed = false;
                            }
                            Err(_) => {
                                cache.failed = true;
                                tracing::warn!(
                                    feed = index,
                                    "XMLTV guide refresh unavailable; keeping unexpired listings"
                                );
                            }
                        }
                    }
                }
            });
        }
        state
    }
    pub fn snapshot(&self, source_name: &str, channels: &[(String, String)]) -> Guide {
        if !self.enabled {
            return Guide {
                enabled: false,
                source_name: source_name.into(),
                updated_at: None,
                channels: vec![],
                message: Some("Program guide is not configured yet".into()),
            };
        }
        let caches = self.feeds.lock().unwrap();
        let now = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
        let mut available = 0;
        let output = channels
            .iter()
            .map(|(id, name)| {
                let programs = self
                    .mappings
                    .iter()
                    .find(|m| m.channel_id == *id && same_name(&m.name, name))
                    .and_then(|m| caches.iter().find_map(|c| c.programs.get(&m.xmltv_id)))
                    .map(|p| {
                        p.iter()
                            .filter(|p| p.end_time > now)
                            .cloned()
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                if !programs.is_empty() {
                    available += 1;
                }
                ChannelGuide {
                    channel_id: id.clone(),
                    programs,
                }
            })
            .collect();
        let updated = caches
            .iter()
            .filter_map(|c| c.updated)
            .min()
            .map(|d| d.to_rfc3339_opts(SecondsFormat::Secs, true));
        let message = if updated.is_none() {
            Some(
                if caches.iter().any(|c| c.failed) {
                    "Program guide is temporarily unavailable; channels can still play"
                } else {
                    "Program guide is loading; channels can still play"
                }
                .into(),
            )
        } else if caches.iter().any(|c| c.failed) {
            Some("Guide refresh is unavailable; showing remaining cached listings. Some channels have no verified guide.".into())
        } else if available < channels.len() {
            Some("Free guide listings are available for verified channel feeds only; some channels have no guide.".into())
        } else {
            None
        };
        Guide {
            enabled: true,
            source_name: source_name.into(),
            updated_at: updated,
            channels: output,
            message,
        }
    }
}
fn same_name(a: &str, b: &str) -> bool {
    a.split_whitespace()
        .map(str::to_ascii_lowercase)
        .eq(b.split_whitespace().map(str::to_ascii_lowercase))
}
/// Explicit CLI diagnostic: parse already downloaded feeds without touching any
/// provider/browser, database, live session or production configuration.
pub async fn diagnostic(paths: Vec<String>) -> anyhow::Result<()> {
    anyhow::ensure!(
        paths.len() == 2,
        "guidetest requires local US2.xml.gz and US_LOCALS1.xml.gz paths"
    );
    for (index, path) in paths.into_iter().enumerate() {
        anyhow::ensure!(
            std::fs::metadata(&path)?.len() <= MAX_COMPRESSED as u64,
            "guide file too large"
        );
        let bytes = std::fs::read(path)?;
        let wanted: HashSet<String> = mappings()
            .into_iter()
            .filter(|m| {
                m.xmltv_id
                    .ends_with(if index == 0 { ".us2" } else { ".us_locals1" })
            })
            .map(|m| m.xmltv_id)
            .collect();
        let count = wanted.len();
        let programs = tokio::task::spawn_blocking(move || parse_gzip(&bytes, &wanted, Utc::now()))
            .await?
            .map_err(|e| anyhow::anyhow!(e))?;
        println!(
            "{}",
            serde_json::json!({"feed":index,"mappedChannels":count,"channelsWithPrograms":programs.len(),"programs":programs.values().map(Vec::len).sum::<usize>()})
        );
    }
    Ok(())
}
async fn download(http: &reqwest::Client, url: &str) -> Result<Vec<u8>, &'static str> {
    let mut response = http
        .get(url)
        .send()
        .await
        .map_err(|_| "Guide unavailable")?;
    if !response.status().is_success()
        || response
            .content_length()
            .is_some_and(|n| n > MAX_COMPRESSED as u64)
    {
        return Err("Guide unavailable");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "Guide interrupted")? {
        if bytes.len().saturating_add(chunk.len()) > MAX_COMPRESSED {
            return Err("Guide too large");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
// Limit individual XML tokens as well as total decompressed input, so malformed
// compressed data cannot make quick-xml grow one unbounded event buffer.
struct TokenReader<R> {
    inner: R,
    consumed: usize,
}
impl<R: BufRead> Read for TokenReader<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let bytes = self.fill_buf()?;
        let n = bytes.len().min(out.len());
        out[..n].copy_from_slice(&bytes[..n]);
        self.consume(n);
        Ok(n)
    }
}
impl<R: BufRead> BufRead for TokenReader<R> {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        let bytes = self.inner.fill_buf()?;
        if bytes.is_empty() {
            return Ok(bytes);
        }
        let remaining = MAX_TOKEN.saturating_sub(self.consumed);
        if remaining == 0 {
            return Err(io::Error::other("XML token too large"));
        }
        Ok(&bytes[..bytes.len().min(remaining)])
    }
    fn consume(&mut self, amount: usize) {
        self.consumed = self.consumed.saturating_add(amount);
        self.inner.consume(amount);
    }
}
fn parse_gzip(
    bytes: &[u8],
    wanted: &HashSet<String>,
    now: DateTime<Utc>,
) -> Result<HashMap<String, Vec<Program>>, &'static str> {
    let decoded = flate2::read::GzDecoder::new(bytes).take(MAX_DECODED + 1);
    parse_xml(BufReader::new(decoded), wanted, now)
}
#[derive(Default)]
struct Pending {
    channel: String,
    start: Option<DateTime<Utc>>,
    end: Option<DateTime<Utc>>,
    title: String,
    description: String,
    episode: String,
}
fn xml_date(value: &str) -> Option<DateTime<Utc>> {
    // XMLTV may omit timezone, but doing so would require guessing the feed's zone.
    if value.len() != 20 {
        return None;
    }
    DateTime::parse_from_str(value, "%Y%m%d%H%M%S %z")
        .ok()
        .map(|v| v.with_timezone(&Utc))
}
fn parse_xml<R: BufRead>(
    input: R,
    wanted: &HashSet<String>,
    now: DateTime<Utc>,
) -> Result<HashMap<String, Vec<Program>>, &'static str> {
    let mut reader = Reader::from_reader(TokenReader {
        inner: input,
        consumed: 0,
    });
    reader.config_mut().trim_text(true);
    let mut buf = Vec::new();
    let mut channels = HashSet::new();
    let mut result: HashMap<String, Vec<Program>> = HashMap::new();
    let mut pending: Option<Pending> = None;
    let mut field = String::new();
    let mut depth = 0usize;
    let mut root = false;
    loop {
        reader.get_mut().consumed = 0;
        let event = reader
            .read_event_into(&mut buf)
            .map_err(|_| "Invalid XMLTV")?;
        if reader.buffer_position() > MAX_DECODED {
            return Err("Guide too large");
        }
        match event {
            Event::DocType(_) => return Err("XMLTV declarations unsupported"),
            Event::Start(ref e) => {
                depth += 1;
                if depth > 32 {
                    return Err("XMLTV nesting too deep");
                }
                if depth == 1 {
                    if e.name().as_ref() != b"tv" {
                        return Err("Invalid XMLTV root");
                    }
                    root = true;
                }
                if depth == 2
                    && (e.name().as_ref() == b"channel" || e.name().as_ref() == b"programme")
                {
                    let mut attrs = HashMap::new();
                    for a in e.attributes() {
                        let a = a.map_err(|_| "Invalid XMLTV attributes")?;
                        let val = a
                            .unescape_value()
                            .map_err(|_| "Invalid XMLTV attributes")?
                            .into_owned();
                        if val.len() > 1000 {
                            return Err("XMLTV attribute too long");
                        }
                        attrs.insert(a.key.as_ref().to_vec(), val);
                    }
                    if e.name().as_ref() == b"channel" {
                        if let Some(id) = attrs
                            .get(b"id".as_slice())
                            .filter(|id| wanted.contains(*id))
                        {
                            channels.insert(id.clone());
                        }
                    } else if let Some(channel) = attrs
                        .get(b"channel".as_slice())
                        .filter(|id| wanted.contains(*id))
                    {
                        let start = attrs.get(b"start".as_slice()).and_then(|s| xml_date(s));
                        let end = attrs.get(b"stop".as_slice()).and_then(|s| xml_date(s));
                        if start.zip(end).is_some_and(|(s, e)| {
                            e > s
                                && e > now - chrono::Duration::hours(6)
                                && s < now + chrono::Duration::hours(48)
                                && e - s <= chrono::Duration::hours(24)
                        }) {
                            pending = Some(Pending {
                                channel: channel.clone(),
                                start,
                                end,
                                ..Default::default()
                            });
                        }
                    }
                } else if depth == 3 && pending.is_some() {
                    field = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                }
            }
            Event::Text(e) => {
                if let Some(p) = pending.as_mut() {
                    let value = e.unescape().map_err(|_| "Invalid XMLTV text")?;
                    let target = match field.as_str() {
                        "title" => Some(&mut p.title),
                        "desc" => Some(&mut p.description),
                        "sub-title" => Some(&mut p.episode),
                        _ => None,
                    };
                    if let Some(target) = target {
                        if target.is_empty() {
                            *target = value
                                .chars()
                                .filter(|c| !c.is_control() || *c == '\n')
                                .take(4000)
                                .collect();
                        }
                    }
                }
            }
            Event::End(e) => {
                if depth == 3 {
                    field.clear();
                }
                if depth == 2 && e.name().as_ref() == b"programme" {
                    if let Some(p) = pending.take() {
                        if !p.title.trim().is_empty() {
                            let list = result.entry(p.channel.clone()).or_default();
                            let start = p.start.unwrap();
                            let end = p.end.unwrap();
                            let program = Program {
                                id: format!("{}:{}", p.channel, start.timestamp()),
                                title: p.title,
                                start_time: start.to_rfc3339_opts(SecondsFormat::Secs, true),
                                end_time: end.to_rfc3339_opts(SecondsFormat::Secs, true),
                                description: (!p.description.is_empty()).then_some(p.description),
                                episode_title: (!p.episode.is_empty()).then_some(p.episode),
                            };
                            if !list.iter().any(|v| v.start_time == program.start_time) {
                                list.push(program);
                                list.sort_by(|a, b| a.start_time.cmp(&b.start_time));
                                list.truncate(MAX_PROGRAMS);
                            }
                        }
                    }
                }
                depth = depth.checked_sub(1).ok_or("Invalid XMLTV nesting")?;
            }
            Event::Eof => break,
            _ => {}
        }
        buf.clear();
    }
    if !root || depth != 0 {
        return Err("Incomplete XMLTV");
    }
    result.retain(|id, _| channels.contains(id));
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-10-12T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }
    #[test]
    fn exact_mapping_never_substitutes_another_affiliate_or_pacific_feed() {
        assert!(same_name("ESPN", "espn"));
        assert!(!same_name("ABC (WEWS)", "ABC (WABC)"));
        let mappings = mappings();
        let mut ids = HashSet::new();
        for m in mappings {
            assert!(ids.insert(m.channel_id));
            assert!(m.xmltv_id.ends_with(".us2") || m.xmltv_id.ends_with(".us_locals1"));
            assert!(!m.xmltv_id.contains("Pacific"));
        }
    }
    #[test]
    fn dates_require_timezone_and_convert_dst_offset_to_utc() {
        assert_eq!(xml_date("20261011200000 -0400").unwrap(), now());
        assert!(xml_date("20261011200000").is_none());
        assert!(xml_date("20261311200000 -0400").is_none());
    }
    #[test]
    fn guide_requires_declared_exact_channel_valid_interval_and_unexpired_time() {
        let xml = r#"<tv><channel id="ESPN.HD.us2"><display-name>ESPN</display-name></channel><programme channel="ESPN.HD.us2" start="20261011200000 -0400" stop="20261011210000 -0400"><title>A &amp; B</title><sub-title>Game 1</sub-title><desc>Live sports</desc></programme><programme channel="ESPN.Pacific.us2" start="20261011200000 -0400" stop="20261011210000 -0400"><title>Wrong feed</title></programme><programme channel="ESPN.HD.us2" start="20261011210000 -0400" stop="20261011200000 -0400"><title>Backwards</title></programme></tv>"#;
        let wanted = HashSet::from(["ESPN.HD.us2".into(), "ESPN.Pacific.us2".into()]);
        let out = parse_xml(xml.as_bytes(), &wanted, now()).unwrap();
        assert_eq!(out.len(), 1);
        let p = &out["ESPN.HD.us2"];
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].title, "A & B");
        assert_eq!(p[0].start_time, "2026-10-12T00:00:00Z");
        assert_eq!(p[0].episode_title.as_deref(), Some("Game 1"));
    }
    #[test]
    fn xml_entities_truncated_docs_and_oversized_tokens_are_rejected() {
        let wanted = HashSet::new();
        for xml in [
            "<!DOCTYPE tv SYSTEM 'file:///etc/passwd'><tv></tv>",
            "<html></html>",
            "<tv><programme>",
        ] {
            assert!(parse_xml(xml.as_bytes(), &wanted, now()).is_err());
        }
        let giant = format!("<tv><x>{}</x></tv>", "a".repeat(MAX_TOKEN + 1));
        assert!(parse_xml(giant.as_bytes(), &wanted, now()).is_err());
    }
    #[test]
    fn snapshots_hide_expired_programs_and_never_map_reused_ids_to_different_stations() {
        let future =
            (Utc::now() + chrono::Duration::hours(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let past =
            (Utc::now() - chrono::Duration::hours(1)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let good = Program {
            id: "test".into(),
            title: "Game".into(),
            start_time: past.clone(),
            end_time: future,
            description: None,
            episode_title: None,
        };
        let mut old = good.clone();
        old.id = "old".into();
        old.end_time = past;
        let state = GuideService {
            enabled: true,
            mappings: vec![Mapping {
                channel_id: "abc-wews".into(),
                name: "ABC (WEWS)".into(),
                xmltv_id: "WEWS-DT.us_locals1".into(),
            }],
            feeds: Mutex::new(vec![FeedCache {
                updated: Some(Utc::now()),
                programs: HashMap::from([("WEWS-DT.us_locals1".into(), vec![old, good])]),
                ..Default::default()
            }]),
        };
        let good = state.snapshot("Spectrum", &[("abc-wews".into(), "ABC (WEWS)".into())]);
        assert_eq!(good.channels[0].programs.len(), 1);
        let wrong = state.snapshot("Spectrum", &[("abc-wews".into(), "ABC (WABC)".into())]);
        assert!(wrong.channels[0].programs.is_empty());
        assert!(wrong.message.is_some());
    }
}
