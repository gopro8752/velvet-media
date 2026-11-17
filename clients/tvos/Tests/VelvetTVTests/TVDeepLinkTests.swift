import XCTest
@testable import Velvet

final class TVDeepLinkTests: XCTestCase {
    func testEpisodeLinkRetainsRequestedEpisode() throws {
        let url = try XCTUnwrap(URL(string: "velvet://play/show/1668?s=1&e=3"))
        guard case .play(let target) = TVDeepLink(url: url) else { return XCTFail("Expected player") }
        XCTAssertEqual(target.mediaId, 1668)
        XCTAssertEqual(target.season, 1)
        XCTAssertEqual(target.episode, 3)
    }

    func testRejectsInvalidNavigation() {
        for raw in ["https://play/movie/1", "velvet://play/movie/-1", "velvet://play/show/1?e=0", "velvet://play/unknown/1"] {
            XCTAssertNil(TVDeepLink(url: URL(string: raw)!))
        }
    }
}
