package tv.velvet.data.streams

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.StreamOption
import tv.velvet.data.model.StreamSourceConfig
import tv.velvet.data.net.await
import tv.velvet.data.settings.SettingsRepository
import java.io.InputStream
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Stremio-protocol-compatible stream resolution.
 *
 * All enabled sources are queried in parallel; each source gets its own try/catch and a
 * 12s timeout, so a dead/unauthorized source (e.g. usenet-streamer answering 401 without
 * its token) contributes an empty list and never blocks or breaks the others.
 *
 * Resolution alone isn't enough: nzbdav happily lists NZBs that are dead or incomplete, so
 * [probeStreams] range-probes the top candidates before the player commits to one, and the
 * survivors double as the mid-playback failover list.
 */
class StreamRepositoryImpl(
    private val client: OkHttpClient,
    private val json: Json,
    private val settings: SettingsRepository,
) : StreamRepository {

    // Internal, not private: [streamComparator] is pure and unit-tested directly —
    // the tests must exercise the EXACT production ordering, not a re-implementation.
    internal companion object {
        const val SOURCE_TIMEOUT_MS = 12_000L

        /**
         * Health probe (spec §3a): 128 KB range read. Budget is 10 s — a COLD nzbdav
         * only starts assembling the NZB when first hit, so first byte legitimately
         * lands at 3–8 s; 6 s classified live-but-cold sources as dead.
         */
        const val PROBE_TIMEOUT_MS = 10_000L
        /**
         * Max probes in flight at once. nzbdav starts a fresh assembly job per open
         * connection, so racing all 5 candidates starves every one of them — the good
         * stream then misses its budget too and we fall back to playing dead streams.
         * Two at a time lets a healthy candidate actually deliver.
         */
        const val PROBE_CONCURRENCY = 2
        const val PROBE_BYTES = 131_072L
        const val PROBE_CHUNK = 16 * 1024

        val QUALITY_2160 = Regex("(?i)\\b(2160p|4k|uhd|ultra\\s*hd)\\b")
        val QUALITY_1080 = Regex("(?i)\\b(1080p|fhd|full\\s*hd)\\b")
        val QUALITY_720 = Regex("(?i)\\b720p\\b")
        val QUALITY_480 = Regex("(?i)\\b480p\\b")

        /**
         * Matches "12.3 GB", "700MB", "1,4 gb", "4.18 GiB" — first match wins.
         * KB-and-up only: a bare "B" unit would misparse bit-depth tokens in release
         * names ("HEVC.10b-GROUP" → 10 bytes) and silently corrupt stream sorting.
         */
        val SIZE_TEXT = Regex("(?i)(\\d+(?:[.,]\\d+)?)\\s*([TGMK]i?B)\\b")

        /**
         * THE stream ordering — best playable quality first, size demoted to tiebreaker.
         *
         * Sorting by size within a resolution picked the BIGGEST file, not the best: a
         * bloated 90 GB HDR10 web encode outranked a 60 GB DoVi TrueHD remux. So after
         * the resolution tiers, real quality signals decide — remux beats re-encode,
         * then dynamic range (DoVi > HDR10+ > HDR10/HDR > none), then audio (TrueHD
         * Atmos > DTS-X > … > DD), and only THEN does size break the remaining ties.
         *
         * 3D (side-by-side / over-under) sinks below every 2D release: it's almost never
         * wanted on a normal screen, so autoPick, the picker order, and probeStreams all
         * prefer 2D. A 3D release only surfaces if nothing else exists.
         *
         * Semantic twin of velvet-backend's release::cmp_streams (ported from this app's
         * StreamTags) — the backend pre-warms whatever this order puts first, so the two
         * MUST keep agreeing or the pre-warm warms the wrong file.
         */
        fun streamComparator(preferredQuality: String): Comparator<StreamOption> =
            compareBy<StreamOption> { StreamTags.is3D(it.title) }
                .thenByDescending { it.quality?.equals(preferredQuality, ignoreCase = true) == true }
                .thenByDescending { qualityRank(it.quality) }
                .thenByDescending { StreamTags.isRemux(it.title) }
                .thenByDescending { StreamTags.hdrRank(it.title) }
                .thenByDescending { StreamTags.audioRank(it.title) }
                .thenByDescending { it.sizeBytes ?: -1L }

        private fun qualityRank(quality: String?): Int = when (quality?.lowercase(Locale.US)) {
            "2160p" -> 4
            "1080p" -> 3
            "720p" -> 2
            "480p" -> 1
            else -> 0
        }
    }

    /**
     * Probe client: shares the app client's connection pool, dispatcher and cache, but gives
     * each probe a hard end-to-end budget — the shared 20 s read timeout is far too patient
     * when five candidates are being raced. Redirects are followed (nzbdav hands out 302s).
     */
    private val probeClient: OkHttpClient by lazy {
        client.newBuilder()
            .callTimeout(PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .connectTimeout(PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .readTimeout(PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
    }

    override suspend fun streamsFor(
        imdbId: String,
        type: MediaType,
        season: Int?,
        episode: Int?,
    ): List<StreamOption> {
        if (imdbId.isBlank()) return emptyList()
        val config = settings.settings.first()
        val sources = config.streamSources.filter { it.enabled }
        if (sources.isEmpty()) return emptyList()

        val streamPath = when (type) {
            MediaType.MOVIE -> "stream/movie/$imdbId.json"
            MediaType.SHOW -> {
                val s = season ?: return emptyList()
                val e = episode ?: return emptyList()
                "stream/series/$imdbId:$s:$e.json"
            }
        }

        return coroutineScope {
            sources.map { source ->
                async {
                    try {
                        withTimeoutOrNull(SOURCE_TIMEOUT_MS) {
                            querySource(source, streamPath, config.backendUrl)
                        } ?: emptyList()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        emptyList() // non-200, network error, bad JSON — never throw
                    }
                }
            }.awaitAll().flatten()
        }
    }

    override fun sortStreams(streams: List<StreamOption>, preferredQuality: String): List<StreamOption> =
        streams.sortedWith(streamComparator(preferredQuality))

    override fun autoPick(
        streams: List<StreamOption>,
        preferredQuality: String,
        previousBingeGroup: String?,
        manualGroup: String?,
    ): StreamOption? {
        if (streams.isEmpty()) return null
        val sorted = sortStreams(streams, preferredQuality)
        // A hand-picked release group (the user overrode an autopick that had issues)
        // outranks session binge continuity. No match for this episode? Fall through
        // silently — best quality just plays, per the owner's spec.
        if (!manualGroup.isNullOrBlank()) {
            sorted.firstOrNull { it.bingeGroup == manualGroup }?.let { return it }
        }
        if (!previousBingeGroup.isNullOrBlank()) {
            sorted.firstOrNull { it.bingeGroup == previousBingeGroup }?.let { return it }
        }
        return sorted.first()
    }

    // ── health probing ───────────────────────────────────────────────────────

    override suspend fun probeStreams(streams: List<StreamOption>, limit: Int): List<StreamOption> {
        if (streams.isEmpty() || limit <= 0) return streams
        val candidates = streams.take(limit)
        // awaitAll preserves candidate order, so the survivors keep the caller's sort.
        // A semaphore caps how many probes hit nzbdav at once (see PROBE_CONCURRENCY).
        val gate = Semaphore(PROBE_CONCURRENCY)
        val healthy = coroutineScope {
            candidates.map { option -> async { gate.withPermit { option.takeIf { probe(it) } } } }.awaitAll()
        }.filterNotNull()
        // All dead (or the whole network is down) — hand back the untouched sorted list so
        // the player still tries something instead of claiming there are no streams.
        return healthy.ifEmpty { streams }
    }

    /**
     * One candidate: ranged GET, 200/206 + >=1 byte of body = healthy. Reads at most
     * [PROBE_BYTES] and never buffers more than [PROBE_CHUNK] at a time, so a source that
     * ignores Range and answers 200 with a 40 GB file can't blow the heap (the 256 MB
     * buffer cap exists for a reason). Never throws — a failure just drops the candidate.
     */
    private suspend fun probe(option: StreamOption): Boolean {
        val url = option.url.toHttpUrlOrNull() ?: return false
        val builder = Request.Builder().url(url).get()
        option.headers.forEach { (name, value) -> builder.header(name, value) }
        builder.header("Range", "bytes=0-${PROBE_BYTES - 1}") // wins over any source header
        val request = builder.build()
        return try {
            // callTimeout bounds the socket work; withTimeoutOrNull bounds the coroutine even
            // if a read blocks past it. Slightly longer so OkHttp is the one that gives up.
            withTimeoutOrNull(PROBE_TIMEOUT_MS + 500L) {
                probeClient.await(request).use { response ->
                    if (response.code != 200 && response.code != 206) return@use false
                    val body = response.body ?: return@use false
                    withContext(Dispatchers.IO) { readsAtLeastOneByte(body.byteStream()) }
                }
            } ?: false
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            false // 4xx/5xx, timeout, reset, TLS failure, malformed range — all just unhealthy
        }
    }

    /**
     * The health criterion is ONE byte (spec §3a), so return the instant one arrives rather
     * than draining the whole 128 KB range. These race against the same nzbdav host (at most
     * [PROBE_CONCURRENCY] at once) inside a ~10 s budget: waiting for the full range classified
     * a healthy but slow usenet source — first byte at 3–8 s, 128 KB not until later — as dead,
     * and burnt 128 KB of transfer per candidate behind every "Finding the best stream…"
     * overlay. The Range header still bounds what the server offers, and the loop never buffers
     * more than one chunk.
     */
    private fun readsAtLeastOneByte(stream: InputStream): Boolean {
        val chunk = ByteArray(PROBE_CHUNK)
        var total = 0L
        try {
            while (total < PROBE_BYTES) {
                val want = minOf(PROBE_BYTES - total, PROBE_CHUNK.toLong()).toInt()
                val read = stream.read(chunk, 0, want)
                if (read <= 0) break
                total += read
                if (total > 0) return true
            }
        } catch (_: Exception) {
            // A stall or reset mid-body still counts as unhealthy unless bytes already flowed.
        }
        return total > 0
    }

    // ── per-source query ─────────────────────────────────────────────────────

    private suspend fun querySource(source: StreamSourceConfig, streamPath: String, configuredBackend: String): List<StreamOption> {
        val base = normalizeBaseUrl(source.baseUrl) ?: return emptyList()
        val url = "$base/$streamPath".toHttpUrlOrNull() ?: return emptyList()
        val request = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .get()
            .build()
        val body: String = client.await(request).use { response ->
            if (!response.isSuccessful) return emptyList()
            withContext(Dispatchers.IO) { response.body?.string() }
        } ?: return emptyList()
        val parsed = try {
            json.decodeFromString(StremioStreamsResponse.serializer(), body)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return emptyList()
        }
        return parsed.streams.mapNotNull { it.toOption(source.name, base, configuredBackend) }
    }

    /** Accepts pasted ".../manifest.json" URLs and trailing slashes; rejects non-http. */
    private fun normalizeBaseUrl(raw: String): String? {
        var base = raw.trim().removeSuffix("/")
        if (base.endsWith("/manifest.json")) base = base.removeSuffix("/manifest.json")
        base = base.removeSuffix("/")
        return base.takeIf { it.startsWith("http://") || it.startsWith("https://") }
    }

    // ── mapping & parsing ────────────────────────────────────────────────────

    private fun StremioStreamDto.toOption(sourceName: String, sourceBase: String, configuredBackend: String): StreamOption? {
        // Torrent entries carry infoHash without url — only direct http(s) URLs are playable.
        val playableUrl = url
            ?.trim()
            ?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
            ?: return null
        val haystack = listOfNotNull(behaviorHints?.filename, title, description, name)
            .joinToString("\n")
        val sizeBytes = behaviorHints?.videoSize?.takeIf { it > 0 }?.toLong()
            ?: parseSizeBytes(haystack)
        val displayTitle = behaviorHints?.filename?.takeIf(String::isNotBlank)
            ?: (title ?: description)?.lineSequence()?.firstOrNull { it.isNotBlank() }?.trim()
            ?: name?.replace('\n', ' ')?.trim()?.takeIf(String::isNotEmpty)
            ?: "Stream"
        return StreamOption(
            url = backendStreamPlaybackUrl(playableUrl, sourceBase, configuredBackend),
            title = displayTitle,
            quality = parseQuality(haystack),
            sizeBytes = sizeBytes,
            sourceName = sourceName,
            bingeGroup = behaviorHints?.bingeGroup?.takeIf(String::isNotBlank),
            headers = behaviorHints?.proxyHeaders?.request ?: emptyMap(),
            sourceReadiness = behaviorHints?.velvetSourceReadiness,
            readinessObservedAtMs = System.nanoTime() / 1_000_000,
        )
    }

    private fun parseQuality(text: String): String? = when {
        QUALITY_2160.containsMatchIn(text) -> "2160p"
        QUALITY_1080.containsMatchIn(text) -> "1080p"
        QUALITY_720.containsMatchIn(text) -> "720p"
        QUALITY_480.containsMatchIn(text) -> "480p"
        else -> null
    }

    private fun parseSizeBytes(text: String): Long? {
        val match = SIZE_TEXT.find(text) ?: return null
        val value = match.groupValues[1].replace(',', '.').toDoubleOrNull() ?: return null
        // Release tooling means binary sizes whether it writes "GB" or "GiB" — 1024-based.
        val multiplier = when (match.groupValues[2].uppercase(Locale.US)) {
            "TB", "TIB" -> 1_099_511_627_776.0
            "GB", "GIB" -> 1_073_741_824.0
            "MB", "MIB" -> 1_048_576.0
            "KB", "KIB" -> 1_024.0
            else -> return null
        }
        return (value * multiplier).toLong().takeIf { it > 0 }
    }
}
