import XCTest
import UIKit

/// Run against a dedicated simulator. These tests deliberately have no stream
/// sources and cannot contact the household backend or sync viewing history.
@MainActor
final class NativeLayoutUITests: XCTestCase {
    private let app = XCUIApplication()
    private var initialWindowSize: CGSize?

    override func setUpWithError() throws {
        continueAfterFailure = false
        initialWindowSize = nil
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testIPadHomeUsesNativeWindowInPortraitAndBothLandscapeDirections() throws {
        try requireIPad()
        launch("velvet://tab/home")
        XCTAssertTrue(app.buttons["Switch profile"].waitForExistence(timeout: 20))
        assertNativeWindow(landscape: false)
        capture("Home — portrait")

        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            assertNativeWindow(landscape: true)
            assertWithinWindow(app.buttons["Switch profile"])
            capture("Home — \(orientation == .landscapeLeft ? "landscape left" : "landscape right")")
        }

        XCUIDevice.shared.orientation = .portrait
        assertNativeWindow(landscape: false)
        XCTAssertTrue(app.buttons["Switch profile"].isHittable)

        XCUIDevice.shared.orientation = .portraitUpsideDown
        XCTAssertEqual(XCUIDevice.shared.orientation, .portraitUpsideDown)
        assertNativeWindow(landscape: false)
        assertWithinWindow(app.buttons["Switch profile"])
        capture("Home — portrait upside down")
    }

