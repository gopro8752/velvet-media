import Foundation

/// Bounds silent waits independently of VLC's HTTP retries. Sample with a
/// monotonic clock on the player actor; reset on each source or explicit seek.
/// The caller owns retry budgets, candidate selection and playback eligibility.
struct StreamFailoverWatchdog {
    static let startupNoProgressMs: Int64 = 6_000
    static let startupMaxBufferingMs: Int64 = 12_000
    static let rebufferNoProgressMs: Int64 = 5_000

    private var generation: UInt64?
    private var bufferingStartedAt: Int64?
    private var lastProgressAt: Int64 = 0
    private var lastPositionMs: Int64 = 0
    private var lastBufferedPositionMs: Int64 = 0
    private var hasDuration = false
    private var hasPlayed = false
    private var triggered = false

    mutating func reset(nowMs: Int64, generation: UInt64, positionMs: Int64 = 0,
                        bufferedPositionMs: Int64 = 0, durationMs: Int64 = 0) {
        self.generation = generation
        bufferingStartedAt = nowMs
        lastProgressAt = nowMs
        lastPositionMs = max(positionMs, 0)
        lastBufferedPositionMs = max(bufferedPositionMs, 0)
        hasDuration = durationMs > 0
        hasPlayed = false
        triggered = false
    }

    /// Returns true only once per stalled window. VLC can report `.playing`
    /// while frozen, so only real time advancement clears a playback deadline.
    /// Pass zero for bufferedPositionMs when the engine exposes no buffer time.
    mutating func shouldFailover(
        nowMs: Int64, generation: UInt64, positionMs: Int64,
        bufferedPositionMs: Int64, durationMs: Int64,
        buffering: Bool, isPlaying: Bool, playWhenReady: Bool,
        suppressed: Bool, eligible: Bool
    ) -> Bool {
        guard self.generation == generation else { return false }
        let position = max(positionMs, 0)
        let buffered = max(bufferedPositionMs, 0)
        let advancing = isPlaying && position > lastPositionMs
        let progressed = position > lastPositionMs || buffered > lastBufferedPositionMs
            || (durationMs > 0 && !hasDuration)
        lastPositionMs = position
        lastBufferedPositionMs = buffered
        hasDuration = hasDuration || durationMs > 0

        guard eligible, playWhenReady, !suppressed, buffering || isPlaying else {
            bufferingStartedAt = nil
            lastProgressAt = nowMs
            triggered = false
            return false
        }
        if advancing {
            hasPlayed = true
            bufferingStartedAt = nil
            lastProgressAt = nowMs
            triggered = false
            return false
        }

        if bufferingStartedAt == nil {
            bufferingStartedAt = nowMs
            lastProgressAt = nowMs
        }
        if progressed { lastProgressAt = nowMs }
        guard !triggered else { return false }
        let noProgressLimit = hasPlayed ? Self.rebufferNoProgressMs : Self.startupNoProgressMs
        let stalled = nowMs - lastProgressAt >= noProgressLimit
        let startupExpired = !hasPlayed && nowMs - (bufferingStartedAt ?? nowMs) >= Self.startupMaxBufferingMs
        if stalled || startupExpired { triggered = true }
        return triggered
    }
}
