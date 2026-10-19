import XCTest
@testable import Velvet

final class PlaybackTelemetryTests: XCTestCase {
    func testWallTimeExcludesPausesAndSurvivesSourceChanges() {
        var clock = PlaybackTelemetryClock(now: 0)
        clock.sample(now: 1, state: "playing")
        clock.sample(now: 2, state: "playing")
        clock.sample(now: 2.5, state: "paused")
        clock.sample(now: 3.5, state: "buffering")
        clock.sample(now: 4.5, state: "playing")
        clock.sample(now: 5, state: "ended")
        clock.sample(now: 6, state: "ended")
        XCTAssertEqual(clock.playedMs, 2_000)
        XCTAssertEqual(clock.bufferedMs, 2_000)
    }
    func testDuplicatesAndUnobservedSuspensionCannotInflateWatchTime() {
        var clock = PlaybackTelemetryClock(now: 0)
        clock.sample(now: 0, state: "playing")
        clock.sample(now: 1, state: "playing")
        clock.sample(now: 1, state: "playing")
        clock.sample(now: 3600, state: "paused")
        XCTAssertEqual(clock.playedMs, 3_000)
        clock.sample(now: 3601, state: "ended")
        XCTAssertEqual(clock.playedMs, 3_000)
    }
}
