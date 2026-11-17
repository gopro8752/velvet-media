import XCTest

/// Exercises the actual tvOS focus engine with Siri Remote events. The fixture
/// is loopback-only and supplies catalog data without personal backend tokens.
@MainActor
final class TVBrowseUITests: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["VELVET_UI_FIXTURE"] = "http://127.0.0.1:18886"
    }

    func testHomeDetailsAndRemoteBack() throws {
        app.launch()
        let heroDetails = app.buttons["home.heroDetails"]
        XCTAssertTrue(heroDetails.waitForExistence(timeout: 20))
        try focus(heroDetails)
        assertFullyOnScreen(heroDetails)
        remote.press(.select)
        XCTAssertTrue(app.buttons["details.back"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["details.play"].exists)
        remote.press(.menu)
        XCTAssertTrue(heroDetails.waitForExistence(timeout: 10), "Back must return to browsing, not trap focus in navigation.")
        capture("Home after returning from details")
    }

    func testDescriptionExpandsWithoutOverlappingActions() throws {
        app.launchArguments = ["-VelvetDeepLink", "velvet://details/show/999002"]
        app.launch()
        let description = app.buttons["details.description"]
        XCTAssertTrue(description.waitForExistence(timeout: 20))
        try focus(description)
        XCTAssertEqual(description.value as? String, "Collapsed")
        let collapsedHeight = description.frame.height
        remote.press(.select)
        XCTAssertTrue(waitUntil { description.value as? String == "Expanded" })
        XCTAssertGreaterThan(description.frame.height, collapsedHeight, "The long fixture description should expand past five lines.")
        let play = app.buttons["details.play"]
        XCTAssertGreaterThanOrEqual(play.frame.minY, description.frame.maxY - 1,
                                    "Actions must move below the expanded description.")
        capture("Expanded details description")
        remote.press(.select)
        XCTAssertTrue(waitUntil { description.value as? String == "Collapsed" })
        XCTAssertLessThanOrEqual(description.frame.height, collapsedHeight + 2)
    }

    func testLeftmostFocusedCardKeepsItsOutlineInsideScreen() throws {
        app.launch()
        let card = app.buttons["home.card.movie.999001"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        try focus(card)
        assertFullyOnScreen(card, inset: 18)
        capture("Leftmost focused home card")
    }

    func testCardContextMenuCanAddToMyList() throws {
        app.launch()
        let card = app.buttons["home.card.movie.999001"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        try focus(card)
        remote.press(.select, forDuration: 1.2)
        // tvOS exposes native context-menu choices as collection cells, not
        // buttons. Match the labeled child, then focus the selectable cell.
        let addToList = app.cells.containing(.other, identifier: "Add to My List").firstMatch
        if !addToList.waitForExistence(timeout: 5) {
            capture("Card context menu after holding Select")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Holding Select should reveal card actions.")
            return
        }
        try select(addToList)
        XCTAssertTrue(app.staticTexts["My List"].waitForExistence(timeout: 8))
    }

    func testProfileCreateRenameAndDeleteUsingRemote() throws {
        app.launchArguments = ["-VelvetDeepLink", "velvet://tab/settings"]
        app.launch()
        try openProfiles()
        try select(app.buttons["profiles.add"])
        let name = app.textFields["profiles.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        try select(name)
        name.typeText("TV Test Viewer")
        remote.press(.menu) // close the system keyboard, retaining the editor
        try select(app.buttons["profiles.save"])

        // A new profile is selected immediately; reopen the picker to manage it.
        try openProfiles()
        let created = app.buttons["profiles.TV Test Viewer"]
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        try select(app.buttons["profiles.edit"])
        try select(created)
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        try select(name)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "TV Renamed Viewer")
        remote.press(.menu)
        try select(app.buttons["profiles.save"])
        let renamed = app.buttons["profiles.TV Renamed Viewer"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 10))
        try select(renamed)
        try select(app.buttons["profiles.delete"])
        try select(app.buttons["Delete"].firstMatch)
        XCTAssertTrue(waitUntil { !renamed.exists })
    }

    private func openProfiles() throws {
        let manage = app.buttons["Switch or manage profiles"]
        XCTAssertTrue(manage.waitForExistence(timeout: 12))
        try select(manage)
        XCTAssertTrue(app.buttons["profiles.add"].waitForExistence(timeout: 10))
    }

    private func select(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        try focus(element, file: file, line: line)
        remote.press(.select)
    }

    /// Move geometrically, allowing tvOS to scroll focused rails into view.
    /// Tests fail if an element is visually present but unreachable by remote.
    private func focus(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 12), file: file, line: line)
        for _ in 0..<45 {
            if element.hasFocus { return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else { remote.press(.down); continue }
            let target = element.frame
            let source = focused.frame
            let dy = target.midY - source.midY
            let dx = target.midX - source.midX
            if abs(dy) > max(45, source.height * 0.7) {
                remote.press(dy > 0 ? .down : .up)
            } else if abs(dx) > 15 {
                remote.press(dx > 0 ? .right : .left)
            } else {
                remote.press(.down)
            }
        }
        capture("Unreachable focus target \(element.identifier)")
        XCTFail("Remote could not focus \(element.identifier)", file: file, line: line)
        throw NSError(domain: "TVRemoteFocus", code: 1)
    }

    private func assertFullyOnScreen(_ element: XCUIElement, inset: CGFloat = 0,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let screen = app.frame.insetBy(dx: inset, dy: inset)
        XCTAssertTrue(screen.contains(element.frame), "Focused element extends outside screen: \(element.frame)", file: file, line: line)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 5) == .completed
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
