//! Short-lived, targeted handoffs. Separate from the legacy broadcast mailbox and
//! watch-state DB: a restart drops playback commands instead of replaying them.
use axum::{
    extract::Request,
    extract::{Query, State},
    http::{header, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

const PRESENCE_MS: i64 = 12_000;
const PENDING_MS: i64 = 15_000;
const STARTUP_MS: i64 = 120_000;
const RETAIN_MS: i64 = 600_000;
const MAX_RECEIVERS: usize = 256;
const MAX_REQUESTS: usize = 512;

#[derive(Clone, Deserialize, Serialize, PartialEq, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceHint {
    stream_id: String,
    title: String,
    source_name: String,
    binge_group: Option<String>,
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Create {
    request_id: String,
    profile_id: String,
    media_id: i64,
    #[serde(rename = "type")]
    media_type: String,
    season: Option<i64>,
    episode: Option<i64>,
    position_ms: i64,
    title: Option<String>,
    source_hint: Option<SourceHint>,
    target_device_id: Option<String>,
    target_session_id: Option<String>,
}

#[derive(Clone, Deserialize, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Presence {
    device_id: String,
    session_id: String,
    name: String,
    profile_id: String,
    sequence: i64,
    available: bool,
}

#[derive(Clone, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Receiver {
    device_id: String,
    session_id: String,
    name: String,
    profile_id: String,
    expires_at: i64,
}
struct Lease {
    receiver: Receiver,
    sequence: i64,
    available: bool,
    touched: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Phase {
    Pending,
    Claimed,
    Started,
    Failed,
    Cancelled,
    Expired,
}
impl Phase {
    fn terminal(self) -> bool {
        !matches!(self, Self::Pending | Self::Claimed)
    }
}
struct Intent {
    original: Option<Create>,
    target: Option<Receiver>,
    phase: Phase,
    expires_at: i64,
    touched: i64,
    error: Option<String>,
}
#[derive(Default)]
struct Store {
    receivers: HashMap<String, Lease>,
    intents: HashMap<String, Intent>,
}
#[derive(Clone)]
struct Shared {
    store: Arc<Mutex<Store>>,
    streams: crate::stream::StreamState,
    stream_base_url: String,
}

#[derive(Debug)]
struct Failure(
    StatusCode,
    &'static str,
    &'static str,
    Option<Vec<Receiver>>,
);
impl IntoResponse for Failure {
    fn into_response(self) -> Response {
        (
            self.0,
            Json(json!({"protocolVersion":2,"code":self.1,"error":self.2,"receivers":self.3})),
        )
            .into_response()
    }
}
type Result<T> = std::result::Result<T, Failure>;
fn invalid() -> Failure {
    Failure(
        StatusCode::BAD_REQUEST,
        "invalid_request",
        "Invalid handoff request.",
        None,
    )
}
fn unknown() -> Failure {
    Failure(
        StatusCode::NOT_FOUND,
        "not_found",
        "This handoff is no longer available.",
        None,
    )
}
fn full() -> Failure {
    Failure(
        StatusCode::SERVICE_UNAVAILABLE,
        "busy",
        "Try sending to TV again shortly.",
        None,
    )
}
fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn label(s: &str, max: usize) -> bool {
    !s.trim().is_empty() && s.chars().count() <= max && !s.chars().any(char::is_control)
}
fn metadata(s: &str, max: usize) -> bool {
    // Addon display titles can legitimately be empty or contain line breaks.
    s.chars().count() <= max
        && !s
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\r' && c != '\t')
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

impl Create {
    fn valid(&self) -> bool {
        uuid(&self.request_id)
            && label(&self.profile_id, 128)
            && self.media_id > 0
            && self.media_id <= i32::MAX as i64
            && matches!(self.media_type.as_str(), "movie" | "show" | "series")
            && (0..=604_800_000).contains(&self.position_ms)
            && (if self.media_type == "movie" {
                self.season.is_none() && self.episode.is_none()
            } else {
                self.season.is_some_and(|n| (0..=100_000).contains(&n))
                    && self.episode.is_some_and(|n| (1..=100_000).contains(&n))
            })
            && self.title.as_ref().is_none_or(|s| metadata(s, 500))
            && self.source_hint.as_ref().is_some_and(|h| {
                crate::stream::valid_stream_id(&h.stream_id)
                    && metadata(&h.title, 500)
                    && metadata(&h.source_name, 100)
                    && h.binge_group.as_ref().is_none_or(|s| metadata(s, 100))
            })
            && match (&self.target_device_id, &self.target_session_id) {
                (None, None) => true,
                (Some(a), Some(b)) => uuid(a) && uuid(b),
                _ => false,
            }
    }
}

impl Store {
    fn eligible(&self, receiver: &Receiver, now: i64) -> bool {
        self.receivers
            .get(&receiver.device_id)
            .is_some_and(|lease| {
                lease.available
                    && lease.receiver.expires_at > now
                    && lease.receiver.session_id == receiver.session_id
            })
    }
    fn prune(&mut self, now: i64) {
        let dead: Vec<_> = self
            .intents
            .iter()
            .filter(|(_, i)| {
                !i.phase.terminal()
                    && (i.expires_at <= now
                        || i.target.as_ref().is_none_or(|t| !self.eligible(t, now)))
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in dead {
            let i = self.intents.get_mut(&id).unwrap();
            i.phase = Phase::Expired;
            i.touched = now;
            i.error = Some("The TV is no longer available or the handoff timed out.".into());
        }
        self.intents
            .retain(|_, i| !i.phase.terminal() || i.touched + RETAIN_MS > now);
        self.receivers.retain(|_, l| l.touched + RETAIN_MS > now);
    }
    fn list(&self, now: i64) -> Vec<Receiver> {
        let mut rows: Vec<_> = self
            .receivers
            .values()
            .filter(|l| l.available && l.receiver.expires_at > now)
            .map(|l| l.receiver.clone())
            .collect();
        rows.sort_by(|a, b| a.name.cmp(&b.name).then(a.device_id.cmp(&b.device_id)));
        rows
    }
    fn presence(&mut self, p: Presence, now: i64) -> Result<Value> {
        if !uuid(&p.device_id)
            || !uuid(&p.session_id)
            || !label(&p.name, 80)
            || !label(&p.profile_id, 128)
            || p.sequence <= 0
        {
            return Err(invalid());
        }
        self.prune(now);
        if let Some(old) = self.receivers.get(&p.device_id) {
            if p.sequence <= old.sequence
                || (!p.available && p.session_id != old.receiver.session_id)
            {
                return Ok(
                    json!({"protocolVersion":2,"accepted":false,"expiresAt":old.receiver.expires_at}),
                );
            }
        } else if self.receivers.len() >= MAX_RECEIVERS {
            return Err(full());
        }
        let expires_at = if p.available { now + PRESENCE_MS } else { now };
        self.receivers.insert(
            p.device_id.clone(),
            Lease {
                receiver: Receiver {
                    device_id: p.device_id,
                    session_id: p.session_id,
                    name: p.name,
                    profile_id: p.profile_id,
                    expires_at,
                },
                sequence: p.sequence,
                available: p.available,
                touched: now,
            },
        );
        self.prune(now);
        Ok(json!({"protocolVersion":2,"accepted":true,"expiresAt":expires_at}))
    }
    fn status(&self, id: &str) -> Result<Value> {
        let i = self.intents.get(id).ok_or_else(unknown)?;
        Ok(
            json!({"protocolVersion":2,"id":id,"state":i.phase,"targetName":i.target.as_ref().map(|t| &t.name),"expiresAt":i.expires_at,"error":i.error}),
        )
    }
    fn create(&mut self, c: Create, now: i64) -> Result<Value> {
        if !c.valid() {
            return Err(invalid());
        }
        self.prune(now);
        if let Some(existing) = self.intents.get(&c.request_id) {
            if existing
                .original
                .as_ref()
                .is_some_and(|original| original != &c)
            {
                return Err(Failure(
                    StatusCode::CONFLICT,
                    "request_conflict",
                    "This request ID was already used.",
                    None,
                ));
            }
            return self.status(&c.request_id);
        }
        if self.intents.len() >= MAX_REQUESTS {
            return Err(full());
        }
        let eligible = self.list(now);
        let target = match (&c.target_device_id, &c.target_session_id) {
            (Some(device), Some(session)) => eligible
                .iter()
                .find(|r| &r.device_id == device && &r.session_id == session)
                .cloned()
                .ok_or(Failure(
                    StatusCode::CONFLICT,
                    "receiver_unavailable",
                    "That TV is no longer available.",
                    None,
                ))?,
            _ => match eligible.len() {
                0 => {
                    return Err(Failure(
                        StatusCode::CONFLICT,
                        "no_receiver",
                        "Open Velvet on an awake TV first.",
                        None,
                    ))
                }
                1 => eligible[0].clone(),
                _ => {
                    return Err(Failure(
                        StatusCode::CONFLICT,
                        "multiple_receivers",
                        "Choose a TV to continue.",
                        Some(eligible),
                    ))
                }
            },
        };
        if self.intents.values().any(|i| {
            !i.phase.terminal()
                && i.target.as_ref().is_some_and(|t| {
                    t.device_id == target.device_id && t.session_id == target.session_id
                })
        }) {
            return Err(Failure(
                StatusCode::CONFLICT,
                "receiver_busy",
                "That TV is already starting another handoff. Try again shortly.",
                None,
            ));
        }
        let id = c.request_id.clone();
        self.intents.insert(
            id.clone(),
            Intent {
                original: Some(c),
                target: Some(target),
                phase: Phase::Pending,
                expires_at: now + PENDING_MS,
                touched: now,
                error: None,
            },
        );
        self.status(&id)
    }
    fn claim(&mut self, device: &str, session: &str, now: i64) -> Result<Value> {
        if !uuid(device) || !uuid(session) {
            return Err(invalid());
        }
        self.prune(now);
        let id = self
            .intents
            .iter()
            .filter(|(_, i)| {
                i.phase == Phase::Pending
                    && i.target
                        .as_ref()
                        .is_some_and(|t| t.device_id == device && t.session_id == session)
            })
            .min_by_key(|(_, i)| i.touched)
            .map(|(id, _)| id.clone());
        let Some(id) = id else {
            return Ok(json!({"protocolVersion":2,"handoff":null}));
        };
        let i = self.intents.get_mut(&id).unwrap();
        i.phase = Phase::Claimed;
        i.expires_at = now + STARTUP_MS;
        i.touched = now;
        let mut payload = serde_json::to_value(i.original.as_ref().unwrap()).unwrap();
        let object = payload.as_object_mut().unwrap();
        object.remove("requestId");
        object.remove("targetDeviceId");
        object.remove("targetSessionId");
        object.insert("id".into(), json!(id));
        object.insert("expiresAt".into(), json!(i.expires_at));
        let sid = &i
            .original
            .as_ref()
            .unwrap()
            .source_hint
            .as_ref()
            .unwrap()
            .stream_id;
        object.insert("playbackPath".into(), json!(format!("/stream/{sid}")));
        Ok(json!({"protocolVersion":2,"handoff":payload}))
    }
    fn cancel(&mut self, id: &str, now: i64) -> Result<Value> {
        if !uuid(id) {
            return Err(invalid());
        }
        self.prune(now);
        if !self.intents.contains_key(id) {
            if self.intents.len() >= MAX_REQUESTS {
                return Err(full());
            }
            self.intents.insert(
                id.into(),
                Intent {
                    original: None,
                    target: None,
                    phase: Phase::Cancelled,
                    expires_at: now,
                    touched: now,
                    error: None,
                },
            );
        }
        let i = self.intents.get_mut(id).unwrap();
        if !i.phase.terminal() {
            i.phase = Phase::Cancelled;
            i.touched = now;
        }
        self.status(id)
    }
    fn ack(&mut self, a: Ack, now: i64) -> Result<Value> {
        if !uuid(&a.id)
            || !uuid(&a.device_id)
            || !uuid(&a.session_id)
            || !matches!(a.state.as_str(), "started" | "failed")
            || a.error.as_ref().is_some_and(|s| s.chars().count() > 240)
        {
            return Err(invalid());
        }
        self.prune(now);
        let i = self.intents.get_mut(&a.id).ok_or_else(unknown)?;
        let target_matches = i
            .target
            .as_ref()
            .is_some_and(|t| t.device_id == a.device_id && t.session_id == a.session_id);
        let next = if a.state == "started" {
            Phase::Started
        } else {
            Phase::Failed
        };
        let accepted = target_matches && (i.phase == Phase::Claimed || i.phase == next);
        if accepted && i.phase == Phase::Claimed {
            i.phase = next;
            i.touched = now;
            if next == Phase::Failed {
                i.error = Some("Playback could not start on the TV. Try again.".into());
            }
        }
        Ok(json!({"protocolVersion":2,"accepted":accepted,"status":self.status(&a.id)?}))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Claim {
    device_id: String,
    session_id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Id {
    id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Ack {
    id: String,
    device_id: String,
    session_id: String,
    state: String,
    error: Option<String>,
}

pub fn router(streams: crate::stream::StreamState, stream_base_url: String) -> Router {
    Router::new()
        .route("/handoff/presence", post(presence))
        .route("/handoff/receivers", get(receivers))
        .route("/handoff/v2", post(create))
        .route("/handoff/v2/claim", post(claim))
        .route("/handoff/v2/status", get(status))
        .route("/handoff/v2/cancel", post(cancel))
        .route("/handoff/v2/ack", post(ack))
        .with_state(Shared {
            store: Arc::new(Mutex::new(Store::default())),
            streams,
            stream_base_url,
        })
        .layer(middleware::from_fn(no_cache))
}
async fn no_cache(req: Request, next: Next) -> Response {
    let mut response = next.run(req).await;
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}
async fn presence(State(s): State<Shared>, Json(p): Json<Presence>) -> Result<Json<Value>> {
    s.store.lock().unwrap().presence(p, now()).map(Json)
}
async fn receivers(State(s): State<Shared>) -> Json<Value> {
    let mut store = s.store.lock().unwrap();
    let n = now();
    store.prune(n);
    // Resolver links may use the LAN address while sync uses a public tunnel.
    // Advertise the configured resolver base, never a client/Host header value,
    // so senders can identify the exact registered source across those aliases.
    Json(json!({"protocolVersion":2,"serverNow":n,"streamBaseURL":s.stream_base_url,"receivers":store.list(n)}))
}
async fn create(State(s): State<Shared>, Json(c): Json<Create>) -> Result<Json<Value>> {
    if !c.valid() {
        return Err(invalid());
    }
    let mut store = s.store.lock().unwrap();
    store.prune(now());
    // Existing requests (including pre-create cancellation tombstones) keep
    // their authoritative outcome even if a registration was later removed.
    if !store.intents.contains_key(&c.request_id)
        && !s
            .streams
            .is_registered(&c.source_hint.as_ref().unwrap().stream_id)
    {
        return Err(Failure(StatusCode::CONFLICT, "source_unavailable",
            "The phone's exact stream is no longer available. Restart playback on the phone and try again.", None));
    }
    store.create(c, now()).map(Json)
}
async fn claim(State(s): State<Shared>, Json(c): Json<Claim>) -> Result<Json<Value>> {
    s.store
        .lock()
        .unwrap()
        .claim(&c.device_id, &c.session_id, now())
        .map(Json)
}
async fn status(State(s): State<Shared>, Query(id): Query<Id>) -> Result<Json<Value>> {
    if !uuid(&id.id) {
        return Err(invalid());
    }
    let mut s = s.store.lock().unwrap();
    s.prune(now());
    s.status(&id.id).map(Json)
}
async fn cancel(State(s): State<Shared>, Json(id): Json<Id>) -> Result<Json<Value>> {
    s.store.lock().unwrap().cancel(&id.id, now()).map(Json)
}
async fn ack(State(s): State<Shared>, Json(a): Json<Ack>) -> Result<Json<Value>> {
    s.store.lock().unwrap().ack(a, now()).map(Json)
}

#[cfg(test)]
mod tests {
    use super::*;
    const DEVICE: &str = "10000000-0000-0000-0000-000000000001";
    const SESSION: &str = "20000000-0000-0000-0000-000000000001";
    const ID: &str = "30000000-0000-0000-0000-000000000001";
    fn presence_value(sequence: i64, available: bool) -> Presence {
        Presence {
            device_id: DEVICE.into(),
            session_id: SESSION.into(),
            name: "Living room".into(),
            profile_id: "tv-profile".into(),
            sequence,
            available,
        }
    }
    fn request() -> Create {
        serde_json::from_value(json!({"requestId":ID,"profileId":"phone-profile","mediaId":7,"type":"show","season":2,"episode":9,"positionMs":2345,"title":"An episode","sourceHint":{"streamId":"0123456789abcdef","title":"Release A","sourceName":"Velvet","bingeGroup":"Cut A"}})).unwrap()
    }
    fn ack_value(state: &str) -> Ack {
        Ack {
            id: ID.into(),
            device_id: DEVICE.into(),
            session_id: SESSION.into(),
            state: state.into(),
            error: None,
        }
    }
    #[test]
    fn absent_asleep_stale_receivers_never_queue() {
        let mut s = Store::default();
        assert_eq!(s.create(request(), 0).unwrap_err().1, "no_receiver");
        s.presence(presence_value(1, false), 0).unwrap();
        assert!(s.create(request(), 1).is_err());
        s.presence(presence_value(2, true), 2).unwrap();
        assert!(s.create(request(), PRESENCE_MS + 2).is_err());
        assert!(s.intents.is_empty());
    }
    #[test]
    fn target_preserves_exact_profile_episode_position_and_hint() {
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        s.create(request(), 1).unwrap();
        let result = s.claim(DEVICE, SESSION, 2).unwrap();
        let p = &result["handoff"];
        assert_eq!(p["profileId"], "phone-profile");
        assert_eq!(p["positionMs"], 2345);
        assert_eq!(p["episode"], 9);
        assert_eq!(p["sourceHint"]["bingeGroup"], "Cut A");
        assert!(s.claim(DEVICE, SESSION, 3).unwrap()["handoff"].is_null());
        assert_eq!(s.ack(ack_value("started"), 4).unwrap()["accepted"], true);
        assert_eq!(s.cancel(ID, 5).unwrap()["state"], "started");
    }
    #[test]
    fn multiple_receivers_require_explicit_target_and_cannot_race() {
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        let mut p = presence_value(1, true);
        p.device_id = "10000000-0000-0000-0000-000000000002".into();
        p.session_id = "20000000-0000-0000-0000-000000000002".into();
        s.presence(p.clone(), 0).unwrap();
        assert_eq!(s.create(request(), 1).unwrap_err().1, "multiple_receivers");
        let mut c = request();
        c.target_device_id = Some(DEVICE.into());
        c.target_session_id = Some(SESSION.into());
        s.create(c, 2).unwrap();
        assert!(s.claim(&p.device_id, &p.session_id, 3).unwrap()["handoff"].is_null());
        assert_eq!(s.claim(DEVICE, SESSION, 4).unwrap()["handoff"]["id"], ID);
    }
    #[test]
    fn late_presence_cannot_revive_sleeping_or_replaced_session() {
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        s.create(request(), 1).unwrap();
        s.presence(presence_value(3, false), 2).unwrap();
        assert_eq!(
            s.presence(presence_value(2, true), 3).unwrap()["accepted"],
            false
        );
        assert!(s.list(3).is_empty());
        assert!(s.claim(DEVICE, SESSION, 4).unwrap()["handoff"].is_null());
        let mut new = presence_value(4, true);
        new.session_id = "20000000-0000-0000-0000-000000000002".into();
        s.presence(new, 5).unwrap();
        assert!(!s.eligible(
            &Receiver {
                device_id: DEVICE.into(),
                session_id: SESSION.into(),
                name: "".into(),
                profile_id: "".into(),
                expires_at: 100
            },
            6
        ));
    }

    #[test]
    fn old_session_cleanup_cannot_withdraw_a_new_foreground_session() {
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        let mut next = presence_value(2, true);
        next.session_id = "20000000-0000-0000-0000-000000000002".into();
        s.presence(next.clone(), 1).unwrap();
        assert_eq!(
            s.presence(presence_value(3, false), 2).unwrap()["accepted"],
            false
        );
        assert_eq!(s.list(2)[0].session_id, next.session_id);
        assert_eq!(s.create(request(), 3).unwrap()["state"], "pending");
    }
    #[test]
    fn idempotency_and_cancel_tombstone_prevent_late_or_duplicate_playback() {
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        s.cancel(ID, 1).unwrap();
        assert_eq!(s.create(request(), 2).unwrap()["state"], "cancelled");
        assert!(s.claim(DEVICE, SESSION, 3).unwrap()["handoff"].is_null());
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        s.create(request(), 1).unwrap();
        s.create(request(), 2).unwrap();
        assert_eq!(s.intents.len(), 1);
        let mut c = request();
        c.position_ms += 1;
        assert_eq!(s.create(c, 3).unwrap_err().1, "request_conflict");
        s.claim(DEVICE, SESSION, 4).unwrap();
        s.cancel(ID, 5).unwrap();
        assert_eq!(s.ack(ack_value("started"), 6).unwrap()["accepted"], false);
    }
    #[test]
    fn lease_lost_during_resolution_blocks_started_ack() {
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        s.create(request(), 1).unwrap();
        s.claim(DEVICE, SESSION, 2).unwrap();
        assert_eq!(
            s.ack(ack_value("started"), PRESENCE_MS).unwrap()["accepted"],
            false
        );
        assert_eq!(s.status(ID).unwrap()["state"], "expired");
    }
    #[test]
    fn validation_rejects_ambiguous_payloads_and_excessive_hints() {
        let mut c = request();
        c.position_ms = -1;
        assert!(!c.valid());
        c = request();
        c.target_device_id = Some(DEVICE.into());
        assert!(!c.valid());
        c = request();
        c.source_hint.as_mut().unwrap().title = "x".repeat(501);
        assert!(!c.valid());
        assert!(serde_json::from_value::<Create>(json!({"requestId":ID,"profileId":"p","mediaId":1,"type":"movie","positionMs":0,"url":"https://example.com"})).is_err());
    }

    #[test]
    fn handoff_requires_exact_canonical_source_identity() {
        let mut c = request();
        c.source_hint = None;
        assert!(!c.valid());
        for sid in [
            "",
            "0123456789ABCDEF",
            "https://example.com/stream/0123456789abcdef",
            "../0123456789abc",
            "0123456789abcdef?x=1",
        ] {
            c = request();
            c.source_hint.as_mut().unwrap().stream_id = sid.into();
            assert!(!c.valid());
        }
        let mut raw = serde_json::to_value(request()).unwrap();
        raw["sourceHint"]["url"] = json!("https://example.com/arbitrary-source");
        assert!(serde_json::from_value::<Create>(raw).is_err());
    }

    #[test]
    fn pending_deadline_is_not_extended_by_heartbeats_or_duplicates() {
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        s.create(request(), 1).unwrap();
        s.presence(presence_value(2, true), 10_000).unwrap();
        assert_eq!(s.create(request(), 14_000).unwrap()["expiresAt"], 15_001);
        assert!(s.claim(DEVICE, SESSION, 15_001).unwrap()["handoff"].is_null());
        assert_eq!(s.status(ID).unwrap()["state"], "expired");
    }

    #[test]
    fn different_requests_cannot_overlap_on_one_receiver() {
        let mut s = Store::default();
        s.presence(presence_value(1, true), 0).unwrap();
        s.create(request(), 1).unwrap();
        let mut second = request();
        second.request_id = "30000000-0000-0000-0000-000000000002".into();
        assert_eq!(s.create(second.clone(), 2).unwrap_err().1, "receiver_busy");
        s.claim(DEVICE, SESSION, 3).unwrap();
        assert_eq!(s.create(second.clone(), 4).unwrap_err().1, "receiver_busy");
        s.ack(ack_value("started"), 5).unwrap();
        assert_eq!(s.create(second, 6).unwrap()["state"], "pending");
    }

    #[test]
    fn concurrent_claims_deliver_exactly_once() {
        let shared = Arc::new(Mutex::new(Store::default()));
        shared
            .lock()
            .unwrap()
            .presence(presence_value(1, true), 0)
            .unwrap();
        shared.lock().unwrap().create(request(), 1).unwrap();
        let workers: Vec<_> = (0..8)
            .map(|_| {
                let s = shared.clone();
                std::thread::spawn(move || {
                    !s.lock().unwrap().claim(DEVICE, SESSION, 2).unwrap()["handoff"].is_null()
                })
            })
            .collect();
        assert_eq!(
            workers
                .into_iter()
                .map(|w| usize::from(w.join().unwrap()))
                .sum::<usize>(),
            1
        );
    }

    #[tokio::test]
    async fn http_auth_cache_and_targeted_wire_preserve_legacy_mailbox() {
        let db = Arc::new(Mutex::new(rusqlite::Connection::open_in_memory().unwrap()));
        crate::sync::migrate(&db.lock().unwrap()).unwrap();
        let streams = crate::stream::StreamState::new(
            crate::pool::Pool::new(&[]),
            reqwest::Client::new(),
            db.clone(),
        );
        let sid = streams.register("https://fixture.invalid/exact.nzb").await;
        let mut fixture = request();
        fixture.source_hint.as_mut().unwrap().stream_id = sid.clone();
        let stream_base = "http://backend.example:8799";
        let app = crate::sync::router(db, "fixture-secret".into(), None, streams, stream_base.into());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = reqwest::Client::new();
        assert_eq!(
            client
                .get(format!("{base}/handoff/receivers"))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let presence=client.post(format!("{base}/handoff/presence")).bearer_auth("fixture-secret").json(&json!({"deviceId":DEVICE,"sessionId":SESSION,"name":"TV","profileId":"tv-profile","sequence":1,"available":true})).send().await.unwrap();
        assert_eq!(presence.status(), StatusCode::OK);
        assert_eq!(presence.headers()["cache-control"], "private, no-store");
        let discovery = client
            .get(format!("{base}/handoff/receivers"))
            .bearer_auth("fixture-secret")
            .header("Host", "untrusted.invalid")
            .header("X-Forwarded-Host", "untrusted.invalid")
            .send().await.unwrap();
        assert_eq!(discovery.status(), StatusCode::OK);
        assert_eq!(discovery.headers()["cache-control"], "private, no-store");
        let discovery: Value = discovery.json().await.unwrap();
        assert_eq!(discovery["streamBaseURL"], stream_base);
        assert_eq!(discovery["receivers"][0]["deviceId"], DEVICE);
        let mut unknown_source = fixture.clone();
        unknown_source.source_hint.as_mut().unwrap().stream_id = "0000000000000000".into();
        let rejected = client
            .post(format!("{base}/handoff/v2"))
            .bearer_auth("fixture-secret")
            .json(&unknown_source)
            .send()
            .await
            .unwrap();
        assert_eq!(rejected.status(), StatusCode::CONFLICT);
        assert_eq!(
            rejected.json::<Value>().await.unwrap()["code"],
            "source_unavailable"
        );
        // Cancel-before-create remains final even when its source is unavailable.
        unknown_source.request_id = "30000000-0000-0000-0000-000000000002".into();
        client
            .post(format!("{base}/handoff/v2/cancel"))
            .bearer_auth("fixture-secret")
            .json(&json!({"id":unknown_source.request_id}))
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap();
        let cancelled_late: Value = client
            .post(format!("{base}/handoff/v2"))
            .bearer_auth("fixture-secret")
            .json(&unknown_source)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(cancelled_late["state"], "cancelled");
        let created: Value = client
            .post(format!("{base}/handoff/v2"))
            .bearer_auth("fixture-secret")
            .json(&fixture)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(created["id"], ID);
        assert_eq!(created["state"], "pending");
        let legacy: Value = client
            .get(format!("{base}/handoff/pending?profileId=phone-profile"))
            .bearer_auth("fixture-secret")
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert!(legacy["handoff"].is_null());
        let body = json!({"deviceId":DEVICE,"sessionId":SESSION});
        let delivered: Value = client
            .post(format!("{base}/handoff/v2/claim"))
            .bearer_auth("fixture-secret")
            .json(&body)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(delivered["handoff"]["profileId"], "phone-profile");
        assert_eq!(delivered["handoff"]["positionMs"], 2345);
        assert_eq!(
            delivered["handoff"]["playbackPath"],
            format!("/stream/{sid}")
        );
        assert_eq!(delivered["handoff"]["sourceHint"]["streamId"], sid);
        assert!(!delivered.to_string().contains("fixture.invalid"));
        let status: Value = client
            .get(format!("{base}/handoff/v2/status?id={ID}"))
            .bearer_auth("fixture-secret")
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(status["state"], "claimed");
        let cancelled: Value = client
            .post(format!("{base}/handoff/v2/cancel"))
            .bearer_auth("fixture-secret")
            .json(&json!({"id":ID}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(cancelled["state"], "cancelled");
        let ack: Value = client
            .post(format!("{base}/handoff/v2/ack"))
            .bearer_auth("fixture-secret")
            .json(&json!({"id":ID,"deviceId":DEVICE,"sessionId":SESSION,"state":"started"}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(ack["accepted"], false);
        server.abort();
    }
}
