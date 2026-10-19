import XCTest
import SwiftData
import AVFoundation
import UIKit
@testable import Velvet

private enum RecoveryFixture {
    static let base = "http://127.0.0.1:18885"
    static let showID = 999997
    static let imdbID = "fixture-recovery-show"
    static func stream(_ source: String, token: String, episode: Int) -> StreamOption {
        var url = URLComponents(string: "\(base)/stream/\(source)")!
        url.queryItems = [.init(name: "case", value: token), .init(name: "episode", value: String(episode))]
        return StreamOption(url: url.url!, title: "Recovery.Fixture.S01E\(String(format: "%02d", episode)).1080p-FIXTURE\(source.uppercased())",
                            quality: "1080p", sizeBytes: nil, sourceName: "Local generated fixture",
                            bingeGroup: "velvet-fixture\(source)", headers: [:])
    }
}

private struct RecoveryMetadata: TmdbRepository {
    var allRows: [RowSpec] { [] }
    func rowItems(rowId: String, page: Int) async -> [MediaItem] { [] }
    func search(query: String) async -> [MediaItem] { [] }
    func episodes(showId: Int, season: Int) async -> [Episode] {
        guard season == 1 else { return [] }
        return [Episode(season: 1, number: 1, title: "First", runtimeMinutes: 2),
                Episode(season: 1, number: 2, title: "Second", runtimeMinutes: 2)]
    }
    func details(id: Int, type: MediaType) async throws -> MediaDetails {
        MediaDetails(item: MediaItem(id: id, type: type, title: "Recovery fixture", imdbId: RecoveryFixture.imdbID),
                     seasons: [Season(number: 1, name: "Season 1", episodeCount: 2, posterUrl: nil)])
    }
}

private struct RecoveryStreams: StreamRepository {
    let sources: [String]
    let token: String
    func streams(imdbId: String, type: MediaType, season: Int?, episode: Int?) async -> [StreamOption] {
        sources.map { RecoveryFixture.stream($0, token: token, episode: episode ?? 1) }
    }
    func sortStreams(_ streams: [StreamOption], preferredQuality: String) -> [StreamOption] { streams }
    func autoPick(_ streams: [StreamOption], preferredQuality: String, previousBingeGroup: String?) -> StreamOption? {
        if let previousBingeGroup, let matching = streams.first(where: { $0.bingeGroup == previousBingeGroup }) { return matching }
        return streams.first
    }
    func probeStreams(_ streams: [StreamOption], limit: Int) async -> [StreamOption] {
        XCTFail("Native playback must start directly; startup/episode changes may not wait for source probes.")
        return streams
    }
}

@MainActor
final class PlaybackRecoveryPlayerTests: XCTestCase {
    private var vm: PlayerViewModel?
    private var playback: PlaybackStore!
    private var settings: SettingsStore!
    private var defaults: UserDefaults!
    private var suite: String?
    private var token = ""
    private var window: UIWindow?
    private var controller: UIViewController?

