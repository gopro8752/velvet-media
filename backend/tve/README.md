# Direct TV Everywhere (optional)

This is a free, self-hosted source adapter for supported channels already included in your TV-provider subscription. It uses [EPlusTV 4.16.6](https://github.com/tonywagner/EPlusTV/releases/tag/v4.16.6) to obtain authenticated network feeds and relay their original HLS media. It does not capture a browser, require a Channels DVR subscription, grant additional channel entitlements, or replace the entire Spectrum lineup.

Velvet prefers a verified direct source for reviewed matching national channels, while retaining the existing Spectrum bridge and guide. FOX affiliates and similarly named overflow feeds are not automatically substituted. Roku Live Sports continues using its existing separate playback path.

## Setup

From the backend directory:

```sh
docker compose -f compose.yaml -f compose.tve.yaml up -d --build
```

Open the TVE admin at `http://127.0.0.1:8810`. For a remote server, forward that loopback port through SSH, for example `ssh -L 8810:127.0.0.1:8810 YOUR_SERVER`. Do not expose this admin through your public reverse proxy: EPlusTV has no built-in admin authentication. Its persistent config volume contains account tokens; protect and back it up as private runtime data.

Enable FOX One and follow its TV-provider activation link. Choose your existing provider rather than purchasing another subscription. One authorization covers the entitled FOX family; different network families can require separate authorization and periodic renewal. Enable only the linear channels you receive. Dedicated linear channels and segment proxying must remain enabled; the Compose environment initializes those settings on a fresh volume.

After confirming playback from the source, set this in your private `config/velvet.toml` and restart the backend:

```toml
[live_tv]
# Retain your existing enabled/upstream_url/lineup_path/guide_enabled settings.
direct_tve_url = "http://velvet-tve:8000"
```

Supported direct channel identities are explicitly reviewed in `src/live.rs`. Unsupported, unavailable, protected, or incompatible feeds retain the current Spectrum route. Remove `direct_tve_url` and restart the backend to disable direct TVE without deleting the saved account authorization.

## Local modifications

The pinned image receives a small patch that bounds FOX One tuning and cancels stalled requests, removes sensitive FOX One error dumps and token display, and preserves the subscriber's existing home-location preference. Provider authentication and entitlement checks remain in place. The admin is still private even with these changes; other providers' admin interfaces have not been hardened by this patch.

EPlusTV and modifications to its source are MIT licensed; see [LICENSE.EPlusTV](LICENSE.EPlusTV). Velvet's project license does not replace that license. This integration depends on network APIs and provider authorization, so availability may change.
