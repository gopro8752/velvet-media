import XCTest
import UIKit

@MainActor
final class LiveSportsUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUp() async throws {
        continueAfterFailure = false
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18881/test/status")!)
        request.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: request)) != nil else { throw XCTSkip("Run scripts/live-tv-fixture.py first.") }
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-VelvetDeepLink", "velvet://tab/sports", "-stream_sources", "",
                               "-sync_url", "http://127.0.0.1:18881", "-sync_token", "fixture-only",
                               "-sync_enabled", "NO", "-active_profile_id", "test-sports", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if name.contains("ForegroundAudioInterruption") { app.launchArguments.append("-VelvetTestAudioInterruption") }
        app.launch()
        XCTAssertTrue(app.buttons["sports.event.test-event"].waitForExistence(timeout: 20))
    }
    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testEventScopesStreamsEmbeddedPlaybackAndIsolation() async throws {
        app.segmentedControls["sports.scope"].buttons["Upcoming"].tap()
        XCTAssertTrue(app.buttons["sports.event.future-event"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sports.event.test-event"].exists)
        app.segmentedControls["sports.scope"].buttons["Live"].tap()
        XCTAssertTrue(app.buttons["sports.event.test-event"].waitForExistence(timeout: 10))
        capture("Live Sports event browser")
        app.buttons["sports.event.test-event"].tap()
        let hd = app.buttons["sports.stream.fixture.1"]
        XCTAssertTrue(hd.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sports.stream.fixture.2"].exists, "Variants sharing the upstream ID must remain selectable.")
        hd.tap()
        XCTAssertTrue(app.buttons["sports.close"].waitForExistence(timeout: 15))
        if #available(iOS 26.2, *), UIDevice.current.userInterfaceIdiom == .pad {
            waitForOrientation(landscape: false)
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        waitForOrientation(landscape: true)
        XCTAssertTrue(app.webViews.staticTexts["Fixture stream HD"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.staticTexts["Video playing"].waitForExistence(timeout: 30), "The selected embed must play inline HLS.")
        XCTAssertTrue(app.staticTexts["Starting stream…"].waitForNonExistence(timeout: 10))
        capture("Embedded sports player")
        app.webViews.buttons["Pause fixture"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Video paused"].waitForExistence(timeout: 5))
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertTrue(app.webViews.staticTexts["Video paused"].exists, "Startup must never resume a later user Pause.")
        let before = try await status()["escapeRequests"] as? Int
        app.webViews.buttons["Open popup"].tap()
        app.webViews.links["Leave player"].tap()
        app.webViews.links["Download file"].tap()
        app.webViews.buttons["Submit form"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Fixture stream HD"].exists)
        let after = try await status()["escapeRequests"] as? Int
        XCTAssertEqual(after, before, "Popup, top navigation, download and form submission must not escape the player.")
        app.buttons["sports.switchStream"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Spanish")).firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Fixture stream SD"].waitForExistence(timeout: 15))
        if #available(iOS 26.2, *), UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .portrait
            waitForOrientation(landscape: false)
            XCTAssertTrue(app.buttons["sports.close"].isHittable)
        }
        app.buttons["sports.close"].tap()
        XCTAssertTrue(app.buttons["sports.event.test-event"].waitForExistence(timeout: 10))
        waitForOrientation(landscape: false)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let requests = try await status()["sportsRequests"] as? Int
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let finalRequests = try await status()["sportsRequests"] as? Int
        XCTAssertEqual(finalRequests, requests, "Closing the player must stop media network requests.")
    }

    func testBackgroundStopsRemotePlayerUntilExplicitResume() async throws {
        app.buttons["sports.event.test-event"].tap()
        let hd = app.buttons["sports.stream.fixture.1"]
        XCTAssertTrue(hd.waitForExistence(timeout: 10)); hd.tap()
        XCTAssertTrue(app.webViews.staticTexts["Video playing"].waitForExistence(timeout: 30))
        // Switch to another app rather than relying on the simulator's Home
        // gesture, which can reveal the iPad Dock without leaving full screen.
        let settingsApp = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settingsApp.activate()
        let backgrounded = NSPredicate { [app] _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: backgrounded, object: app)], timeout: 5), .completed)
        app.activate()
        XCTAssertTrue(app.buttons["sports.retry"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        app.buttons["sports.retry"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Video playing"].waitForExistence(timeout: 30))
        app.buttons["sports.close"].tap()
        XCTAssertTrue(app.buttons["sports.event.test-event"].waitForExistence(timeout: 10))
    }

    func testForegroundAudioInterruptionKeepsRemotePlayer() async throws {
        app.buttons["sports.event.test-event"].tap()
        let hd = app.buttons["sports.stream.fixture.1"]
        XCTAssertTrue(hd.waitForExistence(timeout: 10)); hd.tap()
        XCTAssertTrue(app.webViews.staticTexts["Video playing"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Starting stream…"].waitForNonExistence(timeout: 10))
        // The fixture-only launch flag injects a began audio interruption two
        // seconds after observed playback, while UIKit remains foreground.
        try await Task.sleep(nanoseconds: 6_000_000_000)
        XCTAssertTrue(app.webViews.staticTexts["Video playing"].exists)
        XCTAssertFalse(app.buttons["sports.retry"].exists)
        app.buttons["sports.close"].tap()
    }

    private func status() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18881/test/status")!)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func waitForOrientation(landscape: Bool) {
        let predicate = NSPredicate { [app] _, _ in landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: 15), .completed)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
