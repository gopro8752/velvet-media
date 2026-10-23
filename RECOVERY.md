# Playback recovery

Mainline Velvet includes the recovery system originally developed in the isolated beta. It keeps the original HTTP resource and decoder when exact bytes can be recovered; switching to another release remains a fallback and can still interrupt playback.

## How it works

1. Validate yEnc article lengths, offsets, termination, and checksums. Retry corrupt or missing articles against another configured provider using the same message ID.
2. Use client playback-position heartbeats and bounded ffprobe indexing to map upcoming media timestamps to source bytes. Coverage is reported as verified only while validated data remains available.
3. If provider retries fail, use the original NZB, supporting files, and PAR2 data to repair the posted files. Verify the reconstructed files before serving repaired bytes through the existing stream.
4. Keep the normal alternate-source fallback when exact recovery cannot finish. Temporary connection failures receive bounded retries; healthy playback renews the automatic recovery budget.

The backend fixes for unequal article lengths, seek-position loops, classified HTTP errors, and bounded retries are included. An incomplete or unsupported archive is not treated as a successful stream.

## Choosing a playable source

The backend checks candidate releases concurrently, using up to eight source checks according to configured provider capacity. Saved-history sweeps and speculative preparation share at most two of those slots, leaving capacity for current playback requests. Next-episode requests do not wait for the entire saved-history sweep. Article requests share a separate background allowance so discovery leaves room for active playback. It checks high-quality releases alongside compatible encodes, rather than allowing a long run of broken remuxes to hide a playable source farther down the list.

Startup readiness means checksummed bytes cover the actual media's opening and ending windows. It does not mean every article in the release is available or that every client can decode it. Readiness expires when those cached bytes are evicted. Preparation failures receive a short cooldown instead of launching the same expensive work on every request; uncertainty about a provider is not a permanent missing-article verdict.

Updated clients fetch cached readiness in one request protected by the configured backend token, prefer quality among prepared candidates, and continue through untried startup candidates without the former four-failure cutoff. Discovery retains prepared backups and checks higher-quality candidates still outstanding. A failed background check does not interrupt a stream that is already playing. Mid-play alternatives still need preparation around the current playback position; another encode may require a visible player restart.

## Enable on your server

Build the current backend image; it includes ffprobe and PAR2. Add these sections to your private `velvet.toml`, preserving your existing providers, indexers, token, and database:

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

Restart the backend and update your clients. Keep the repair cache on a writable persistent volume with enough free space. These conservative example limits are per backend, and other applications using the same provider account still share its connection allowance.

The 8 GiB job limit includes retained posted files and parity; larger releases can play while healthy but may exceed repair limits. A repair may need much of the release to reconstruct a small hole. The download budget counts provider retries, and interrupted transfers conservatively retain their allocation. The 90-second look-ahead is a target, not a guaranteed buffer.

Repair and buffering remain opt-in server settings so upgrading a self-hosted installation does not silently allocate large repair downloads. Credentials belong in private runtime configuration, never in the image or source tree.

## Reporting

Open **Recovery** in the private admin dashboard. Mainline reports its own database by default. If you previously forwarded this panel to an isolated beta backend, remove `VELVET_RECOVERY_REPORT_URL` and `VELVET_RECOVERY_REPORT_TOKEN` from the main server's environment to show its local recovery activity instead.

Reports distinguish provider article rescues, PAR2 success/failure, failure reasons, download overhead, prepared-only jobs, and watches that received repaired bytes. Source-switch attempts and successful replacement starts are separate. The average uses measured movie/episode watches with positive playing time, including those with zero switches. Legacy telemetry without the required counters is excluded instead of being recorded as zero.

“Started by look-ahead” identifies what initiated a repair; it does not prove that a stall was prevented. Repaired bytes delivered by the server do not prove that the player decoded those frames. Collection is prospective, with retention and incomplete-collection warnings described in the backend admin guide.

## Migrating an isolated beta

The regular Android package remains `tv.velvet`; the optional beta package remains `tv.velvet.beta`. Updating regular Velvet preserves its settings and Velour integration. Use the regular server URL for mainline clients. Keep a backup of beta state before merging any newer watch progress through the sync API, preserving timestamps and profile IDs. Do not replace a populated main database with the beta database or copy beta provider limits over your production configuration.

The isolated beta may remain installed for comparison. Its data, cache, and provider connections are independent, so account for both processes if both backends run.

## Limits and validation

Missing parity, excessive damage, inaccessible supporting data, disk/traffic limits, and deadlines can prevent repair. Archive metadata must be readable enough to construct media extents. Different releases can have different edits, timestamps, codecs, or HDR data; Velvet does not splice arbitrary encodes into the original byte stream.

The backend unit tests cover seeks, offset gaps, error classification, provider fallback, PAR2 verification, cancellation, deadlines, resource limits, and recovery reporting. `backend/tests/recovery_e2e.py` generates media and real PAR2 files, runs local NNTP fixtures, and checks exact-byte recovery, look-ahead, decoding, and safe failure with insufficient parity. These controlled tests establish correctness, not guaranteed performance for every provider and release.
