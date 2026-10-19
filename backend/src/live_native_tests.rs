use super::*;
use axum::http::Uri;
use std::sync::atomic::AtomicUsize;

const CAP: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OTHER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
fn channel() -> serde_json::Value { serde_json::json!({"id":"native-news","name":"Native News","number":"42","logoUrl":null,"group":"News"}) }
fn descriptor() -> serde_json::Value {
    serde_json::json!({"sessionId":CAP,"playbackPath":format!("/live/streams/{CAP}/index.mpd"),"mimeType":DASH,
        "channel":channel(),"canPause":false,"canSeek":false,"drm":{"scheme":"widevine","licensePath":format!("/live/drm/{CAP}"),"multiSession":true}})
}
#[derive(Default)]
struct Mock {
    catalogs: AtomicUsize, tunes: AtomicUsize, streams: AtomicUsize, licenses: AtomicUsize,
    certificates: AtomicUsize, ends: AtomicUsize, prism: AtomicUsize,
    descriptor: Mutex<Option<serde_json::Value>>, failure: Mutex<Option<(&'static str, StatusCode)>>,
    requests: Mutex<Vec<(String, HeaderMap, Vec<u8>)>>, redirect: Mutex<String>,
}
struct Fixture { base: String, mock: Arc<Mock>, bridge: NativeBridge, tasks: Vec<tokio::task::JoinHandle<()>> }
impl Drop for Fixture { fn drop(&mut self) { for task in &self.tasks { task.abort(); } } }
async fn serve(router: Router) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    (base, tokio::spawn(async move { axum::serve(listener, router).await.unwrap(); }))
}
fn record(mock: &Mock, path: &str, headers: HeaderMap, bytes: Vec<u8>) {
    assert!(!headers.contains_key(header::AUTHORIZATION));
    assert!(!headers.contains_key(header::COOKIE));
    assert!(!headers.contains_key("ast-authorization"));
    mock.requests.lock().unwrap().push((path.into(), headers, bytes));
}
impl Fixture {
    async fn new() -> Self {
        let mock = Arc::new(Mock::default());
        let prism_state = mock.clone();
        let prism = Router::new().fallback(move || { let mock = prism_state.clone(); async move {
            mock.prism.fetch_add(1, Ordering::Relaxed);
            "#EXTM3U\n#EXTINF:2,\nsegment.ts\n"
        }});
        let (prism_base, prism_task) = serve(prism).await;
        *mock.redirect.lock().unwrap() = format!("{prism_base}/must-not-be-requested");
        let sidecar = Router::new()
            .route("/live/channels", get(|State(mock): State<Arc<Mock>>, headers: HeaderMap| async move {
                mock.catalogs.fetch_add(1, Ordering::Relaxed); record(&mock, "channels", headers, vec![]);
                if let Some((code,status)) = *mock.failure.lock().unwrap() {
                    return (status,Json(serde_json::json!({"code":code,"error":"PRIVATE account details"}))).into_response();
                }
                Json(serde_json::json!({"enabled":true,"sourceName":"Native Spectrum","channels":[channel()],"message":null})).into_response()
            }))
            .route("/live/tune", post(|State(mock): State<Arc<Mock>>, headers: HeaderMap, Json(body): Json<serde_json::Value>| async move {
                mock.tunes.fetch_add(1, Ordering::Relaxed);
                record(&mock, "tune", headers, serde_json::to_vec(&body).unwrap());
                if let Some((code, status)) = *mock.failure.lock().unwrap() {
                    return (status, Json(serde_json::json!({"code":code,"error":"PRIVATE provider URL and account details"}))).into_response();
                }
                Json(mock.descriptor.lock().unwrap().clone().unwrap_or_else(descriptor)).into_response()
            }))
            .route("/live/streams/:id/:key", get(|State(mock): State<Arc<Mock>>, Path((id,key)): Path<(String,String)>, headers: HeaderMap| async move {
                mock.streams.fetch_add(1, Ordering::Relaxed); record(&mock, "stream", headers.clone(), vec![]);
                if id != CAP { return (StatusCode::NOT_FOUND, "PRIVATE missing capability").into_response(); }
                match key.as_str() {
                    "index.mpd" => ([(header::CONTENT_TYPE,DASH),(header::SET_COOKIE,"private=secret")], "<MPD><Period/></MPD>").into_response(),
                    "index.m3u8" => format!("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT=\"com.apple.streamingkeydelivery\",URI=\"skd://velvet/key_1?ContentId=raw%2Fvalue\"\n#EXTINF:6,\n/live/streams/{CAP}/captemplate_123-seg.m4s\n").into_response(),
                    "captemplate_123-seg.m4s" => {
                        assert_eq!(headers[header::RANGE], "bytes=0-3");
                        (StatusCode::PARTIAL_CONTENT,[(header::CONTENT_TYPE,"video/mp4"),(header::CONTENT_RANGE,"bytes 0-3/8")], vec![0,255,2,3]).into_response()
                    },
                    "redirect.mpd" => (StatusCode::FOUND, [(header::LOCATION,mock.redirect.lock().unwrap().clone())]).into_response(),
                    "large.mpd" => vec![b'x'; MAX_MANIFEST+1].into_response(),
                    "large.m4s" => Response::builder().header(header::CONTENT_LENGTH,MAX_SEGMENT+1).body(Body::from_stream(futures::stream::empty::<std::result::Result<Bytes,std::io::Error>>())).unwrap(),
                    _ => StatusCode::NOT_FOUND.into_response(),
                }
            }))
            .route("/live/drm/:id", post(|State(mock): State<Arc<Mock>>, Path(id): Path<String>, uri: Uri, headers: HeaderMap, body: Bytes| async move {
                mock.licenses.fetch_add(1, Ordering::Relaxed);
                record(&mock, uri.query().unwrap_or("license"), headers.clone(), body.to_vec());
                assert_eq!(headers[header::CONTENT_TYPE], "application/octet-stream");
                if id != CAP { return StatusCode::NOT_FOUND.into_response(); }
                if body.as_ref() == b"oversized-response" {
                    return Response::new(Body::from_stream(futures::stream::iter([
                        Ok::<_,std::io::Error>(Bytes::from(vec![7;MAX_LICENSE])), Ok(Bytes::from_static(b"x"))])));
                }
                if let Some((code,status)) = *mock.failure.lock().unwrap() {
                    return (status,Json(serde_json::json!({"code":code,"error":"PRIVATE provider failure"}))).into_response();
                }
                ([(header::CONTENT_TYPE,"application/octet-stream"),(header::SET_COOKIE,"private=secret")],body).into_response()
            }))
            .route("/live/cert/:id", get(|State(mock): State<Arc<Mock>>, Path(id): Path<String>, headers: HeaderMap| async move {
                mock.certificates.fetch_add(1, Ordering::Relaxed); record(&mock, "certificate", headers, vec![]);
                if id != CAP { return StatusCode::NOT_FOUND.into_response(); }
                vec![0x30,0,255,0].into_response()
            }))
            .route("/live/sessions/:id", delete(|State(mock): State<Arc<Mock>>, headers: HeaderMap| async move {
                mock.ends.fetch_add(1, Ordering::Relaxed); record(&mock, "end", headers, vec![]); StatusCode::NO_CONTENT
            })).with_state(mock.clone());
        let (native_base, sidecar_task) = serve(sidecar).await;
        let cfg = LiveTv { enabled:true, upstream_url:prism_base, native_spectrum_url:Some(native_base), ..LiveTv::default() };
        let (router,bridge) = router_with_bridge(cfg,"outer-secret".into()).unwrap();
        let (base,adapter_task) = serve(router).await;
        Self { base,mock,bridge,tasks:vec![prism_task,sidecar_task,adapter_task] }
    }
    fn tune(&self, caps: &str) -> reqwest::RequestBuilder {
        reqwest::Client::new().post(format!("{}/live/tune",self.base)).bearer_auth("outer-secret")
            .header(CLIENT,"roku").header(CAPABILITIES,caps).header(header::COOKIE,"account=outer-private")
            .header("ast-authorization","outer-provider-private").json(&serde_json::json!({"channelId":"native-news","client":"roku"}))
    }
}

