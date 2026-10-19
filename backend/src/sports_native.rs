//! Native-device adaptation through the configured browser bridge. The client
//! supplies catalog identifiers only; no client URL or origin reaches this path.
use axum::http::StatusCode;
use reqwest::{Client, Url};
use std::time::Duration;

pub(crate) type BridgeResult<T> = Result<T, (StatusCode, &'static str)>;
const UNAVAILABLE: (StatusCode, &str) = (StatusCode::BAD_GATEWAY, "Sports browser could not start this source; choose another source or retry");

pub(crate) fn capture_url(origin: &Url, embed: &str) -> BridgeResult<Url> {
    if !crate::sports::allowed_embed(embed) {
        return Err((StatusCode::BAD_REQUEST, "Invalid sports source"));
    }
    let mut url = origin.join("/play").map_err(|_| UNAVAILABLE)?;
    url.query_pairs_mut()
        .append_pair("url", embed)
        .append_pair("profile", "embeddedPlayer");
    Ok(url)
}

pub(crate) fn playlist_redirect(origin: &Url, location: &str) -> BridgeResult<Url> {
    if location.contains(['%', '\\', '?', '#']) || location.contains("..") {
        return Err(UNAVAILABLE);
    }
    let url = origin.join(location).map_err(|_| UNAVAILABLE)?;
    let key = url.path().strip_prefix("/hls/play-").and_then(|p| p.strip_suffix("/stream.m3u8"));
    if url.origin() != origin.origin() || !url.username().is_empty() || url.password().is_some()
        || !key.is_some_and(|k| k.len() == 8 && k.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())) {
        return Err(UNAVAILABLE);
    }
    Ok(url)
}

pub(crate) async fn start(http: &Client, origin: &Url, embed: &str) -> BridgeResult<Url> {
    let response = http.get(capture_url(origin, embed)?)
        .timeout(Duration::from_secs(70)).send().await.map_err(|_| UNAVAILABLE)?;
    if response.status() == StatusCode::SERVICE_UNAVAILABLE || response.status() == StatusCode::TOO_MANY_REQUESTS {
        return Err((StatusCode::SERVICE_UNAVAILABLE, "Sports browser is busy; close another live stream and retry"));
    }
    if response.status() != StatusCode::FOUND { return Err(UNAVAILABLE); }
    let location = response.headers().get(reqwest::header::LOCATION)
        .and_then(|v| v.to_str().ok()).ok_or(UNAVAILABLE)?;
    playlist_redirect(origin, location)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn origin() -> Url { Url::parse("http://bridge:5589").unwrap() }
    #[test]
    fn capture_accepts_only_catalog_embed_hosts() {
        let url = capture_url(&origin(), "https://embed.st/embed/admin/event/1").unwrap();
        assert_eq!(url.origin(), origin().origin());
        assert_eq!(url.path(), "/play");
        assert!(url.query_pairs().any(|(k,v)| k == "profile" && v == "embeddedPlayer"));
        for input in ["http://127.0.0.1/admin", "https://embed.st.evil/embed/a", "https://embed.st/embed/../admin", "https://embed.st/embed/a?url=http://localhost"] {
            assert!(capture_url(&origin(), input).is_err(), "accepted {input}");
        }
    }
    #[test]
    fn redirect_is_confined_to_exact_synthetic_capture() {
        assert!(playlist_redirect(&origin(), "/hls/play-0123abcd/stream.m3u8").is_ok());
        assert!(playlist_redirect(&origin(), "http://bridge:5589/hls/play-0123abcd/stream.m3u8").is_ok());
        for input in ["https://elsewhere/hls/play-0123abcd/stream.m3u8", "/admin", "/hls/play-0123ABCD/stream.m3u8", "/hls/play-0123abcd/stream.m3u8?url=admin", "/hls/play-0123abcd/../stream.m3u8", "/hls/play-0123abcd%2f/stream.m3u8", "//user@bridge:5589/hls/play-0123abcd/stream.m3u8"] {
            assert!(playlist_redirect(&origin(), input).is_err(), "accepted {input}");
        }
    }
    #[tokio::test]
    async fn native_capture_uses_existing_revocable_scoped_proxy() {
        use axum::{Router, routing::get, response::Redirect};
        let upstream = Router::new()
            .route("/play",get(|| async { Redirect::temporary("/hls/play-0123abcd/stream.m3u8") }))
            .route("/hls/play-0123abcd/stream.m3u8",get(|| async { "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment1.ts\n" }))
            .route("/hls/play-0123abcd/segment1.ts",get(|| async { b"captured-video".to_vec() }));
        // PrismCast's /play contract uses 302, not 307.
        let upstream = upstream.route("/start",get(|| async { (StatusCode::FOUND,[("location","/hls/play-0123abcd/stream.m3u8")]) }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_base = format!("http://{}",listener.local_addr().unwrap());
        let upstream_task = tokio::spawn(async move { axum::serve(listener,upstream).await.unwrap() });
        let no_redirect = Client::builder().redirect(reqwest::redirect::Policy::none()).build().unwrap();
        assert!(start(&no_redirect,&Url::parse(&upstream_base).unwrap(),"https://embed.st/embed/admin/event/1").await.is_err(),"unexpected redirect status must fail");
        upstream_task.abort();

        let upstream = Router::new()
            .route("/play",get(|| async { (StatusCode::FOUND,[("location","/hls/play-0123abcd/stream.m3u8")]) }))
            .route("/hls/play-0123abcd/stream.m3u8",get(|| async { "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment1.ts\n" }))
            .route("/hls/play-0123abcd/segment1.ts",get(|| async { b"captured-video".to_vec() }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let upstream_base = format!("http://{}",listener.local_addr().unwrap());
        let upstream_task = tokio::spawn(async move { axum::serve(listener,upstream).await.unwrap() });
        let cfg = crate::config::LiveTv { enabled:true, upstream_url:upstream_base, guide_enabled:false, ..Default::default() };
        let (router,bridge) = crate::live::router_with_bridge(cfg,String::new()).unwrap();
        let tuned = bridge.tune_sports("https://embed.st/embed/admin/event/1","event-1","Example game",None).await.unwrap();
        assert_eq!(tuned["channel"]["name"],"Example game");
        assert_eq!(tuned["canSeek"],false);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}",listener.local_addr().unwrap());
        let app_task = tokio::spawn(async move { axum::serve(listener,router).await.unwrap() });
        let client = Client::new();
        let path = tuned["playbackPath"].as_str().unwrap();
        let manifest = client.get(format!("{base}{path}")).send().await.unwrap().text().await.unwrap();
        assert!(!manifest.contains("/hls/"));
        let resource = manifest.lines().find(|line| line.starts_with("/live/")).unwrap();
        assert_eq!(client.get(format!("{base}{resource}")).send().await.unwrap().bytes().await.unwrap().as_ref(),b"captured-video");
        client.delete(format!("{base}/live/sessions/{}",tuned["sessionId"].as_str().unwrap())).send().await.unwrap();
        assert_eq!(client.get(format!("{base}{path}")).send().await.unwrap().status(),StatusCode::NOT_FOUND);
        app_task.abort(); upstream_task.abort();
    }

}
