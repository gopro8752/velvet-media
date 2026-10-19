import Foundation
import VLCKitSPM

/// Watchdog that un-wedges VLCKit 3.x network playback around pause/resume.
///
/// Root cause (verified against libVLC 3.0.x sources): while paused, libVLC
/// keeps the HTTP input's TCP connection open and idle. The streaming server
/// (nzbdav) or a NAT/router idle timeout silently kills that connection; on
/// resume the input thread blocks in a read on the dead socket. The modern
/// http access module (the one that actually serves http/https in VLC 3.x)
/// only auto-resumes — re-issuing a ranged GET at the current offset — when a
/// read RETURNS AN ERROR. A silently dead connection just hangs: no error, no
/// state change, no `.error` event, so the player screen freezes with a live
/// UI and a dead pipeline, and no media option can save it. Recovery has to
/// come from the app layer: detect "play intent but no time advancement" and
/// rebuild the input in place (the same set-media + play + seek path the view
/// model already uses for stream swaps).
///
/// Detection rules:
///  - After a user play intent, if the position has not advanced within
///    `stallGraceSeconds` (~3.5s) while VLC still claims a live-ish state
///    (playing / buffering / opening / stuck paused), reconnect in place.
///  - If the resume follows a pause longer than `longPauseSeconds` (90s),
///    reconnect proactively — the socket is presumed stale; waiting for the
///    stall timer would just burn 3.5s before the inevitable.
///  - Each reconnect is verified with a longer window (`reconnectVerifySeconds`,
///    10s — a fresh connection legitimately needs open + buffer time). At most
///    `maxAttemptsPerWedge` (2) reconnects per wedge; then the recovery gives
///    up and the view model's normal error/failover path owns the outcome.
///  - Any genuine time advancement clears the wedge bookkeeping.
///
/// Ownership/liveness: the view model owns this object strongly and provides
/// `Hooks`. Hook closures must not capture the view model strongly (capture
/// the engine, and `[weak self]` for the reconnect — see the integration doc)
/// or a retain cycle results: VM -> recovery -> hooks -> VM. The watchdog is a
/// single cancellable `Task` holding only a weak self: no timer-driven cycle,
/// and `noteStopped()` / deinit cancel it deterministically.
@MainActor
final class PlaybackRecovery {

    // MARK: - Wiring

    /// Closures the owning view model provides. All are invoked synchronously
    /// on the main actor, from `note*()` calls or the watchdog timer.
    struct Hooks {
        /// Engine's current position in ms (0 when unknown).
        var currentPositionMs: @MainActor () -> Int64
        /// Media duration in ms (0 until VLC has resolved it).
        var mediaDurationMs: @MainActor () -> Int64
        /// `VLCMediaPlayer.isPlaying` right now.
        var isPlayingNow: @MainActor () -> Bool
        /// `VLCMediaPlayer.state` right now.
        var vlcStateNow: @MainActor () -> VLCMediaPlayerState
        /// Rebuild the input in place: set the CURRENT stream's media again,
        /// play, and seek to `atMs` — the view model's existing swap path.
        var reconnectInPlace: @MainActor (_ atMs: Int64) -> Void
        /// Clock; injectable for tests.
        var now: @MainActor () -> Date

        init(currentPositionMs: @escaping @MainActor () -> Int64,
             mediaDurationMs: @escaping @MainActor () -> Int64,
             isPlayingNow: @escaping @MainActor () -> Bool,
             vlcStateNow: @escaping @MainActor () -> VLCMediaPlayerState,
             reconnectInPlace: @escaping @MainActor (_ atMs: Int64) -> Void,
             now: @escaping @MainActor () -> Date = { Date() }) {
            self.currentPositionMs = currentPositionMs
            self.mediaDurationMs = mediaDurationMs
            self.isPlayingNow = isPlayingNow
            self.vlcStateNow = vlcStateNow
            self.reconnectInPlace = reconnectInPlace
            self.now = now
        }
    }

    /// Thresholds, overridable in tests.
    struct Tuning {
        /// How long a play intent may go without time advancement before the
        /// input is judged wedged.
        var stallGraceSeconds: TimeInterval = 3.5
        /// Verification window after a reconnect attempt — a fresh HTTP input
        /// legitimately needs open + buffer time, so it gets more rope than
        /// the plain resume watchdog.
        var reconnectVerifySeconds: TimeInterval = 10.0
        /// Pauses at least this long trigger a proactive reconnect on resume
        /// (the socket is presumed dead — NAT/server idle timeouts).
        var longPauseSeconds: TimeInterval = 90.0
        /// Reconnects per wedge before giving up and leaving the outcome to
        /// the view model's normal error path.
        var maxAttemptsPerWedge: Int = 2
        /// Minimum position delta (ms) that counts as "time advanced".
        var advanceEpsilonMs: Int64 = 250
        /// Never reconnect-seek into the last few seconds of the media —
        /// landing past ~95% would trip the ended pipeline instead of resuming.
        var endGuardMs: Int64 = 5_000
    }

    private let hooks: Hooks
    private let tuning: Tuning

    // MARK: - State

    /// Start of the CURRENT pause (first `notePaused` since the last play
    /// intent — refreshing it on repeat pauses would under-measure and skip
    /// the proactive reconnect after e.g. pause -> background -> resume).
    private var pausedAt: Date?
    /// Last position a VLC time callback reported; the reconnect target.
    private var lastKnownMs: Int64 = 0
    /// Position snapshot when the watchdog was armed; advancement is measured
    /// against this.
    private var baselineMs: Int64 = 0
    /// Reconnects attempted for the current wedge.
    private var attempts = 0
    /// Latched after the attempt cap: stop interfering until playback is
    /// observed healthy again (or the media is torn down / replaced).
    private var gaveUp = false