#[test]
fn native_origin_paths_capabilities_and_descriptors_fail_closed() {
    for origin in ["file:///tmp","https://user:pass@private/","http://private/path","http://private/?url=http://elsewhere","http://private/#fragment"] {
        assert!(NativeSpectrum::new(origin).is_err());
    }
    for resource in ["",".","..","../key","a/b","a%2Fb","key?url=http://elsewhere","\\host",".hidden","a..b","a b","${Number}"] { assert!(!valid_resource(resource)); }
    for resource in ["index.mpd","index.m3u8","captemplate_123-seg-004.m4s","init_123.mp4"] { assert!(valid_resource(resource)); }
    for id in ["short","AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaag"] { assert!(!valid_cap(id)); }
    assert!(valid_cap(CAP));
    let decoded: Descriptor = serde_json::from_value(descriptor()).unwrap();
    assert!(validate_descriptor(&decoded,"native-news",&["dash-widevine"]).is_ok());
    assert_eq!(validate_descriptor(&decoded,"native-news",&["hls-clear"]).unwrap_err().0,StatusCode::UPGRADE_REQUIRED);
    let mut hls = descriptor(); hls["playbackPath"] = format!("/live/streams/{CAP}/index.m3u8").into(); hls["mimeType"] = HLS.into();
    let decoded: Descriptor = serde_json::from_value(hls.clone()).unwrap();
    assert!(validate_descriptor(&decoded,"native-news",&["hls-fmp4-widevine"]).is_ok());
    assert_eq!(validate_descriptor(&decoded,"native-news",&["dash-widevine"]).unwrap_err().0,StatusCode::UPGRADE_REQUIRED);
    hls["drm"] = serde_json::Value::Null;
    assert!(validate_descriptor(&serde_json::from_value(hls).unwrap(),"native-news",&["hls-clear"]).is_ok());
}

