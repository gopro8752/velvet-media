import XCTest

@MainActor
final class TVServicesUITests: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["VELVET_UI_FIXTURE"] = "http://127.0.0.1:18886"
    }

    func testGuideFocusFavoritesFutureProgramAndLivePlayback() throws {
        app.launchArguments = ["-VelvetDeepLink", "velvet://tab/live"]
        app.launch()
        let channel = app.buttons["live.channel.fixture-1"]
        XCTAssertTrue(channel.waitForExistence(timeout: 20))
        let favorite = app.buttons["live.favorite.fixture-1"]
        try select(favorite)
        let original = favorite.value as? String
        XCTAssertTrue(original == "Favorite" || original == "Not favorite")
        try select(favorite)
        XCTAssertNotEqual(favorite.value as? String, original)
        let future = app.buttons["live.program.fixture-1.fixture-1-1"]
        try select(future)
        XCTAssertTrue(app.buttons["Watch channel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Next on Velvet One"].exists)
        capture("Upcoming program details")
        remote.press(.menu)
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        try focus(channel)
        capture("Live TV guide with remote focus")
        try select(channel)
        XCTAssertTrue(app.buttons["live.play"].waitForExistence(timeout: 20), "The generated HLS fixture should play natively.")
        remote.press(.menu)
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
    }

    func testSportsCatalogSourceSelectionAndNativePlayback() throws {
        app.launchArguments = ["-VelvetDeepLink", "velvet://tab/sports"]
        app.launch()
        try select(app.buttons["sports.event.fixture-game"])
        try select(app.buttons["sports.source.fixture-source.1"])
        XCTAssertTrue(app.buttons["live.play"].waitForExistence(timeout: 20), "Sports should use the server's native HLS lease.")
        XCTAssertTrue(app.staticTexts["Comets at Meteors"].exists)
        capture("Native sports playback")
        remote.press(.menu)
        XCTAssertTrue(app.buttons["sports.event.fixture-game"].waitForExistence(timeout: 10))
    }

    func testCategoryCreationUsesSelectedProfileAndClosesOnSuccess() throws {
        app.launchArguments = ["-VelvetDeepLink", "velvet://tab/home"]
        app.launch()
        try select(app.buttons["home.createCategory"])
        XCTAssertTrue(app.textFields["category.prompt"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.keyboards.count, 0, "Opening the composer must not start text entry automatically.")
        try select(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Star Wars movies in story order")).firstMatch)
        try select(app.buttons["category.create"])
        XCTAssertTrue(app.buttons["home.createCategory"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your Test Collection"].waitForExistence(timeout: 10))
        try select(app.buttons["Play all"].firstMatch)
        XCTAssertTrue(app.buttons["player.play"].waitForExistence(timeout: 20))
        remote.press(.menu)
        try select(app.buttons["Shuffle"].firstMatch)
        XCTAssertTrue(app.buttons["player.play"].waitForExistence(timeout: 20))
        remote.press(.menu)
        try select(app.buttons["Delete Your Test Collection"])
        try select(app.buttons["Delete category"].firstMatch)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.app.staticTexts["Your Test Collection"].exists
        }, object: nil)], timeout: 5) == .completed)
    }

    private func select(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        try focus(element, file: file, line: line)
        remote.press(.select)
    }

    private func focus(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 20), file: file, line: line)
        for _ in 0..<50 {
            if element.hasFocus { return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else { remote.press(.down); continue }
            let dy = element.frame.midY - focused.frame.midY
            let dx = element.frame.midX - focused.frame.midX
            if abs(dy) > max(45, focused.frame.height * 0.7) { remote.press(dy > 0 ? .down : .up) }
            else if abs(dx) > 15 { remote.press(dx > 0 ? .right : .left) }
            else { remote.press(.down) }
        }
        XCTFail("Remote cannot reach \(element.identifier)", file: file, line: line)
        throw NSError(domain: "TVServicesFocus", code: 1)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
