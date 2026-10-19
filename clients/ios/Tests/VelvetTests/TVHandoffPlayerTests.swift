import XCTest
import SwiftData
import AVFoundation
@testable import Velvet

private final class HandoffFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var mode = "started"
    static var created: [String: Any]?
    static var statusCount = 0
    static var cancelCount = 0
    static var streamBaseURL = "http://127.0.0.1:18882"
    private var stopped = false
    static func reset(_ value: String, streamBaseURL: String = "http://127.0.0.1:18882") {
        lock.withLock { mode = value; created = nil; statusCount = 0; cancelCount = 0; Self.streamBaseURL = streamBaseURL }
    }
    static var snapshot: ([String: Any]?, Int, Int) { lock.withLock { (created, statusCount, cancelCount) } }
    override class func canInit(with request: URLRequest) -> Bool { ["127.0.0.1", "localhost"].contains(request.url?.host ?? "") && request.url?.path.hasPrefix("/handoff") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; body.append(contentsOf: bytes.prefix(n)) }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let output: (Int, [String: Any]) = Self.lock.withLock {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let receivers: [[String: Any]] = Self.mode == "none" ? [] : (Self.mode == "multiple" ? ["living", "bedroom"] : ["living"]).map {
                ["deviceId": $0, "sessionId": $0 + "-awake-session", "name": $0 == "living" ? "Living Room" : "Bedroom", "profileId": "tv-profile", "expiresAt": now + 20000]
            }
            if request.url?.path == "/handoff/receivers" {
                var discovery: [String: Any] = ["protocolVersion":2,"serverNow":now,"receivers":receivers]
                if Self.mode != "missingbase" {
                    discovery["streamBaseURL"] = Self.mode == "foreignbase"
                        ? "https://unrelated.invalid" : Self.streamBaseURL
                }
                return (200, discovery)
            }
            if request.url?.path == "/handoff/v2" { Self.created = payload }
            let id = (Self.created?["requestId"] ?? payload["id"]) as? String ?? "missing"
            var state = "pending"
            if request.url?.path == "/handoff/v2/status" {
                Self.statusCount += 1
                state = Self.mode == "failed" ? "failed" : (Self.mode == "waiting" ? "claimed" : "started")
                if Self.mode == "failed_slow" { state = Self.statusCount >= 4 ? "failed" : "claimed" }
            }
            if request.url?.path == "/handoff/v2/cancel" { Self.cancelCount += 1; state = "cancelled" }
            if Self.mode == "uncertain", request.url?.path == "/handoff/v2" || (request.url?.path == "/handoff/v2/cancel" && Self.cancelCount == 1) { return (503,[:]) }
            return (200,["protocolVersion":2,"id":id,"state":state,"targetName":"Living Room","expiresAt":now + 120000])
        }
        let complete = {
            guard !Self.lock.withLock({ self.stopped }) else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: output.0, httpVersion: nil,
                headerFields: ["Content-Type":"application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: output.1))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if request.url?.path == "/handoff/receivers", Self.lock.withLock({ Self.mode == "delayed" }) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: complete)
        } else { complete() }
    }
    override func stopLoading() { Self.lock.withLock { stopped = true } }
}

private struct HandoffMetadata: TmdbRepository {
    var allRows: [RowSpec] { [] }
    func rowItems(rowId: String, page: Int) async -> [MediaItem] { [] }
    func search(query: String) async -> [MediaItem] { [] }
    func episodes(showId: Int, season: Int) async -> [Episode] {
        [Episode(season: 1, number: 1, title: "First"), Episode(season: 1, number: 2, title: "Second")]
    }
    func details(id: Int, type: MediaType) async throws -> MediaDetails {
        MediaDetails(item: MediaItem(id: id, type: type, title: "Handoff fixture", imdbId: "fixture-movie"),
            seasons: type == .show ? [Season(number: 1, name: "Season 1", episodeCount: 2, posterUrl: nil)] : [])
    }
}
private struct HandoffStreams: StreamRepository {
    let url: URL
    var delayNextEpisode = false
    func streams(imdbId: String, type: MediaType, season: Int?, episode: Int?) async -> [StreamOption] {
        if delayNextEpisode, episode == 2 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        return [.init(url: url, title: "Fixture release", quality: "720p", sizeBytes: nil, sourceName: "Fixture", bingeGroup: "fixture-cut", headers: [:])]
    }
    func sortStreams(_ streams: [StreamOption], preferredQuality: String) -> [StreamOption] { streams }
    func autoPick(_ streams: [StreamOption], preferredQuality: String, previousBingeGroup: String?) -> StreamOption? { streams.first }
    func probeStreams(_ streams: [StreamOption], limit: Int) async -> [StreamOption] { streams }
}