    override func setUp() async throws {
        continueAfterFailure = false
        var request = URLRequest(url: URL(string: RecoveryFixture.base + "/health")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              String(data: data, encoding: .utf8)?.contains("playback-recovery") == true else {
            throw XCTSkip("Run scripts/playback-recovery-fixture.py before native recovery tests.")
        }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        token = UUID().uuidString
        let suite = "tv.velvet.tests.playback-recovery." + token
        self.suite = suite
        defaults = UserDefaults(suiteName: suite)!
        settings = SettingsStore(defaults: defaults)
        settings.syncEnabled = false
        settings.autoplayNext = false
        settings.activeProfileId = "recovery-fixture"
        let container = try ModelContainer(for: WatchProgress.self, WatchedEpisode.self, MyListItem.self, Profile.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        playback = PlaybackStore(container: container)
        playback.activeProfileId = { "recovery-fixture" }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.controller = controller
    }

    override func tearDown() async throws {
        await stopPlayer()
        window?.isHidden = true
        window = nil
        controller = nil
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults = nil
        settings = nil
        playback = nil
    }

    private func stopPlayer() async {
        vm?.teardown()
        vm?.engine.videoView.removeFromSuperview()
        vm = nil
        // VLC stops asynchronously; don't overlap two decoder instances.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @discardableResult
    private func start(sources: [String] = ["b", "c"], episode: Int = 1) -> PlayerViewModel {
        let model = PlayerViewModel(target: .init(mediaId: RecoveryFixture.showID, type: .show, season: 1, episode: episode),
                                    tmdb: RecoveryMetadata(), streamRepo: RecoveryStreams(sources: sources, token: token),
                                    settings: settings, playback: playback, companion: CompanionApi(settings: settings))
        model.engine.videoView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        controller?.view.addSubview(model.engine.videoView)
        vm = model
        return model
    }

    private func waitUntil(timeout: TimeInterval = 12, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), "phase=\(String(describing: vm?.phase)) source=\(vm?.currentStreamUrl?.absoluteString ?? "none") "
                      + "playing=\(vm?.engine.isPlayingNow ?? false) position=\(vm?.engine.positionMs ?? -1) "
                      + "error=\(vm?.errorMessage ?? "none")", file: file, line: line)
    }

    private func isPlaying(_ model: PlayerViewModel, source: String, episode: Int = 1) -> Bool {
        model.currentStreamUrl == RecoveryFixture.stream(source, token: token, episode: episode).url
            && model.engine.isPlayingNow && model.engine.positionMs >= 250
    }

    private struct Metrics: Decodable {
        struct Event: Decodable { let source: String; let at: TimeInterval; let method: String }
        let events: [Event]
    }
    private func metrics() async throws -> Metrics {
        let url = URL(string: RecoveryFixture.base + "/metrics?case=" + token)!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(Metrics.self, from: data)
    }

    func testHungFirstSourceReachesHealthyPlaybackWithinTenSecondsOfMediaRequest() async throws {
        let model = start(sources: ["hang", "b"])
        await waitUntil { self.isPlaying(model, source: "b") }
        let playedAt = Date().timeIntervalSince1970
        let events = try await metrics().events
        let first = try XCTUnwrap(events.first(where: { $0.source == "hang" && $0.method == "GET" }))
        XCTAssertNotNil(events.first(where: { $0.source == "b" && $0.method == "GET" }))
        XCTAssertLessThan(playedAt - first.at, 10.0, "Startup recovery must be bounded from the actual first media request.")
    }

    func testEpisodeEndChoiceDoesNotTriggerWatchdogFailoverAfterWatchingCredits() async throws {
        settings.autoplayNext = false
        let model = start()
        await waitUntil { self.isPlaying(model, source: "b") && model.hasNext }
        let originalURL = try XCTUnwrap(model.currentStreamUrl)
        model.watchCredits()
        // Model VLC's terminal event without spending 90 seconds on the fixture.
        // Stop the real input first, so a watchdog sees a genuinely idle decoder.
        model.engine.stopPlayback()
        model.engine.onStateChanged?(.ended)
        await waitUntil {
            if case .endChoice = model.upNext { return true }
            return false
        }
        let requestsBefore = try await metrics().events.filter { $0.method == "GET" }.count
        // Longer than the six-second watchdog deadline plus its polling interval.
        try await Task.sleep(nanoseconds: 7_000_000_000)
        XCTAssertEqual(model.currentStreamUrl, originalURL)
        XCTAssertEqual(model.phase, .playing, "The end-choice overlay deliberately retains the player page.")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.engine.isPlayingNow)
        if case .endChoice(let next) = model.upNext {
            XCTAssertEqual(next.season, 1)
            XCTAssertEqual(next.episode, 2)
        } else {
            XCTFail("An ended episode must keep its next-episode choice until the user acts.")
        }
        let requestsAfter = try await metrics().events.filter { $0.method == "GET" }.count
        XCTAssertEqual(requestsAfter, requestsBefore, "The watchdog must not reopen B or start alternate C after normal completion.")
    }

    func testPreviousEpisodePlaysS1E1WithoutMarkingS1E2Watched() async throws {
        let model = start(episode: 2)
        await waitUntil { self.isPlaying(model, source: "b", episode: 2) && model.hasPrevious }
        model.seek(toMs: 25_000)
        await waitUntil { model.engine.positionMs >= 24_000 && model.engine.positionMs < 30_000 }
        model.playPreviousEpisode()
        await waitUntil { self.isPlaying(model, source: "b", episode: 1) && !model.hasPrevious }
        XCTAssertTrue(playback.watchedEpisodes(mediaId: RecoveryFixture.showID).isEmpty,
                      "Going backward is navigation, not completion of the abandoned episode.")
        model.saveProgressNow()
        let progress = try XCTUnwrap(playback.progress(mediaId: RecoveryFixture.showID, typeKey: MediaType.show.rawValue))
        XCTAssertEqual(progress.season, 1)
        XCTAssertEqual(progress.episode, 1)
    }

