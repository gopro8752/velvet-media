package tv.velvet.data.streams

import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class ExactRecoveryTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun legacyBackendDoesNotClaimExactRecoveryOrHoldFallback() {
        val health = json.decodeFromString(StreamHealth.serializer(),
            """{"status":"incomplete","recovery":{"status":"ready","streamId":"alternate"}}""")
        assertNull(health.exactRecovery)
    }

    @Test fun onlyFreshEnabledServerDecisionHoldsSpeculativeSwitching() {
        val fresh = ExactRecoveryState(enabled = true, holdFallback = true, updatedAgoSeconds = 2.0)
        assertTrue(fresh.shouldHoldProactiveFallback())
        assertFalse(fresh.copy(enabled = false).shouldHoldProactiveFallback())
        assertFalse(fresh.copy(holdFallback = false).shouldHoldProactiveFallback())
        for (age in listOf(null, -1.0, 8.001, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertFalse(fresh.copy(updatedAgoSeconds = age).shouldHoldProactiveFallback())
        }
    }

    @Test fun missingTimingIndexDoesNotInventVerifiedSeconds() {
        val health = json.decodeFromString(StreamHealth.serializer(),
            """{"exactRecovery":{"enabled":true,"status":"repairing","indexStatus":"building","holdFallback":true,"updatedAgoSeconds":1.2,"lookaheadTargetSeconds":90},"repair":{"privateDetail":"must not enter UI"}}""")
        assertTrue(health.exactRecovery!!.shouldHoldProactiveFallback())
        assertNull(health.exactRecovery!!.verifiedAheadSeconds)
    }

    @Test fun repairMetricsDecodeWithoutCarryingUpstreamErrorDetail() {
        val health = json.decodeFromString(StreamHealth.serializer(),
            """{"repair":{"phase":"ready","charged_download_bytes":1048576,"detail":"private provider value","reserved_bytes":2097152}}""")
        assertEquals(ExactRepairState("ready", 1048576), health.repair)
    }

    @Test fun playbackContractCarriesGenerationAndExplicitStop() {
        val sample = RecoveryPlaybackPosition(12_000, 600_000, 42_000, true,
            sessionId = "independent-install-session", generation = 4)
        val stopped = sample.copy(playing = false, stopped = true)
        val encoded = json.encodeToString(RecoveryPlaybackPosition.serializer(), stopped)
        val decoded = json.decodeFromString(RecoveryPlaybackPosition.serializer(), encoded)
        assertEquals(stopped, decoded)
        assertTrue(encoded.contains("\"generation\":4"))
        assertTrue(encoded.contains("\"stopped\":true"))
        assertEquals("https://backend.example.com/stream/id/playback", StreamRecoveryApi.endpoint(
            "https://backend.example.com/stream/id", "playback").toString())
    }
}
