package tv.velvet.data.telemetry

enum class SourceSwitchReason { AUTOMATIC, MANUAL }

/**
 * Viewer outcomes for one movie or episode. Source identifiers stay in memory;
 * only aggregate counters are serialized. A source attempt becomes a successful
 * switch only when that exact replacement source actually starts playing.
 */
internal class RecoveryPlaybackMetrics(private var lastMs: Long) {
    private var sourceId: String? = null
    private var pendingSwitch: SourceSwitchReason? = null
    private var hasPlayed = false
    private var rebuffering = false
    private var currentRebufferMs = 0L
    private var seekTargetMs: Long? = null
    private var seekDispatched = false

    var automaticSwitchAttempts = 0; private set
    var manualSwitchAttempts = 0; private set
    var automaticSourceSwitches = 0; private set
    var manualSourceSwitches = 0; private set
    val sourceSwitchAttempts get() = automaticSwitchAttempts + manualSwitchAttempts
    val sourceSwitches get() = automaticSourceSwitches + manualSourceSwitches
    var rebufferCount = 0; private set
    var rebufferedMs = 0L; private set
    var maxRebufferMs = 0L; private set
    var seekCount = 0; private set

    fun sourcePrepared(nextSourceId: String, reason: SourceSwitchReason) {
        if (sourceId == nextSourceId) return // Retry of the same source is not a switch.
        if (sourceId != null) {
            when (reason) {
                SourceSwitchReason.AUTOMATIC -> automaticSwitchAttempts++
                SourceSwitchReason.MANUAL -> manualSwitchAttempts++
            }
            pendingSwitch = reason
        }
        sourceId = nextSourceId
    }

    fun beginSeek(targetPositionMs: Long) {
        seekTargetMs = targetPositionMs.coerceAtLeast(0)
        seekDispatched = false
        seekCount++
        rebuffering = false
        currentRebufferMs = 0
    }

    fun seekDispatched() { seekDispatched = true }

    fun sample(nowMs: Long, state: String, playingSourceId: String?, eligible: Boolean,
               positionMs: Long = 0) {
        // A suspended/hung client cannot prove it was continuously buffering.
        val elapsed = (nowMs - lastMs).coerceIn(0, 2_000)
        if (rebuffering) {
            rebufferedMs += elapsed
            currentRebufferMs += elapsed
            maxRebufferMs = maxOf(maxRebufferMs, currentRebufferMs)
        }
        lastMs = nowMs
        if (state == "playing") {
            hasPlayed = true
            // Matching the current player item prevents late callbacks from the
            // old source marking a freshly prepared replacement as successful.
            if (playingSourceId != null && playingSourceId == sourceId) {
                when (pendingSwitch) {
                    SourceSwitchReason.AUTOMATIC -> automaticSourceSwitches++
                    SourceSwitchReason.MANUAL -> manualSourceSwitches++
                    null -> Unit
                }
                pendingSwitch = null
            }
            seekTargetMs?.let { target ->
                // Ignore a synchronous callback still describing the pre-seek
                // position. A delayed callback may already be past the target;
                // it must not leave subsequent network stalls hidden forever.
                if (seekDispatched && positionMs >= target - 2_000) seekTargetMs = null
            }
        }
        val nextRebuffering = state == "buffering" && eligible && hasPlayed && seekTargetMs == null
        if (nextRebuffering && !rebuffering) {
            rebufferCount++
            currentRebufferMs = 0
        }
        if (!nextRebuffering) currentRebufferMs = 0
        rebuffering = nextRebuffering
    }
}
