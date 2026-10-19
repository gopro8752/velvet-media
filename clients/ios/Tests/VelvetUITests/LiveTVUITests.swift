import XCTest
import UIKit

/// Run scripts/live-tv-fixture.py on the Mac first. These tests never use the
/// household backend, Spectrum credentials, or the household's watch profile.
@MainActor
final class LiveTVUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        var fixtureRequest = URLRequest(url: URL(string: "http://127.0.0.1:18881/test/status")!)
        fixtureRequest.timeoutInterval = 2
        guard (try? await URLSession.shared.data(for: fixtureRequest)) != nil else {
            throw XCTSkip("Run scripts/live-tv-fixture.py for the local HLS integration tests.")
        }
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-VelvetDeepLink", "velvet://tab/live", "-stream_sources", "",
            "-sync_url", "http://127.0.0.1:18881", "-sync_token", "fixture-only",
            "-sync_enabled", "NO", "-active_profile_id", "test-live-tv",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["live.channel.sports-1"].waitForExistence(timeout: 20), "Start the local fixture before running these tests.")
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testLiveBrowseGuidePlaybackChannelChangeAndDismiss() async throws {
        let sports = app.buttons["live.channel.sports-1"]
        let news = app.buttons["live.channel.news-1"]
        XCTAssertTrue(sports.isHittable)
        XCTAssertTrue(news.exists)
        XCTAssertFalse(app.segmentedControls["live.channelFilter"].exists, "Spectrum must show every channel; sports events have their own tab.")
        let schedule = app.buttons["live.schedule.sports-1"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 10))
        schedule.tap()
        XCTAssertTrue(app.staticTexts["Fixture Championship"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Highlights"].exists)
        app.buttons["Done"].tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(landscape: true)
            XCTAssertLessThan(sports.frame.width, app.frame.width * 0.75)
            XCUIDevice.shared.orientation = .portrait
            waitForOrientation(landscape: false)
        }
        capture("Live TV channels")
        sports.tap()
        if #available(iOS 26.2, *), UIDevice.current.userInterfaceIdiom == .pad {
            waitForOrientation(landscape: false)
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        waitForOrientation(landscape: true)
        // Rotating the modern iPad window can outlast the player's control
        // auto-hide delay; reveal controls before inspecting loaded tracks.
        revealControls()
        let audio = app.buttons["Audio tracks"]
        XCTAssertTrue(audio.waitForExistence(timeout: 45), "The generated HLS fixture must open its audio/video tracks.")
        XCTAssertTrue(app.sliders.allElementsBoundByIndex.isEmpty, "Live channels must not expose a VOD seek slider.")
        capture("Live TV HLS playback")
        revealControls()
        app.buttons["live.chooseChannel"].tap()
        let change = app.buttons["Watch Test News live"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        change.tap()
        XCTAssertTrue(audio.waitForExistence(timeout: 45))
        if #available(iOS 26.2, *), UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .portrait
            waitForOrientation(landscape: false)
        }
        revealControls()
        app.buttons["live.close"].tap()
        XCTAssertTrue(news.waitForExistence(timeout: 15))
        waitForOrientation(landscape: false)
        try await expectNoActiveSessions()
    }

    func testClosingWhileTuneIsPendingReleasesLateSession() async throws {
        app.buttons["live.channel.slow-1"].tap()
        let close = app.buttons["live.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.buttons["live.channel.slow-1"].waitForExistence(timeout: 15))
        try await Task.sleep(nanoseconds: 4_000_000_000)
        try await expectNoActiveSessions()
        XCTAssertFalse(app.buttons["live.close"].exists, "A late tune must not reopen the player.")
    }

    private func expectNoActiveSessions() async throws {
        for _ in 0..<15 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18881/test/status")!)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if (object["activeSessions"] as? Int) == 0 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTFail("Closing Live TV must release its server viewer, including late tune responses.")
    }

    private func revealControls() {
        let toggle = app.buttons["live.toggleControls"]
        if toggle.exists {
            // Refresh the interaction timer even if controls are visible at
            // this exact instant but about to hide during the next query.
            if toggle.label == "Hide live TV controls" { toggle.tap() }
            app.buttons["Show live TV controls"].tap()
        }
        XCTAssertTrue(app.buttons["live.close"].waitForExistence(timeout: 5))
    }

    private func waitForOrientation(landscape: Bool) {
        let predicate = NSPredicate { [app] _, _ in landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: 15), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
