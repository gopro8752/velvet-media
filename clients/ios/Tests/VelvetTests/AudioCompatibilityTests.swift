import XCTest
import AVFoundation
import SwiftData
import VLCKitSPM
@testable import Velvet

private struct AudioMetadata: TmdbRepository {
    var allRows: [RowSpec] { [] }
    func rowItems(rowId: String, page: Int) async -> [MediaItem] { [] }
    func search(query: String) async -> [MediaItem] { [] }
    func episodes(showId: Int, season: Int) async -> [Episode] { [] }
    func details(id: Int, type: MediaType) async throws -> MediaDetails {
        MediaDetails(item: MediaItem(id: id, type: type, title: "Audio fixture", imdbId: "fixture-audio"))
    }
}
private struct AudioStreams: StreamRepository {
    let options: [StreamOption]
    func streams(imdbId: String, type: MediaType, season: Int?, episode: Int?) async -> [StreamOption] { options }
    func sortStreams(_ streams: [StreamOption], preferredQuality: String) -> [StreamOption] { streams }
    func autoPick(_ streams: [StreamOption], preferredQuality: String, previousBingeGroup: String?) -> StreamOption? { streams.first }
    func probeStreams(_ streams: [StreamOption], limit: Int) async -> [StreamOption] { streams }
}

@MainActor final class AudioCompatibilityTests: XCTestCase {
    private var vm: PlayerViewModel?
    private var window: UIWindow?
    private var suite: String?
    private let trueHD = "0123456789abcdef"
    private let alternate = "1111111111111111"
    private let aac = "2222222222222222"

