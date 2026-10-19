import AVFoundation
import Combine
import UIKit
import VLCKitSPM

enum LivePlayerPhase { case loading, playing, failed, suspended }

/// Deliberately has no VOD repositories, progress store, or sync dependency.
/// Closing, reconnecting, and channel changes only manage a live viewer lease.
@MainActor
final class LivePlayerViewModel: ObservableObject {
    @Published private(set) var channel: LiveChannel
    @Published private(set) var phase = LivePlayerPhase.loading
    @Published private(set) var message = "Connecting to live TV…"
    @Published private(set) var engine: PlayerEngine?
    @Published private(set) var fairPlayEngine: FairPlayLiveEngine?
    @Published private(set) var buffering = false
    @Published private(set) var audioOptions: [TrackOption] = []
    @Published private(set) var subtitleOptions: [TrackOption] = []

    private let client: LiveTVServing
    private var telemetry: PlaybackTelemetry?
    private var telemetryChannel: String?
    private let hardwareDecoding: Bool
    private var lifecycle = LivePlaybackLifecycle()
    private var liveSession: LiveSession?
    private var retryTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var openedAt = Date()
    private var lastProgressAt = Date()
    private var previousPosition: Int64?
    private var healthySince: Date?
    private var hasStarted = false

    init(channel: LiveChannel, client: LiveTVServing, hardwareDecoding: Bool, settings: SettingsStore? = nil) {
        self.channel = channel
        self.client = client
        self.hardwareDecoding = hardwareDecoding
        if let settings { telemetry = PlaybackTelemetry(settings: settings) }
    }

    deinit {
        retryTask?.cancel()
        watchdog?.cancel()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        watchLive()
    }

    func selectChannel(_ selected: LiveChannel) {
        guard !lifecycle.closed else { return }
        channel = selected
        watchLive()
    }

    func watchLive() {
        if telemetryChannel != channel.id {
            telemetryChannel = channel.id
            phase = .loading
            telemetry?.start(kind: "live_tv", mediaId: channel.id, title: channel.name) { [weak self] in
                guard let self else { return .init(state: "ended") }
                let status = self.phase == .suspended ? "paused" : self.phase == .failed ? "error" :
                    self.phase == .loading || self.buffering ? "buffering" :
                    self.isPlayingNow ? "playing" : "paused"
                return .init(state: status, positionMs: self.positionMs)
            }
        }
        guard let generation = lifecycle.start() else { return }
        retryTask?.cancel()
        activateAudio()
        beginTune(generation)
    }

    private func beginTune(_ generation: UUID) {
        guard lifecycle.accepts(generation) else { return }
        let oldSession = detachPlayer()
        phase = .loading
        message = lifecycle.retryCount > 0 ? "Reconnecting to \(channel.name)…" : "Connecting to \(channel.name)…"
        let channelID = channel.id
        let client = client
        // Do not cancel an in-flight tune: a successful late response contains
        // the session ID needed to release its server resource. The request is
        // bounded, and the backend also expires unused leases after 120s.
        Task { [weak self] in
            if let oldSession { await client.release(oldSession) }
            guard self?.lifecycle.accepts(generation) == true else { return }
            do {
                let session = try await client.tune(channelID: channelID)
                guard let self, self.lifecycle.accepts(generation) else {
                    await client.release(session)
                    return
                }
                self.install(session, generation: generation)
            } catch {
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.handleFailure(error.localizedDescription, generation: generation,
                                   retryable: (error as? LiveTVError)?.canRetryAutomatically == true)
            }
        }
    }

    private func install(_ session: LiveSession, generation: UUID) {
        liveSession = session
        channel = session.channel
        openedAt = Date()
        lastProgressAt = openedAt
        previousPosition = nil
        healthySince = nil
        if let configuration = session.fairPlay {
            installFairPlay(session, configuration: configuration, generation: generation)
            return
        }
        let player = PlayerEngine()
        engine = player
        player.onStateChanged = { [weak self, weak player] state in
            guard let self, let player, self.engine === player,
                  self.lifecycle.accepts(generation) else { return }
            defer { self.telemetry?.observe() }
            switch state {
            case .playing:
                self.phase = .playing
                self.buffering = false
                self.refreshTracks()
            case .opening, .buffering:
                self.buffering = true
            case .esAdded:
                self.refreshTracks()
            case .error, .ended, .stopped:
                self.handleFailure("The live connection was interrupted.", generation: generation)
            default:
                break
            }
        }
        player.onTimeChanged = { [weak self, weak player] in
            guard let self, let player, self.engine === player,
                  self.lifecycle.accepts(generation) else { return }
            self.observeProgress(player.positionMs)
        }
        player.setMedia(url: session.playbackURL, headers: [:], hardwareDecoding: hardwareDecoding)
        player.play()
        startWatchdog(generation)
    }

    private var isPlayingNow: Bool { fairPlayEngine?.isPlayingNow ?? engine?.isPlayingNow ?? false }
    private var positionMs: Int64 { fairPlayEngine?.positionMs ?? engine?.positionMs ?? 0 }

