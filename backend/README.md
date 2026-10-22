# Velvet backend

One self-hosted service for on-demand Usenet streaming, a Stremio-compatible resolver, profiles and watch progress, playback handoff, metadata browsing, personal categories, live-source adapters, and private usage reporting.

Bring your own services and credentials. No provider accounts, metadata keys, media, sign-in sessions, or personal server configuration are included.

## Start with Docker Compose

You need Docker with Compose, an NNTP provider, a Newznab-compatible indexer, and your own TMDB API key for metadata browsing. Obtain any external subscriptions or permissions you need separately.

1. Prepare private configuration:

   ```sh
   mkdir -p config
   chmod 700 config
   cp velvet.toml.example config/velvet.toml
   cp .env.example .env
   chmod 600 .env config/velvet.toml
   ```

2. Edit `.env` with your provider credentials, TMDB key, public backend URL, and a strong random `VELVET_TOKEN`. Generate a token locally with `openssl rand -hex 32`. Edit `config/velvet.toml` with your own indexer URL and API key. Add extra provider blocks there if needed; environment overrides affect the first provider only.

3. Build and start:

   ```sh
   docker compose up -d --build
   curl --fail http://127.0.0.1:8799/health
   ```

4. Enter the reachable backend URL and shared token in each Velvet client. The Compose example binds only to host loopback. Configure your own HTTPS reverse proxy or trusted network access and set `VELVET_PUBLIC_BASE_URL` to the address clients actually use.

The shared token protects supported app APIs; it is not a blanket access-control layer for every media URL. Stream links must remain reachable by the player, so treat them as private. Protect the service at your network or reverse proxy when exposing it remotely.

Provider limits belong to your provider plan. Set `NNTP_CONNS` accordingly; idle reusable connections do not consume the dashboard's *busy* connection count.

## Metadata for every client

Configure `VELVET_TMDB_KEY` once in the backend's private runtime environment. Updated Android and iOS clients use `GET /metadata/tmdb/{path}` for their TMDB v3 discovery, search, details, season, and IMDb lookup requests; Roku uses the backend's `/catalog` endpoints. Clients need the backend URL and shared app token, not a copy of the TMDB key. Restart the backend after rotating its runtime key.

The metadata endpoint accepts only supported read-only paths and query parameters, authenticates each request with the same shared Bearer token as `/catalog`, and returns TMDB-compatible JSON. It rejects client-supplied credentials and account operations, uses a fixed upstream host with bounded requests, and never returns the backend key or credential-bearing upstream errors. Responses use `Cache-Control: private, no-store` so shared proxies cannot serve authenticated results to other callers. A missing backend key returns HTTP 503 with a configuration message.

## Admin portal

Open `/admin` on your backend. Admin access uses a separate random key, created on first startup in the data volume. Read it locally:

```sh
docker compose exec backend cat /data/velvet-admin-key
```

Keep this key private. It can view usage by profile and device, current playback, content titles, provider capacity, playback quality, and server metrics. `VELVET_ADMIN_TOKEN` can supply an alternative key of at least 24 characters; set it only in your private runtime environment.

Playback reports begin when compatible clients send telemetry. Historic playback is not inferred from existing watch progress. The analytics database is separate from watch-state data, defaults to `/data/velvet-analytics.db`, and can be relocated with `VELVET_ANALYTICS_DB`. Capacity samples, usage buckets, and session records are retained for 90 days.

### Recovery reporting for Velvet Beta

The **Recovery** section at `/admin#recovery` reports the separate beta backend’s work. It keeps beta repair and viewing statistics separate from the dashboard’s existing stable capacity and playback reports. Update the beta backend and Android beta app together to enable watch-level attribution and the new source-switch counters.

To view beta reporting through your existing dashboard, configure both values on the **server hosting that dashboard**, using a backend build that supports the recovery report proxy:

