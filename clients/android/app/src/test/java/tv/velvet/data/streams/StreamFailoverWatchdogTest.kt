package tv.velvet.data.streams

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamFailoverWatchdogTest {
    @Test fun silentStartupHasSixSecondBudgetAndTriggersOnlyOnce() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0) }
        assertFalse(watchdog.check(5_999))
        assertTrue(watchdog.check(6_000))
        assertFalse(watchdog.check(6_500))
    }

    @Test fun startupThatKeepsBufferingStillStopsAtTwelveSeconds() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0) }
        for (time in 2_000L..10_000L step 2_000L) {
            assertFalse(watchdog.check(time, buffered = time))
        }
        assertFalse(watchdog.check(11_999, buffered = 11_999))
        assertTrue(watchdog.check(12_000, buffered = 12_000))
    }

    @Test fun initialMetadataCountsAsProgressButDurationCorrectionsDoNotHideAStall() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0) }
        assertFalse(watchdog.check(5_000, duration = 100_000))
        assertFalse(watchdog.check(10_999, duration = 100_100))
        assertTrue(watchdog.check(11_000, duration = 100_200))
    }

    @Test fun rebufferAfterPlaybackHasFiveSecondsFromTheStartOfTheStall() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0) }
        assertFalse(watchdog.check(1_000, position = 1_000, buffered = 8_000,
            buffering = false, playing = true))
        assertFalse(watchdog.check(2_000, position = 2_000, buffered = 8_000))
        assertFalse(watchdog.check(6_999, position = 2_000, buffered = 8_000))
        assertTrue(watchdog.check(7_000, position = 2_000, buffered = 8_000))
    }

    @Test fun arrivingBufferDuringRebufferRestartsTheNoProgressBudget() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0) }
        assertFalse(watchdog.check(1_000, position = 1_000, buffered = 2_000,
            buffering = false, playing = true))
        assertFalse(watchdog.check(2_000, position = 2_000, buffered = 2_000))
        assertFalse(watchdog.check(6_000, position = 2_000, buffered = 3_000))
        assertFalse(watchdog.check(10_999, position = 2_000, buffered = 3_000))
        assertTrue(watchdog.check(11_000, position = 2_000, buffered = 3_000))
    }

    @Test fun pausedSuppressedAndIneligibleTimeDoesNotCountTowardRecovery() {
        for (guard in listOf("paused", "suppressed", "ineligible")) {
            val watchdog = StreamFailoverWatchdog().apply { reset(0) }
            assertFalse(watchdog.check(5_000))
            assertFalse(watchdog.check(30_000,
                playWhenReady = guard != "paused", suppressed = guard == "suppressed",
                eligible = guard != "ineligible"))
            assertFalse(watchdog.check(40_000))
            assertFalse(watchdog.check(45_999))
            assertTrue(watchdog.check(46_000))
        }
    }

    @Test fun nonBufferingAndPlayingStatesNeverTriggerADeadline() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0) }
        assertFalse(watchdog.check(30_000, buffering = false))
        assertFalse(watchdog.check(60_000, playing = true))
        assertFalse(watchdog.check(90_000))
        assertFalse(watchdog.check(94_999))
        assertTrue(watchdog.check(95_000))
    }

    @Test fun sourceChangeOrExplicitSeekDropsOldDeadlineAndStartsFreshGrace() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0) }
        assertFalse(watchdog.check(1_000, position = 1_000, buffering = false, playing = true))
        assertFalse(watchdog.check(2_000, position = 2_000))
        watchdog.reset(6_000, positionMs = 60_000, bufferedPositionMs = 60_000, durationMs = 100_000)
        assertFalse(watchdog.check(11_999, position = 60_000, buffered = 60_000, duration = 100_000))
        assertTrue(watchdog.check(12_000, position = 60_000, buffered = 60_000, duration = 100_000))
    }

    @Test fun recoveryRearmsOnlyAfterTheBufferingWindowEnds() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0) }
        assertTrue(watchdog.check(6_000))
        assertFalse(watchdog.check(6_500))
        assertFalse(watchdog.check(7_000, position = 1_000, buffering = false, playing = true))
        assertFalse(watchdog.check(8_000, position = 2_000))
        assertTrue(watchdog.check(13_000, position = 2_000))
    }

    @Test fun unacknowledgedHandoffCannotFailOverButGetsFreshBudgetOnceEligible() {
        val watchdog = StreamFailoverWatchdog().apply { reset(0, positionMs = 120_000) }
        assertFalse(watchdog.check(60_000, position = 120_000, eligible = false))
        assertFalse(watchdog.check(90_000, position = 120_000, eligible = false))
        assertFalse(watchdog.check(91_000, position = 120_000))
        assertFalse(watchdog.check(96_999, position = 120_000))
        assertTrue(watchdog.check(97_000, position = 120_000))
    }

    private fun StreamFailoverWatchdog.check(
        now: Long,
        position: Long = 0,
        buffered: Long = 0,
        duration: Long = 0,
        buffering: Boolean = true,
        playing: Boolean = false,
        playWhenReady: Boolean = true,
        suppressed: Boolean = false,
        eligible: Boolean = true,
    ) = shouldFailover(now, position, buffered, duration, buffering, playing, playWhenReady, suppressed, eligible)
}