    private func track(_ id: Int, _ codec: String, _ language: String?, _ title: String, ordinal: Int = 0) -> PlayerTrack {
        PlayerTrack(id: id, name: title, codec: codec, language: language, channelCount: 8, audioOrdinal: ordinal)
    }
    private func stream(_ id: String) -> StreamOption {
        .init(url: URL(string: "http://127.0.0.1:18883/stream/" + id)!, title: "Audio fixture",
              quality: "1080p", sizeBytes: nil, sourceName: "Fixture", bingeGroup: nil, headers: [:])
    }
    private func start(_ id: String) async throws -> PlayerViewModel {
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:18883/health")!); probe.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: probe)) != nil else {
            throw XCTSkip("Run scripts/audio-player-fixture.py before native audio tests.")
        }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        suite = "tv.velvet.tests.audio." + UUID().uuidString
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite!)!)
        settings.syncEnabled = false
        let container = try ModelContainer(for: WatchProgress.self, WatchedEpisode.self, MyListItem.self, Profile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = PlayerViewModel(target: .init(mediaId: 999998, type: .movie), tmdb: AudioMetadata(),
            streamRepo: AudioStreams(options: [stream(id)]), settings: settings,
            playback: PlaybackStore(container: container), companion: CompanionApi(settings: settings))
        vm = model
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        model.engine.videoView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        controller.view.addSubview(model.engine.videoView)
        window.makeKeyAndVisible()
        self.window = window
        return model
    }
    override func tearDown() async throws {
        vm?.teardown(); vm = nil
        window?.isHidden = true; window = nil
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testSameLanguageMainTrackFallbackPreservesRequestedAudio() {
        let main = track(10, "trhd", "eng", "English Surround 7.1")
        let commentary = track(11, "a52 ", "eng", "English commentary")
        let description = track(12, "mp4a", "eng", "English Audio Description")
        let french = track(13, "mp4a", "fra", "French")
        let english = track(14, "a52 ", "eng", "English Surround 5.1")
        XCTAssertEqual(MobileAudioSelection.preferred(in: [main, commentary, description, french, english], currentId: 10, manualName: nil)?.id, 14)
        XCTAssertEqual(MobileAudioSelection.preferred(in: [main, commentary, description, french], currentId: 10, manualName: nil)?.id, 10)
        XCTAssertEqual(MobileAudioSelection.preferred(in: [main, english], currentId: 10, manualName: main.name)?.id, 10)
        let unknown = track(20, "trhd", nil, "Track 1")
        XCTAssertEqual(MobileAudioSelection.preferred(in: [unknown, track(21, "mp4a", nil, "Track 2")], currentId: 20, manualName: nil)?.id, 20)
        XCTAssertFalse(track(22, "mp4a", "eng", "AAC 7.1").needsAudioCompatibility)
    }

    func testProbeUsesAudioOrdinalWithCodecAndLanguageChecks() {
        let requested = track(257, "trhd", "eng", "Main", ordinal: 1) // TS PID is not stream index.
        let probe = AudioCompatibility.Probe(durationMs: 30000, audioTracks: [
            .init(index: 1, codec: "aac", channels: 2, language: "fra", title: nil),
            .init(index: 4, codec: "truehd", channels: 8, language: "eng", title: nil)])
        XCTAssertEqual(AudioCompatibility.soundtrack(in: probe, matching: requested)?.index, 4)
        XCTAssertEqual(AudioCompatibility.soundtrack(in: probe, matching: track(257, "trhd", "en", "Main", ordinal: 1))?.index, 4)
        XCTAssertNil(AudioCompatibility.soundtrack(in: probe, matching: track(257, "trhd", "fra", "Wrong language", ordinal: 1)))
        XCTAssertNil(AudioCompatibility.soundtrack(in: probe, matching: track(257, "trhd", "eng", "Wrong ordinal", ordinal: 0)))
    }

    func testTrueHDOnlySourceAutomaticallyPlaysAudioAndSeeksBothWays() async throws {
        let model = try await start(trueHD)
        await waitUntil { model.engine.hasCompatibleAudio && model.engine.positionMs > 3000 && model.engine.isPlayingNow }
        XCTAssertEqual(model.currentStreamUrl, stream(trueHD).url)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertGreaterThan(model.engine.player.media!.statistics.playedAudioBuffers, 0)
        XCTAssertEqual(model.audioOptions.count, 1) // Converted input is not a duplicate soundtrack.
        model.seek(toMs: 18000)
        await waitUntil { model.engine.positionMs >= 17500 }
        var before = model.engine.player.media!.statistics.playedAudioBuffers
        await waitUntil { model.engine.player.media!.statistics.playedAudioBuffers > before + 10 }
        model.seek(toMs: 5000)
        await waitUntil { model.engine.positionMs >= 4500 && model.engine.positionMs < 8000 }
        before = model.engine.player.media!.statistics.playedAudioBuffers
        await waitUntil { model.engine.player.media!.statistics.playedAudioBuffers > before + 10 }
    }

    func testPauseDuringPreparationNeverAutoResumes() async throws {
        let model = try await start(trueHD)
        await waitUntil { model.engine.audioTracks.contains(where: \.needsAudioCompatibility) && !model.engine.isPlayingNow }
        XCTAssertTrue(model.playbackButtonShowsPause)
        model.pause()
        XCTAssertFalse(model.playbackButtonShowsPause)
        await waitUntil { model.engine.hasCompatibleAudio && !model.isBuffering }
        XCTAssertFalse(model.engine.isPlayingNow)
        model.togglePlayPause()
        await waitUntil { model.engine.isPlayingNow && model.engine.player.media!.statistics.playedAudioBuffers > 10 }
    }

    func testManualNativeTrackCancelsPendingConversionAndStopsOldSlave() async throws {
        let model = try await start(alternate)
        await waitUntil { model.engine.audioTracks.count == 2 && !model.engine.isPlayingNow }
        let native = try XCTUnwrap(model.engine.audioTracks.first { !$0.needsAudioCompatibility })
        model.selectAudioTrack(id: native.id)
        await waitUntil { model.engine.isPlayingNow && model.engine.player.media!.statistics.playedAudioBuffers > 10 }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertFalse(model.engine.hasCompatibleAudio)
        XCTAssertEqual(model.engine.currentAudioTrackId, native.id)
        // Explicitly request the main TrueHD track, then return to native after
        // conversion exists: reload same source/position to remove the slave.
        let main = try XCTUnwrap(model.engine.audioTracks.first(where: \.needsAudioCompatibility))
        model.selectAudioTrack(id: main.id)
        await waitUntil { model.engine.hasCompatibleAudio && model.engine.isPlayingNow }
        model.seek(toMs: 1000)
        model.selectAudioTrack(id: native.id)
        await waitUntil { !model.engine.hasCompatibleAudio && model.engine.isPlayingNow && model.engine.currentAudioTrackId == native.id }
        XCTAssertEqual(model.currentStreamUrl, stream(alternate).url)
        await waitUntil { model.engine.positionMs >= 800 && model.engine.positionMs < 4000 }
        XCTAssertLessThan(model.engine.positionMs, 4000)
    }

    func testSourceChangeDiscardsLateAudioPreparation() async throws {
        let model = try await start(trueHD)
        await waitUntil { model.engine.audioTracks.contains(where: \.needsAudioCompatibility) && !model.engine.isPlayingNow }
        model.switchStream(stream(aac))
        await waitUntil { model.engine.isPlayingNow && model.engine.player.media!.statistics.playedAudioBuffers > 10 }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(model.currentStreamUrl, stream(aac).url)
        XCTAssertFalse(model.engine.hasCompatibleAudio)
    }
}
