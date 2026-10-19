# Native Spectrum service

This service gives Velvet the current channel lineup from a signed-in Spectrum account and relays its original encrypted streams to the device's native player. It does not run a video browser, capture a display, transcode protected media, or require Channels DVR. The Spectrum TV subscription and its existing channel, location, blackout, simultaneous-stream and output-protection rules still apply.

The backend keeps the public API, guide, and client-facing session URLs. This private service owns Spectrum authentication refresh, stream leases, CDN requests and raw license exchanges. Provider credentials and signed media URLs stay on the server. Video and audio remain encrypted until the device's DRM system handles them.

| Client | Native path |
| --- | --- |
| Android TV / Shield | DASH, Media3 and Widevine |
| iPhone / iPad | HLS, AVPlayer and FairPlay |
| Roku | DASH and the Roku Video node's Widevine support; Roku remains alpha |

Older Velvet builds cannot use this source. Update every client before enabling it. Simulator playback is not a substitute for a hardware DRM test.

## Private deployment

The service currently requires a provisioned runtime session from your own signed-in Spectrum account. An account sign-in UI is not included in this source package. Do not copy another installation's session, place credentials in an image, or publish the private configuration directory. Normal refreshes use the stored refresh token; if Spectrum revokes the session, a new account sign-in is required.

Create `backend/spectrum-config/` outside version control, protect it with mode `0700`, and protect its JSON files with mode `0600`:

- `auth.json`: the provisioned account's `accessToken`, `refreshToken`, `expiresAt` (Unix milliseconds), and `deviceId`. Additional device verifier/context fields are retained when refreshing.
- `spectrum.json`: `authFile` set to `/config/auth.json`; `tuneQuery` and `manifestQuery` containing the account's actual provider-issued playback/privacy/location settings; optionally `sourceName` and reviewed `channelAliases` (`id`, `entitlementId`, optional `name`). Do not change location flags to claim another home or market. Do not include another playback's Aegis token or stream-session identifier.

Start the optional private service alongside the backend:

```sh
cd backend
docker compose -f compose.yaml -f compose.spectrum.yaml up -d --build
```

After validating playback on your devices, set this in the backend's private `velvet.toml` and restart the backend:

```toml
[live_tv]
enabled = true
source_name = "Spectrum"
native_spectrum_url = "http://velvet-spectrum:8812"
guide_enabled = true
# Keep your existing upstream_url if using Roku's separate sports bridge.
```

The native service becomes the authoritative Live TV lineup and playback source. It does not silently fall back to PrismCast. The existing `upstream_url` remains available for the separate Roku sports browser path. An included channel does not guarantee availability outside the account's home.

## Program guide

The guide uses Spectrum's own 24-hour schedule, matched to exact station IDs from the signed-in channel lineup. It includes program times, descriptions, episode titles, artwork, genres, ratings and Live/New flags when provided. Reading the guide never opens a stream or uses a playback connection.

Listings refresh at most every 15 minutes. Browsing serves cached listings while a refresh runs; temporary failures retain only programs that have not ended, with retries limited to once per minute. The backend's verified XMLTV mappings remain a fallback for entirely missing provider rows. Conflicting schedules are never combined, and channels without listings remain playable. Provider authentication stays private on the server; only normalized program metadata reaches clients.

## Session behavior

Each tune allocates its own provider lease and a random, scoped playback capability. Stop, failed startup, abandoned requests, inactivity and shutdown release that lease. Manifest refreshes keep a short grace period for already-requested media. DASH timelines and HLS renditions, init segments, byte ranges and key rotation retain their original playback semantics.

The license endpoints relay raw device-generated Widevine challenges or FairPlay SPC/CKC messages. They do not expose content keys. Native output requirements, including an active protected HDMI connection where required, remain enforced by the device.

No host port is published in the Compose example. Expose only the Velvet backend; never publish this service, its runtime configuration, browser debugging ports, or a Spectrum sign-in desktop through your public reverse proxy.

## Development checks

Node.js 22 or newer is required. There are no npm runtime dependencies.

```sh
npm test
docker build -t velvet-spectrum:local .
```

Tests use synthetic manifests and fake transports. They cover credential refresh, opaque license bytes, scoped manifest rewriting, bounded requests, cancellation cleanup and provider errors. They do not log in to Spectrum or establish that a particular account or device can play a channel. The Docker context is an explicit source-only allowlist.
