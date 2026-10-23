import XCTest
@testable import Velvet

final class StreamFailoverWatchdogTests: XCTestCase {
    private func watchdog() -> StreamFailoverWatchdog {
        var result = StreamFailoverWatchdog()
        result.reset(nowMs: 0, generation: 1)
        return result
    }

    func testSilentStartupTriggersOnceAtSixSeconds() {
        var timer = watchdog()
        XCTAssertFalse(timer.check(5_999))
        XCTAssertTrue(timer.check(6_000))
        XCTAssertFalse(timer.check(6_500))
    }

    func testBufferProgressCannotExtendStartupPastTwelveSeconds() {
        var timer = watchdog()
        for time in stride(from: Int64(2_000), through: 10_000, by: 2_000) {
            XCTAssertFalse(timer.check(time, buffered: time))
        }
        XCTAssertFalse(timer.check(11_999, buffered: 11_999))
        XCTAssertTrue(timer.check(12_000, buffered: 12_000))
    }

    func testFirstMetadataCountsOnceButCorrectionsDoNotHideStall() {
        var timer = watchdog()
        XCTAssertFalse(timer.check(5_000, duration: 100_000))
        XCTAssertFalse(timer.check(10_999, duration: 100_100))
        XCTAssertTrue(timer.check(11_000, duration: 100_200))
    }

    func testTransientUnknownDurationDoesNotRefreshMetadataBudget() {
        var timer = watchdog()
        XCTAssertFalse(timer.check(1_000, duration: 100_000))
        XCTAssertFalse(timer.check(5_000, duration: 0))
        XCTAssertTrue(timer.check(7_000, duration: 100_000))
    }

    func testRebufferAfterActualPlaybackHasFifteenSecondBudget() {
        var timer = watchdog()
        XCTAssertFalse(timer.check(1_000, position: 1_000, playing: true))
        XCTAssertFalse(timer.check(2_000, position: 1_000))
        XCTAssertFalse(timer.check(16_999, position: 1_000))
        XCTAssertTrue(timer.check(17_000, position: 1_000))
    }

    func testVLCPlayingClaimWithoutAdvancementCannotSuppressStall() {
        var timer = watchdog()
        XCTAssertFalse(timer.check(1_000, position: 1_000, playing: true))
        XCTAssertFalse(timer.check(2_000, position: 1_000, playing: true))
        XCTAssertTrue(timer.check(17_000, position: 1_000, playing: true))
        var startup = watchdog()
        XCTAssertTrue(startup.check(6_000, playing: true))
    }

    func testActualAdvancementKeepsHealthyPlaybackAlive() {
        var timer = watchdog()
        for time in stride(from: Int64(500), through: 30_000, by: 500) {
            XCTAssertFalse(timer.check(time, position: time, playing: true))
        }
    }

    func testPauseBackgroundAndIneligibilityExcludeElapsedTime() {
        for gate in ["paused", "suppressed", "ineligible"] {
            var timer = watchdog()
            XCTAssertFalse(timer.check(5_000))
            XCTAssertFalse(timer.check(30_000, ready: gate != "paused", suppressed: gate == "suppressed", eligible: gate != "ineligible"))
            XCTAssertFalse(timer.check(40_000))
            XCTAssertFalse(timer.check(45_999))
            XCTAssertTrue(timer.check(46_000))
        }
    }

    func testTerminalStateDoesNotTrigger() {
        var timer = watchdog()
        XCTAssertFalse(timer.check(30_000, buffering: false))
        XCTAssertFalse(timer.check(60_000, buffering: false))
        XCTAssertFalse(timer.check(90_000))
        XCTAssertTrue(timer.check(96_000))
    }

    func testSourceChangeOrSeekGetsFreshGrace() {
        var timer = watchdog()
        XCTAssertFalse(timer.check(1_000, position: 1_000, playing: true))
        timer.reset(nowMs: 6_000, generation: 2, positionMs: 60_000, durationMs: 100_000)
        XCTAssertFalse(timer.check(11_999, generation: 2, position: 60_000, duration: 100_000))
        XCTAssertTrue(timer.check(12_000, generation: 2, position: 60_000, duration: 100_000))
    }

    func testStaleGenerationCannotTriggerOrChangeNewDeadline() {
        var timer = watchdog()
        timer.reset(nowMs: 10_000, generation: 2)
        XCTAssertFalse(timer.check(15_999, generation: 1, position: 30_000, playing: true))
        XCTAssertTrue(timer.check(16_000, generation: 2))
    }

    func testRecoveryRearmsAfterPlaybackAdvancesAgain() {
        var timer = watchdog()
        XCTAssertTrue(timer.check(6_000))
        XCTAssertFalse(timer.check(6_500))
        XCTAssertFalse(timer.check(7_000, position: 1_000, playing: true))
        XCTAssertFalse(timer.check(8_000, position: 1_000))
        XCTAssertTrue(timer.check(23_000, position: 1_000))
    }
}

private extension StreamFailoverWatchdog {
    mutating func check(_ now: Int64, generation: UInt64 = 1, position: Int64 = 0,
                        buffered: Int64 = 0, duration: Int64 = 0, buffering: Bool = true,
                        playing: Bool = false, ready: Bool = true, suppressed: Bool = false,
                        eligible: Bool = true) -> Bool {
        shouldFailover(nowMs: now, generation: generation, positionMs: position,
                       bufferedPositionMs: buffered, durationMs: duration,
                       buffering: buffering, isPlaying: playing, playWhenReady: ready,
                       suppressed: suppressed, eligible: eligible)
    }
}
