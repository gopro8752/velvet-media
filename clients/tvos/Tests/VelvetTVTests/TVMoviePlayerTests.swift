import AVFoundation
import SwiftData
import UIKit
import XCTest
@testable import Velvet

private struct TVMovieMetadata: TmdbRepository {
    var allRows: [RowSpec] { [] }
    func rowItems(rowId: String, page: Int) async -> [MediaItem] { [] }
    func search(query: String) async -> [MediaItem] { [] }
    func episodes(showId: Int, season: Int) async -> [Episode] { [] }
    func details(id: Int, type: MediaType) async throws -> MediaDetails {
        MediaDetails(item: MediaItem(id: id, type: type, title: "Generated movie fixture", imdbId: "tv-movie-fixture"))
    }
}

private struct TVMovieStreams: StreamRepository {
    let token: String
    var candidates: [StreamOption] {
        ["b", "c"].map { name in
            StreamOption(url: URL(string: "http://127.0.0.1:18885/stream/\(name)?case=\(token)")!,
                title: "Fixture.1080p", quality: "1080p", sizeBytes: nil, sourceName: "Generated fixture",
                bingeGroup: "velvet-samegroup", headers: [:])
        }
    }
    func streams(imdbId: String, type: MediaType, season: Int?, episode: Int?) async -> [StreamOption] { candidates }
    func sortStreams(_ streams: [StreamOption], preferredQuality: String) -> [StreamOption] { streams }
    func autoPick(_ streams: [StreamOption], preferredQuality: String, previousBingeGroup: String?) -> StreamOption? { streams.first }
    func probeStreams(_ streams: [StreamOption], limit: Int) async -> [StreamOption] { streams }
}

@MainActor
final class TVMoviePlayerTests: XCTestCase {
    func testExactMovieBlockChangesSourceWithoutBlockingSameGroupAndPersists() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18885/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Run clients/ios/scripts/playback-recovery-fixture.py for native playback checks.")
        }
        let suite = "tv.velvet.tests.movie-native." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.syncEnabled = false
        let container = try ModelContainer(for: WatchProgress.self, WatchedEpisode.self, MyListItem.self, Profile.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = PlaybackStore(container: container)
        store.activeProfileId = { "fixture" }
        let blocks = MovieReleaseBlockStore(defaults: defaults)
        let streams = TVMovieStreams(token: UUID().uuidString)
        let vm = PlayerViewModel(target: .init(mediaId: 999996, type: .movie), tmdb: TVMovieMetadata(),
            streamRepo: streams, settings: settings, playback: store, companion: CompanionApi(settings: settings),
            movieReleaseBlocks: blocks)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        vm.engine.videoView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        controller.view.addSubview(vm.engine.videoView)
        defer { vm.teardown(); vm.engine.videoView.removeFromSuperview(); window.isHidden = true }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        await wait { vm.engine.isPlayingNow && vm.positionMs > 250 }
        XCTAssertEqual(vm.currentStreamUrl, streams.candidates[0].url)
        XCTAssertTrue(vm.canBlockCurrentRelease)
        vm.seek(toMs: 20_000)
        await wait { vm.positionMs >= 18_000 }
        vm.blockCurrentRelease()
        await wait { vm.currentStreamUrl == streams.candidates[1].url && vm.engine.isPlayingNow && vm.positionMs >= 18_000 }
        XCTAssertEqual(vm.streams.count, 1, "Exact movie blocks must not exclude the same group's other release")
        XCTAssertEqual(MovieReleaseBlockStore(defaults: defaults).keys(movie: "tv-movie-fixture").count, 1)
        XCTAssertTrue(blocks.keys(movie: "different-movie").isEmpty)
        vm.blockCurrentRelease()
        XCTAssertEqual(vm.phase, .error)
        XCTAssertTrue(vm.canChooseStream, "All-blocked state must retain reset controls")
        vm.resetBlockedReleases()
        XCTAssertEqual(vm.streams.count, 2)
        XCTAssertFalse(vm.hasBlockedReleases)
    }

    private func wait(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(predicate())
    }
}
