package tv.velvet.data.streams

import androidx.media3.common.C
import androidx.media3.common.Player

/** A snapshot belongs to one media item, never to an episode transition. */
internal data class PlaybackTimeline(val positionMs: Long, val durationMs: Long, val bufferedMs: Long) {
    companion object {
        fun read(player: Player, transitioning: Boolean): PlaybackTimeline? {
            if (transitioning) return null
            return PlaybackTimeline(
                player.currentPosition.coerceAtLeast(0),
                player.duration.takeIf { it > 0 && it != C.TIME_UNSET } ?: 0,
                player.bufferedPosition.coerceAtLeast(0),
            )
        }

        fun clearForNextEpisode(player: Player) {
            player.stop()
            // stop() retains the old timeline and position. Clear before any
            // new episode identity, telemetry sample, or suspending lookup.
            player.clearMediaItems()
        }
    }
}
