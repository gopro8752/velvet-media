package tv.velvet.data.telemetry

import org.junit.Assert.assertEquals
import org.junit.Test

class RecoveryPlaybackMetricsTest {
    @Test fun sourceAttemptsAndActualStartsAreDistinctAndIdempotent() {
        val metrics = RecoveryPlaybackMetrics(0)
        metrics.sourcePrepared("original", SourceSwitchReason.AUTOMATIC)
        metrics.sample(0, "playing", "original", true)
        metrics.sourcePrepared("broken", SourceSwitchReason.AUTOMATIC)
        metrics.sourcePrepared("broken", SourceSwitchReason.MANUAL) // Retry, not a switch.
        metrics.sample(1, "playing", "original", true) // Late event from the previous item.
        assertEquals(0, metrics.sourceSwitches)
        metrics.sourcePrepared("working", SourceSwitchReason.AUTOMATIC)
        metrics.sample(10, "playing", "working", true)
        metrics.sample(1000, "playing", "working", true)
        metrics.sourcePrepared("preferred", SourceSwitchReason.MANUAL)
        metrics.sample(2000, "playing", "preferred", true)
        assertEquals(3, metrics.sourceSwitchAttempts)
        assertEquals(2, metrics.automaticSwitchAttempts)
        assertEquals(1, metrics.manualSwitchAttempts)
        assertEquals(2, metrics.sourceSwitches)
        assertEquals(1, metrics.automaticSourceSwitches)
        assertEquals(1, metrics.manualSourceSwitches)
    }

    @Test fun initialLoadPausedAndSuppressedBufferingAreNotRebuffers() {
        val metrics = RecoveryPlaybackMetrics(0)
        metrics.sample(1000, "buffering", "a", true)
        metrics.sample(2000, "playing", "a", true)
        metrics.sample(3000, "buffering", "a", false) // User paused or audio focus was lost.
        metrics.sample(4000, "buffering", "a", false)
        metrics.sample(5000, "playing", "a", true)
        assertEquals(0, metrics.rebufferCount)
        assertEquals(0L, metrics.rebufferedMs)
        metrics.sample(6000, "buffering", "a", true)
        metrics.sample(6000, "buffering", "a", true) // Duplicate callbacks.
        metrics.sample(7000, "buffering", "a", true)
        metrics.sample(7500, "playing", "a", true)
        metrics.sample(8500, "buffering", "a", true)
        metrics.sample(9000, "ended", null, false)
        assertEquals(2, metrics.rebufferCount)
        assertEquals(2000L, metrics.rebufferedMs)
        assertEquals(1500L, metrics.maxRebufferMs)
    }

    @Test fun seekLoadingDoesNotHideSubsequentRealStall() {
        val metrics = RecoveryPlaybackMetrics(0)
        metrics.sample(0, "playing", "a", true, 10_000)
        metrics.beginSeek(20_000)
        metrics.sample(0, "playing", "a", true, 10_000) // Synchronous stale position.
        metrics.seekDispatched()
        metrics.sample(1000, "buffering", "a", true, 20_000)
        metrics.sample(2000, "playing", "a", true, 20_000)
        assertEquals(0, metrics.rebufferCount)
        assertEquals(0L, metrics.rebufferedMs)
        metrics.sample(3000, "buffering", "a", true, 21_000)
        metrics.sample(4500, "playing", "a", true, 21_000)
        assertEquals(1, metrics.seekCount)
        assertEquals(1, metrics.rebufferCount)
        assertEquals(1500L, metrics.rebufferedMs)
    }

    @Test fun tinySeekCannotClearSuppressionBeforeTheSeekIsDispatched() {
        val metrics = RecoveryPlaybackMetrics(0)
        metrics.sample(0, "playing", "a", true, 10_000)
        metrics.beginSeek(10_500)
        metrics.sample(0, "playing", "a", true, 10_000)
        metrics.sample(1000, "buffering", "a", true, 10_500)
        metrics.seekDispatched()
        metrics.sample(2000, "playing", "a", true, 10_500)
        assertEquals(0L, metrics.rebufferedMs)
        assertEquals(0, metrics.rebufferCount)
    }

    @Test fun suspensionCannotClaimHoursOfRebuffering() {
        val metrics = RecoveryPlaybackMetrics(0)
        metrics.sample(0, "playing", "a", true)
        metrics.sample(1000, "buffering", "a", true)
        metrics.sample(3_600_000, "paused", "a", false)
        assertEquals(2000L, metrics.rebufferedMs)
        assertEquals(1, metrics.rebufferCount)
    }

    @Test fun delayedPlayingSamplePastTheSeekTargetRestoresStallCounting() {
        val metrics = RecoveryPlaybackMetrics(0)
        metrics.sample(0, "playing", "a", true, 10_000)
        metrics.beginSeek(20_000)
        metrics.seekDispatched()
        metrics.sample(5000, "playing", "a", true, 25_000)
        metrics.sample(6000, "buffering", "a", true, 26_000)
        metrics.sample(7000, "playing", "a", true, 26_000)
        assertEquals(1, metrics.rebufferCount)
        assertEquals(1000L, metrics.rebufferedMs)
    }

    @Test fun newEpisodeHasFreshCountersAndDoesNotCountItsFirstSourceAsASwitch() {
        val previous = RecoveryPlaybackMetrics(0)
        previous.sourcePrepared("episode-one", SourceSwitchReason.AUTOMATIC)
        previous.sourcePrepared("episode-one-alternate", SourceSwitchReason.AUTOMATIC)
        previous.sample(100, "playing", "episode-one-alternate", true)
        val next = RecoveryPlaybackMetrics(100)
        next.sourcePrepared("episode-two", SourceSwitchReason.AUTOMATIC)
        next.sample(200, "playing", "episode-two", true)
        assertEquals(1, previous.sourceSwitches)
        assertEquals(0, next.sourceSwitches)
        assertEquals(0, next.sourceSwitchAttempts)
    }
}
