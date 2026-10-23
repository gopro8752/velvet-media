package tv.velvet.data.streams

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import tv.velvet.data.model.SourceReadiness
import tv.velvet.data.model.StreamOption

/** Cached server metadata only: this never opens media or starts a byte probe. */
internal suspend fun startupReadinessSnapshot(
    streams: List<StreamOption>,
    nowMs: Long,
    forceRefresh: Boolean,
    bulkQuery: (suspend (List<StreamOption>) -> Map<String, SourceReadiness>?)? = null,
    query: suspend (StreamOption) -> SourceReadiness?,
): Map<String, SourceReadiness> {
    val results = ConcurrentHashMap<String, SourceReadiness>()
    if (!forceRefresh) streams.forEach { stream ->
        val age = nowMs - stream.readinessObservedAtMs
        stream.sourceReadiness?.takeIf { age in 0..5_000 }?.let { results[stream.url] = it }
    }
    val requested = streams.filterNot { results.containsKey(it.url) }
        // A previously ready source can sit far below many unusable remuxes.
        .sortedBy { if (it.sourceReadiness?.status == "ready") 0 else 1 }
        .distinctBy { it.url }
    if (bulkQuery != null && requested.isNotEmpty()) {
        var unsupported = false
        withTimeoutOrNull(1_000) {
            val bulk = bulkQuery(requested)
            if (bulk == null) unsupported = true else results.putAll(bulk)
        }
        // Timeouts/auth/network failures must not fan out into hundreds of requests.
        // Only an old backend's explicit unsupported response enables legacy polling.
        if (!unsupported) return results.toMap()
    }
    val slots = Semaphore(4)
    withTimeoutOrNull(1_000) {
        coroutineScope {
            requested.map { stream -> async {
                slots.withPermit { query(stream)?.let { results[stream.url] = it } }
            } }.awaitAll()
        }
    }
    // Keep completed answers when one server request missed the total deadline.
    return results.toMap()
}

/** Give the server's parallel preparation a brief head start, without opening media. */
internal suspend fun awaitStartupReadiness(
    streams: List<StreamOption>,
    forceRefresh: Boolean,
    waitForReadyMs: Long,
    snapshot: suspend (Boolean) -> Map<String, SourceReadiness>,
): Map<String, SourceReadiness> {
    if (streams.isEmpty() || waitForReadyMs <= 0) return snapshot(forceRefresh)
    var latest = emptyMap<String, SourceReadiness>()
    withTimeoutOrNull(waitForReadyMs) {
        latest = snapshot(forceRefresh)
        while (latest.values.none { it.status == "ready" } &&
            streams.any { latest[it.url]?.status != "unavailable" }) {
            delay(200)
            latest = snapshot(true)
        }
    }
    return latest
}

/** A mismatch stays last; confirmed and unknown episode titles share the quality tier. */
internal fun startupCandidates(
    ordered: List<StreamOption>,
    readiness: Map<String, SourceReadiness>,
    verdictRank: (StreamOption) -> Int = { 1 },
    preferred: StreamOption? = null,
    preferPreparedPosition: Boolean = false,
): List<StreamOption> {
    fun readyRank(stream: StreamOption) = if (readiness[stream.url]?.status == "ready") 0 else 1
    fun mismatchRank(stream: StreamOption) = if (verdictRank(stream) == 2) 1 else 0
    val eligible = ordered.filterNot { readiness[it.url]?.status == "unavailable" }
        .sortedWith(compareBy<StreamOption> { mismatchRank(it) }.thenBy { readyRank(it) })
    // A mid-play alternate verified at the current position is more useful than
    // a higher-quality source with only its opening warmed. Initial sticky group
    // preference stays within the best quality/readiness tier. Neither can revive
    // an unavailable source or promote an episode-title mismatch.
    val first = eligible.firstOrNull() ?: return emptyList()
    val promoted = preferred?.takeIf { wanted -> eligible.any { it.url == wanted.url } &&
        mismatchRank(wanted) == mismatchRank(first) &&
        (preferPreparedPosition || (readyRank(wanted) == readyRank(first) && wanted.quality == first.quality)) }
    return if (promoted == null) eligible else listOf(promoted) + eligible.filterNot { it.url == promoted.url }
}
