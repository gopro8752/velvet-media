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

## Admin portal

Open `/admin` on your backend. Admin access uses a separate random key, created on first startup in the data volume. Read it locally:

```sh
docker compose exec backend cat /data/velvet-admin-key
```

Keep this key private. It can view usage by profile and device, current playback, content titles, provider capacity, playback quality, and server metrics. `VELVET_ADMIN_TOKEN` can supply an alternative key of at least 24 characters; set it only in your private runtime environment.

Playback reports begin when compatible clients send telemetry. Historic playback is not inferred from existing watch progress. The analytics database is separate from watch-state data, defaults to `/data/velvet-analytics.db`, and can be relocated with `VELVET_ANALYTICS_DB`. Capacity samples, usage buckets, and session records are retained for 90 days.

## Optional integrations

- **AI categories:** set `VELVET_IMAGE_TARGET=with-codex` in `.env`, set `category_ai.enabled=true`, rebuild, and run `docker compose exec backend codex login --device-auth`. Authentication is stored under the private `config/codex` mount. This integration uses the official CLI's account authentication; service availability and usage limits are determined by the account and upstream service. Never put account credentials into a Dockerfile, image, or repository.
- **Live TV:** configure your own compatible bridge in `[live_tv]`. The bundled adapter understands PrismCast's Spectrum playlist format. The bridge and its authentication are separate services; neither is included in the image.
- **TV guide:** enable `guide_enabled` for supported channel mappings. Listings are fetched at runtime from an external feed. Exact feed coverage varies.
- **Live sports:** opt into `[live_sports]` to enable the external event/embed adapter. Availability and playback depend on that external service and client support.
- **Mobile/Roku compatibility:** FFmpeg supplies audio conversion and live remuxing. Original streams remain available to capable clients.

All optional integrations default to disabled. The public repository includes no external media assets or program listings. Runtime metadata, artwork, guide feeds, and media remain subject to their respective providers' terms and licenses.

## Run from source

Use a current stable Rust toolchain and install FFmpeg plus Chromaprint (`fpcalc`) if you need transcoding or intro detection.

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
