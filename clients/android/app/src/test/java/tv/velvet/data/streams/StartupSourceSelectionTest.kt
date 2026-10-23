package tv.velvet.data.streams

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.model.SourceReadiness
import tv.velvet.data.model.StreamOption

class StartupSourceSelectionTest {
    private fun stream(index: Int, readiness: String? = null, observed: Long = 0) = StreamOption(
        url = "https://example.test/stream/$index", title = "Source $index", sourceName = "Test",
        sourceReadiness = readiness?.let { SourceReadiness(it) }, readinessObservedAtMs = observed,
    )

    @Test fun aPreparedSourcePastTheOldRetryLimitIsSelectedAndOtherReadySourcesRemain() {
        val sources = (1..40).map(::stream)
        val health = sources.take(28).associate { it.url to SourceReadiness("unavailable") } +
            mapOf(sources[28].url to SourceReadiness("ready"), sources[35].url to SourceReadiness("ready"))
        val selected = startupCandidates(sources, health)
        assertEquals(listOf(sources[28], sources[35]), selected.take(2))
        assertEquals(sources[29], selected[2])
        assertEquals(40, sources.size) // The manual picker retains every release.
    }

    @Test fun readyQualityOrderAndEpisodeIdentityOutrankStickyReleasePreference() {
        val sources = (1..5).map(::stream)
        val health = sources.associate { it.url to SourceReadiness("ready") }
        val selected = startupCandidates(sources, health,
            verdictRank = { if (it == sources[0]) 2 else 1 }, preferred = sources[0])
        assertEquals(sources.drop(1) + sources[0], selected)
        val unknownPreferred = startupCandidates(sources, mapOf(sources[1].url to SourceReadiness("ready")),
            preferred = sources[0])
        assertEquals(sources[1], unknownPreferred.first())
        assertEquals(sources, startupCandidates(sources, emptyMap()))
    }

    @Test fun readyUnknownEpisodeTitleBeatsUnverifiedConfirmedAndReadyMismatch() {
        val sources = (1..4).map(::stream)
        val health = mapOf(sources[1].url to SourceReadiness("ready"), sources[2].url to SourceReadiness("ready"))
        val selected = startupCandidates(sources, health,
            verdictRank = { when (it) { sources[0] -> 0; sources[2] -> 2; else -> 1 } })
        assertEquals(listOf(sources[1], sources[0], sources[3], sources[2]), selected)
        val high = sources[0].copy(quality = "2160p")
        val low = sources[1].copy(quality = "720p")
        val bothReady = listOf(high, low).associate { it.url to SourceReadiness("ready") }
        assertEquals(high, startupCandidates(listOf(high, low), bothReady, preferred = low).first())
        assertEquals(high, startupCandidates(listOf(high, low), bothReady,
            verdictRank = { if (it == low) 0 else 1 }).first())
    }

    @Test fun establishedPlaybackKeepsTheCurrentPositionPreparedBackupWithoutRevivingDeadSources() {
        val headReady = stream(1).copy(quality = "2160p")
        val positionReady = stream(2).copy(quality = "1080p")
        val sources = listOf(headReady, positionReady)
        val health = mapOf(headReady.url to SourceReadiness("ready"))
        assertEquals(headReady, startupCandidates(sources, health, preferred = positionReady).first())
        assertEquals(positionReady, startupCandidates(sources, health, preferred = positionReady,
            preferPreparedPosition = true).first())
        assertEquals(headReady, startupCandidates(sources,
            health + (positionReady.url to SourceReadiness("unavailable")), preferred = positionReady,
            preferPreparedPosition = true).first())
        assertEquals(headReady, startupCandidates(sources, health,
            verdictRank = { if (it == positionReady) 2 else 1 }, preferred = positionReady,
            preferPreparedPosition = true).first())
    }

    @Test fun onlyFreshHintsCanSkipHealthAndPrefetchRefreshAlwaysRechecks() = runBlocking {
        val fresh = stream(1, "ready", 10_000)
        var calls = 0
        suspend fun snapshot(force: Boolean, at: Long) = startupReadinessSnapshot(listOf(fresh), at, force) {
            calls++; SourceReadiness("unavailable")
        }
        assertEquals("ready", snapshot(false, 10_500)[fresh.url]?.status)
        assertEquals(0, calls)
        assertEquals("unavailable", snapshot(true, 10_500)[fresh.url]?.status)
        assertEquals("unavailable", snapshot(false, 16_000)[fresh.url]?.status)
        assertEquals(2, calls)
    }

