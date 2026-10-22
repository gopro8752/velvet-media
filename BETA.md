# Exact recovery beta

This branch tests whether missing Usenet data can be recovered **before playback needs it**, while keeping the same stream URL and decoder. It is a separate experiment based on the current stable source. It does not promise uninterrupted playback for every release.

## What is implemented

1. **Validate each article.** Check yEnc termination, decoded lengths, multipart offsets, and CRC. A corrupt response is retried against another configured provider, using the same message ID.
2. **Look ahead in playback time.** The beta Android app reports its playback position. A bounded local ffprobe worker reads the original stream and maps audio/video packet timestamps to file ranges. Health reports verified seconds only while the associated validated segments remain cached. An estimate from file size is never labeled verified.
3. **Repair exact source bytes.** Preserve the original NZB, supporting files, and PAR2 metadata. When all providers fail, a bounded job downloads the required supporting data and parity, validates metadata and paths, and runs PAR2 in a private directory. Independently verify whole-file checksums before publishing repaired ranges.
4. **Continue the same HTTP resource.** Successful repair supplies original bytes to the existing stream. It does not replace the player or silently splice a different encode into it.
5. **Keep the existing alternate-source fallback.** Alternatives can be prepared in advance. If exact recovery cannot finish, the normal player failure path remains available. Switching to a different release can still pause, seek, or differ in timing; this is not advertised as seamless.

The original posted file is the repair unit, including stored archive volumes before media extraction. Recovery can require data from later in the release. This first beta deliberately favors verified, bounded whole-set recovery over a partial PAR2 implementation. That can increase bandwidth and disk use substantially when an article is missing.

## Run an isolated backend

Use the `beta` branch in a separate checkout. Do not point it at the stable database or repair directory. Secrets belong only in private runtime configuration.

```sh
git clone --branch beta https://github.com/gopro8752/velvet-media.git velvet-beta
cd velvet-beta/backend
mkdir -p beta-config
cp velvet.toml.example beta-config/velvet.toml
```

Set your providers and indexers in `beta-config/velvet.toml`. Reserve connection capacity for beta: a second process has its own pool, and both processes count against the same provider account limit. Start with a small budget such as four connections. The published configuration contains no account credentials.

Enable these sections in that private file:

```toml
[repair]
enabled = true
cache_dir = "/data/recovery"
par2_binary = "par2"
max_job_bytes = 8589934592
max_cache_bytes = 34359738368
max_download_bytes = 17179869184
max_parity_bytes = 1073741824
max_jobs = 1
max_job_seconds = 180
fetch_parallelism = 2
min_free_bytes = 2147483648

[stream_buffer]
enabled = true
lookahead_seconds = 90
max_probe_bytes = 268435456
max_probe_seconds = 40
max_memory_bytes = 268435456
heartbeat_timeout_seconds = 15
ffprobe_binary = "ffprobe"
```

The cache reserves space for input files, a staging copy, and possible PAR2 output/backup. The 8 GiB job limit above bounds retained posted files, including parity, and excludes large releases from repair; those can still play normally while healthy. Repair is refused when a limit is reached. The transfer budget includes provider retries; interrupted article transfers conservatively retain their allocation, so “budget used” can exceed actual downloaded bytes. The 90-second look-ahead is a target, not a guaranteed buffer: throughput, format indexing, memory, and repair time determine actual coverage.

Provide `VELVET_BETA_TOKEN`, `VELVET_BETA_PUBLIC_BASE_URL`, and `VELVET_TMDB_KEY` through a private `.env`. To allow LAN access, also set `VELVET_BETA_BIND_ADDRESS` to the appropriate host interface. Then:

```sh
docker compose -f compose.beta.yaml up -d --build
```

The example uses host port 8801 and an independent named data volume. Keep authentication and normal network protections in place. Optional Live TV, Live Sports, and AI categories still require their own setup; they are not needed to test Usenet recovery.

## Install the Android beta alongside Velvet

```sh
cd clients/android
./gradlew :app:assembleBetaDebug
adb install -r app/build/outputs/apk/beta/debug/app-beta-arm64-v8a-debug.apk
```

The app is named **Velvet Beta**, with package `tv.velvet.beta`. It has separate preferences, providers, permissions, and handoff identity. Configure its backend URL and token to point at the beta service. Regular Velvet remains installed. Velour continues to integrate with regular Velvet by default.

During playback, open **Playback options** for recovery diagnostics. No recovery toast or overlay is added to successful playback. Verified seconds may be unavailable when the stream cannot be indexed within the configured limits. A seek invalidates the previous timing window.