#[tokio::test]
async fn native_catalog_failure_uses_native_message_without_prism_fallback() {
    let fixture = Fixture::new().await;
    *fixture.mock.failure.lock().unwrap() = Some(("sign_in_required",StatusCode::UNAUTHORIZED));
    let catalog: serde_json::Value = reqwest::Client::new().get(format!("{}/live/channels",fixture.base)).bearer_auth("outer-secret")
        .send().await.unwrap().json().await.unwrap();
    assert_eq!(catalog["channels"],serde_json::json!([]));
    assert!(catalog["message"].as_str().unwrap().contains("Sign in to Spectrum"));
    assert!(!catalog.to_string().contains("PRIVATE"));
    assert_eq!(fixture.mock.prism.load(Ordering::Relaxed),0);
}

#[tokio::test]
async fn native_catalog_guide_and_roku_tune_never_visit_prism_or_remux() {
    let fixture = Fixture::new().await;
    let client = reqwest::Client::new();
    assert_eq!(client.get(format!("{}/live/channels",fixture.base)).send().await.unwrap().status(),StatusCode::UNAUTHORIZED);
    let guide = client.get(format!("{}/live/guide",fixture.base)).bearer_auth("outer-secret").send().await.unwrap();
    assert_eq!(guide.status(),StatusCode::OK);
    assert_eq!(fixture.mock.catalogs.load(Ordering::Relaxed),1,"guide obtains the native metadata even before catalog browsing");
    let catalog: serde_json::Value = client.get(format!("{}/live/channels",fixture.base)).bearer_auth("outer-secret").send().await.unwrap().json().await.unwrap();
    assert_eq!(catalog["channels"][0],channel());
    let response = fixture.tune("hls-clear,dash-widevine").send().await.unwrap();
    assert_eq!(response.status(),StatusCode::OK,"no Roku remux manager exists in this fixture");
    assert_eq!(response.json::<serde_json::Value>().await.unwrap(),descriptor());
    assert!(fixture.bridge.0.sessions.lock().unwrap().items.is_empty());
    assert_eq!(fixture.mock.prism.load(Ordering::Relaxed),0);
    let requests = fixture.mock.requests.lock().unwrap();
    let (_,headers,body) = requests.iter().find(|(path,_,_)|path=="tune").unwrap();
    assert_eq!(headers[CLIENT],"roku");
    assert_eq!(headers[CAPABILITIES],"hls-clear,dash-widevine");
    assert_eq!(serde_json::from_slice::<serde_json::Value>(body).unwrap()["client"],"roku");
}