```dotenv
VELVET_RECOVERY_REPORT_URL=https://beta-backend.example
VELVET_RECOVERY_REPORT_TOKEN=REPLACE_WITH_BETA_ADMIN_KEY
```

Replace the reserved example origin with the beta backend’s address reachable by the dashboard server. Use a bare HTTP(S) origin, without a path, query, embedded credentials, or fragment. The token is the beta backend’s **admin key**, not its client playback token. Retrieve it privately from the beta data volume; with the beta Compose example, run `docker compose -f compose.beta.yaml exec backend-beta cat /data/velvet-admin-key`. Keep both settings in private deployment configuration and pass them into the dashboard container’s environment. A Compose `.env` file alone does not inject variables unless the service’s `environment` or `env_file` configuration includes them.

Restart the dashboard backend after setting the variables. Your browser uses its existing dashboard admin session; the proxy token stays on the server. The beta backend need only be reachable from that server. Leave the proxy settings unset on the beta backend itself to read its local report directly. An unreachable beta service shows an unavailable state without replacing the stable reporting data.

The report distinguishes provider article rescues, completed and unsuccessful PAR2 jobs with reasons, prepared data without observed playback delivery, and repaired bytes delivered on an active stream. It also shows successful source switches per measured movie/episode watch, manual and automatic attempts, startup, post-start buffering, title breakdowns, session details, and a CSV of the latest 5,000 instrumented sessions. The per-watch average includes watches with zero switches and excludes attempts with no reported playing time; a source is counted as switched only when replacement playback starts.

