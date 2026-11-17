import XCTest
@testable import Velvet

final class TVPlayerTests: XCTestCase {
    func testMovieReleaseIdentitySurvivesBackendAddressAndAudioAdaptation() throws {
        let original = try XCTUnwrap(URL(string: "https://backend.example/token/stream/0123456789abcdef?token=old"))
        let mobileAudio = try XCTUnwrap(URL(string: "http://192.0.2.1:7000/stream/0123456789abcdef/audio/1.wav?token=new"))
        XCTAssertEqual(MovieReleaseBlocks.key(for: original), "velvet:0123456789abcdef")
        XCTAssertEqual(MovieReleaseBlocks.key(for: original), MovieReleaseBlocks.key(for: mobileAudio))
        XCTAssertNotEqual(MovieReleaseBlocks.key(for: original), MovieReleaseBlocks.key(for: URL(string: "https://backend.example/stream/0123456789abcdee")!))
    }

    func testExternalAddonIdentityDiscardsCredentialsButKeepsContentQuery() {
        let first = URL(string: "https://user:password@addon.example/watch?id=movie1&token=secret&signature=first#token")!
        let refreshed = URL(string: "https://addon.example/watch?id=movie1&token=changed&signature=second")!
        let another = URL(string: "https://addon.example/watch?id=movie2&token=changed")!
        let key = MovieReleaseBlocks.key(for: first)
        XCTAssertEqual(key, MovieReleaseBlocks.key(for: refreshed))
        XCTAssertNotEqual(key, MovieReleaseBlocks.key(for: another))
        XCTAssertEqual(key?.count, 68)
        XCTAssertFalse(key?.contains("secret") ?? true)
        XCTAssertNil(MovieReleaseBlocks.key(for: URL(string: "file:///private/movie.mkv")!))
    }

    @MainActor
    func testMovieBlocksPersistAndResetOnlySelectedMovie() {
        let suite = "tv.velvet.tests.movie-blocks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MovieReleaseBlockStore(defaults: defaults)
        let url = URL(string: "https://backend.example/stream/0123456789abcdef?token=secret")!
        XCTAssertTrue(store.block(movie: "tt1", url: url))
        XCTAssertTrue(store.block(movie: "tt2", url: url))
        XCTAssertTrue(store.block(movie: "tt1", url: url))
        let restarted = MovieReleaseBlockStore(defaults: defaults)
        XCTAssertEqual(restarted.keys(movie: "tt1").count, 1)
        XCTAssertTrue(restarted.keys(movie: "tt3").isEmpty)
        restarted.reset(movie: "tt1")
        XCTAssertTrue(restarted.keys(movie: "tt1").isEmpty)
        XCTAssertEqual(restarted.keys(movie: "tt2").count, 1)
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("secret"))
    }

    func testTVVideoPolicyRejectsDolbyEvenOnHDRDisplayAndPreservesHDR10PlusFallback() {
        let hdr = TVVideoCompatibility(hdr10: true, hlg: false)
        XCTAssertFalse(hdr.supports(title: "Movie.2160p.DV.HEVC"))
        XCTAssertFalse(hdr.supports(title: "Movie.2160p.DV.HDR10.HEVC"), "A filename is not proof of a compatible base layer")
        XCTAssertTrue(hdr.supports(title: "Movie.2160p.HDR10+.HEVC"))
        XCTAssertFalse(hdr.supports(title: "Movie.2160p.HLG.HEVC"))
        let sdr = TVVideoCompatibility(hdr10: false, hlg: false)
        XCTAssertFalse(sdr.supports(title: "Movie.2160p.HDR.HEVC"))
        XCTAssertTrue(sdr.supports(title: "Movie.1080p.SDR.H264"))
        XCTAssertTrue(sdr.supports(title: "Movie.1080p.H264"))
        XCTAssertTrue(TVVideoCompatibility.isDolbyCodec("dvh1"))
        XCTAssertFalse(TVVideoCompatibility.isDolbyCodec("hevc"))
    }

    func testTimelineHandlesUnknownDurationAndOutOfRangeClock() {
        XCTAssertEqual(TVPlaybackFormatting.progress(position: 100, duration: 0), 0)
        XCTAssertEqual(TVPlaybackFormatting.progress(position: -1, duration: 100), 0)
        XCTAssertEqual(TVPlaybackFormatting.progress(position: 200, duration: 100), 1)
        XCTAssertEqual(TVPlaybackFormatting.progress(position: 50, duration: 100), 0.5)
        XCTAssertEqual(TVPlaybackFormatting.time(-1), "0:00")
        XCTAssertEqual(TVPlaybackFormatting.time(3_661_000), "1:01:01")
    }

    func testSourcePickerNeverExposesCredentialedURLOrRawReleaseGroup() {
        let stream = StreamOption(url: URL(string: "https://backend.example/stream/movie?token=secret")!,
            title: "Movie.2160p.HEVC.DTS-HD.5.1-GROUP", quality: "2160p", sizeBytes: nil,
            sourceName: "Private server", bingeGroup: "velvet-GROUP", headers: [:])
        let label = TVPlaybackFormatting.sourceDescription(stream, index: 0)
        XCTAssertTrue(label.contains("4K"))
        XCTAssertTrue(label.contains("HEVC"))
        XCTAssertFalse(label.contains("GROUP"))
        XCTAssertFalse(label.contains("secret"))
    }
}