This beta's position reporting and testing client are Android TV. iOS and Roku source is retained in this branch, but no separate beta distribution or new client-side recovery UI is supplied for those platforms.

## Measure recovery in the admin dashboard

Use the updated beta backend and Android beta app together, then open **Recovery** at `/admin#recovery`. The beta backend can serve its own report with its own admin key. To bring that report into your existing Velvet dashboard, set `VELVET_RECOVERY_REPORT_URL` to the beta backend’s bare origin and `VELVET_RECOVERY_REPORT_TOKEN` to its admin key on the **dashboard-hosting backend only**. Both are private server configuration; neither belongs in an app, image, repository, or browser URL. A placeholder example is:

```dotenv
VELVET_RECOVERY_REPORT_URL=https://beta-backend.example
VELVET_RECOVERY_REPORT_TOKEN=REPLACE_WITH_BETA_ADMIN_KEY
```

The dashboard server needs a build with the report proxy, network access to the beta backend, and those variables passed into its container environment. Restart it after configuration. Keep the proxy variables unset on the beta backend so it reports its own local database. See [the backend setup instructions](backend/README.md#recovery-reporting-for-velvet-beta) for the admin-key command and deployment details. Existing stable capacity/playback reports remain separate.

Recovery reporting shows provider article rescues, PAR2 outcomes and failure reasons, repair download overhead, prepared-only jobs, and watches that received repaired bytes. It counts **successful replacement starts** separately from manual/automatic source-switch attempts. Switches per watch includes every measured movie or episode watch with positive playing time, including those with no switches; sessions that never start are still available in session details and the CSV. Startup and post-start buffering show the observed viewing experience.

Successful jobs labeled **Started by look-ahead** or **Started by playback request** describe what initiated the repair. They do not establish whether repair finished before the playhead, nor that a stall was prevented. Repaired-byte delivery is observed on the server, not proof of decoded frames. Collection is prospective: prior repair history cannot be reconstructed. Missing or unreachable reporting stays unavailable, and dropped-event warnings identify incomplete collection. Recovery events are retained for up to 90 days or 250,000 records.

## Validation and reproducible tests

```sh
cd backend
# Install ffmpeg/ffprobe and the official par2cmdline first.
VELVET_TEST_PAR2=/path/to/par2 cargo test --locked
cargo build --locked
python3 tests/recovery_e2e.py --binary target/debug/velvet-backend --par2 /path/to/par2
```

The black-box test generates its own video and real PAR2 data, starts two loopback NNTP fixtures, and runs the actual backend. It checks corrupt-primary provider fallback, missing-article repair through the original HTTP stream, packet-indexed repair ahead of playback, exact file identity, successful decoding, and safe failure with insufficient parity. Evidence and media are written outside the repository. No real provider or deployed service is contacted.

Validation on October 22, 2026: **249 backend tests**, including real PAR2 recovery, and **137 Android tests in each flavor** passed. The black-box test also passed in the final Linux runtime image with external networking disabled. Its synthetic look-ahead case verified about 14.93 seconds before the consumer requested the repaired stream. These results establish controlled correctness, not a real-provider latency guarantee.

The repair module also covers unequal article lengths, consecutive missing ranges, multiple protected files, failed verification, unsafe metadata, cancellation, deadlines, and resource limits. Real PAR2 tests require the executable; CI installs it explicitly.

For hardware testing, start with a troublesome episode, check the verified buffer in Playback options, seek ahead and back, and let it play through its previous failure point. Keep the normal app available for comparison. Synthetic tests establish correctness under controlled conditions; they do not establish real-provider performance or guarantee zero visible stalls.

## Limits to keep visible

- No usable parity, too many missing blocks, inaccessible supporting data, or a deadline/cap can make exact recovery impossible.
- Archive headers must still be readable to construct media extents. Recovery does not add support for compressed archive formats or missing archive metadata during initial loading.
- PAR2 may need much of a release before it can recover a small hole. A short look-ahead window cannot hide arbitrarily slow downloads.
- Packet indexing has time, byte, and memory caps. Unknown coverage stays unknown.
- Provider retries and parity traffic use additional bandwidth and provider connections.
- A different release can have different edits, frame timing, audio, or HDR metadata. This beta does not splice it into the original byte stream or claim an invisible handoff.
- This branch is experimental. Roll back by opening regular Velvet and stopping only the beta backend. The stable database is independent.