#[tokio::test]
async fn native_raw_media_certificate_and_license_are_capability_scoped_and_credentials_stay_local() {
    let fixture = Fixture::new().await;
    let client = reqwest::Client::new();
    let response = client.get(format!("{}/live/streams/{CAP}/index.mpd",fixture.base)).bearer_auth("not-forwarded").send().await.unwrap();
    assert_eq!(response.status(),StatusCode::OK);
    assert_eq!(response.headers()[header::CACHE_CONTROL],"no-store, private");
    assert!(!response.headers().contains_key(header::SET_COOKIE));
    assert_eq!(response.text().await.unwrap(),"<MPD><Period/></MPD>");
    let hls = client.get(format!("{}/live/streams/{CAP}/index.m3u8",fixture.base)).send().await.unwrap().text().await.unwrap();
    assert!(hls.contains("SAMPLE-AES") && hls.contains("skd://velvet/key_1?ContentId=raw%2Fvalue"));
    let segment = client.get(format!("{}/live/streams/{CAP}/captemplate_123-seg.m4s",fixture.base)).header(header::RANGE,"bytes=0-3").send().await.unwrap();
    assert_eq!(segment.status(),StatusCode::PARTIAL_CONTENT);
    assert_eq!(segment.headers()[header::CONTENT_RANGE],"bytes 0-3/8");
    assert_eq!(segment.bytes().await.unwrap().as_ref(),&[0,255,2,3]);
    let cert = client.get(format!("{}/live/cert/{CAP}",fixture.base)).send().await.unwrap();
    assert_eq!(cert.bytes().await.unwrap().as_ref(),&[0x30,0,255,0]);
    for query in ["","?key=opaque_key-1"] {
        let challenge = vec![0,255,1,0,128,2];
        let response = client.post(format!("{}/live/drm/{CAP}{query}",fixture.base)).bearer_auth("not-forwarded")
            .header(header::COOKIE,"not-forwarded").body(challenge.clone()).send().await.unwrap();
        assert_eq!(response.status(),StatusCode::OK);
        assert!(!response.headers().contains_key(header::SET_COOKIE));
        assert_eq!(response.bytes().await.unwrap().as_ref(),challenge.as_slice());
    }
    assert_eq!(fixture.mock.licenses.load(Ordering::Relaxed),2);
    assert_eq!(fixture.mock.prism.load(Ordering::Relaxed),0);
}

#[tokio::test]
async fn native_update_and_provider_errors_are_actionable_sanitized_and_never_fall_back() {
    let fixture = Fixture::new().await;
    let client = reqwest::Client::new();
    let old = client.post(format!("{}/live/tune",fixture.base)).bearer_auth("outer-secret")
        .json(&serde_json::json!({"channelId":"native-news","client":"roku"})).send().await.unwrap();
    assert_eq!(old.status(),StatusCode::UPGRADE_REQUIRED);
    assert_eq!(fixture.mock.tunes.load(Ordering::Relaxed),0);
    for (code,status) in [("sign_in_required",401),("channel_not_entitled",403),("home_network_required",403),("location_restricted",403),
        ("concurrency_limit",429),("native_update_required",426),("drm_unavailable",503),("source_unavailable",503),("unrecognized",502)] {
        *fixture.mock.failure.lock().unwrap() = Some((code,StatusCode::BAD_GATEWAY));
        let response = fixture.tune("dash-widevine").send().await.unwrap();
        assert_eq!(response.status().as_u16(),status);
        let body = response.text().await.unwrap();
        assert!(!body.contains("PRIVATE") && !body.contains("provider URL"));
        if code == "home_network_required" { assert!(body.contains("home network")); }
        if code == "channel_not_entitled" { assert!(body.contains("subscription")); }
    }
    *fixture.mock.failure.lock().unwrap() = Some(("home_network_required",StatusCode::FORBIDDEN));
    let response = client.post(format!("{}/live/drm/{CAP}",fixture.base)).body("challenge").send().await.unwrap();
    assert_eq!(response.status(),StatusCode::FORBIDDEN);
    assert!(response.text().await.unwrap().contains("home network"));
    assert_eq!(fixture.mock.prism.load(Ordering::Relaxed),0);
}

