package tv.velvet.data.streams

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import org.junit.Assert.*
import org.junit.Test
import java.io.EOFException
import java.io.IOException
import java.net.ProtocolException
import java.net.SocketTimeoutException

@OptIn(UnstableApi::class)
class StreamLoadErrorPolicyTest {
    @Test fun startupStillFailsFastEvenForTransientGatewayErrors() {
        val budget = StreamRecoveryBudget(); val generation = budget.sourceChanged()
        val policy = StreamLoadErrorPolicy(budget, generation) { 1000 }
        assertEquals(0, policy.getMinimumLoadableRetryCount(C.DATA_TYPE_MEDIA))
        assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(StreamPolicyFixtures.info(StreamPolicyFixtures.http(502, null, ""), 1)))
        assertEquals(0L, budget.retryUntilMs)
    }

    @Test fun actualMedia3PolicyRetriesEstablishedTransient502OnlyTwice() {
        val budget = StreamRecoveryBudget(); val generation = budget.sourceChanged(); establish(budget)
        val policy = StreamLoadErrorPolicy(budget, generation) { 2000 }
        val error = StreamPolicyFixtures.http(502, null, "Transient proxy error")
        assertEquals(2, policy.getMinimumLoadableRetryCount(C.DATA_TYPE_MEDIA))
        assertEquals(250L, policy.getRetryDelayMsFor(StreamPolicyFixtures.info(error, 1)))
        assertEquals(750L, policy.getRetryDelayMsFor(StreamPolicyFixtures.info(error, 2)))
        assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(StreamPolicyFixtures.info(error, 3)))
    }

    @Test fun knownPermanentFailuresNeverRetryEvenWhenTheirStatusIs502() {
        val budget = StreamRecoveryBudget(); val generation = budget.sourceChanged(); establish(budget)
        val policy = StreamLoadErrorPolicy(budget, generation) { 2000 }
        for (code in listOf("missing_articles", "unsupported_archive", "invalid_archive", "unknown_stream", "invalid_range")) {
            assertEquals(code, C.TIME_UNSET, policy.getRetryDelayMsFor(
                StreamPolicyFixtures.info(StreamPolicyFixtures.http(502, code, "private upstream detail"), 1)))
        }
        assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(StreamPolicyFixtures.info(
            StreamPolicyFixtures.http(502, null, "source has missing articles"), 1)))
        for (status in listOf(401, 403, 404, 416, 422)) assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(
            StreamPolicyFixtures.info(StreamPolicyFixtures.http(status, null, ""), 1)))
        assertEquals(0L, budget.retryUntilMs)
    }

    @Test fun transportCausesAreRecognizedWithoutRetryingEveryIOException() {
        val budget = StreamRecoveryBudget(); val generation = budget.sourceChanged(); establish(budget)
        val policy = StreamLoadErrorPolicy(budget, generation) { 2000 }
        for (error in listOf(SocketTimeoutException(), EOFException(), ProtocolException("unexpected end of stream"), IOException("wrapped", SocketTimeoutException()))) {
            assertEquals(250L, policy.getRetryDelayMsFor(StreamPolicyFixtures.info(error, 1)))
        }
        assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(StreamPolicyFixtures.info(IOException("parser failed"), 1)))
        assertEquals(C.TIME_UNSET, policy.getRetryDelayMsFor(StreamPolicyFixtures.info(ProtocolException("malformed HTTP response"), 1)))
    }

    @Test fun expiredWindowAndStaleSourceGenerationCannotRetry() {
        val budget = StreamRecoveryBudget(); val generation = budget.sourceChanged(); establish(budget)
        var now = 2000L
        val oldPolicy = StreamLoadErrorPolicy(budget, generation) { now }
        val error = StreamPolicyFixtures.info(StreamPolicyFixtures.http(503, "upstream_unavailable", ""), 1)
        assertEquals(250L, oldPolicy.getRetryDelayMsFor(error))
        now = 17_000
        assertEquals(C.TIME_UNSET, oldPolicy.getRetryDelayMsFor(error))
        budget.sourceChanged(); establish(budget)
        assertEquals(0, oldPolicy.getMinimumLoadableRetryCount(C.DATA_TYPE_MEDIA))
        assertEquals(C.TIME_UNSET, oldPolicy.getRetryDelayMsFor(error))
        assertEquals(0L, budget.retryUntilMs)
    }

    private fun establish(budget: StreamRecoveryBudget) {
        budget.observe(0, 100_000, true); budget.observe(1000, 101_000, true)
    }
}
