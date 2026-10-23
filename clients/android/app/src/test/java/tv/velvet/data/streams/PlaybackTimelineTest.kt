package tv.velvet.data.streams

import androidx.media3.common.C
import androidx.media3.common.Player
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class PlaybackTimelineTest {
    /** Media3 stop retains the old timeline; clearMediaItems removes it. */
    private class RetainedTimeline {
        var position = 1_337_919L
        var duration = 1_390_000L
        var buffered = 1_380_000L
        var propertyReads = 0
        val actions = mutableListOf<String>()
        val player = Proxy.newProxyInstance(Player::class.java.classLoader, arrayOf(Player::class.java)) { _, method, _ ->
            when (method.name) {
                "stop" -> { actions += "stop"; null }
                "clearMediaItems" -> {
                    actions += "clear"; position = 0; duration = C.TIME_UNSET; buffered = 0; null
                }
                "getCurrentPosition" -> { propertyReads++; position }
                "getDuration" -> { propertyReads++; duration }
                "getBufferedPosition" -> { propertyReads++; buffered }
                else -> error("Unexpected player operation: ${method.name}")
            }
        } as Player
    }

    @Test fun autoNextClearsRetainedPositionBeforeTheNewEpisodeCanFail() {
        val source = RetainedTimeline()
        // Reproduce Media3's old-item state, not an already-empty fake player.
        source.player.stop()
        assertEquals(1_337_919L, source.player.currentPosition)
        source.actions.clear()
        PlaybackTimeline.clearForNextEpisode(source.player)
        assertEquals(listOf("stop", "clear"), source.actions)
        // A cold failure before the next frame now falls back at zero, without
        // inheriting the previous episode's 22-minute seek or its duration.
        assertEquals(PlaybackTimeline(0, 0, 0), PlaybackTimeline.read(source.player, false))
    }

    @Test fun aTickerDuringASuspendedEpisodeSwapCannotObserveTheOldTimeline() {
        val source = RetainedTimeline()
        repeat(6) { assertNull(PlaybackTimeline.read(source.player, transitioning = true)) }
        assertEquals(0, source.propertyReads)
        PlaybackTimeline.clearForNextEpisode(source.player)
        assertEquals(PlaybackTimeline(0, 0, 0), PlaybackTimeline.read(source.player, false))
        source.position = 4_000; source.duration = 1_410_000; source.buffered = 20_000
        assertEquals(PlaybackTimeline(4_000, 1_410_000, 20_000), PlaybackTimeline.read(source.player, false))
    }
}
