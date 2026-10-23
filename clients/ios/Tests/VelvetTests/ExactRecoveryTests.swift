import XCTest
@testable import Velvet

final class ExactRecoveryTests: XCTestCase {
    func testRepairGraceRequiresFreshExplicitDecision() throws {
        func decision(_ enabled: Bool, _ hold: Bool, _ age: Double?) -> StreamLookahead.ExactRecovery {
            .init(enabled: enabled, holdFallback: hold, updatedAgoSeconds: age)
        }
        XCTAssertTrue(decision(true, true, 8).holdsProactiveFallback)
        XCTAssertFalse(decision(true, true, 8.01).holdsProactiveFallback)
        XCTAssertFalse(decision(true, true, nil).holdsProactiveFallback)
        XCTAssertFalse(decision(true, true, -.infinity).holdsProactiveFallback)
        XCTAssertFalse(decision(false, true, 0).holdsProactiveFallback)
        XCTAssertFalse(decision(true, false, 0).holdsProactiveFallback)
    }
    func testHeartbeatRemainsOnConfiguredBackendOrigin() {
        XCTAssertTrue(StreamLookahead.belongsToBackend(URL(string: "https://velvet.example/stream/abc")!, base: "https://velvet.example"))
        XCTAssertFalse(StreamLookahead.belongsToBackend(URL(string: "https://other.example/stream/abc")!, base: "https://velvet.example"))
        XCTAssertFalse(StreamLookahead.belongsToBackend(URL(string: "http://velvet.example/stream/abc")!, base: "https://velvet.example"))
    }
    func testMediaAttributionIsScopedAndPreservesOriginalQuery() {
        let session = "12345678-1234-1234-1234-123456789abc"
        let media = URL(string: "https://velvet.example/stream/0123456789abcdef?token=fixture")!
        let attributed = StreamLookahead.attributedMediaURL(media, backend: "https://velvet.example", sessionId: session)
        let query = URLComponents(url: attributed, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "playbackSessionId" }?.value, session)
        XCTAssertEqual(query.first { $0.name == "token" }?.value, "fixture")
        XCTAssertFalse(media.absoluteString.contains("playbackSessionId"))
        XCTAssertEqual(StreamLookahead.attributedMediaURL(media, backend: "https://other.example", sessionId: session), media)
        let probe = URL(string: "https://velvet.example/stream/0123456789abcdef/audio")!
        XCTAssertEqual(StreamLookahead.attributedMediaURL(probe, backend: "https://velvet.example", sessionId: session), probe)
        let wav = URL(string: "https://velvet.example/stream/0123456789abcdef/audio/0.wav")!
        XCTAssertTrue(StreamLookahead.attributedMediaURL(wav, backend: "https://velvet.example", sessionId: session).absoluteString.contains("playbackSessionId"))
    }
    func testRewindIgnoresPreSeekPlayingCallbacks() {
        let a = URL(string: "https://example.test/stream/a")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 120_000)
        metrics.sample(nowMs: 1000, state: "playing", source: a, positionMs: 120_500)
        metrics.seek(to: 60_000)
        metrics.sample(nowMs: 1100, state: "playing", source: a, positionMs: 120_600)
        metrics.didDispatchSeek()
        metrics.sample(nowMs: 1200, state: "playing", source: a, positionMs: 120_700)
        metrics.sample(nowMs: 1500, state: "buffering", source: a, positionMs: 120_700)
        XCTAssertEqual(metrics.rebufferCount, 0)
    }
    func testAttemptsOnlyBecomeSuccessfulOnReplacementPlayback() {
        let a = URL(string: "https://example.test/stream/a")!, b = URL(string: "https://example.test/stream/b")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 500)
        metrics.prepare(b, automatic: true)
        metrics.prepare(b, automatic: true)
        metrics.sample(nowMs: 1000, state: "playing", source: a, positionMs: 1000)
        XCTAssertEqual(metrics.automaticSwitchAttempts, 1)
        XCTAssertEqual(metrics.automaticSourceSwitches, 0)
        metrics.sample(nowMs: 1500, state: "playing", source: b, positionMs: 1500)
        metrics.sample(nowMs: 2000, state: "playing", source: b, positionMs: 2000)
        XCTAssertEqual(metrics.automaticSourceSwitches, 1)
    }
    func testFrozenPlayingStateCannotClaimSuccessfulReplacement() {
        let a = URL(string: "https://example.test/stream/a")!, b = URL(string: "https://example.test/stream/b")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 500)
        metrics.sample(nowMs: 1000, state: "playing", source: a, positionMs: 1000)
        metrics.prepare(b, automatic: false)
        for time in stride(from: Int64(1500), through: 5000, by: 500) {
            metrics.sample(nowMs: time, state: "playing", source: b, positionMs: 0)
        }
        XCTAssertEqual(metrics.manualSwitchAttempts, 1)
        XCTAssertEqual(metrics.manualSourceSwitches, 0)
        metrics.sample(nowMs: 5500, state: "playing", source: b, positionMs: 500)
        XCTAssertEqual(metrics.manualSourceSwitches, 1)
    }
    func testFailedSeekCannotHideBufferingIndefinitely() {
        let a = URL(string: "https://example.test/stream/a")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 500)
        metrics.sample(nowMs: 1000, state: "playing", source: a, positionMs: 1000)
        metrics.seek(to: 60_000); metrics.didDispatchSeek()
        for time in stride(from: Int64(1500), through: 15_500, by: 500) {
            metrics.sample(nowMs: time, state: "buffering", source: a, positionMs: 1000)
        }
        XCTAssertEqual(metrics.rebufferCount, 0)
        metrics.sample(nowMs: 16_000, state: "buffering", source: a, positionMs: 1000)
        XCTAssertEqual(metrics.rebufferCount, 1)
    }
    func testSeekBufferingExcludedFromNetworkStalls() {
        let a = URL(string: "https://example.test/stream/a")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 500)
        metrics.sample(nowMs: 750, state: "playing", source: a, positionMs: 750)
        metrics.seek(to: 60_000)
        metrics.didDispatchSeek()
        metrics.sample(nowMs: 1000, state: "buffering", source: a, positionMs: 500)
        XCTAssertEqual(metrics.rebufferCount, 0)
        metrics.sample(nowMs: 1500, state: "playing", source: a, positionMs: 60_000)
        metrics.sample(nowMs: 1750, state: "playing", source: a, positionMs: 60_250)
        metrics.sample(nowMs: 2000, state: "buffering", source: a, positionMs: 60_500)
        metrics.sample(nowMs: 3000, state: "playing", source: a, positionMs: 60_500)
        XCTAssertEqual(metrics.rebufferCount, 1)
        XCTAssertEqual(metrics.rebufferedMs, 1000)
        XCTAssertEqual(metrics.seekCount, 1)
    }
}
