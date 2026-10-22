package tv.velvet.data.streams

/**
 * Bounds buffering waits independently of the player's HTTP retry policy.
 * Call on the player thread with monotonic time; reset on each source or explicit seek.
 * The caller owns candidate selection, retry limits and handoff/queue eligibility.
 */
internal class StreamFailoverWatchdog {
    private var bufferingStartedAt: Long? = null
    private var lastProgressAt = 0L
    private var lastPositionMs = 0L
    private var lastBufferedPositionMs = 0L
    private var lastDurationMs = 0L
    private var hasPlayed = false
    private var triggered = false

    fun reset(
        nowMs: Long,
        positionMs: Long = 0,
        bufferedPositionMs: Long = 0,
        durationMs: Long = 0,
        establishedPlayback: Boolean = false,
    ) {
        bufferingStartedAt = nowMs
        lastProgressAt = nowMs
        recordPosition(positionMs, bufferedPositionMs, durationMs)
        hasPlayed = establishedPlayback
        triggered = false
    }

    /** Returns true once per stalled buffering window, never while paused or ineligible. */
    fun shouldFailover(
        nowMs: Long,
        positionMs: Long,
        bufferedPositionMs: Long,
        durationMs: Long,
        buffering: Boolean,
        isPlaying: Boolean,
        playWhenReady: Boolean,
        suppressed: Boolean,
        eligible: Boolean,
        inPlaceRetryUntilMs: Long = 0,
    ): Boolean {
        val progressed = positionMs > lastPositionMs ||
            bufferedPositionMs > lastBufferedPositionMs ||
            (durationMs > 0 && lastDurationMs == 0L)
        recordPosition(positionMs, bufferedPositionMs, durationMs)
        if (isPlaying) hasPlayed = true

        if (!eligible || !playWhenReady || suppressed || !buffering || isPlaying) {
            bufferingStartedAt = null
            lastProgressAt = nowMs
            triggered = false
            return false
        }

        val startedAt = bufferingStartedAt ?: nowMs.also {
            bufferingStartedAt = it
            lastProgressAt = it
        }
        if (progressed) lastProgressAt = nowMs
        if (triggered) return false

        val noProgressLimit = if (hasPlayed) REBUFFER_NO_PROGRESS_MS else STARTUP_NO_PROGRESS_MS
        // A real same-range retry receives a finite grace window. It cannot
        // postpone startup, and even a bad deadline cannot hold a stall forever.
        val retryActive = hasPlayed && nowMs < minOf(inPlaceRetryUntilMs, startedAt + 30_000)
        val stalled = nowMs - lastProgressAt >= noProgressLimit && !retryActive
        val startupExpired = !hasPlayed && nowMs - startedAt >= STARTUP_MAX_BUFFERING_MS
        return (stalled || startupExpired).also { if (it) triggered = true }
    }

    private fun recordPosition(positionMs: Long, bufferedPositionMs: Long, durationMs: Long) {
        lastPositionMs = positionMs.coerceAtLeast(0)
        lastBufferedPositionMs = bufferedPositionMs.coerceAtLeast(0)
        lastDurationMs = durationMs.coerceAtLeast(0)
    }

    internal companion object {
        const val STARTUP_NO_PROGRESS_MS = 6_000L
        const val STARTUP_MAX_BUFFERING_MS = 12_000L
        const val REBUFFER_NO_PROGRESS_MS = 15_000L
    }
}