    private func installFairPlay(_ session: LiveSession, configuration: LiveFairPlayConfiguration, generation: UUID) {
        let player: FairPlayLiveEngine
        do { player = try FairPlayLiveEngine(session: session, configuration: configuration) }
        catch {
            handleFailure(error.localizedDescription, generation: generation, retryable: false)
            return
        }
        fairPlayEngine = player
        player.onStateChanged = { [weak self, weak player] state in
            guard let self, let player, self.fairPlayEngine === player, self.lifecycle.accepts(generation) else { return }
            switch state {
            case .playing:
                self.phase = .playing
                self.buffering = false
                self.refreshTracks()
            case .buffering:
                self.buffering = true
            }
            self.telemetry?.observe()
        }
        player.onTimeChanged = { [weak self, weak player] in
            guard let self, let player, self.fairPlayEngine === player, self.lifecycle.accepts(generation) else { return }
            self.observeProgress(player.positionMs)
        }
        player.onTracksChanged = { [weak self, weak player] in
            guard let self, let player, self.fairPlayEngine === player, self.lifecycle.accepts(generation) else { return }
            self.refreshTracks()
        }
        player.onFailure = { [weak self, weak player] retryable in
            guard let self, let player, self.fairPlayEngine === player, self.lifecycle.accepts(generation) else { return }
            self.handleFailure("The protected live channel could not continue playback.", generation: generation, retryable: retryable)
        }
        player.play()
        startWatchdog(generation)
    }

    private func observeProgress(_ position: Int64) {
        if previousPosition.map({ abs(position - $0) >= 100 }) ?? (position > 0) {
            lastProgressAt = Date()
            buffering = false
            if healthySince == nil { healthySince = lastProgressAt }
        }
        previousPosition = position
    }

    private func startWatchdog(_ generation: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.lifecycle.accepts(generation) else { return }
                self.refreshTracks()
                let now = Date()
                if self.healthySince != nil {
                    if now.timeIntervalSince(self.lastProgressAt) > 25 {
                        self.handleFailure("The live channel stopped responding.", generation: generation)
                        return
                    }
                    // The bridge's placeholder can advance its media clock
                    // while provider startup is failing. Only an explicit user
                    // retry/channel selection resets the reconnect budget.
                } else if now.timeIntervalSince(self.openedAt) > 75 {
                    // The bridge can spend up to 60s preparing its first HLS
                    // playlist, so ordinary VOD startup deadlines are too short.
                    self.handleFailure("This channel is taking too long to start.", generation: generation)
                    return
                }
            }
        }
    }

    private func handleFailure(_ text: String, generation: UUID, retryable: Bool = true) {
        guard lifecycle.accepts(generation), phase != .failed else { return }
        telemetry?.error()
        let oldSession = detachPlayer()
        release(oldSession)
        if retryable, let next = lifecycle.reconnect(after: generation) {
            telemetry?.sourceSwitch()
            phase = .loading
            message = "Reconnecting to \(channel.name)…"
            let delay = UInt64(lifecycle.retryCount) * 1_500_000_000
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self, self.lifecycle.accepts(next) else { return }
                self.beginTune(next)
            }
        } else {
            phase = .failed
            message = text + " Tap Retry to reconnect."
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func suspend() {
        guard !lifecycle.closed, !lifecycle.suspended else { return }
        lifecycle.suspend()
        retryTask?.cancel()
        release(detachPlayer())
        phase = .suspended
        telemetry?.observe(force: true)
        message = "Live TV stopped while the app was away. Rejoin the channel live when you're ready."
        deactivateAudio()
    }

    func teardown() {
        guard !lifecycle.closed else { return }
        telemetry?.end()
        lifecycle.close()
        retryTask?.cancel()
        release(detachPlayer())
        deactivateAudio()
    }

    private func detachPlayer() -> LiveSession? {
        watchdog?.cancel()
        watchdog = nil
        engine?.teardown()
        engine = nil
        fairPlayEngine?.teardown()
        fairPlayEngine = nil
        buffering = false
        audioOptions = []
        subtitleOptions = []
        let old = liveSession
        liveSession = nil
        return old
    }

    private func release(_ session: LiveSession?) {
        guard let session else { return }
        let client = client
        Task { await client.release(session) }
    }

    private func refreshTracks() {
        if let fairPlayEngine {
            audioOptions = fairPlayEngine.audioOptions
            subtitleOptions = fairPlayEngine.subtitleOptions
            return
        }
        guard let engine else { return }
        audioOptions = engine.audioTracks.map {
            TrackOption(index: $0.id, label: $0.name, selected: $0.id == engine.currentAudioTrackId)
        }
        let subtitles = engine.subtitleTracks
        subtitleOptions = subtitles.isEmpty ? [] : [
            TrackOption(index: -1, label: "Off", selected: engine.currentSubtitleTrackId == -1)
        ] + subtitles.map {
            TrackOption(index: $0.id, label: $0.name, selected: $0.id == engine.currentSubtitleTrackId)
        }
    }

    func selectAudio(_ option: TrackOption) {
        fairPlayEngine?.selectAudio(option.index)
        engine?.selectAudioTrack(id: option.index)
        refreshTracks()
    }

    func selectSubtitle(_ option: TrackOption) {
        fairPlayEngine?.selectSubtitle(option.index)
        engine?.selectSubtitleTrack(id: option.index)
        refreshTracks()
    }

    private func activateAudio() {
        UIApplication.shared.isIdleTimerDisabled = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func deactivateAudio() {
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