Collection begins with the updated components. No historic repair activity is reconstructed. A repair started by look-ahead is not proof that it completed before playback reached the missing data; server delivery is not proof that every frame was displayed. Post-start buffering is measured separately. Recovery events are retained for up to 90 days or 250,000 records, whichever limit is reached first; dropped-event warnings identify incomplete collection. See [the beta guide](https://github.com/gopro8752/velvet-media/blob/beta/BETA.md) for isolation, resource limits, and testing.

## Optional integrations

- **AI categories:** set `VELVET_IMAGE_TARGET=with-codex` in `.env`, set `category_ai.enabled=true`, rebuild, and run `docker compose exec backend codex login --device-auth`. Authentication is stored under the private `config/codex` mount. This integration uses the official CLI's account authentication; service availability and usage limits are determined by the account and upstream service. Never put account credentials into a Dockerfile, image, or repository.
- **Live TV:** configure your own compatible bridge in `[live_tv]`. The experimental [native Spectrum service](../tve/spectrum/README.md) supplies the full account lineup to updated Widevine/FairPlay clients. The legacy adapter also supports PrismCast's Spectrum playlist and an optional EPlusTV source for reviewed national channels. Bridges and provider authentication run separately from the backend image.
- **TV guide:** enable `guide_enabled`. The [native Spectrum source](../tve/spectrum/README.md#program-guide) supplies its own 24-hour schedule with program artwork and metadata, matched to exact station IDs. Other bridges use verified XMLTV station mappings; those mappings also fill entirely missing Spectrum rows. Coverage depends on the provider's listings.
- **Live sports:** opt into `[live_sports]` to enable the external event/embed adapter. Availability and playback depend on that external service and client support.
- **Mobile/Roku compatibility:** FFmpeg supplies audio conversion and live remuxing. Original streams remain available to capable clients.

All optional integrations default to disabled. The public repository includes no external media assets or program listings. Runtime metadata, artwork, guide feeds, and media remain subject to their respective providers' terms and licenses.

### Native Spectrum source

Set `native_spectrum_url` to the private origin of the [native service](../tve/spectrum/README.md) after provisioning its account session and updating every client. This selects Spectrum's current account catalog and native protected playback for Live TV, with no browser fallback. The backend relays only scoped manifests, encrypted media, public FairPlay certificates, and opaque platform license exchanges. It never sends client credentials to Spectrum or decrypts protected streams. Existing `upstream_url` settings still serve the separate Roku sports browser path.

### Optional direct TV Everywhere source

The additive [EPlusTV](https://github.com/tonywagner/EPlusTV) adapter can relay a network's original HLS stream through Velvet without browser capture. See the [private bridge setup](tve/README.md) for the optional deployment. It does not replace the Spectrum bridge or promise access to every channel. Spectrum continues to supply the complete channel list, existing channel IDs, artwork, guide matching, and playback fallback. Roku's separate sports browser bridge also stays on the existing `upstream_url`.

After authenticating and verifying a compatible EPlusTV instance, add its private origin to your runtime configuration:

```toml
[live_tv]
enabled = true
source_name = "Spectrum"
upstream_url = "http://live-bridge:5589"
lineup_path = "/playlist?service=spectrum"
guide_enabled = true
direct_tve_url = "http://velvet-tve:8000"
```

Enable EPlusTV's dedicated linear channels and segment proxying (`PROXY_SEGMENTS=true`), and set its `BASE_URL` to the same private origin used by Velvet. Keep its administration, provider credentials, and persistent state private. Do not expose the bridge through the public Velvet hostname or put its logins into images or source control.

The initial reviewed mappings cover FS1, FS2, the national Big Ten Network feed, Fox News, Fox Business, and Fox Weather, when present in your existing Spectrum lineup. Matching requires the original Velvet channel identity plus EPlusTV's exact provider/channel identity and station ID. Local FOX affiliates and Big Ten overflow channels retain Spectrum; similar names are not enough to substitute a feed.

Before selecting a direct source, Velvet checks its master and child playlists, then verifies current media and its key/init resources within a bounded startup budget. Only EPlusTV's channel-scoped proxy routes on the configured origin are permitted. DRM playlists, inline key URLs, external media URLs, redirects, unavailable sources, or failed authentication fall back to Spectrum. A later direct playback error temporarily excludes that source when the client reconnects. Current upstream EPlusTV can leave some `.mp4` segments external or inline session keys even with segment proxying enabled; those feeds need a bridge that normalizes them into its local proxy routes before this adapter will select them. Leave the setting unset until real video and audio have been tested with your account.

Provider entitlements, concurrent-stream limits, channel availability, and periodic sign-in requirements still apply. Authentication for one network does not establish access to other networks. No additional Velvet subscription is required.

## Run from source

Use a current stable Rust toolchain. The full test suite requires FFmpeg and `ffprobe`; playback compatibility uses the same tools. Chromaprint (`fpcalc`) supplies intro detection. On Debian/Ubuntu, install these with `sudo apt-get install ffmpeg libchromaprint-tools` before running the commands below.

```sh
cargo test --locked
cargo build --locked --release
VELVET_CONFIG=config/velvet.toml VELVET_TMDB_KEY=YOUR_OWN_KEY ./target/release/velvet-backend serve
```

For a native run, set an existing writable `db_path` in the TOML file. Native runs read the TOML file and process environment; they do not automatically read `.env`. Without `VELVET_TMDB_KEY`, metadata browsing and title-based resolver fallback are unavailable; no shared fallback key is bundled.

## Runtime files and builds

`config/`, `.env`, databases, logs, and account authentication are private runtime state. Git ignores these paths, and `.dockerignore` allows only the source files needed to build. Back up your private configuration and persistent data volume independently. Do not include them in releases.

The default Docker target is `runtime`. `with-codex` adds the optional CLI. Both build from the checked-in lockfile. Build and verify release images from this source.

## License and third-party software

Velvet's own code is source-available under the repository's [license](../LICENSE). Personal noncommercial use and customization are permitted under its terms; commercial use or distribution outside those terms requires the owner's permission. This is not an OSI open-source license.

Third-party software retains its own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the locked Rust dependency inventory and the separately distributed Docker runtime components. Do not apply Velvet's license restrictions to those components.
