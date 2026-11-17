import XCTest

@MainActor
final class TVPlayerUITests: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["VELVET_UI_FIXTURE"] = "http://127.0.0.1:18886"
    }

    func testRemotePlaybackControlsSourcesAndTracksThenReturnToBrowsing() throws {
        app.launchArguments = ["-VelvetDeepLink", "velvet://play/movie/999001"]
        app.launch()
        let play = app.buttons["player.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20), "Native VOD should begin from the fixture backend.")
        remote.press(.playPause)
        XCTAssertTrue(wait { play.label == "Play" }, "Hardware Play/Pause must pause playback and reveal controls.")
        try select(app.buttons["player.rewind"])
        try select(app.buttons["player.forward"])
        try select(app.buttons["player.streams"])
        XCTAssertTrue(app.staticTexts["Choose a stream"].waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(app.buttons["player.options"].waitForExistence(timeout: 5))
        try select(app.buttons["player.options"])
        XCTAssertTrue(app.staticTexts["Playback options"].waitForExistence(timeout: 5))
        let audio = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Audio")).firstMatch
        try select(audio)
        XCTAssertTrue(app.staticTexts["Audio"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Remote audio selection"
        attachment.lifetime = .keepAlways
        add(attachment)
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["Playback options"].waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(app.buttons["player.play"].waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(app.buttons["home.heroDetails"].waitForExistence(timeout: 10))
    }

    private func select(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0..<30 {
            if element.hasFocus { remote.press(.select); return }
            let current = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard current.exists else { remote.press(.down); continue }
            let dx = element.frame.midX - current.frame.midX
            let dy = element.frame.midY - current.frame.midY
            if abs(dy) > max(40, current.frame.height * 0.7) { remote.press(dy > 0 ? .down : .up) }
            else if abs(dx) > 15 { remote.press(dx > 0 ? .right : .left) }
            else { remote.press(.down) }
        }
        XCTFail("Remote could not reach \(element.identifier)", file: file, line: line)
        throw NSError(domain: "TVPlayerFocus", code: 1)
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 5) == .completed
    }
}
