import XCTest

/// Optional manual smoke: run the fixture with --real-sports. Captures the
/// actual official embed; deterministic regressions use LiveSportsUITests.
@MainActor final class RealSportsSmokeUITests: XCTestCase {
    func testOfficialEmbedLoadsAndRespondsToPlay() async throws {
        continueAfterFailure = false
        let base = "http://127.0.0.1:18881"
        var request = URLRequest(url: URL(string: base + "/test/status")!)
        request.timeoutInterval = 2
        guard let (statusData, _) = try? await URLSession.shared.data(for: request),
              let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
              status["realSports"] as? Bool == true else { throw XCTSkip("Requires --real-sports fixture.") }
        request.url = URL(string: base + "/sports/events?scope=live")!
        request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(catalog["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first(where: { ($0["title"] as? String)?.contains("Denver") == true }) ?? events.first)
        let id = try XCTUnwrap(event["id"] as? String)
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-VelvetDeepLink", "velvet://tab/sports", "-stream_sources", "", "-sync_url", base,
                               "-sync_token", "fixture-only", "-sync_enabled", "NO", "-active_profile_id", "test-sports-real"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let eventButton = app.buttons["sports.event." + id]
        XCTAssertTrue(eventButton.waitForExistence(timeout: 30))
        eventButton.tap()
        let stream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sports.stream.")).firstMatch
        XCTAssertTrue(stream.waitForExistence(timeout: 45)); stream.tap()
        XCTAssertTrue(app.buttons["sports.close"].waitForExistence(timeout: 15))
        try await Task.sleep(nanoseconds: 8_000_000_000)
        capture(app, "Official embed before play")
        print("SPORTS_WEB_VIEWS=\(app.webViews.count)")
        print(app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56)).tap()
        try await Task.sleep(nanoseconds: 15_000_000_000)
        capture(app, "Official embed after play")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56)).tap()
        try await Task.sleep(nanoseconds: 15_000_000_000)
        capture(app, "Official embed playback followup")
        app.buttons["sports.close"].tap()
        XCTAssertTrue(eventButton.waitForExistence(timeout: 15))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