@MainActor final class TVHandoffPlayerTests: XCTestCase {
    private var vm: PlayerViewModel!
    private var playback: PlaybackStore!
    private var suite: String!
    private var settings: SettingsStore!
    private var videoWindow: UIWindow!
    private var videoController: UIViewController!

    override func setUp() async throws {
        continueAfterFailure = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        videoWindow = UIWindow(windowScene: scene)
        videoController = UIViewController()
        videoWindow.rootViewController = videoController
        videoWindow.makeKeyAndVisible()
        suite = "tv.velvet.tests.handoff." + UUID().uuidString
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.syncEnabled = true
        // Same deployed topology: API uses one hostname, resolver emits another.
        settings.syncUrl = "http://localhost:18882"
        settings.activeProfileId = "sender-profile"
        let container = try ModelContainer(for: WatchProgress.self, WatchedEpisode.self, MyListItem.self, Profile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        playback = PlaybackStore(container: container)
        playback.activeProfileId = { "sender-profile" }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HandoffFixtureProtocol.self]
        let url = URL(string: "http://127.0.0.1:18882/stream/0123456789abcdef")!
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:18882/health")!); probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            throw XCTSkip("Run scripts/handoff-player-fixture.py before native handoff tests.")
        }
        vm = PlayerViewModel(target: .init(mediaId: 999999, type: .movie), tmdb: HandoffMetadata(),
            streamRepo: HandoffStreams(url: url), settings: settings, playback: playback,
            companion: CompanionApi(settings: settings, handoffSession: URLSession(configuration: configuration)))
        mountVideo()
        await waitUntil { self.vm.engine.isPlayingNow && self.vm.engine.positionMs > 500 }
    }
    override func tearDown() async throws {
        vm?.teardown()
        vm?.engine.videoView.removeFromSuperview()
        vm = nil
        videoWindow?.isHidden = true
        videoWindow = nil
        videoController = nil
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // Let VLCKit's asynchronous stop finish before the next native player.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    private func mountVideo() {
        vm.engine.videoView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        videoController.view.addSubview(vm.engine.videoView)
    }
    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        let diagnostic = "phase=\(String(describing: vm?.phase)) state=\(String(describing: vm?.engine.stateNow)) "
            + "preparingAudio=\(vm?.isPreparingAudioForPlayback ?? false) buffering=\(vm?.isBuffering ?? false) "
            + "playing=\(vm?.engine.isPlayingNow ?? false) tracks=\(String(describing: vm?.engine.audioTracks)) "
            + "error=\(vm?.errorMessage ?? "none")"
        XCTAssertTrue(condition(), diagnostic, file: file, line: line)
    }

    func testUnadvertisedMediaOriginNeverPausesOrCreatesHandoff() async {
        for mode in ["missingbase", "foreignbase"] {
            HandoffFixtureProtocol.reset(mode)
            vm.throwToTv()
            await waitUntil { !self.vm.handoffInProgress }
            XCTAssertTrue(vm.engine.isPlayingNow)
            XCTAssertEqual(vm.throwToTvNotice?.message, TVHandoffError.exactSourceUnsupported.localizedDescription)
            XCTAssertNil(HandoffFixtureProtocol.snapshot.0)
        }
    }
    func testOlderServerStillAcceptsSameOriginMedia() async {
        settings.syncUrl = "http://127.0.0.1:18882"
        HandoffFixtureProtocol.reset("missingbase")
        vm.throwToTv()
        await waitUntil { self.vm.throwToTvNotice?.isSuccess == true }
        XCTAssertFalse(vm.engine.isPlayingNow)
        XCTAssertNotNil(HandoffFixtureProtocol.snapshot.0)
    }

    private func startShowPlayer() async {
        vm.teardown()
        vm.engine.videoView.removeFromSuperview()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HandoffFixtureProtocol.self]
        vm = PlayerViewModel(target: .init(mediaId: 999999, type: .show, season: 1, episode: 1),
            tmdb: HandoffMetadata(), streamRepo: HandoffStreams(
                url: URL(string: "http://127.0.0.1:18882/stream/0123456789abcdef")!, delayNextEpisode: true),
            settings: settings, playback: playback,
            companion: CompanionApi(settings: settings, handoffSession: URLSession(configuration: configuration)))
        mountVideo()
        await waitUntil { self.vm.engine.isPlayingNow && self.vm.hasNext }
    }

    func testEpisodeEndingDuringDiscoveryClearsObsoleteAttempt() async {
        await startShowPlayer()
        HandoffFixtureProtocol.reset("delayed")
        vm.throwToTv()
        vm.engine.onStateChanged?(.ended)
        await waitUntil { self.vm.phase == .loading && self.vm.episodeLabel?.hasPrefix("S1 E2") == true }
        await waitUntil { !self.vm.handoffInProgress }
        XCTAssertTrue(vm.tvReceivers.isEmpty)
        XCTAssertNil(HandoffFixtureProtocol.snapshot.0)
    }

    func testEpisodeEndingWhilePickerIsOpenCannotSendOldStreamAsNewEpisode() async throws {
        await startShowPlayer()
        HandoffFixtureProtocol.reset("multiple")
        vm.throwToTv()
        await waitUntil { self.vm.tvReceivers.count == 2 }
        let receiver = try XCTUnwrap(vm.tvReceivers.first)
        // Deliver the actual engine event while next-episode resolution is held.
        vm.engine.onStateChanged?(.ended)
        await waitUntil { self.vm.phase == .loading && self.vm.episodeLabel?.hasPrefix("S1 E2") == true }
        vm.sendToTv(receiver)
        XCTAssertFalse(vm.handoffInProgress)
        XCTAssertTrue(vm.tvReceivers.isEmpty)
        XCTAssertNil(HandoffFixtureProtocol.snapshot.0)
    }

    func testSourceReplacementInvalidatesOpenReceiverPicker() async throws {
        HandoffFixtureProtocol.reset("multiple")
        vm.throwToTv()
        await waitUntil { self.vm.tvReceivers.count == 2 }
        let receiver = try XCTUnwrap(vm.tvReceivers.first)
        vm.switchStream(.init(url: URL(string: "http://127.0.0.1:18882/stream/fedcba9876543210")!,
            title: "Replacement", quality: "720p", sizeBytes: nil, sourceName: "Fixture", bingeGroup: nil, headers: [:]))
        vm.sendToTv(receiver)
        XCTAssertFalse(vm.handoffInProgress)
        XCTAssertTrue(vm.tvReceivers.isEmpty)
        XCTAssertNil(HandoffFixtureProtocol.snapshot.0)
    }

    private func startAudioPreparation(streamID: String) async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:18883/health")!); probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            throw XCTSkip("Run scripts/audio-player-fixture.py before audio handoff race tests.")
        }
        vm.teardown()
        vm.engine.videoView.removeFromSuperview()
        try await Task.sleep(nanoseconds: 300_000_000)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HandoffFixtureProtocol.self]
        vm = PlayerViewModel(target: .init(mediaId: 999998, type: .movie),
            tmdb: HandoffMetadata(), streamRepo: HandoffStreams(
                url: URL(string: "http://127.0.0.1:18883/stream/" + streamID)!),
            settings: settings, playback: playback,
            companion: CompanionApi(settings: settings, handoffSession: URLSession(configuration: configuration)))
        mountVideo()
        await waitUntil {
            self.vm.phase == .playing && self.vm.isPreparingAudioForPlayback
                && !self.vm.engine.isPlayingNow && self.vm.playbackButtonShowsPause
                && self.vm.engine.audioTracks.contains(where: \.needsAudioCompatibility)
        }
    }

    func testFailedHandoffBeforeAudioReadyWaitsForSoundBeforeResuming() async throws {
        let sid = "3333333333333333" // Metadata deliberately waits five seconds.
        try await startAudioPreparation(streamID: sid)
        HandoffFixtureProtocol.reset("failed", streamBaseURL: "http://127.0.0.1:18883")
        vm.throwToTv()
        await waitUntil { HandoffFixtureProtocol.snapshot.0 != nil && !self.vm.handoffInProgress }
        XCTAssertFalse(vm.engine.isPlayingNow, "Handoff failure must not resume silent playback while audio is preparing")
        XCTAssertEqual((HandoffFixtureProtocol.snapshot.0?["sourceHint"] as? [String: Any])?["streamId"] as? String, sid)
        await waitUntil { self.vm.engine.isPlayingNow && (self.vm.engine.player.media?.statistics.playedAudioBuffers ?? 0) > 0 }
        XCTAssertEqual(vm.currentStreamUrl?.path, "/stream/" + sid)
    }

    func testFailedHandoffAfterAudioReadyRestoresOriginalPlayIntent() async throws {
        let sid = "0123456789abcdef"
        try await startAudioPreparation(streamID: sid)
        HandoffFixtureProtocol.reset("failed_slow", streamBaseURL: "http://127.0.0.1:18883")
        vm.throwToTv()
        await waitUntil { HandoffFixtureProtocol.snapshot.0 != nil }
        await waitUntil { self.vm.engine.audioTracks.contains { ["s16l", "araw"].contains($0.codec ?? "") } }
        XCTAssertTrue(vm.handoffInProgress)
        XCTAssertFalse(vm.engine.isPlayingNow, "Ready audio must not override an active handoff pause")
        await waitUntil { !self.vm.handoffInProgress && self.vm.engine.isPlayingNow }
        await waitUntil { (self.vm.engine.player.media?.statistics.playedAudioBuffers ?? 0) > 0 }
        XCTAssertEqual((HandoffFixtureProtocol.snapshot.0?["sourceHint"] as? [String: Any])?["streamId"] as? String, sid)
        XCTAssertEqual(vm.currentStreamUrl?.path, "/stream/" + sid)
    }

    func testNoAwakeReceiverKeepsPhonePlaying() async {
        HandoffFixtureProtocol.reset("none")
        vm.throwToTv()
        await waitUntil { !self.vm.handoffInProgress }
        XCTAssertTrue(vm.engine.isPlayingNow)
        XCTAssertTrue(vm.throwToTvNotice?.message.contains("No awake TV") == true)
        XCTAssertNil(HandoffFixtureProtocol.snapshot.0)
    }
    func testPickerFreezesExactPositionAndConfirmedTransferStopsStaleSaves() async throws {
        HandoffFixtureProtocol.reset("multiple")
        vm.throwToTv()
        await waitUntil { self.vm.tvReceivers.count == 2 }
        XCTAssertTrue(vm.engine.isPlayingNow)
        vm.seek(toMs: 8731) // Explicit local control cancels the first picker.
        vm.throwToTv()
        await waitUntil { self.vm.tvReceivers.count == 2 }
        let receiver = try XCTUnwrap(vm.tvReceivers.first { $0.deviceId == "bedroom" })
        vm.sendToTv(receiver)
        await waitUntil { self.vm.throwToTvNotice?.isSuccess == true }
        XCTAssertFalse(vm.engine.isPlayingNow)
        let sent = try XCTUnwrap(HandoffFixtureProtocol.snapshot.0)
        XCTAssertEqual(sent["targetDeviceId"] as? String, "bedroom")
        XCTAssertEqual(sent["targetSessionId"] as? String, "bedroom-awake-session")
        XCTAssertEqual(sent["profileId"] as? String, "sender-profile")
        XCTAssertEqual((sent["sourceHint"] as? [String: Any])?["streamId"] as? String, "0123456789abcdef")
        XCTAssertEqual(sent["positionMs"] as? Int64, 8731)
        let row = try XCTUnwrap(playback.progress(mediaId: 999999, typeKey: "movie"))
        row.positionMs = 50000 // Simulates a newer receiver sync update.
        vm.onHostStop(); vm.teardown()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(row.positionMs, 50000)
    }
    func testReceiverFailureRestoresOnlyPreviouslyPlayingPhone() async {
        HandoffFixtureProtocol.reset("failed")
        vm.throwToTv()
        await waitUntil { !self.vm.handoffInProgress }
        await waitUntil { self.vm.engine.isPlayingNow }
        XCTAssertFalse(vm.throwToTvNotice?.isSuccess == true)
        vm.pause()
        await waitUntil { !self.vm.engine.isPlayingNow }
        HandoffFixtureProtocol.reset("failed")
        vm.throwToTv()
        await waitUntil { !self.vm.handoffInProgress }
        XCTAssertFalse(vm.engine.isPlayingNow)
    }
    func testManualPlayCancelsPendingTransferWithoutLateSuccess() async {
        HandoffFixtureProtocol.reset("waiting")
        vm.throwToTv()
        await waitUntil { HandoffFixtureProtocol.snapshot.0 != nil && !self.vm.engine.isPlayingNow }
        vm.togglePlayPause()
        await waitUntil { HandoffFixtureProtocol.snapshot.2 > 0 && self.vm.engine.isPlayingNow }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(vm.throwToTvNotice?.isSuccess == true)
    }
    func testUncertainCreateRetainsCancellationForManualContinue() async {
        HandoffFixtureProtocol.reset("uncertain")
        vm.throwToTv()
        await waitUntil { self.vm.throwToTvNotice == .uncertain }
        XCTAssertFalse(vm.engine.isPlayingNow)
        XCTAssertEqual(HandoffFixtureProtocol.snapshot.2, 1)
        vm.togglePlayPause()
        await waitUntil { HandoffFixtureProtocol.snapshot.2 >= 2 && self.vm.engine.isPlayingNow }
    }
    func testBackgroundCancelsPendingTransferAndDoesNotResume() async {
        HandoffFixtureProtocol.reset("waiting")
        vm.throwToTv()
        await waitUntil { HandoffFixtureProtocol.snapshot.0 != nil && !self.vm.engine.isPlayingNow }
        vm.onHostStop()
        await waitUntil { HandoffFixtureProtocol.snapshot.2 > 0 }
        XCTAssertFalse(vm.engine.isPlayingNow)
        XCTAssertFalse(vm.handoffInProgress)
    }
}
