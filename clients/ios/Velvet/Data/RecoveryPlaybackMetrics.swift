import Foundation

/// One watch, counted independently of the release attempts used to play it.
struct RecoveryPlaybackMetrics {
    private var source: URL?
    private var pendingAutomatic: Bool?
    private var lastMs: Int64
    private var hasPlayed = false
    private var lastSampledSource: URL?
    private var lastPositionMs: Int64 = 0
    private var lastState = "buffering"
    private var rebuffering = false
    private var currentRebufferMs: Int64 = 0
    private var seekTargetMs: Int64?
    private var seekDispatched = false
    private var seekDeadlineMs: Int64 = 0
    private(set) var automaticSwitchAttempts = 0
    private(set) var manualSwitchAttempts = 0
    private(set) var automaticSourceSwitches = 0
    private(set) var manualSourceSwitches = 0
    private(set) var rebufferCount = 0
    private(set) var rebufferedMs: Int64 = 0
    private(set) var maxRebufferMs: Int64 = 0
    private(set) var seekCount = 0
    init(nowMs: Int64) { lastMs = nowMs }
    mutating func prepare(_ next: URL, automatic: Bool) {
        guard source != next else { return }
        if source != nil {
            if automatic { automaticSwitchAttempts += 1 } else { manualSwitchAttempts += 1 }
            pendingAutomatic = automatic
        }
        source = next
        lastSampledSource = nil
    }
    mutating func seek(to target: Int64) {
        seekCount += 1; seekTargetMs = max(0, target)
        seekDispatched = false; seekDeadlineMs = lastMs + 15_000
        rebuffering = false; currentRebufferMs = 0
    }
    mutating func didDispatchSeek() { seekDispatched = true }
    mutating func sample(nowMs: Int64, state: String, source playingSource: URL?, positionMs: Int64) {
        let rawElapsed = nowMs - lastMs
        let elapsed = max(0, min(2_000, rawElapsed)); lastMs = nowMs
        if rebuffering {
            rebufferedMs += elapsed; currentRebufferMs += elapsed
            maxRebufferMs = max(maxRebufferMs, currentRebufferMs)
        }
        let advanced = positionMs - lastPositionMs
        let moving = state == "playing" && lastState == "playing" && playingSource == source
            && playingSource != nil && playingSource == lastSampledSource
            && rawElapsed > 0 && rawElapsed <= 2_000 && advanced > 0 && advanced <= elapsed * 2 + 750
        lastState = state; lastSampledSource = playingSource; lastPositionMs = positionMs
        if moving {
            hasPlayed = true
            if let automatic = pendingAutomatic {
                if automatic { automaticSourceSwitches += 1 } else { manualSourceSwitches += 1 }
                pendingAutomatic = nil
            }
            if let target = seekTargetMs, seekDispatched,
               abs(positionMs - target) <= 2_000 { seekTargetMs = nil }
        }
        // Even a seek that never resumes must stop hiding later network stalls.
        if seekTargetMs != nil && nowMs >= seekDeadlineMs { seekTargetMs = nil }
        let next = state == "buffering" && hasPlayed && seekTargetMs == nil
        if next && !rebuffering { rebufferCount += 1; currentRebufferMs = 0 }
        if !next { currentRebufferMs = 0 }
        rebuffering = next
    }
    var payload: [String: Any] {
        ["telemetryVersion": 2, "buildChannel": "stable", "sourceSwitchAttempts": automaticSwitchAttempts + manualSwitchAttempts,
         "automaticSwitchAttempts": automaticSwitchAttempts, "manualSwitchAttempts": manualSwitchAttempts,
         "sourceSwitches": automaticSourceSwitches + manualSourceSwitches,
         "successfulSourceSwitches": automaticSourceSwitches + manualSourceSwitches,
         "automaticSourceSwitches": automaticSourceSwitches, "manualSourceSwitches": manualSourceSwitches,
         "rebufferCount": rebufferCount, "rebufferedMs": rebufferedMs, "maxRebufferMs": maxRebufferMs,
         "seekCount": seekCount]
    }
}
