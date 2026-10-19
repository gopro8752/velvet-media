import XCTest
@testable import Velvet

final class LiveGuidePolicyTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let channel = LiveChannel(id: "news", name: "Local News", number: "102", logoUrl: nil, group: "News")

    private func program(_ id: String, _ start: TimeInterval, _ end: TimeInterval, title: String = "Evening report", episode: String? = nil) -> LiveProgram {
        LiveProgram(id: id, title: title, startTime: origin.addingTimeInterval(start), endTime: origin.addingTimeInterval(end),
                    description: nil, episodeTitle: episode)
    }

    func testProgramSearchFindsUpcomingEpisodeButIgnoresExpiredPrograms() {
        let schedule = LiveChannelSchedule(channelId: channel.id, programs: [
            program("old", -600, 0, title: "Expired show"),
            program("current", -60, 60, title: "Evening report"),
            program("next", 60, 3600, title: "Wild Worlds", episode: "Hidden coast")])
        XCTAssertTrue(LiveGuidePolicy.matches("  wild  ", channel: channel, schedule: schedule, at: origin))
        XCTAssertTrue(LiveGuidePolicy.matches("coast", channel: channel, schedule: schedule, at: origin))
        XCTAssertTrue(LiveGuidePolicy.matches("102", channel: channel, schedule: schedule, at: origin))
        XCTAssertFalse(LiveGuidePolicy.matches("Expired", channel: channel, schedule: schedule, at: origin))
        XCTAssertEqual(LiveGuidePolicy.matchingPrograms("COAST", schedule: schedule, at: origin).map(\.id), ["next"])
    }

    func testTimelineClipsOverlapsAndRetainsRealGapsWithoutChangingTimeScale() {
        let schedule = LiveChannelSchedule(channelId: "news", programs: [
            program("end", 100, 180), program("overlap", 20, 70), program("start", -50, 40),
            program("invalid", 110, 105)])
        let pieces = LiveGuidePolicy.segments(schedule: schedule, from: origin, to: origin.addingTimeInterval(120))
        XCTAssertEqual(pieces.map { $0.start.timeIntervalSince(origin) }, [0, 40, 70, 100])
        XCTAssertEqual(pieces.map { $0.end.timeIntervalSince(origin) }, [40, 70, 100, 120])
        XCTAssertEqual(pieces.map { $0.program?.id }, ["start", "overlap", nil, "end"])
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, 120)
        XCTAssertEqual(LiveGuidePolicy.segments(schedule: nil, from: origin, to: origin.addingTimeInterval(120)).count, 1)
    }

    func testNowBoundaryAndProgressNeverTreatUpcomingProgramAsLive() {
        let item = program("one", 0, 60)
        XCTAssertFalse(LiveGuidePolicy.isLive(item, at: origin.addingTimeInterval(-1)))
        XCTAssertTrue(LiveGuidePolicy.isLive(item, at: origin))
        XCTAssertFalse(LiveGuidePolicy.isLive(item, at: origin.addingTimeInterval(60)))
        XCTAssertEqual(LiveGuidePolicy.progress(item, at: origin.addingTimeInterval(-1)), 0)
        XCTAssertEqual(LiveGuidePolicy.progress(item, at: origin.addingTimeInterval(30)), 0.5)
        XCTAssertEqual(LiveGuidePolicy.progress(item, at: origin.addingTimeInterval(99)), 1)
    }

    func testTimePagingStopsAtLastRealProgramWindow() {
        let start = LiveGuidePolicy.windowStart(at: origin)
        XCTAssertEqual(LiveGuidePolicy.lastWindowStart(lastProgramEnd: start.addingTimeInterval(7200), now: origin), start)
        XCTAssertEqual(LiveGuidePolicy.lastWindowStart(lastProgramEnd: start.addingTimeInterval(7201), now: origin), start.addingTimeInterval(7200))
        XCTAssertEqual(LiveGuidePolicy.lastWindowStart(lastProgramEnd: origin.addingTimeInterval(-20), now: origin), start)
    }

    func testFavoritesFollowBackendAndProfileButNeverStoreCredentialsInKey() {
        let primary = LiveGuidePolicy.favoriteKey(backend: "https://EXAMPLE.invalid:443/prefix/", profile: "one")
        XCTAssertEqual(primary, LiveGuidePolicy.favoriteKey(backend: "https://example.invalid/prefix", profile: "one"))
        XCTAssertNotEqual(primary, LiveGuidePolicy.favoriteKey(backend: "https://example.invalid/prefix", profile: "two"))
        XCTAssertNotEqual(primary, LiveGuidePolicy.favoriteKey(backend: "https://example.invalid/other", profile: "one"))
        XCTAssertNotEqual(primary, LiveGuidePolicy.favoriteKey(backend: "https://other.invalid/prefix", profile: "one"))
        XCTAssertFalse(primary.contains("example"))
        XCTAssertEqual(primary, LiveGuidePolicy.favoriteKey(backend: "https://user:secret@example.invalid/prefix?token=private", profile: "one"))
    }
}