    @Test fun concurrentHealthTraversesTheWholeListWithoutExceedingFourRequests() = runBlocking {
        val active = AtomicInteger()
        val maximum = AtomicInteger()
        val calls = AtomicInteger()
        val sources = (1..80).map(::stream)
        val health = startupReadinessSnapshot(sources, 0, true) { source ->
            val count = active.incrementAndGet()
            maximum.updateAndGet { maxOf(it, count) }
            try {
                delay(5)
                calls.incrementAndGet()
                SourceReadiness(if (source == sources[68]) "ready" else "unavailable")
            } finally { active.decrementAndGet() }
        }
        assertEquals(80, calls.get())
        assertEquals(4, maximum.get())
        assertEquals(0, active.get())
        assertEquals(sources[68], startupCandidates(sources, health).single())
    }

    @Test fun bulkHealthReachesTheEntireListInOneRequestAndSkipsLegacyFanout() = runBlocking {
        val sources = (1..180).map(::stream)
        var bulkCalls = 0
        var legacyCalls = 0
        val result = startupReadinessSnapshot(sources, 0, true, bulkQuery = { requested ->
            bulkCalls++
            assertEquals(sources, requested)
            mapOf(sources.last().url to SourceReadiness("ready"))
        }) { legacyCalls++; null }
        assertEquals(1, bulkCalls)
        assertEquals(0, legacyCalls)
        assertEquals(sources.last(), startupCandidates(sources, result).first())
    }

    @Test fun onlyExplicitlyUnsupportedBulkHealthFallsBackToLegacyRequests() = runBlocking {
        val source = stream(1)
        var legacyCalls = 0
        startupReadinessSnapshot(listOf(source), 0, true, bulkQuery = { emptyMap() }) {
            legacyCalls++; SourceReadiness("ready")
        }
        assertEquals(0, legacyCalls) // Auth/transport failure returns an empty snapshot.
        val result = startupReadinessSnapshot(listOf(source), 0, true, bulkQuery = { null }) {
            legacyCalls++; SourceReadiness("ready")
        }
        assertEquals(1, legacyCalls)
        assertEquals("ready", result[source.url]?.status)
    }

    @Test fun aSlowHealthRequestCannotLoseCompletedAnswersOrOutliveItsBatch() = runBlocking {
        val sources = (1..8).map(::stream)
        val active = AtomicInteger()
        val health = startupReadinessSnapshot(sources, 0, true) { source ->
            active.incrementAndGet()
            try {
                delay(if (source == sources[0]) 10 else 10_000)
                SourceReadiness("ready")
            } finally { active.decrementAndGet() }
        }
        assertEquals(mapOf(sources[0].url to SourceReadiness("ready")), health)
        assertEquals(0, active.get())
    }

    @Test fun cancelledNavigationCancelsOutstandingHealthRequests() = runBlocking {
        val active = AtomicInteger()
        val job = async {
            startupReadinessSnapshot((1..12).map(::stream), 0, true) {
                active.incrementAndGet()
                try { delay(10_000); SourceReadiness("ready") }
                finally { active.decrementAndGet() }
            }
        }
        delay(30)
        job.cancelAndJoin()
        assertTrue(job.isCancelled)
        assertEquals(0, active.get())
    }

    @Test fun initialSelectionWaitsBrieflyForServerPreparationAndStopsOnReady() = runBlocking {
        val source = stream(1)
        var calls = 0
        val result = awaitStartupReadiness(listOf(source), false, 1_000) { refresh ->
            calls++
            assertEquals(calls > 1, refresh)
            mapOf(source.url to SourceReadiness(if (calls == 1) "unverified" else "ready"))
        }
        assertEquals(2, calls)
        assertEquals("ready", result[source.url]?.status)
        var unavailableCalls = 0
        awaitStartupReadiness(listOf(source), true, 1_000) {
            unavailableCalls++; mapOf(source.url to SourceReadiness("unavailable"))
        }
        assertEquals(1, unavailableCalls)
    }

    @Test fun preparationWaitIsBoundedAndPreservesTheLastCompleteSnapshot() = runBlocking {
        val source = stream(1)
        var calls = 0
        val result = awaitStartupReadiness(listOf(source), true, 300) {
            calls++
            if (calls > 1) delay(10_000)
            mapOf(source.url to SourceReadiness("unverified"))
        }
        assertEquals(2, calls)
        assertEquals("unverified", result[source.url]?.status)
    }

    @Test fun backendReadinessContractDecodesInResolverAndHealthResponses() {
        val json = Json { ignoreUnknownKeys = true }
        val resolver = json.decodeFromString(StremioStreamsResponse.serializer(), """
            {"streams":[{"url":"https://example.test/stream/1","behaviorHints":{
              "velvetSourceReadiness":{"status":"unavailable","retryAfterSeconds":30}}}]}
        """)
        assertEquals(SourceReadiness("unavailable", 30), resolver.streams.single().behaviorHints?.velvetSourceReadiness)
        val health = json.decodeFromString(StreamHealth.serializer(), """{"status":"warm","startup":{"status":"ready"}}""")
        assertEquals(SourceReadiness("ready"), health.startup)
    }
}
