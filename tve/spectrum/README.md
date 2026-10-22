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

The service currently requires a provisioned runtime session from your own signed-in Spectrum account. An account sign-in UI is not included in this source package. Do not copy another installation's session, place credentials in an image, or publish the private configuration directory. Normal refreshes use the stored refresh token. Expired sessions with a saved device verifier are checked with Spectrum first; device renewal occurs only when Spectrum explicitly directs it. Tokens and rotated device context are saved atomically. A provider instruction to sign in again is respected, and temporary provider failures do not become misleading sign-in prompts.

Create `backend/spectrum-config/` outside version control, protect it with mode `0700`, and protect its JSON files with mode `0600`:

- `auth.json`: the provisioned account's `accessToken`, `refreshToken`, `expiresAt` (Unix milliseconds), and `deviceId`. Preserve its `deviceVerifier` and `contextToken` when provided; these support provider-directed session renewal. Do not invent or substitute device identity fields.
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

Each tune allocates a random, scoped playback capability and owns any concurrency lease returned by Spectrum. Stop, failed startup, abandoned requests, inactivity and shutdown release that lease. Spectrum can omit a lease for an in-home session; this is accepted only when a fresh location check and the tune response both recognize the account's home connection. Session limits, expiry and DRM checks still apply. Manifest refreshes keep a short grace period for already-requested media. DASH timelines and HLS renditions, init segments, byte ranges and key rotation retain their original playback semantics.

The license endpoints relay raw device-generated Widevine challenges or FairPlay SPC/CKC messages. They do not expose content keys. Native output requirements, including an active protected HDMI connection where required, remain enforced by the device.

No host port is published in the Compose example. Expose only the Velvet backend; never publish this service, its runtime configuration, browser debugging ports, or a Spectrum sign-in desktop through your public reverse proxy.

## Separate authorization and video routes

The video path is **Spectrum CDN → this service → Velvet backend → client**. The client performs native DRM playback. For installations using a private connection to the account's home network, the service can send Spectrum authorization requests through an HTTP CONNECT proxy while continuing to fetch video directly through the server's ordinary internet connection.

Set `refreshLocation` to `true` in private `spectrum.json` to retrieve Spectrum's actual location response before tuning. Location checks are cached for up to 15 minutes; an expired check must succeed before a new tune can proceed. Current provider values replace captured location flags in tune and manifest requests. A proxy also requires this setting.

Set `controlProxyUrl` to the private proxy's HTTP URL, including its username and password when authentication is enabled. Keep that URL exclusively in runtime configuration. The optional [WireGuard egress service](../spectrum-egress/README.md) provides a restricted proxy and an independent WireGuard client in its own container.

| Traffic | Route when a control proxy is configured |
| --- | --- |
| Account token refresh, location, lineup, tuning, guide, lease renewal, DRM license and certificate | Private proxy → account home connection → Spectrum |
| Video manifests, encrypted audio/video segments and CDN redirects | Server's ordinary internet connection → Spectrum CDN |
| Client playback | Server → client, unchanged |

The proxy can connect only to the four Spectrum control hosts, and TLS remains verified end to end between this service and Spectrum. A failed proxy does not fall back to direct authorization. Video traffic does not enter the proxy. The routing option does not change the subscription, add-on, blackout or device permissions returned by Spectrum. Validate actual playback and license renewal on the intended devices before activation; obtaining a manifest alone does not establish playable DRM video.

## Development checks

Node.js 22 or newer is required. There are no npm runtime dependencies. Tests also require the `openssl` command to generate temporary local TLS certificates.

```sh
npm test
docker build -t velvet-spectrum:local .
```

Tests use synthetic manifests, fake media transports, and local CONNECT/TLS fixtures. They cover credential refresh, opaque license bytes, scoped manifest rewriting, bounded requests, cancellation cleanup, provider errors, and separation of proxied control requests from direct media requests. They do not log in to Spectrum or establish that a particular account or device can play a channel. The Docker context is an explicit source-only allowlist.
