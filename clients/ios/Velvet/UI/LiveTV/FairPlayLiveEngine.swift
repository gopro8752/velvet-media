import AVFoundation
import SwiftUI

private final class LiveContentKeyDelegate: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "tv.velvet.live.fairplay")
    private let transport: LiveFairPlayTransport
    private let failure: @Sendable (Bool) -> Void
    private var pending: [ObjectIdentifier: (AVContentKeyRequest, Task<Void, Never>)] = [:]
    private var reportedFailures = Set<ObjectIdentifier>()
    private var closed = false

    init(transport: LiveFairPlayTransport, failure: @escaping @Sendable (Bool) -> Void) {
        self.transport = transport
        self.failure = failure
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        load(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        load(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest,
                           reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        false // The live view model owns the bounded session reconnect policy.
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest: AVContentKeyRequest, didFailWithError error: Error) {
        guard !closed, !reportedFailures.contains(ObjectIdentifier(contentKeyRequest)) else { return }
        failure(false)
    }

    private func load(_ request: AVContentKeyRequest) {
        guard !closed else { request.processContentKeyResponseError(CancellationError()); return }
        let identifier = (request.identifier as? String) ?? (request.identifier as? URL)?.absoluteString
        guard let identifier, let key = LiveFairPlayKey(identifier: identifier) else {
            reportedFailures.insert(ObjectIdentifier(request))
            request.processContentKeyResponseError(LiveTVError.invalidResponse)
            failure(false)
            return
        }
        let id = ObjectIdentifier(request)
        guard pending[id] == nil else { return }
        let transport = transport
        let task = Task { [weak self] in
            do {
                let certificate = try await transport.certificate()
                try Task.checkCancellation()
                let spc = try await request.makeStreamingContentKeyRequestData(
                    forApp: certificate, contentIdentifier: key.contentIdentifier, options: nil)
                try Task.checkCancellation()
                let ckc = try await transport.license(spc: spc, keyReference: key.reference)
                try Task.checkCancellation()
                self?.finish(id, result: .success(ckc))
            } catch {
                self?.finish(id, result: .failure(error))
            }
        }
        pending[id] = (request, task)
    }

    private func finish(_ id: ObjectIdentifier, result: Result<Data, Error>) {
        queue.async { [weak self] in
            guard let self, !self.closed, let (request, _) = self.pending.removeValue(forKey: id) else { return }
            switch result {
            case .success(let ckc):
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
            case .failure(let error):
                self.reportedFailures.insert(id)
                request.processContentKeyResponseError(error)
                if !(error is CancellationError) {
                    self.failure((error as? LiveTVError)?.canRetryAutomatically == true)
                }
            }
        }
    }

    func cancel() {
        queue.sync {
            closed = true
            let requests = pending.values
            pending.removeAll()
            reportedFailures.removeAll()
            for (request, task) in requests {
                task.cancel()
                request.processContentKeyResponseError(CancellationError())
            }
        }
        transport.cancel()
    }
}

@MainActor
final class FairPlayLiveEngine: ObservableObject {
    enum State { case playing, buffering }
    let player = AVPlayer()
    var onStateChanged: ((State) -> Void)?
    var onTimeChanged: (() -> Void)?
    var onFailure: ((Bool) -> Void)?
    var onTracksChanged: (() -> Void)?
    private let asset: AVURLAsset
    private lazy var item = AVPlayerItem(asset: asset)
    private let keySession: AVContentKeySession
    private var keyDelegate: LiveContentKeyDelegate?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var tracksTask: Task<Void, Never>?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var tornDown = false
    private var failed = false

    init(session: LiveSession, configuration: LiveFairPlayConfiguration,
         keySession: AVContentKeySession? = nil) throws {
        #if targetEnvironment(simulator)
        // Apple raises an Objective-C exception for FPS in the simulator. Tests
        // can supply a non-FPS session to exercise the shared player lifecycle.
        guard let keySession else {
            throw LiveTVError.server("Protected live TV requires a physical iPhone or iPad.", 422)
        }
        self.keySession = keySession
        #else
        self.keySession = keySession ?? AVContentKeySession(keySystem: .fairPlayStreaming)
        #endif
        asset = AVURLAsset(url: session.playbackURL)
        let transport = LiveFairPlayTransport(configuration: configuration, connection: session.connection)
        let delegate = LiveContentKeyDelegate(transport: transport) { [weak self] retryable in
            Task { @MainActor [weak self] in self?.fail(retryable: retryable) }
        }
        keyDelegate = delegate
        self.keySession.setDelegate(delegate, queue: delegate.queue)
        self.keySession.addContentKeyRecipient(asset)
        player.replaceCurrentItem(with: item)
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateStatus() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateStatus() }
            }
        ]
        for name in [AVPlayerItem.failedToPlayToEndTimeNotification, AVPlayerItem.didPlayToEndTimeNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.fail(retryable: true) }
            })
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.tornDown else { return }
                self.onTimeChanged?()
            }
        }
        tracksTask = Task { [weak self, asset] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled, let self, !self.tornDown else { return }
            self.audioGroup = audio
            self.subtitleGroup = subtitles
            self.onTracksChanged?()
        }
    }

    func play() {
        guard !tornDown else { return }
        player.play()
        updateStatus()
    }

    var isPlayingNow: Bool { !tornDown && !failed && player.timeControlStatus == .playing }
    var positionMs: Int64 {
        let value = player.currentTime().seconds * 1000
        return value.isFinite && value >= 0 && value < Double(Int64.max) ? Int64(value) : 0
    }
    var audioOptions: [TrackOption] { options(in: audioGroup, includeOff: false) }
    var subtitleOptions: [TrackOption] { options(in: subtitleGroup, includeOff: true) }

    private func options(in group: AVMediaSelectionGroup?, includeOff: Bool) -> [TrackOption] {
        guard let group, !group.options.isEmpty else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        let off = includeOff && group.allowsEmptySelection ? [TrackOption(index: -1, label: "Off", selected: selected == nil)] : []
        return off + group.options.enumerated().map {
            TrackOption(index: $0.offset, label: $0.element.displayName, selected: $0.element == selected)
        }
    }

    func selectAudio(_ index: Int) { select(index, in: audioGroup) }
    func selectSubtitle(_ index: Int) { select(index, in: subtitleGroup) }

    private func select(_ index: Int, in group: AVMediaSelectionGroup?) {
        guard !tornDown, let group else { return }
        if index == -1 && group.allowsEmptySelection { item.select(nil, in: group) }
        else if group.options.indices.contains(index) { item.select(group.options[index], in: group) }
        onTracksChanged?()
    }

    private func updateStatus() {
        guard !tornDown, !failed else { return }
        if item.status == .failed { fail(retryable: true); return }
        onStateChanged?(player.timeControlStatus == .playing ? .playing : .buffering)
    }

    private func fail(retryable: Bool) {
        guard !tornDown, !failed else { return }
        failed = true
        onFailure?(retryable)
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        onStateChanged = nil
        onTimeChanged = nil
        onFailure = nil
        onTracksChanged = nil
        tracksTask?.cancel()
        tracksTask = nil
        observations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        keyDelegate?.cancel()
        keySession.removeContentKeyRecipient(asset)
        keySession.expire()
        keySession.setDelegate(nil, queue: nil)
        keyDelegate = nil
        audioGroup = nil
        subtitleGroup = nil
        asset.cancelLoading()
    }
}

private final class FairPlayPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct FairPlayLiveVideoSurface: UIViewRepresentable {
    let engine: FairPlayLiveEngine

    func makeUIView(context: Context) -> UIView {
        let view = FairPlayPlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = engine.player
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        (view as? FairPlayPlayerUIView)?.playerLayer.player = engine.player
    }

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        (view as? FairPlayPlayerUIView)?.playerLayer.player = nil
    }
}
