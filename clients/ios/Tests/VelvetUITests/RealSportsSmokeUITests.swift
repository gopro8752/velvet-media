import XCTest

/// Optional manual smoke: run the fixture with --real-sports. Captures the
/// actual official embed; deterministic regressions use LiveSportsUITests.
@MainActor final class RealSportsSmokeUITests: XCTestCase {
    func testOfficialEmbedLoadsAndRespondsToPlay() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        let id: String
        let sportID: String
        if let existingID = environment["VELVET_SPORTS_EXISTING_EVENT_ID"], !existingID.isEmpty {
            // Physical-device smoke can use its existing backend and profile.
            // No temporary server, token, or profile is persisted on the device.
            id = existingID
            sportID = environment["VELVET_SPORTS_EXISTING_SPORT_ID"] ?? "basketball"
            app.launchArguments = ["-VelvetDeepLink", "velvet://tab/sports"]
        } else {
            let base = environment["VELVET_SPORTS_TEST_BASE"] ?? "http://127.0.0.1:18881"
            var request = URLRequest(url: URL(string: base + "/test/status")!)
            request.timeoutInterval = 2
            guard let (statusData, _) = try? await URLSession.shared.data(for: request),
                  let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
                  status["realSports"] as? Bool == true else { throw XCTSkip("Requires --real-sports fixture or an existing event ID.") }
            request.url = URL(string: base + "/sports/events?scope=live")!
            request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let events = try XCTUnwrap(catalog["events"] as? [[String: Any]])
            let event = try XCTUnwrap(events.first(where: { ($0["title"] as? String)?.contains("Cavaliers") == true }) ?? events.first)
            id = try XCTUnwrap(event["id"] as? String)
            sportID = event["sportId"] as? String ?? ""
            app.launchArguments = ["-VelvetDeepLink", "velvet://tab/sports", "-stream_sources", "", "-sync_url", base,
                                   "-sync_token", "fixture-only", "-sync_enabled", "NO", "-active_profile_id", "test-sports-real"]
        }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        if app.staticTexts["Who's watching?"].waitForExistence(timeout: 3), app.buttons["Close"].exists {
            app.buttons["Close"].tap()
        }
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let filter = app.buttons["sports.sportFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 30))
        if sportID == "basketball" {
            filter.tap()
            app.buttons["Basketball"].tap()
        }
        let eventButton = app.buttons["sports.event." + id]
        for _ in 0..<15 {
            if eventButton.exists && eventButton.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(eventButton.waitForExistence(timeout: 10))
        eventButton.tap()
        let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sports.stream.")).firstMatch
        XCTAssertTrue(stream.waitForExistence(timeout: 45)); stream.tap()
        XCTAssertTrue(app.buttons["sports.close"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Starting stream…"].waitForNonExistence(timeout: 55), "Decoded playback must start without manually pressing the provider's Play button.")
        capture(app, "StreamFree startup result")
        if app.buttons["sports.retry"].exists { print(app.debugDescription) }
        XCTAssertFalse(app.buttons["sports.retry"].exists, "Startup must not end at a retry error.")
        XCTAssertFalse(app.buttons["sports.manualPlay"].exists)
        capture(app, "StreamFree automatic playback")
        try await Task.sleep(nanoseconds: 15_000_000_000)
        XCTAssertFalse(app.buttons["sports.retry"].exists, "Blocked ads must not suspend playback as if the app left the foreground.")
        XCTAssertTrue(app.webViews.firstMatch.exists)
        capture(app, "StreamFree playback followup")
        app.buttons["sports.close"].tap()
        XCTAssertTrue(eventButton.waitForExistence(timeout: 15))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
