package tv.velvet.data.streams

import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.model.StreamOption

class StreamRecoveryTest {
    private fun stream(url: String) = StreamOption(url, "release", sourceName = "Velvet")

    @Test fun endpointRetainsPrefixAndAuthorizationQuery() {
        assertEquals("https://host.test/prefix/stream/abc/prepare?token=private",
            StreamRecoveryApi.endpoint("https://host.test/prefix/stream/abc?token=private", "prepare").toString())
        assertNull(StreamRecoveryApi.endpoint("https://host.test/movie.mkv", "prepare"))
        assertNull(StreamRecoveryApi.endpoint("https://host.test/stream/", "health"))
    }

    @Test fun readyFallbackMustBeAnExistingCandidateOnSameOriginAndPath() {
        val current = stream("https://host.test/prefix/stream/current")
        val valid = stream("https://host.test/prefix/stream/backup?token=private")
        val state = StreamHealth("incomplete", RecoveryState("ready", "backup", .5))
        assertEquals(valid, StreamRecoveryApi.preparedCandidate(current, state, listOf(
            stream("https://other.test/prefix/stream/backup"),
            stream("http://host.test/prefix/stream/backup"),
            stream("https://host.test:8443/prefix/stream/backup"),
            stream("https://host.test/other/stream/backup"), valid), requestedFraction = .5))
        assertNull(StreamRecoveryApi.preparedCandidate(current, state, emptyList(), requestedFraction = .5))
        assertNull(StreamRecoveryApi.preparedCandidate(current,
            state.copy(recovery = state.recovery.copy(status = "preparing")), listOf(valid), requestedFraction = .5))
        assertNull(StreamRecoveryApi.preparedCandidate(current,
            state.copy(recovery = state.recovery.copy(streamId = "current")), listOf(current), requestedFraction = .5))
    }

    @Test fun preparedFallbackMustMatchTheLatestRequestedPosition() {
        val current = stream("https://host.test/stream/current")
        val backup = stream("https://host.test/stream/backup")
        fun candidate(prepared: Double?, requested: Double) = StreamRecoveryApi.preparedCandidate(
            current, StreamHealth("incomplete", RecoveryState("ready", "backup", prepared)),
            listOf(backup), requestedFraction = requested,
        )
        assertEquals(backup, candidate(.75, .75))
        assertEquals(backup, candidate(.7519, .75))
        assertEquals(backup, candidate(.7481, .75))
        assertNull(candidate(.5, .75)) // ready state left over from before the seek
        assertNull(candidate(null, .75))
        assertEquals(backup, candidate(.001999, 0.0))
        assertNull(candidate(.002, 0.0)) // strict < .002, not inclusive
        assertNull(candidate(0.0, .002))
    }

    @Test fun nonfinitePreparationOrRequestedPositionNeverMatches() {
        val current = stream("https://host.test/stream/current")
        val backup = stream("https://host.test/stream/backup")
        for (nonfinite in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertNull(StreamRecoveryApi.preparedCandidate(
                current, StreamHealth("incomplete", RecoveryState("ready", "backup", nonfinite)),
                listOf(backup), requestedFraction = .5,
            ))
            assertNull(StreamRecoveryApi.preparedCandidate(
                current, StreamHealth("incomplete", RecoveryState("ready", "backup", .5)),
                listOf(backup), requestedFraction = nonfinite,
            ))
            assertNull(StreamRecoveryApi.preparedCandidate(
                current, StreamHealth("incomplete", RecoveryState("ready", "backup", nonfinite)),
                listOf(backup), requestedFraction = nonfinite,
            ))
        }
    }

    @Test fun callersWithoutRequestedPositionKeepExistingCompatibility() {
        val current = stream("https://host.test/stream/current")
        val backup = stream("https://host.test/stream/backup")
        val health = StreamHealth("incomplete", RecoveryState("ready", "backup"))
        assertEquals(backup, StreamRecoveryApi.preparedCandidate(current, health, listOf(backup)))
    }
}
