package tv.velvet.data.streams

/** Recovery is bounded per failure burst, not exhausted for an entire episode. */
internal class StreamRecoveryBudget(private val maximumSwitches: Int = 4) {
    @Volatile var automaticAttempts = 0; private set
    @Volatile var sourceEstablished = false; private set
    @Volatile var retryUntilMs = 0L; private set
    private var generation = 0L
    private var lastAt: Long? = null
    private var lastPosition = 0L
    private var wasPlaying = false
    private var healthyMs = 0L
    private var sourceMovingMs = 0L

    @Synchronized fun sourceChanged(): Long {
        generation++
        sourceEstablished = false
        sourceMovingMs = 0
        retryUntilMs = 0
        interrupt()
        return generation
    }

    @Synchronized fun isEstablished(sourceGeneration: Long): Boolean = sourceGeneration == generation && sourceEstablished

    @Synchronized fun interrupt() {
        lastAt = null
        wasPlaying = false
        healthyMs = 0
    }

    @Synchronized fun resetBurst() {
        automaticAttempts = 0
        retryUntilMs = 0
        interrupt()
    }

    @Synchronized fun tryAutomaticSwitch(): Boolean {
        if (automaticAttempts >= maximumSwitches) return false
        automaticAttempts++
        return true
    }

    /** Unplayable startup candidates must not consume the mid-play recovery budget.
     * The caller excludes attempted URLs, so this can traverse the finite source list
     * without retrying a failed source or stopping before a working candidate. */
    @Synchronized fun tryCandidateSwitch(): Boolean = !sourceEstablished || tryAutomaticSwitch()

    /** True only when genuine sustained progress renews a spent failure budget. */
    @Synchronized fun observe(nowMs: Long, positionMs: Long, isPlaying: Boolean): Boolean {
        val elapsed = lastAt?.let { nowMs - it } ?: 0
        val movement = positionMs - lastPosition
        val continuous = isPlaying && wasPlaying && elapsed in 1..2_000 && movement > 0 && movement <= 4_000
        if (continuous) {
            val proven = minOf(elapsed, movement)
            healthyMs += proven
            sourceMovingMs += proven
            if (sourceMovingMs >= 1_000) sourceEstablished = true
        } else healthyMs = 0
        lastAt = nowMs
        lastPosition = positionMs
        wasPlaying = isPlaying
        if (healthyMs < HEALTHY_PLAYBACK_MS) return false
        val renewed = automaticAttempts > 0
        automaticAttempts = 0
        retryUntilMs = 0
        healthyMs = 0
        return renewed
    }

    /** Repeated errors cannot push this incident's deadline farther into the future. */
    @Synchronized fun allowInPlaceRetry(sourceGeneration: Long, nowMs: Long): Boolean {
        if (sourceGeneration != generation || !sourceEstablished) return false
        if (retryUntilMs == 0L) retryUntilMs = nowMs + IN_PLACE_RETRY_WINDOW_MS
        return nowMs < retryUntilMs
    }

    companion object {
        const val HEALTHY_PLAYBACK_MS = 30_000L
        const val IN_PLACE_RETRY_WINDOW_MS = 15_000L
    }
}