    func testBlockCurrentGroupPreservesPositionAndPersistsOnlyForThisShow() async throws {
        let model = start()
        await waitUntil { self.isPlaying(model, source: "b") }
        model.seek(toMs: 35_000)
        await waitUntil { model.engine.positionMs >= 34_000 && model.engine.positionMs < 39_000 }
        let before = model.engine.positionMs
        let blocked = RecoveryFixture.stream("b", token: token, episode: 1)
        model.blockReleaseGroup(blocked)
        await waitUntil { self.isPlaying(model, source: "c") && model.engine.positionMs >= before - 2_000 }
        XCTAssertLessThan(model.engine.positionMs, before + 6_000)
        XCTAssertFalse(model.streams.contains(where: { $0.bingeGroup == blocked.bingeGroup }))
        XCTAssertTrue(blocked.isReleaseGroupBlocked(settings.blockedGroups(imdbId: RecoveryFixture.imdbID)))
        XCTAssertFalse(blocked.isReleaseGroupBlocked(settings.blockedGroups(imdbId: "unrelated-show")))
        await stopPlayer()
        settings = SettingsStore(defaults: defaults)
        let restarted = start()
        await waitUntil { self.isPlaying(restarted, source: "c") }
        XCTAssertFalse(restarted.streams.contains(where: { $0.bingeGroup == blocked.bingeGroup }))
    }

    func testAllBlockedKeepsManagementAvailableAndUnblockAllowsExplicitPlayback() async throws {
        let model = start()
        await waitUntil { self.isPlaying(model, source: "b") }
        let first = RecoveryFixture.stream("b", token: token, episode: 1)
        let second = RecoveryFixture.stream("c", token: token, episode: 1)
        model.blockReleaseGroup(first)
        await waitUntil { self.isPlaying(model, source: "c") }
        model.blockReleaseGroup(second)
        await waitUntil { model.phase == .error && model.streams.isEmpty && model.blockedGroups.count == 2 }
        XCTAssertTrue(model.canChooseStream, "The source picker must remain reachable to unblock a group.")
        XCTAssertFalse(model.engine.isPlayingNow)
        model.unblockReleaseGroup(try XCTUnwrap(first.bingeGroup))
        await waitUntil { model.streams.contains(where: { $0.url == first.url }) && model.blockedGroups.count == 1 }
        XCTAssertEqual(model.blockedGroups.map(\.key), [try XCTUnwrap(second.bingeGroup)])
        XCTAssertFalse(model.engine.isPlayingNow, "Unblocking restores a choice without starting it automatically.")
        model.switchStream(first)
        await waitUntil { self.isPlaying(model, source: "b") }
    }

    func testEmptyResolverKeepsSavedBlockManagementAvailable() async throws {
        let group = try XCTUnwrap(RecoveryFixture.stream("b", token: token, episode: 1).releaseGroupForBlocking())
        XCTAssertTrue(settings.blockReleaseGroup(imdbId: RecoveryFixture.imdbID, group: group))
        let model = start(sources: [])
        await waitUntil { model.phase == .error }
        XCTAssertTrue(model.streams.isEmpty)
        XCTAssertTrue(model.canChooseStream, "Saved group exclusions must remain manageable when the resolver returns no sources.")
        XCTAssertEqual(model.blockedGroups, [group])
        XCTAssertEqual(settings.blockedGroups(imdbId: RecoveryFixture.imdbID), [group])
        XCTAssertFalse(model.engine.isPlayingNow)
        model.unblockReleaseGroup(group.key)
        await waitUntil { model.blockedGroups.isEmpty }
        XCTAssertTrue(settings.blockedGroups(imdbId: RecoveryFixture.imdbID).isEmpty)
        XCTAssertFalse(model.engine.isPlayingNow)
    }
}
