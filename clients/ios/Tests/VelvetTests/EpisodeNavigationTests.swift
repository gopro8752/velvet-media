import XCTest
@testable import Velvet

final class EpisodeNavigationTests: XCTestCase {
    private func episode(_ season: Int, _ number: Int) -> Episode {
        Episode(season: season, number: number, title: "S\(season) E\(number)")
    }

    func testFirstRegularEpisodeDoesNotEnterSpecials() async throws {
        var calls = [Int]()
        let previous = try await findPreviousEpisode(season: 1, episode: 1, seasonNumbers: [0, 1]) {
            calls.append($0)
            return [self.episode(0, 8)]
        }
        XCTAssertNil(previous)
        XCTAssertTrue(calls.isEmpty)
    }

    func testNearestExistingEpisodeIgnoresGapsAndWrongSeason() async throws {
        let previous = try await findPreviousEpisode(season: 2, episode: 6, seasonNumbers: [1, 2]) { _ in
            [self.episode(2, 1), self.episode(1, 5), self.episode(2, 4), self.episode(2, 6), self.episode(2, 0)]
        }
        XCTAssertEqual(previous, episode(2, 4))
    }

    func testSeasonBoundaryChoosesLastActualEpisode() async throws {
        var calls = [Int]()
        let previous = try await findPreviousEpisode(season: 3, episode: 1, seasonNumbers: [0, 1, 2, 3]) {
            calls.append($0)
            return [self.episode(2, 4), self.episode(2, 10), self.episode(2, 1)]
        }
        XCTAssertEqual(previous, episode(2, 10))
        XCTAssertEqual(calls, [2])
    }

    func testEmptySeasonsAreSkippedOnceInDescendingOrder() async throws {
        var calls = [Int]()
        let previous = try await findPreviousEpisode(season: 4, episode: 1, seasonNumbers: [2, 0, 3, 3, 1, 4]) {
            calls.append($0)
            return $0 == 1 ? [self.episode(1, 7)] : []
        }
        XCTAssertEqual(previous, episode(1, 7))
        XCTAssertEqual(calls, [3, 2, 1])
    }

    func testNoEarlierActualEpisodeReturnsNil() async throws {
        let previous = try await findPreviousEpisode(season: 2, episode: 1, seasonNumbers: [0, 1, 2]) { _ in [] }
        XCTAssertNil(previous)
    }

    func testSpecialsNavigateOnlyWithinTheirSeason() async throws {
        let previous = try await findPreviousEpisode(season: 0, episode: 4, seasonNumbers: [0, 1]) { _ in
            [self.episode(0, 1), self.episode(0, 3)]
        }
        XCTAssertEqual(previous, episode(0, 3))
        let first = try await findPreviousEpisode(season: 0, episode: 1, seasonNumbers: [0, 1]) { _ in
            XCTFail("S0 E1 must not fetch another season")
            return []
        }
        XCTAssertNil(first)
    }

    func testInvalidCoordinatesNeverFetch() async throws {
        for (season, number) in [(-1, 2), (1, 0), (1, -1)] {
            let previous = try await findPreviousEpisode(season: season, episode: number, seasonNumbers: [1]) { _ in
                XCTFail("Invalid coordinates must not fetch metadata")
                return []
            }
            XCTAssertNil(previous)
        }
    }

    func testMissingCurrentSeasonFailsWithoutSkippingIt() async {
        enum Offline: Error { case failed }
        var calls = [Int]()
        do {
            _ = try await findPreviousEpisode(season: 3, episode: 4, seasonNumbers: [1, 2, 3]) {
                calls.append($0)
                throw Offline.failed
            }
            XCTFail("Expected metadata error")
        } catch { XCTAssertTrue(error is Offline) }
        XCTAssertEqual(calls, [3])
    }

    func testMissingEarlierSeasonFailsWithoutSkippingIt() async {
        enum Offline: Error { case failed }
        var calls = [Int]()
        do {
            _ = try await findPreviousEpisode(season: 3, episode: 1, seasonNumbers: [1, 2, 3]) {
                calls.append($0)
                throw Offline.failed
            }
            XCTFail("Expected metadata error")
        } catch { XCTAssertTrue(error is Offline) }
        XCTAssertEqual(calls, [2])
    }

    func testCancellationPropagatesWithoutTryingAnotherSeason() async {
        var calls = [Int]()
        do {
            _ = try await findPreviousEpisode(season: 3, episode: 1, seasonNumbers: [1, 2, 3]) {
                calls.append($0)
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, [2])
    }
}
