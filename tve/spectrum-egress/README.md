# Spectrum control egress

An optional companion to the native Spectrum bridge. It sends Spectrum account, location, tune, and native DRM requests through one authorized home-network WireGuard peer. Encrypted video remains on the Spectrum bridge's ordinary internet connection. It does not record video, decrypt content, forge location responses, or provide a general VPN/proxy.

The service permits authenticated HTTP `CONNECT` only to these exact destinations on TCP 443:

- `apis.spectrum.net`
- `apis-vid.spectrum.net`
- `apis-drm.spectrum.net`
- `pi-lite.spectrum.net`

The bridge verifies Spectrum's TLS certificates end to end through each tunnel. Provider availability, subscription entitlements, native DRM acceptance, geographic restrictions, and account stream limits still apply.

## Private configuration

Create a **dedicated WireGuard client/peer** on the home network that supplies the Spectrum subscription. Do not reuse the peer running on a phone, Mac, or another device: simultaneous use of one WireGuard identity causes endpoint roaming and unreliable connections.

Place these private files in `backend/spectrum-egress-config/` with restrictive permissions. They are runtime mounts, never build inputs:

- `wg.conf`: the dedicated peer's WireGuard profile.
- `proxy.json`: a unique proxy username and a long random password.

`proxy.json` accepts this shape; replace both placeholders:

```json
{"username":"YOUR_PROXY_USER","password":"YOUR_RANDOM_PROXY_PASSWORD"}
```

Alternatively use `{"basicToken":"BASE64_OF_USERNAME_COLON_PASSWORD"}`. Authentication is mandatory. Never publish credentials, private keys, or authenticated proxy URLs.

Supported profiles contain exactly one `[Interface]` and one `[Peer]`. An IPv4 interface address, IPv4-capable endpoint, and `AllowedIPs` containing `0.0.0.0/0` are required. Profiles may also contain IPv6 addresses and allowed networks; the service assigns only IPv4 addresses and creates only IPv4 control connections. `PrivateKey`, `Address`, `DNS`, `MTU`, and `ListenPort` are the accepted interface settings; peer settings are `PublicKey`, optional `PresharedKey`, `AllowedIPs`, `Endpoint`, and `PersistentKeepalive`. Hooks, `SaveConfig`, route-table overrides, and unknown settings are rejected. Profile DNS entries are validated but the container retains Docker DNS. Keepalive defaults to 25 seconds, including an explicitly disabled value, to maintain connectivity and make the handshake health check meaningful; explicit nonzero values must be 1–60 seconds.

The Linux host must provide WireGuard kernel support. The service does not load host modules or change host routes.

## Start with the native bridge

From `backend/`:

```sh
docker compose -f compose.yaml -f compose.spectrum.yaml -f compose.spectrum-vpn.yaml build velvet-spectrum-egress velvet-spectrum
docker compose -f compose.yaml -f compose.spectrum.yaml -f compose.spectrum-vpn.yaml run --rm --no-deps velvet-spectrum-egress python /app/egress.py --validate
```

Validation parses both files without creating interfaces, making network requests, or printing secrets. Add the following fields to the native Spectrum bridge's private `spectrum.json`:

```json
{
  "refreshLocation": true,
  "controlProxyUrl": "http://YOUR_PROXY_USER:YOUR_URL_ENCODED_PASSWORD@velvet-spectrum-egress:8888"
}
```

Percent-encode reserved characters in the username/password when constructing the URL. Keep the existing authentication file, tune parameters, channel aliases, and other bridge settings. Then start the services:

```sh
docker compose -f compose.yaml -f compose.spectrum.yaml -f compose.spectrum-vpn.yaml up -d velvet-spectrum-egress velvet-spectrum
```

The overlay publishes **no proxy host port** and creates a separate bridge network shared only by the Spectrum service and egress service. Do not add public ports, host networking, privileged mode, or a public reverse-proxy route. Runtime configuration is mounted read-only; temporary WireGuard configuration exists only in a private `/run` tmpfs. The container receives only `NET_ADMIN` and `NET_RAW`; these capabilities apply within its own network namespace.

Every upstream TCP socket must bind to `wg0`. A route in table 51820 applies only to those interface-bound sockets; rules at priorities 10000/10001 precede the ordinary main route table and terminate with a prohibit rule. Before resolving a control hostname or opening a socket, the service also verifies that this table contains exactly one direct default route through `wg0`. Missing interfaces, unavailable tunnels, or missing WireGuard routes cannot silently fall back to ordinary internet egress. WireGuard's outer UDP connection and Docker DNS continue through the container's ordinary network. Video hosts are excluded from the proxy allowlist entirely.

The local Docker health check requires the expected default route, `wg0`, and one nonzero handshake no older than 180 seconds. It does not expose an HTTP health endpoint. A supervisor exits if no healthy connection is established within 180 seconds, or none is observed for 240 seconds after connection. Docker's restart policy then recreates the tunnel and resolves its endpoint again, including after a home internet address change. Diagnose failures using container health status and sanitized event logs. The service caps active requests at 32, request headers at 8 KiB/5 seconds, and tunnels at 45 seconds idle/120 seconds total. Route validation, DNS resolution, and the upstream TCP connection share an eight-second connection budget. DNS uses at most eight daemon workers; stalled lookups retain their slots until they return, and new lookups fail when all slots are occupied. Long-lived HTTP connections are expected to reconnect normally.

## Checks

```sh
cd tve/spectrum-egress
python3 -m unittest -v test_egress.py
```

Tests cover profile parsing, mandatory authentication, exact destination restrictions, header deadlines and size caps, binding failures, rejection of private DNS answers, bounded DNS workers, private bootstrap files, routing-rule configuration and route-loss rejection, connection limits, and tunnel expiry. Real deployment verification must also confirm a recent handshake, routing failure when the WireGuard route is removed, and actual native player DRM playback. HTTP success for an encrypted playlist alone does not establish playable video.