#[tokio::test]
async fn native_bad_descriptors_release_allocations_and_never_expose_provider_fields() {
    let fixture = Fixture::new().await;
    let mut variants = Vec::new();
    let mut value = descriptor(); value["playbackPath"] = format!("https://foreign/live/streams/{CAP}/index.mpd").into(); variants.push(value);
    let mut value = descriptor(); value["playbackPath"] = format!("/live/streams/{OTHER}/index.mpd").into(); variants.push(value);
    let mut value = descriptor(); value["drm"]["licensePath"] = format!("/live/drm/{OTHER}").into(); variants.push(value);
    let mut value = descriptor(); value["drm"]["licensePath"] = format!("/live/drm/{CAP}?url=https://foreign").into(); variants.push(value);
    let mut value = descriptor(); value["drm"]["scheme"] = "playready".into(); variants.push(value);
    let mut value = descriptor(); value["channel"]["id"] = "other".into(); variants.push(value);
    let mut value = descriptor(); value["drm"] = serde_json::json!({"scheme":"widevine"}); variants.push(value);
    for value in variants {
        *fixture.mock.descriptor.lock().unwrap() = Some(value);
        assert_eq!(fixture.tune("dash-widevine").send().await.unwrap().status(),StatusCode::BAD_GATEWAY);
    }
    assert_eq!(fixture.mock.ends.load(Ordering::Relaxed),7);
    *fixture.mock.descriptor.lock().unwrap() = None;
    assert_eq!(fixture.tune("hls-clear").send().await.unwrap().status(),StatusCode::UPGRADE_REQUIRED);
    assert_eq!(fixture.mock.ends.load(Ordering::Relaxed),8);
    let mut value = descriptor(); value["drm"]["headers"] = serde_json::json!({"Authorization":"PRIVATE"}); value["upstreamUrl"] = "https://PRIVATE".into();
    *fixture.mock.descriptor.lock().unwrap() = Some(value);
    let response = fixture.tune("dash-widevine").send().await.unwrap();
    assert_eq!(response.status(),StatusCode::OK);
    assert!(!response.text().await.unwrap().contains("PRIVATE"));
    let mut fairplay = descriptor(); fairplay["playbackPath"] = format!("/live/streams/{CAP}/index.m3u8").into(); fairplay["mimeType"] = HLS.into();
    fairplay["drm"] = serde_json::json!({"scheme":"fairplay","licensePath":format!("/live/drm/{CAP}"),"certificatePath":format!("/live/cert/{CAP}"),"contentIdMode":"spectrum-content-id"});
    *fixture.mock.descriptor.lock().unwrap() = Some(fairplay.clone());
    assert_eq!(fixture.tune("hls-fairplay").send().await.unwrap().status(),StatusCode::OK);
    fairplay["drm"]["certificatePath"] = format!("/live/cert/{OTHER}").into();
    *fixture.mock.descriptor.lock().unwrap() = Some(fairplay);
    assert_eq!(fixture.tune("hls-fairplay").send().await.unwrap().status(),StatusCode::BAD_GATEWAY);
}

