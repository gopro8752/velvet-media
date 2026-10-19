import XCTest
import UIKit

/// Optional read-only production smoke. Start the local fixture with
/// --real-sports to opt in. This never tunes a Spectrum channel.
@MainActor
final class ProductionLiveBrowseUITests: XCTestCase {
    private let app = XCUIApplication()
    private var backendURL = ""
    override func setUp() async throws {
        guard let configured = ProcessInfo.processInfo.environment["VELVET_SMOKE_BACKEND_URL"],
              let url = URL(string: configured), ["http", "https"].contains(url.scheme ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            throw XCTSkip("Set VELVET_SMOKE_BACKEND_URL to your own test backend to opt in.")
        }
        backendURL = configured
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18881/test/status")!)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              status["realSports"] as? Bool == true else { throw XCTSkip("Optional production catalog smoke is not enabled.") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
    func testProductionSportsAndSpectrumGuideBrowseWithoutTuning() {
        launch(tab: "sports")
        let events = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sports.event."))
        XCTAssertTrue(events.firstMatch.waitForExistence(timeout: 40))
        capture("Production Live Sports portrait")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(app.segmentedControls["sports.scope"].waitForExistence(timeout: 10))
            capture("Production Live Sports landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        events.firstMatch.tap()
        let streams = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sports.stream."))
        XCTAssertTrue(streams.firstMatch.waitForExistence(timeout: 40))
        capture("Production stream choices")
        app.buttons["Done"].tap()
        app.terminate()
        launch(tab: "live")
        let schedules = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "live.schedule."))
        XCTAssertTrue(schedules.firstMatch.waitForExistence(timeout: 40))
        XCTAssertFalse(app.buttons["live.sportsFilter"].exists)
        capture("Production Spectrum Now and Next portrait")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            capture("Production Spectrum Now and Next landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        schedules.firstMatch.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        capture("Production program schedule")
        app.buttons["Done"].tap()
    }
    private func launch(tab: String) {
        app.launchArguments = ["-VelvetDeepLink", "velvet://tab/\(tab)", "-stream_sources", "",
                               "-sync_url", backendURL, "-sync_token", "", "-sync_enabled", "NO",
                               "-active_profile_id", "test-production-live", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
