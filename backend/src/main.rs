//! velvet-backend — Velvet's unified self-hosted backend in one binary:
//!   • usenet streaming: NNTP client + on-demand range server (no download queue,
//!     no whole-file grab, no delete-on-missing — the streaming-first rewrite of
//!     nzbdav that never wedges on a bad NZB).
//!   • Stremio-protocol resolver: IMDb → NZB list, availability-checked & sorted
//!     (the rewrite of usenet-streamer).
//!   • watch-state sync: profiles / progress / watched / mylist / handoffs (the
//!     former velvet-sync).
//!   • skip-intro detection worker (the former velvet-intro).
//!
//! Built streaming-first: every request is independent and fails fast.

mod admin;
mod admin_report;
mod capacity;
mod archive;
mod audio;
mod roku_audio;
mod roku_live;
mod catalog;
mod catalog_browse;
mod metadata;
mod saved_categories;
mod category_queue;
mod categories;
mod config;
mod db;
mod handoff;
mod intro;
mod live;
mod epg;
mod sports;
mod sports_native;
mod nntp;
mod nzb;
mod pool;
mod release;
mod repair;
mod resolver;
mod sevenzip;
mod stream;
mod sync;
mod warm;
mod yenc;

use anyhow::Context;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "velvet_backend=info".into()),
        )
        .init();
    // Pin one rustls crypto provider so both our NNTP TLS and reqwest agree.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mode = std::env::args().nth(1).unwrap_or_default();
    match mode.as_str() {
        "selftest" => selftest().await,
        "streamtest" => streamtest().await,
        "healthtest" => healthtest().await,
        "statprobe" => statprobe().await,
        "seektest" => seektest().await,
        "sniff" => sniff().await,
        "rartest" => rartest().await,
        "scan7z" => scan7z().await,
        "sztest" => sztest().await,
        "catalogtest" => {
            let row = catalog::load_halloween(&reqwest::Client::new()).await;
            anyhow::ensure!(row.items.len() == 29, "expected 29 verified Halloween episodes, got {}", row.items.len());
            println!("{}", serde_json::to_string_pretty(&row)?);
            Ok(())
        }
        "guidetest" => epg::diagnostic(std::env::args().skip(2).collect()).await,
        "serve" | "" => serve().await,
        other => {
            anyhow::bail!("unknown mode '{other}' — use: serve | selftest | streamtest | healthtest")
        }
    }
}

/// The real entrypoint: one process serving usenet streaming + Stremio resolver +
/// watch-state sync + the skip-intro worker. Replaces nzbdav + usenet-streamer +
/// velvet-sync + velvet-intro with a single binary.
async fn serve() -> anyhow::Result<()> {
    let cfg = config::Config::load().context("load velvet.toml / env")?;
    anyhow::ensure!(!cfg.providers.is_empty(), "no [[providers]] configured");
    if resolver::tmdb_key().is_empty() {
        tracing::warn!("VELVET_TMDB_KEY is unset; metadata browsing and title-based resolver fallback are unavailable");
    }

    let http = reqwest::Client::builder()
        .user_agent("velvet-backend/0.1")
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    // DB + schema (sync owns the tables; intro shares them).
    let db = db::open(&cfg.db_path).context("open db")?;
    {
        let conn = db.lock().unwrap();
        sync::migrate(&conn).context("migrate")?;
        saved_categories::migrate(&conn).context("migrate saved categories")?;
    }

    let pool = pool::Pool::new_verified(&cfg.providers, cfg.repair.enabled);
    let names: Vec<&str> = cfg
        .providers
        .iter()
        .map(|p| if p.name.is_empty() { p.host.as_str() } else { p.name.as_str() })
        .collect();
    tracing::info!(
        "providers: {} ({} pooled connections)",
        names.join(", "),
        pool.total_capacity(),
    );

    let stream_state = stream::StreamState::with_recovery(pool.clone(), http.clone(), db.clone(), cfg.repair.clone(), cfg.stream_buffer.clone(), format!("http://127.0.0.1:{}", cfg.port));
    let public_base = cfg
        .public_base_url
        .clone()
        .unwrap_or_else(|| format!("http://localhost:{}", cfg.port));
    let resolver_state = resolver::ResolverState {
        stream: stream_state.clone(),
        indexers: std::sync::Arc::new(cfg.indexers.clone()),
        public_base: public_base.clone(),
    };

    // Skip-intro worker: fingerprints played episodes in the background.
    let data_dir = std::path::Path::new(&cfg.db_path)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| ".".into());
    tokio::spawn(intro::run(db.clone(), data_dir, 60));

    // Pre-warm worker: report_play → next-episode warm; periodic sweep of the
    // progress table re-validates + re-warms everything in progress.
    let (warm_tx, warm_rx) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(warm::run_worker(
        warm_rx,
        http.clone(),
        std::sync::Arc::new(cfg.indexers.clone()),
        stream_state.clone(),
        db.clone(),
    ));

    let (live_router, sports_bridge) = live::router_with_roku_bridge(
        cfg.live_tv.clone(), cfg.token.clone(), format!("http://127.0.0.1:{}", cfg.port),
    )?;
    let app = axum::Router::new()
        .merge(admin::router(&cfg, pool.clone(), db.clone())?)
        .merge(catalog::router(http.clone(), cfg.token.clone(), cfg.category_ai.clone(), db.clone()))
        .merge(metadata::router(cfg.token.clone())?)
        .merge(live_router)
        .merge(sports::router_with_bridge(cfg.live_sports.clone(), cfg.token.clone(), sports_bridge)?)
        .merge(sync::router(db.clone(), cfg.token.clone(), Some(warm_tx), stream_state.clone(), public_base))
        .merge(resolver::router(resolver_state))
        .merge(audio::router(stream_state.clone(), format!("http://127.0.0.1:{}", cfg.port))?)
        .merge(roku_audio::router(stream_state.clone(), format!("http://127.0.0.1:{}", cfg.port))?)
        .merge(stream::router(stream_state));

    let addr = format!("{}:{}", cfg.bind, cfg.port);
    let listener = tokio::net::TcpListener::bind(&addr).await.context("bind")?;
    tracing::info!("velvet-backend {} listening on {addr}", env!("CARGO_PKG_VERSION"));
    axum::serve(listener, app).await?;
    Ok(())
}