#[tokio::test]
async fn native_proxy_rejects_query_escape_redirects_and_oversized_bytes() {
    let fixture = Fixture::new().await;
    let client = reqwest::Client::new();
    for path in [format!("/live/streams/{CAP}/index.mpd?url=http://foreign"),format!("/live/streams/{CAP}/bad%2Ffile.mpd"),
        format!("/live/streams/{CAP}/a..b.mpd"),"/live/streams/not-a-cap/index.mpd".into(),format!("/live/cert/{CAP}?url=http://foreign")] {
        assert!(!client.get(format!("{}{path}",fixture.base)).send().await.unwrap().status().is_success());
    }
    assert_eq!(fixture.mock.streams.load(Ordering::Relaxed),0);
    assert_eq!(fixture.mock.certificates.load(Ordering::Relaxed),0);
    for query in ["?key=../escape","?key=one&key=two","?url=http://foreign","?key=%61","?key="] {
        assert_eq!(client.post(format!("{}/live/drm/{CAP}{query}",fixture.base)).body("bytes").send().await.unwrap().status(),StatusCode::BAD_REQUEST);
    }
    assert_eq!(fixture.mock.licenses.load(Ordering::Relaxed),0);
    assert_eq!(client.post(format!("{}/live/drm/{CAP}",fixture.base)).body(vec![1;MAX_LICENSE+1]).send().await.unwrap().status(),StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(fixture.mock.licenses.load(Ordering::Relaxed),0);
    assert_eq!(client.post(format!("{}/live/drm/{CAP}",fixture.base)).body("oversized-response").send().await.unwrap().status(),StatusCode::BAD_GATEWAY);
    for key in ["large.mpd","large.m4s","redirect.mpd"] {
        assert_eq!(client.get(format!("{}/live/streams/{CAP}/{key}",fixture.base)).send().await.unwrap().status(),StatusCode::BAD_GATEWAY);
    }
    assert_eq!(fixture.mock.prism.load(Ordering::Relaxed),0);
}

#[tokio::test]
async fn native_unknown_caps_forward_but_legacy_browser_sessions_keep_precedence() {
    let fixture = Fixture::new().await;
    let client = reqwest::Client::new();
    let response = client.get(format!("{}/live/streams/{OTHER}/index.mpd",fixture.base)).send().await.unwrap();
    assert_eq!(response.status(),StatusCode::NOT_FOUND);
    assert!(!response.text().await.unwrap().contains("PRIVATE"));
    assert_eq!(fixture.mock.streams.load(Ordering::Relaxed),1);
    let entry = Entry { channel:serde_json::from_value(channel()).unwrap(),url:fixture.bridge.0.origin.join("/hls/legacy/stream.m3u8").unwrap() };
    let legacy = fixture.bridge.0.sessions.lock().unwrap().create(&entry,Instant::now()).unwrap();
    let response = client.get(format!("{}/live/streams/{legacy}/index.m3u8",fixture.base)).send().await.unwrap();
    assert_eq!(response.status(),StatusCode::OK);
    assert!(response.text().await.unwrap().contains(&format!("/live/streams/{legacy}/")));
    assert_eq!(fixture.mock.streams.load(Ordering::Relaxed),1);
    assert_eq!(fixture.mock.prism.load(Ordering::Relaxed),1);
    assert_eq!(client.delete(format!("{}/live/sessions/{legacy}",fixture.base)).bearer_auth("outer-secret").send().await.unwrap().status(),StatusCode::NO_CONTENT);
    assert_eq!(fixture.mock.ends.load(Ordering::Relaxed),0);
    assert_eq!(client.delete(format!("{}/live/sessions/{OTHER}",fixture.base)).bearer_auth("outer-secret").send().await.unwrap().status(),StatusCode::NO_CONTENT);
    assert_eq!(fixture.mock.ends.load(Ordering::Relaxed),1);
}

#[tokio::test]
async fn native_unknown_session_deletion_shares_the_request_budget() {
    let fixture = Fixture::new().await;
    let permits = fixture.bridge.0.requests.clone().acquire_many_owned(64).await.unwrap();
    let request = || reqwest::Client::new().delete(format!("{}/live/sessions/{OTHER}",fixture.base)).bearer_auth("outer-secret");
    assert_eq!(request().send().await.unwrap().status(),StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(fixture.mock.ends.load(Ordering::Relaxed),0);
    drop(permits);
    assert_eq!(request().send().await.unwrap().status(),StatusCode::NO_CONTENT);
    assert_eq!(fixture.mock.ends.load(Ordering::Relaxed),1);
}