    func testIPadSearchGridAndPushedDetailsRemainUsableAfterRotation() throws {
        try requireIPad()
        launch("velvet://tab/search")
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .landscapeLeft
        assertNativeWindow(landscape: true)
        assertWithinWindow(search)
        search.tap()
        search.typeText("iCarly\n")

        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "iCarly")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 60), "Public TMDB search must return the iCarly fixture.")
        XCTAssertTrue(result.isHittable)
        assertWithinWindow(result)
        // Three giant posters on a native landscape iPad would fail this check.
        // The adaptive grid should add columns instead of stretching phone cards.
        XCTAssertLessThanOrEqual(result.frame.width, 240)
        XCTAssertGreaterThan(result.frame.width, 90)
        capture("Search results — landscape")

        result.tap()
        let play = detailsPlayButton
        XCTAssertTrue(play.waitForExistence(timeout: 60), "The selected result must open full-screen details.")
        assertNativeWindow(landscape: true)
        assertWithinWindow(play)
        assertWithinWindow(hittableButton(named: "My List"))
        capture("Details pushed — landscape left")

        XCUIDevice.shared.orientation = .portrait
        assertNativeWindow(landscape: false)
        assertWithinWindow(play)
        capture("Details pushed — portrait")

        XCUIDevice.shared.orientation = .landscapeRight
        assertNativeWindow(landscape: true)
        assertWithinWindow(play)
        capture("Details pushed — landscape right")

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        assertWithinWindow(search)
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Returning from details preserves the search results.")
    }

    func testIPadDetailsSheetFitsNarrowerPresentationInBothOrientations() throws {
        try requireIPad()
        launch("velvet://details/show/5371")
        let play = detailsPlayButton
        XCTAssertTrue(play.waitForExistence(timeout: 60), "Public TMDB details must load the iCarly fixture.")
        assertNativeWindow(landscape: false)
        assertWithinWindow(play)
        assertWithinWindow(hittableButton(named: "My List"))
        capture("Details sheet — portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        assertNativeWindow(landscape: true)
        assertWithinWindow(play)
        assertWithinWindow(hittableButton(named: "My List"))
        capture("Details sheet — landscape")
    }

    func testIPadPlayerForcesLandscapeAndRestoresBrowsingOrientationOnDismiss() throws {
        try requireIPad()
        let cases: [(name: String, start: UIDeviceOrientation, rotateDuringPlayback: UIDeviceOrientation?)] = [
            ("portrait to portrait", .portrait, nil),
            ("landscape to landscape", .landscapeRight, nil),
            ("landscape rotated to portrait", .landscapeLeft, .portrait),
        ]
        for scenario in cases {
            app.terminate()
            XCUIDevice.shared.orientation = scenario.start
            launch("velvet://play/show/5371?s=1&e=7")
            assertNativeWindow(landscape: playerFollowsWindow ? scenario.start.isLandscape : true)
            let close = waitForPlayerClose()
            assertWithinWindow(close)
            capture("Player — \(scenario.name)")
            if let orientation = scenario.rotateDuringPlayback {
                XCUIDevice.shared.orientation = orientation
                XCTAssertEqual(XCUIDevice.shared.orientation, orientation)
                // Modern iPad windows follow physical rotation; older iPads
                // retain landscape until the player is dismissed.
                assertNativeWindow(landscape: playerFollowsWindow ? orientation.isLandscape : true)
                assertWithinWindow(close)
                capture("Player — physical portrait, interface still landscape")
            }
            close.tap()
            XCTAssertTrue(app.buttons["Switch profile"].waitForExistence(timeout: 15))
            assertNativeWindow(landscape: (scenario.rotateDuringPlayback ?? scenario.start).isLandscape)
            assertWithinWindow(app.buttons["Switch profile"])
            capture("After player dismissal — \(scenario.name)")
        }
    }

    func testIPhoneBrowsingRemainsPortraitAfterLandscapePlayerDismissal() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-only orientation contract")
        launch("velvet://tab/home")
        XCTAssertTrue(app.buttons["Switch profile"].waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .landscapeLeft
        assertNativeWindow(landscape: false)
        capture("iPhone Home — physical landscape remains portrait")

        app.terminate()
        launch("velvet://play/show/5371?s=1&e=7")
        assertNativeWindow(landscape: true)
        let close = waitForPlayerClose()
        capture("iPhone Player — landscape")
        close.tap()
        XCTAssertTrue(app.buttons["Switch profile"].waitForExistence(timeout: 15))
        assertNativeWindow(landscape: false)
        capture("iPhone after player dismissal — portrait")
    }

    private func launch(_ deepLink: String) {
        app.launchArguments = [
            "-VelvetDeepLink", deepLink,
            "-sync_url", "http://127.0.0.1:1",
            "-sync_enabled", "NO",
            "-sync_token", "",
            // SettingsStore expects Data here; an empty argument-domain string
            // overrides any persisted sources and therefore decodes as none.
            "-stream_sources", "",
            "-active_profile_id", "test-ipad",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }

    private func requireIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only native-window regression")
    }

    private var playerFollowsWindow: Bool {
        if #available(iOS 26.2, *) { return UIDevice.current.userInterfaceIdiom == .pad }
        return false
    }

    private var detailsPlayButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play S")).firstMatch
    }

    private func waitForPlayerClose() -> XCUIElement {
        // PlayerErrorOverlay has an explicit, stable "Close" action. With no
        // stream sources it appears after metadata loads; no video is requested.
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 60), "The source-disabled player must remain dismissible.")
        XCTAssertTrue(close.isHittable)
        return close
    }

    private func hittableButton(named name: String) -> XCUIElement {
        // A presented details sheet can leave Home's identically named control
        // in the accessibility tree. Resolve the visible action by index instead
        // of asking XCTest to treat several matches as a single element.
        let matches = app.buttons.matching(identifier: name)
        return matches.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            ?? matches.firstMatch
    }

    private func assertNativeWindow(landscape: Bool, file: StaticString = #filePath, line: UInt = #line) {
        // UIScreen in the runner may describe its own legacy 768×1024 hosting
        // surface even on a larger simulator. Inspect the AUT instead: a native
        // iPad window has a tablet-sized short edge, starts at the screen origin,
        // and preserves both dimensions when the interface rotates. The built
        // application's universal device-family setting is checked separately.
        let minimumShortEdge: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 700 : 300
        let initial = initialWindowSize
        let ready = NSPredicate { [app] _, _ in
            let frame = app.frame
            let short = min(frame.width, frame.height)
            let long = max(frame.width, frame.height)
            guard short >= minimumShortEdge, abs(frame.minX) <= 4, abs(frame.minY) <= 4,
                  landscape ? frame.width > frame.height : frame.height > frame.width else { return false }
            guard let initial else { return true }
            return abs(short - initial.width) <= 4 && abs(long - initial.height) <= 4
        }
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       "The application must retain its native \(landscape ? "landscape" : "portrait") window: \(app.frame), initial normalized size \(String(describing: initial)).",
                       file: file, line: line)
        if initialWindowSize == nil {
            initialWindowSize = CGSize(width: min(app.frame.width, app.frame.height),
                                       height: max(app.frame.width, app.frame.height))
        }
        if landscape {
            XCTAssertGreaterThan(app.frame.width, app.frame.height, file: file, line: line)
        } else {
            XCTAssertGreaterThan(app.frame.height, app.frame.width, file: file, line: line)
        }
    }

    private func assertWithinWindow(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, "Control must remain usable after rotation: \(element.label)", file: file, line: line)
        let frame = element.frame
        let window = app.frame.insetBy(dx: -2, dy: -2)
        XCTAssertFalse(frame.isEmpty, file: file, line: line)
        XCTAssertTrue(window.contains(frame), "Control drifted outside the application window: \(frame), window \(window)", file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
