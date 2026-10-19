import XCTest
@testable import Velvet

final class CategoryQueueNavigationTests: XCTestCase {
    private func cursor() throws -> CategoryQueueCursor {
        let json = #"""
        {"id":"mixed","title":"Saved shuffle","items":[
          {"mediaId":10,"type":"show","title":"Show A","season":3,"episode":8},
          {"mediaId":20,"type":"movie","title":"Movie"},
          {"mediaId":10,"type":"show","title":"Show A","season":1,"episode":2}
        ]}
        """#
        return CategoryQueueCursor(category: try JSONDecoder().decode(HomeCategory.self, from: Data(json.utf8)))
    }

    func testFirstItemHasNoPreviousAndDoesNotWrap() throws {
        var queue = try cursor()
        let id = queue.id
        XCTAssertNil(queue.previous)
        XCTAssertFalse(queue.previous(expectedID: id, expectedIndex: 0))
        XCTAssertEqual(queue.id, id)
        XCTAssertEqual(queue.index, 0)
    }

    func testPreviousUsesSavedOrderAcrossMoviesAndShows() throws {
        var queue = try cursor()
        XCTAssertTrue(queue.advance(expectedID: queue.id, expectedIndex: 0, reason: .manual))
        XCTAssertTrue(queue.advance(expectedID: queue.id, expectedIndex: 1, reason: .manual))
        XCTAssertEqual(queue.previous?.type, .movie)
        XCTAssertTrue(queue.advance(expectedID: queue.id, expectedIndex: 2, reason: .previous))
        XCTAssertEqual(queue.current?.mediaId, 20)
        XCTAssertTrue(queue.previous(expectedID: queue.id, expectedIndex: 1))
        XCTAssertEqual(queue.current?.season, 3)
        XCTAssertEqual(queue.current?.episode, 8)
    }

    func testBackwardMoveRotatesIdentityAndInvalidatesOldCallbacks() throws {
        var queue = try cursor()
        let firstID = queue.id
        XCTAssertTrue(queue.advance(expectedID: firstID, expectedIndex: 0, reason: .manual))
        let secondID = queue.id
        let oldPrefetchID = queue.nextID
        XCTAssertTrue(queue.previous(expectedID: secondID, expectedIndex: 1))
        XCTAssertNotEqual(queue.id, firstID)
        XCTAssertNotEqual(queue.id, secondID)
        XCTAssertNotEqual(queue.nextID, oldPrefetchID)
        XCTAssertFalse(queue.advance(expectedID: firstID, expectedIndex: 0, reason: .completed))
        XCTAssertFalse(queue.previous(expectedID: secondID, expectedIndex: 1))
        let validID = queue.id
        XCTAssertTrue(queue.advance(expectedID: validID, expectedIndex: 0, reason: .manual))
        XCTAssertFalse(queue.advance(expectedID: secondID, expectedIndex: 1, reason: .completed))
        XCTAssertEqual(queue.index, 1)
    }

    func testPreviousResetsFailuresAndRejectsWrongIndex() throws {
        var queue = try cursor()
        XCTAssertTrue(queue.advance(expectedID: queue.id, expectedIndex: 0, reason: .unavailable))
        XCTAssertTrue(queue.advance(expectedID: queue.id, expectedIndex: 1, reason: .unavailable))
        XCTAssertFalse(queue.canAutoSkipUnavailable)
        XCTAssertFalse(queue.previous(expectedID: queue.id, expectedIndex: 0))
        XCTAssertTrue(queue.previous(expectedID: queue.id, expectedIndex: 2))
        XCTAssertEqual(queue.consecutiveFailures, 0)
        XCTAssertTrue(queue.canAutoSkipUnavailable)
    }

    func testNextPassStartsWithoutPreviousFromOldPass() throws {
        var queue = try cursor()
        for index in 0..<3 {
            XCTAssertTrue(queue.advance(expectedID: queue.id, expectedIndex: index, reason: .completed))
        }
        XCTAssertEqual(queue.index, 0)
        XCTAssertNil(queue.previous)
    }

    func testEmptyQueueAndLegacyPlaybackInitializerHaveNoPrevious() {
        var queue = CategoryQueueCursor(category: HomeCategory(id: "empty", title: "Empty", items: []))
        XCTAssertNil(queue.previous)
        XCTAssertFalse(queue.previous(expectedID: queue.id, expectedIndex: 0))
        let state = CategoryQueuePlayback(title: "Existing caller", index: 0, count: 1,
                                          next: nil, canAutoSkipUnavailable: true)
        XCTAssertNil(state.previous)
    }
}