    private var watchdog: Task<Void, Never>?
    /// Guards a fired watchdog body against a cancel-then-rearm race: only the
    /// generation that armed the task may act.
    private var generation: UInt64 = 0

    // MARK: - Lifecycle

    init(hooks: Hooks, tuning: Tuning = Tuning()) {
        self.hooks = hooks
        self.tuning = tuning
    }

    deinit {
        // Task is Sendable; cancelling from the nonisolated deinit is safe
        // (same pattern as PlayerViewModel.deinit) and guarantees no timer
        // outlives the owner even if noteStopped was missed.
        watchdog?.cancel()
    }

    // MARK: - Events (the view model's four call sites)

    /// Call when the user unpauses / playback should be advancing again.
    func noteUserPlayIntent() {
        let pausedFor = pausedAt.map { hooks.now().timeIntervalSince($0) }
        pausedAt = nil
        guard !gaveUp else { return }
        switch hooks.vlcStateNow() {
        case .error, .ended, .stopped:
            // Terminal states have first-class view-model handling (error UI,
            // failover, ended pipeline) — recovery never fights those paths.
            return
        default:
            break
        }
        if let pausedFor, pausedFor >= tuning.longPauseSeconds {
            // The socket is presumed stale after a long pause: reconnect now
            // instead of letting the user stare at a frozen frame for the
            // stall grace first.
            attemptReconnect()
        } else {
            armWatchdog(after: tuning.stallGraceSeconds)
        }
    }

    /// Call on pause. While paused no advancement is expected, so the
    /// watchdog is disarmed rather than left to misfire.
    func notePaused() {
        if pausedAt == nil { pausedAt = hooks.now() }
        disarmWatchdog()
    }

    /// Call from the engine's time callback. Genuine advancement both feeds
    /// the reconnect target and clears wedge bookkeeping.
    func noteTimeAdvanced(ms: Int64) {
        guard ms > 0 else { return }
        lastKnownMs = ms
        if watchdog != nil {
            // Any real movement away from the armed baseline — forward play,
            // or the position jump of a landed reconnect seek — proves the
            // input is alive (a wedged input emits no time callbacks at all).
            if abs(ms - baselineMs) >= tuning.advanceEpsilonMs {
                markHealthy()
            }
        } else {
            attempts = 0
            gaveUp = false
        }
    }

    /// Call on teardown AND whenever the media is deliberately replaced
    /// (stream switch, retry, episode swap): a fresh input is a fresh world.
    /// NOT called from the reconnect path itself — that would zero the
    /// attempt cap mid-wedge (see the integration doc).
    func noteStopped() {
        disarmWatchdog()
        pausedAt = nil
        attempts = 0
        gaveUp = false
        baselineMs = 0
        lastKnownMs = 0
    }

    // MARK: - Watchdog

    private func armWatchdog(after seconds: TimeInterval) {
        disarmWatchdog()
        // Baseline for advancement checks. When the engine can't report a
        // position (wedged inputs sometimes read 0), fall back to the last
        // known position so a re-emitted frozen value can't fake a recovery.
        let cur = hooks.currentPositionMs()
        baselineMs = cur > 0 ? cur : lastKnownMs
        generation &+= 1
        let expected = generation
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.generation == expected else { return }
            self.watchdogFired()
        }
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        // Bump so a task that already slept past its cancel check can't act.
        generation &+= 1
    }

    private func watchdogFired() {
        watchdog = nil
        guard !gaveUp else { return }
        // Belt and braces for a missed/racing time callback: check the live
        // position before judging the input wedged.
        let pos = hooks.currentPositionMs()
        if pos > 0 && abs(pos - baselineMs) >= tuning.advanceEpsilonMs {
            lastKnownMs = pos
            markHealthy()
            return
        }
        switch hooks.vlcStateNow() {
        case .error, .ended, .stopped:
            // A terminal state surfaced while we slept — the view model's
            // error/ended handling owns it now.
            return
        case .playing, .buffering, .opening, .esAdded:
            // Claims live, isn't: the wedge signature.
            attemptReconnect()
        case .paused:
            // notePaused disarms the watchdog, so reaching here paused means
            // the play intent itself was swallowed (play() on a stale input
            // can leave VLC stuck in paused) — that is also a wedge.
            attemptReconnect()
        @unknown default:
            // Future states: only treat as wedged if the player still claims
            // to be playing.
            if hooks.isPlayingNow() { attemptReconnect() }
        }
    }

    // MARK: - Recovery

    private func attemptReconnect() {
        attempts += 1
        guard attempts <= tuning.maxAttemptsPerWedge else {
            // Out of budget: stand down and let the view model's normal
            // error path take over (stall -> user retry / error / failover).
            gaveUp = true
            disarmWatchdog()
            return
        }
        hooks.reconnectInPlace(reconnectTargetMs())
        // Verify the reconnect with a longer window — open + buffer on a
        // fresh connection takes seconds legitimately.
        armWatchdog(after: tuning.reconnectVerifySeconds)
    }

    /// Best position to resume at: the freshest of the engine's live position
    /// and the last time-callback position, kept clear of the end-of-media
    /// zone so a reconnect can't accidentally trip the ended pipeline.
    private func reconnectTargetMs() -> Int64 {
        var target = max(lastKnownMs, 0)
        let cur = hooks.currentPositionMs()
        if cur > target { target = cur }
        let dur = hooks.mediaDurationMs()
        if dur > 0 {
            target = min(target, max(dur - tuning.endGuardMs, 0))
        }
        return target
    }

    private func markHealthy() {
        disarmWatchdog()
        attempts = 0
        gaveUp = false
    }
}
