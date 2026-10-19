package tv.velvet.data.telemetry

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackClockTest {
    @Test fun countsWallTimeNotPauseOrSeekPosition() {
        val clock = PlaybackClock(0)
        clock.sample(1000, "playing")
        clock.sample(2000, "playing")
        clock.sample(2500, "paused")
        clock.sample(3500, "buffering")
        clock.sample(4500, "playing")
        clock.sample(5000, "ended")
        clock.sample(6000, "ended")
        assertEquals(2000L, clock.playedMs)
        assertEquals(2000L, clock.bufferedMs)
    }
    @Test fun duplicateCallbacksAndSuspensionDoNotInflateViewing() {
        val clock = PlaybackClock(0)
        clock.sample(0, "playing")
        clock.sample(1000, "playing")
        clock.sample(1000, "playing")
        clock.sample(3600000, "paused")
        assertEquals(3000L, clock.playedMs)
        clock.sample(3601000, "ended")
        assertEquals(3000L, clock.playedMs)
    }
}