/// In-memory DB for diagnostic modes (bad-release ledger etc. — discarded on exit).
fn test_db() -> anyhow::Result<db::Db> {
    let d = db::open(":memory:")?;
    {
        let conn = d.lock().unwrap();
        sync::migrate(&conn)?;
    }
    Ok(d)
}

/// Resolve a widely-seeded 1080p test title to a (title, nzb_url).
async fn resolve_test_nzb(
    http: &reqwest::Client,
    cfg: &config::Config,
) -> anyhow::Result<(String, String)> {
    let imdb = "1375666"; // Inception
    let mut results = Vec::new();
    for ix in &cfg.indexers {
        if let Ok(mut r) = resolver::search_movie(http, ix, imdb).await {
            if !r.is_empty() {
                results.append(&mut r);
                break;
            }
        }
    }
    let pick = results
        .into_iter()
        .filter(|r| {
            let t = r.title.to_lowercase();
            t.contains("1080p") && !t.contains("2160") && !t.contains("remux")
                && !t.contains("sample") && r.size > 2_000_000_000
        })
        .min_by_key(|r| r.size)
        .context("no suitable NZB")?;
    Ok((pick.title, pick.nzb_url))
}

/// Live range-server test: register a real NZB, start the server, and pull byte
/// ranges — the start of the file (must be Matroska) and a mid-file seek.
async fn streamtest() -> anyhow::Result<()> {
    let cfg = config::Config::load().context("load velvet.toml")?;
    let http = reqwest::Client::builder()
        .user_agent("velvet-backend/0.1")
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    let (title, nzb_url) = resolve_test_nzb(&http, &cfg).await?;
    tracing::info!("stream target: {title}");

    let pool = pool::Pool::new(&cfg.providers);
    tracing::info!("pool: {} providers, {} total connections", cfg.providers.len(), pool.total_capacity());
    let state = stream::StreamState::new(pool, http.clone(), test_db()?);
    let id = state.register(&nzb_url).await;

    // Serve on a loopback port.
    let app = stream::router(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:8791").await?;
    let addr = listener.local_addr()?;
    tokio::spawn(async move { axum::serve(listener, app).await.ok(); });
    tokio::time::sleep(std::time::Duration::from_millis(150)).await;
    let base = format!("http://{addr}/stream/{id}");

    // 1. Start of file — 1 MiB. Must decode to Matroska.
    let t0 = std::time::Instant::now();
    let head = http.get(&base).header("Range", "bytes=0-1048575").send().await?;
    tracing::info!("HEAD range status {} content-range {:?}", head.status(),
        head.headers().get("content-range").and_then(|v| v.to_str().ok()));
    let head_bytes = head.bytes().await?;
    let magic: String = head_bytes[..16.min(head_bytes.len())].iter().map(|b| format!("{b:02x} ")).collect();
    tracing::info!("first MiB: {} bytes in {:?}, magic {}", head_bytes.len(), t0.elapsed(), magic);
    let is_mkv = head_bytes.len() >= 4 && head_bytes[..4] == [0x1A, 0x45, 0xDF, 0xA3];

    // 2. Mid-file seek — 64 KiB starting ~700 MB in (proves range→segment math).
    let seek_start = 700_000_000u64;
    let t1 = std::time::Instant::now();
    let mid = http.get(&base)
        .header("Range", format!("bytes={}-{}", seek_start, seek_start + 65535))
        .send().await?;
    let cr = mid.headers().get("content-range").and_then(|v| v.to_str().ok()).map(str::to_string);
    let mid_bytes = mid.bytes().await?;
    tracing::info!("mid seek @{}MB: {} bytes in {:?}, content-range {:?}",
        seek_start / 1_000_000, mid_bytes.len(), t1.elapsed(), cr);

    if !is_mkv {
        anyhow::bail!("start-of-file range did not decode to Matroska");
    }
    if mid_bytes.len() != 65536 {
        anyhow::bail!("mid-file seek returned {} bytes, expected 65536", mid_bytes.len());
    }
    tracing::info!("✅ RANGE SERVER OK: real Matroska at byte 0, exact 64KiB at a mid-file seek");
    Ok(())
}

/// Validate RAR5 store-mode streaming against the real PHOENiX release: build the
/// extents, then read the media file at offset 0 (must be Matroska) and check that
/// mid-file reads assemble across volumes correctly.
async fn rartest() -> anyhow::Result<()> {
    let cfg = config::Config::load()?;
    let http = reqwest::Client::builder().user_agent("velvet/0.1")
        .timeout(std::time::Duration::from_secs(60)).build()?;
    let imdb = std::env::var("VELVET_PROBE_IMDB").context("set VELVET_PROBE_IMDB to an IMDb numeric identifier")?;
    let season: u32 = std::env::var("VELVET_PROBE_SEASON").context("set VELVET_PROBE_SEASON")?.parse()?;
    let episode: u32 = std::env::var("VELVET_PROBE_EPISODE").context("set VELVET_PROBE_EPISODE")?.parse()?;
    let mut results = Vec::new();
    for ix in &cfg.indexers {
        if let Ok(mut r) = resolver::search_series(&http, ix, &imdb, season, episode).await { results.append(&mut r); }
    }
    let pool = pool::Pool::new(&cfg.providers);

    // Find a multi-volume RAR5 release.
    let mut chosen = None;
    for r in &results {
        let nzb = match resolver::download_nzb(&http, &r.nzb_url).await { Ok(b) => b, Err(_) => continue };
        let parsed = match nzb::parse(&nzb) { Ok(p) => p, Err(_) => continue };
        let vols = archive::rar_volumes(&parsed.files);
        if vols.len() >= 2 { chosen = Some((r.title.clone(), vols)); break; }
    }
    let (title, vols) = chosen.context("no multi-volume RAR release found")?;
    tracing::info!("RAR release: {title} ({} volumes)", vols.len());

    let (extents, total) = archive::build_extents(&pool, &vols).await?;
    tracing::info!("built {} extents, media total = {} bytes ({:.2} GB)", extents.len(), total, total as f64/1e9);

    // Read the start of the media file — must be Matroska.
    let head = archive::read_media(&pool, &extents, 0, 65536).await;
    let magic: String = head[..16.min(head.len())].iter().map(|b| format!("{b:02x} ")).collect();
    let container = detect_container(&head);
    tracing::info!("media@0: {magic} => {container}");
    let is_video = container != "unknown";

    // Read a mid-file range that must cross a volume boundary, and one near the end.
    let mid = archive::read_media(&pool, &extents, total/2, 32768).await;
    let tail = archive::read_media(&pool, &extents, total.saturating_sub(16384), 16384).await;
    tracing::info!("media@50%: {} bytes; media@end: {} bytes", mid.len(), tail.len());

    if !is_video { anyhow::bail!("RAR media did not start with a known container — parser wrong"); }
    if mid.len() != 32768 || tail.len() != 16384 { anyhow::bail!("cross-volume read short"); }
    tracing::info!("✅ RAR5 STORE-MODE STREAMS: real {container} at byte 0, cross-volume reads assemble");
    Ok(())
}

/// Targeted 7z validation: `sztest <nzb_url>` — download that NZB, build the
/// store-mode extent, and read media@0 to confirm a real container at byte 0.
async fn sztest() -> anyhow::Result<()> {
    let cfg = config::Config::load()?;
    let http = reqwest::Client::builder().user_agent("velvet/0.1")
        .timeout(std::time::Duration::from_secs(60)).build()?;
    let nzb_url = std::env::args().nth(2).context("usage: sztest <nzb_url>")?;
    let nzb = resolver::download_nzb(&http, &nzb_url).await?;
    let parsed = nzb::parse(&nzb)?;
    let pool = pool::Pool::new(&cfg.providers);
    let (extents, total) = sevenzip::build_extents(&pool, &parsed.files).await?;
    tracing::info!("built {} extent(s), media total {} bytes ({:.2} GB)", extents.len(), total, total as f64/1e9);
    let head = archive::read_media(&pool, &extents, 0, 65536).await;
    let container = detect_container(&head);
    let magic: String = head[..16.min(head.len())].iter().map(|b| format!("{b:02x} ")).collect();
    tracing::info!("media@0: {magic} => {container}");
    let mid = archive::read_media(&pool, &extents, total/2, 32768).await;
    let tail = archive::read_media(&pool, &extents, total.saturating_sub(16384), 16384).await;
    tracing::info!("media@50%: {} bytes; media@end: {} bytes", mid.len(), tail.len());
    if container == "unknown" { anyhow::bail!("media@0 not a known container — 7z offsets wrong"); }
    tracing::info!("✅ 7z STORE-MODE STREAMS: real {container} at byte 0");
    Ok(())
}

/// Recon for 7-Zip coverage: scan many real releases for single-file `.7z`
/// posts, and for each report whether its header is plain (`kHeader`) or
/// LZMA-encoded (`kEncodedHeader`), plus the data coder — the two facts that
/// decide whether store-mode streaming is possible. If a plain store-mode one
/// turns up, validate it end-to-end (build the extent, read media@0).
async fn scan7z() -> anyhow::Result<()> {
    let cfg = config::Config::load()?;
    let http = reqwest::Client::builder().user_agent("velvet/0.1")
        .timeout(std::time::Duration::from_secs(60)).build()?;

    // Movie imdbs to scan (digits only). Extra CLI args override this list.
    let default_movies = [
        "1375666", "0133093", "0816692", "0110912", "0468569", "0094625",
        "0245429", "0083658", "0078748", "0084787", "1160419", "0088247",
        "0087332", "0107290", "0120737", "15398776",
    ];
    let arg_movies: Vec<String> = std::env::args().skip(2).collect();
    let movies: Vec<&str> = if arg_movies.is_empty() {
        default_movies.iter().copied().filter(|s| s.chars().all(|c| c.is_ascii_digit())).collect()
    } else {
        arg_movies.iter().map(String::as_str).collect()
    };

    // Gather releases from movie lookups + a couple of series episodes.
    let mut results: Vec<resolver::NzbResult> = Vec::new();
    for m in &movies {
        for ix in &cfg.indexers {
            if let Ok(r) = resolver::search_movie(&http, ix, m).await { results.extend(r); }
        }
    }
    for (imdb, s, e) in [("182576", 1, 5), ("0182576", 1, 1), ("0944947", 1, 1)] {
        for ix in &cfg.indexers {
            if let Ok(r) = resolver::search_series(&http, ix, imdb, s, e).await { results.extend(r); }
        }
    }
    tracing::info!("scan7z: {} releases gathered; scanning NZBs for single-file .7z…", results.len());

    let pool = pool::Pool::new(&cfg.providers);
    let mut checked = 0usize;
    let mut seven_found = 0usize;
    let (mut n_raw, mut n_rar, mut n_zip, mut n_other) = (0usize, 0usize, 0usize, 0usize);
    let mut plain_store: Option<(String, Vec<nzb::NzbFile>)> = None;

    for r in &results {
        if checked >= 300 { break; }
        let nzb = match resolver::download_nzb(&http, &r.nzb_url).await { Ok(b) => b, Err(_) => continue };
        let parsed = match nzb::parse(&nzb) { Ok(p) => p, Err(_) => continue };
        checked += 1;
        // Tally the release's packaging so we know the real landscape.
        let subj = |pred: fn(&str) -> bool| parsed.files.iter().any(|f| !f.segments.is_empty() && pred(&f.subject.to_ascii_lowercase()));
        let has_7z = subj(|s| s.contains(".7z"));
        let has_rar = subj(|s| s.contains(".rar") || (0..s.len().saturating_sub(3)).any(|i| { let b=s.as_bytes(); b[i]==b'.'&&b[i+1]==b'r'&&b[i+2].is_ascii_digit()&&b[i+3].is_ascii_digit() }));
        let has_zip = subj(|s| s.contains(".zip"));
        let has_raw = parsed.files.iter().any(|f| f.is_media_candidate() && !f.segments.is_empty());
        if has_7z { /* counted below */ }
        else if has_rar { n_rar += 1; }
        else if has_zip { n_zip += 1; }
        else if has_raw { n_raw += 1; }
        else { n_other += 1; }
        if !has_7z { continue; }
        seven_found += 1;

        match sevenzip::seven_zip_file(&parsed.files) {
            Ok(file) => {
                let group = file.groups.first().cloned().unwrap_or_default();
                let seg0 = &file.segments[0];
                // Fetch seg0: signature header + uniform part size.
                let (head0, part_size) = match pool.fetch(&group, &seg0.message_id).await {
                    pool::Fetched::Found(raw) => match yenc::decode(&raw) {
                        Ok(d) => { let n = d.data.len() as u64; (d.data, n) }
                        Err(_) => { tracing::warn!("  {} — seg0 decode failed", r.title); continue; }
                    },
                    _ => { tracing::warn!("  {} — seg0 missing on all providers", r.title); continue; }
                };
                if !head0.starts_with(sevenzip::SZ_SIG) {
                    tracing::info!("  {} — .7z present but first file isn't the 7z (magic mismatch)", r.title);
                    continue;
                }
                // Read next header and classify.
                let no = u64::from_le_bytes(head0[12..20].try_into().unwrap());
                let ns = u64::from_le_bytes(head0[20..28].try_into().unwrap());
                let hdr = archive::read_volume_range(&pool, &group, &file.segments, part_size, 32 + no, ns).await;
                let kind = hdr.first().map(|b| *b).unwrap_or(0);
                tracing::info!("  7z: {}  ({:.2} GB, {} segs) next_hdr @+{} size {} first_byte 0x{:02x}",
                    r.title, r.size as f64/1e9, file.segments.len(), no, ns, kind);
                match sevenzip::parse_next_header(&hdr) {
                    Ok(layout) => {
                        tracing::info!("     => PLAIN store-mode: coder={:?} pack_pos={} pack_size={}",
                            layout.coder_id, layout.pack_pos, layout.pack_size);
                        if plain_store.is_none() {
                            plain_store = Some((r.title.clone(), parsed.files.clone()));
                        }
                    }
                    Err(e) => tracing::info!("     => NOT streamable: {e}"),
                }
            }
            Err(e) => tracing::info!("  {} — {}", r.title, e),
        }
    }

    tracing::info!("scan7z: checked {checked} NZBs — packaging: raw={n_raw} rar={n_rar} 7z={seven_found} zip={n_zip} other={n_other}");

    // If we found a plain store-mode 7z, validate the whole path.
    if let Some((title, files)) = plain_store {
        tracing::info!("validating plain store-mode 7z end-to-end: {title}");
        let (extents, total) = sevenzip::build_extents(&pool, &files).await?;
        let head = archive::read_media(&pool, &extents, 0, 65536).await;
        let container = detect_container(&head);
        let magic: String = head[..16.min(head.len())].iter().map(|b| format!("{b:02x} ")).collect();
        tracing::info!("  media total {:.2} GB; media@0: {magic} => {container}", total as f64/1e9);
        if container == "unknown" {
            anyhow::bail!("7z store-mode parsed but media@0 is not a known container — offsets wrong");
        }
        tracing::info!("✅ 7z STORE-MODE STREAMS: real {container} at byte 0");
    } else {
        tracing::info!("no plain store-mode 7z found in this scan (all were encoded-header or compressed)");
    }
    Ok(())
}

/// Recon: for archived FG releases, fetch the first bytes of the first volume and
/// report the container format + volume file list, so we build the right parser.
async fn sniff() -> anyhow::Result<()> {
    let cfg = config::Config::load()?;
    let http = reqwest::Client::builder().user_agent("velvet/0.1")
        .timeout(std::time::Duration::from_secs(60)).build()?;
    let imdb = std::env::var("VELVET_PROBE_IMDB").context("set VELVET_PROBE_IMDB to an IMDb numeric identifier")?;
    let season: u32 = std::env::var("VELVET_PROBE_SEASON").context("set VELVET_PROBE_SEASON")?.parse()?;
    let episode: u32 = std::env::var("VELVET_PROBE_EPISODE").context("set VELVET_PROBE_EPISODE")?.parse()?;
    let mut results = Vec::new();
    for ix in &cfg.indexers {
        if let Ok(mut r) = resolver::search_series(&http, ix, &imdb, season, episode).await { results.append(&mut r); }
    }
    results.sort_by_key(|r| std::cmp::Reverse(r.size));
    let pool = pool::Pool::new(&cfg.providers);

    let mut shown = 0;
    for r in results.iter().filter(|r| !r.title.to_lowercase().contains("sample")) {
        let nzb = match resolver::download_nzb(&http, &r.nzb_url).await { Ok(b) => b, Err(_) => continue };
        let parsed = match nzb::parse(&nzb) { Ok(p) => p, Err(_) => continue };
        // List the files in this release, flagged by kind.
        let mut vols: Vec<&nzb::NzbFile> = parsed.files.iter()
            .filter(|f| f.is_archive() && !f.segments.is_empty()).collect();
        vols.sort_by(|a, b| a.subject.cmp(&b.subject));
        let raw = parsed.files.iter().any(|f| f.is_media_candidate() && !f.segments.is_empty());
        tracing::info!("release: {}  (raw_media={}, archive_vols={})", r.title, raw, vols.len());
        if raw || vols.is_empty() { continue; }
        // Fetch the first volume's first segment, decode, show magic + header.
        let v0 = &vols[0];
        tracing::info!("  vol0 subject: {}", v0.subject);
        match pool.fetch(v0.groups.first().map(String::as_str).unwrap_or(""), &v0.segments[0].message_id).await {
            pool::Fetched::Found(raw) => {
                let d = yenc::decode(&raw)?;
                let head = &d.data[..64.min(d.data.len())];
                let hex: String = head.iter().take(16).map(|b| format!("{b:02x} ")).collect();
                let fmt = if d.data.starts_with(b"Rar!\x1a\x07\x01\x00") { "RAR5" }
                    else if d.data.starts_with(b"Rar!\x1a\x07\x00") { "RAR4" }
                    else if d.data.starts_with(&[0x37,0x7a,0xbc,0xaf,0x27,0x1c]) { "7-Zip" }
                    else if d.data.starts_with(b"PK\x03\x04") { "ZIP" }
                    else { "unknown" };
                tracing::info!("  magic: {hex} => {fmt}");
                let ascii: String = head.iter().map(|&b| if (0x20..0x7f).contains(&b) { b as char } else { '.' }).collect();
                tracing::info!("  ascii: {ascii}");
            }
            _ => tracing::info!("  vol0 seg0 unavailable"),
        }
        shown += 1;
        if shown >= 4 { break; }
    }
    Ok(())
}

/// Prove seek byte-accuracy: serve a mid-file range through the real range server,
/// and independently assemble the SAME bytes straight from the segments' =ypart
/// offsets. If they match, seeks are aligned.
async fn seektest() -> anyhow::Result<()> {
    let cfg = config::Config::load()?;
    let http = reqwest::Client::builder().user_agent("velvet/0.1")
        .timeout(std::time::Duration::from_secs(60)).build()?;
    // Resolve FG S1E5 and take the first candidate that's fully present.
    let imdb = std::env::var("VELVET_PROBE_IMDB").context("set VELVET_PROBE_IMDB to an IMDb numeric identifier")?;
    let season: u32 = std::env::var("VELVET_PROBE_SEASON").context("set VELVET_PROBE_SEASON")?.parse()?;
    let episode: u32 = std::env::var("VELVET_PROBE_EPISODE").context("set VELVET_PROBE_EPISODE")?.parse()?;
    let mut results = Vec::new();
    for ix in &cfg.indexers {
        if let Ok(mut r) = resolver::search_series(&http, ix, &imdb, season, episode).await { results.append(&mut r); }
    }
    results.sort_by_key(|r| std::cmp::Reverse(r.size));
    let pool = pool::Pool::new(&cfg.providers);

    // Find a complete release + its parsed file.
    let mut chosen = None;
    for r in results.iter().filter(|r| !r.title.to_lowercase().contains("sample")).take(6) {
        let nzb = match resolver::download_nzb(&http, &r.nzb_url).await { Ok(b) => b, Err(_) => continue };
        let parsed = match nzb::parse(&nzb) { Ok(p) => p, Err(_) => continue };
        let file = match parsed.primary_file() { Some(f) => f.clone(), None => continue };
        let ids: Vec<String> = file.segments.iter().map(|s| s.message_id.clone()).collect();
        let h = pool.completeness(&ids).await;
        tracing::info!("candidate {} — {}/{} present", r.title, h.present, h.total);
        if h.is_complete() { chosen = Some((r.nzb_url.clone(), file)); break; }
    }
    let (nzb_url, file) = chosen.context("no complete FG release on this provider")?;
    let group = file.groups.first().cloned().unwrap_or_default();

    // Learn part_size + total from segment 1.
    let raw0 = match pool.fetch(&group, &file.segments[0].message_id).await {
        pool::Fetched::Found(r) => r, _ => anyhow::bail!("seg0 fetch failed") };
    let d0 = yenc::decode(&raw0)?;
    let part = d0.data.len() as u64;
    let total = d0.total_size.unwrap_or(part * file.segments.len() as u64);
    tracing::info!("part_size={part}, total={total}, segments={}", file.segments.len());

    // Serve via the real range server.
    let state = stream::StreamState::new(pool.clone(), http.clone(), test_db()?);
    let id = state.register(&nzb_url).await;
    let app = stream::router(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:8793").await?;
    let addr = listener.local_addr()?;
    tokio::spawn(async move { axum::serve(listener, app).await.ok(); });
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let base = format!("http://{addr}/stream/{id}");

    // Test a few mid-file offsets.
    for pct in [0.37_f64, 0.63, 0.9] {
        let x = (total as f64 * pct) as u64;
        let n = 200_000u64;
        let served = http.get(&base)
            .header("Range", format!("bytes={}-{}", x, x + n - 1))
            .send().await?.bytes().await?;
        // Ground truth: assemble decoded bytes [x, x+n) from segments by =ypart.
        let truth = ground_truth(&pool, &group, &file, part, x, n).await?;
        let ok = served.as_ref() == truth.as_slice();
        let first_diff = served.iter().zip(truth.iter()).position(|(a, b)| a != b);
        tracing::info!(
            "  @{:.0}% (byte {x}): served {} vs truth {} — {} {}",
            pct * 100.0, served.len(), truth.len(),
            if ok { "MATCH ✅" } else { "MISMATCH ❌" },
            first_diff.map(|p| format!("first diff @+{p}")).unwrap_or_default(),
        );
        if !ok { anyhow::bail!("seek bytes wrong at {x}"); }
    }
    tracing::info!("✅ SEEK BYTE-ACCURATE: range server matches ground truth at every offset");
    Ok(())
}

/// Assemble decoded bytes [x, x+n) directly from the segments that (by real =ypart)
/// cover that span — independent of the range server's own math.
async fn ground_truth(
    pool: &std::sync::Arc<pool::Pool>, group: &str, file: &nzb::NzbFile,
    part: u64, x: u64, n: u64,
) -> anyhow::Result<Vec<u8>> {
    let mut out = Vec::new();
    // Estimate a window of segments and walk until covered.
    let mut idx = (x / part).saturating_sub(2) as usize;
    while out.len() < n as usize && idx < file.segments.len() {
        let raw = match pool.fetch(group, &file.segments[idx].message_id).await {
            pool::Fetched::Found(r) => r, _ => { idx += 1; continue }
        };
        let d = yenc::decode(&raw)?;
        let seg_start = d.part_begin.map(|b| b - 1).unwrap_or(idx as u64 * part);
        let seg_end = seg_start + d.data.len() as u64;
        // If this segment ends before x, advance; if it starts after x+n, stop.
        if seg_end <= x { idx += 1; continue; }
        if seg_start >= x + n { break; }
        // Overlap [max(seg_start,x), min(seg_end,x+n))
        let from = x.max(seg_start) - seg_start;
        let to = (x + n).min(seg_end) - seg_start;
        out.extend_from_slice(&d.data[from as usize..to as usize]);
        idx += 1;
    }
    out.truncate(n as usize);
    Ok(out)
}

/// Diagnostic: for the first segments of a real NZB, run BOTH `STAT` and `BODY`
/// on the SAME message-id and compare — this pinpoints whether STAT lies (the
/// "0/139 present" false-negative) and whether segments decode to a uniform size
/// (needed for correct seek math).
async fn statprobe() -> anyhow::Result<()> {
    let cfg = config::Config::load()?;
    let http = reqwest::Client::builder().user_agent("velvet/0.1")
        .timeout(std::time::Duration::from_secs(60)).build()?;
    // Diagnostic input is supplied by the operator; no personal watch history is bundled.
    let imdb = std::env::var("VELVET_PROBE_IMDB").context("set VELVET_PROBE_IMDB to an IMDb numeric identifier")?;
    let season: u32 = std::env::var("VELVET_PROBE_SEASON").context("set VELVET_PROBE_SEASON")?.parse()?;
    let episode: u32 = std::env::var("VELVET_PROBE_EPISODE").context("set VELVET_PROBE_EPISODE")?.parse()?;
    let mut results = Vec::new();
    for ix in &cfg.indexers {
        if let Ok(mut r) = resolver::search_series(&http, ix, &imdb, season, episode).await {
            results.append(&mut r);
        }
    }
    let pick = results.into_iter().filter(|r| !r.title.to_lowercase().contains("sample"))
        .max_by_key(|r| r.size).context("no matching episode result")?;
    tracing::info!("probe target: {}", pick.title);
    let nzb = resolver::download_nzb(&http, &pick.nzb_url).await?;
    let parsed = nzb::parse(&nzb)?;
    let file = parsed.primary_file().context("no media file")?;
    let group = file.groups.first().cloned().unwrap_or_default();
    tracing::info!("group={group}, {} segments; NZB byte-sizes of first 5: {:?}",
        file.segments.len(),
        file.segments.iter().take(5).map(|s| s.bytes).collect::<Vec<_>>());

    let provider = cfg.providers.first().context("no provider")?;
    let mut conn = nntp::NntpConn::connect(provider).await?;
    tracing::info!("connected. Comparing STAT vs BODY (no GROUP) then WITH group:");
    for (i, seg) in file.segments.iter().take(5).enumerate() {
        let stat_no_group = conn.stat(&seg.message_id).await;
        let body = conn.body(&seg.message_id).await;
        let (decoded_len, part) = match &body {
            Ok(nntp::ArticleBody::Found(raw)) => {
                match yenc::decode(raw) { Ok(d) => (d.data.len() as i64, format!("{:?}..{:?}", d.part_begin, d.part_end)), Err(_) => (-1, "decode-err".into()) }
            }
            Ok(nntp::ArticleBody::Missing) => (-2, "missing".into()),
            Err(_) => (-3, "err".into()),
        };
        tracing::info!(
            "  seg#{}: STAT={:?}  BODY={}  decoded={} ypart={}",
            seg.number,
            stat_no_group,
            match &body { Ok(nntp::ArticleBody::Found(_)) => "Found", Ok(nntp::ArticleBody::Missing) => "Missing", Err(_) => "Err" },
            decoded_len, part,
        );
        let _ = i;
    }
    // Now select the group and STAT again, to see if GROUP is required.
    conn.group(&group).await.ok();
    tracing::info!("after GROUP {group}:");
    for seg in file.segments.iter().take(5) {
        tracing::info!("  seg#{}: STAT={:?}", seg.number, conn.stat(&seg.message_id).await);
    }
    conn.quit().await;
    Ok(())
}

/// Completeness check: STAT every segment of a real NZB (no body download) to
/// prove we can verify a file is whole BEFORE playback, then inject a bogus
/// segment id and confirm the check catches the gap.
async fn healthtest() -> anyhow::Result<()> {
    let cfg = config::Config::load().context("load velvet.toml")?;
    let http = reqwest::Client::builder()
        .user_agent("velvet-backend/0.1")
        .timeout(std::time::Duration::from_secs(60))
        .build()?;
    let (title, nzb_url) = resolve_test_nzb(&http, &cfg).await?;
    tracing::info!("health target: {title}");

    let nzb_bytes = resolver::download_nzb(&http, &nzb_url).await?;
    let parsed = nzb::parse(&nzb_bytes)?;
    let file = parsed.primary_file().context("no media file")?;
    let ids: Vec<String> = file.segments.iter().map(|s| s.message_id.clone()).collect();
    tracing::info!("{} segments to verify", ids.len());

    let pool = pool::Pool::new(&cfg.providers);

    // 1. Verify the real file — should be 100% complete.
    let t0 = std::time::Instant::now();
    let health = pool.completeness(&ids).await;
    tracing::info!(
        "STAT-verified {}/{} segments ({:.2}%) in {:?} — complete: {}",
        health.present, health.total, health.fraction() * 100.0, t0.elapsed(), health.is_complete(),
    );

    // 2. Inject a bogus segment and confirm the check now reports a gap.
    let mut broken = ids.clone();
    let mid = broken.len() / 2;
    broken[mid] = "definitely-not-a-real-article@velvet.invalid".to_string();
    let t1 = std::time::Instant::now();
    let broken_health = pool.completeness(&broken).await;
    tracing::info!(
        "with 1 bogus segment: {}/{} present ({:.2}%) in {:?} — complete: {}",
        broken_health.present, broken_health.total, broken_health.fraction() * 100.0,
        t1.elapsed(), broken_health.is_complete(),
    );

    if !health.is_complete() {
        anyhow::bail!("real file reported incomplete ({}/{})", health.present, health.total);
    }
    if broken_health.is_complete() || broken_health.present != health.total - 1 {
        anyhow::bail!("gap detection failed: {}/{}", broken_health.present, broken_health.total);
    }
    tracing::info!("✅ COMPLETENESS CHECK OK: whole file verified via STAT, and a single missing article is caught — no more mid-playback surprises");
    Ok(())
}

/// Full live loop: indexer → NZB → fetch first segments off the provider →
/// yEnc-decode → confirm the bytes are a real media container.
async fn selftest() -> anyhow::Result<()> {
    let cfg = config::Config::load().context("load velvet.toml")?;
    let http = reqwest::Client::builder()
        .user_agent("velvet-backend/0.1")
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    // A widely-seeded title so any indexer returns hits: Inception (tt1375666).
    let imdb = "1375666";
    let mut results = Vec::new();
    for ix in &cfg.indexers {
        match resolver::search_movie(&http, ix, imdb).await {
            Ok(mut r) if !r.is_empty() => {
                tracing::info!("indexer {}: {} results", ix.name, r.len());
                results.append(&mut r);
                break;
            }
            Ok(_) => tracing::warn!("indexer {}: 0 results", ix.name),
            Err(e) => tracing::warn!("indexer {} failed: {e}", ix.name),
        }
    }
    let pick = results
        .into_iter()
        .filter(|r| {
            let t = r.title.to_lowercase();
            t.contains("1080p")
                && !t.contains("2160")
                && !t.contains("remux")
                && !t.contains("sample")
                && r.size > 2_000_000_000 // a real feature, not a sample/clip
        })
        .min_by_key(|r| r.size) // smallest full 1080p = fastest to prove the loop
        .context("no suitable NZB result from any indexer")?;
    tracing::info!("picked: {} ({:.2} GB) via {}", pick.title, pick.size as f64 / 1e9, pick.indexer);

    let nzb_bytes = resolver::download_nzb(&http, &pick.nzb_url).await.context("download nzb")?;
    tracing::info!("nzb downloaded: {} bytes", nzb_bytes.len());
    let parsed = nzb::parse(&nzb_bytes).context("parse nzb")?;
    let file = parsed.primary_file().context("nzb had no media file")?;
    tracing::info!(
        "primary file: {} — {} segments, group {}",
        file.subject,
        file.segments.len(),
        file.groups.first().map(String::as_str).unwrap_or("?"),
    );

    // Fetch the first few segments off the primary provider and decode them.
    let provider = cfg.providers.first().context("no providers configured")?;
    let mut conn = nntp::NntpConn::connect(provider).await.context("nntp connect")?;
    tracing::info!("connected + authed to {}", provider.host);
    if let Some(g) = file.groups.first() {
        conn.group(g).await.ok();
    }

    let mut assembled = Vec::new();
    let t0 = std::time::Instant::now();
    let take = file.segments.len().min(3);
    for seg in file.segments.iter().take(take) {
        match conn.body(&seg.message_id).await? {
            nntp::ArticleBody::Found(raw) => {
                let decoded = yenc::decode(&raw).context("yenc decode")?;
                tracing::info!(
                    "  segment #{}: {} raw → {} decoded bytes (part {:?}-{:?})",
                    seg.number,
                    raw.len(),
                    decoded.data.len(),
                    decoded.part_begin,
                    decoded.part_end,
                );
                assembled.extend_from_slice(&decoded.data);
            }
            nntp::ArticleBody::Missing => {
                tracing::warn!("  segment #{} MISSING (would stream past this gap)", seg.number);
            }
        }
    }
    conn.quit().await;

    let elapsed = t0.elapsed();
    let magic = &assembled[..assembled.len().min(16)];
    let hex: String = magic.iter().map(|b| format!("{b:02x} ")).collect();
    let container = detect_container(&assembled);
    tracing::info!("fetched {} segments in {:?}", take, elapsed);
    tracing::info!("first bytes: {hex}");
    tracing::info!("container magic: {container}");

    if container == "unknown" {
        anyhow::bail!("decoded bytes don't look like a media container — decode path is wrong");
    }
    tracing::info!("✅ END-TO-END OK: indexer → NZB → NNTP → yEnc → real {container} bytes");
    Ok(())
}

fn detect_container(data: &[u8]) -> &'static str {
    if data.len() >= 4 && data[..4] == [0x1A, 0x45, 0xDF, 0xA3] {
        "Matroska/WebM (EBML)"
    } else if data.len() >= 12 && &data[4..8] == b"ftyp" {
        "MP4/MOV (ftyp)"
    } else if data.len() >= 3 && &data[..3] == b"ID3" {
        "MP3/ID3"
    } else if data.len() >= 4 && &data[..4] == b"RIFF" {
        "AVI/RIFF"
    } else {
        "unknown"
    }
}
