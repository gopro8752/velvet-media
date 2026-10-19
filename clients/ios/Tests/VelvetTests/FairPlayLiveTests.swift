import XCTest
import AVFoundation
@testable import Velvet

private final class PendingFairPlayProtocol: URLProtocol {
    static var started: XCTestExpectation?
    static var stopped: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?.fulfill() }
    override func stopLoading() { Self.stopped?.fulfill() }
}

@MainActor
final class FairPlayLiveTests: XCTestCase {
    private var connection: LiveConnection {
        LiveConnection(baseUrl: "https://fixture.invalid", syncUrl: "https://fixture.invalid", token: "fixture-only")!
    }
    private var configuration: LiveFairPlayConfiguration {
        LiveFairPlayConfiguration(response: LiveDRMResponse(scheme: "fairplay", licensePath: "/live/drm/fixture",
            certificatePath: "/live/cert/fixture", contentIdMode: "spectrum-content-id"), sessionID: "fixture", connection: connection)!
    }

    func testClosingTransportCancelsPendingLicense() async throws {
        let started = expectation(description: "license request started")
        let stopped = expectation(description: "pending request cancelled")
        PendingFairPlayProtocol.started = started
        PendingFairPlayProtocol.stopped = stopped
        defer {
            PendingFairPlayProtocol.started = nil
            PendingFairPlayProtocol.stopped = nil
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [PendingFairPlayProtocol.self]
        let transport = LiveFairPlayTransport(configuration: configuration, connection: connection,
                                              session: URLSession(configuration: settings))
        let request = Task { try await transport.license(spc: Data([1, 2, 3]), keyReference: "key1") }
        await fulfillment(of: [started], timeout: 3)
        transport.cancel()
        await fulfillment(of: [stopped], timeout: 3)
        do { _ = try await request.value; XCTFail("Cancelled license completed successfully") }
        catch is CancellationError {}
        catch { XCTFail("Cancellation became a playback failure") }
    }

    func testProtectedEngineTeardownDetachesItemAndCannotRestart() throws {
        let channel = LiveChannel(id: "fixture", name: "Fixture", number: nil, logoUrl: nil, group: nil)
        let session = LiveSession(id: "fixture", channel: channel,
            playbackURL: URL(string: "https://fixture.invalid/live/streams/fixture/index.m3u8")!,
            connection: connection, fairPlay: configuration)
        // The simulator does not implement FPS. A Clear Key session exercises
        // registration, detachment and expiration without a provider exchange.
        let engine = try FairPlayLiveEngine(session: session, configuration: configuration,
                                            keySession: AVContentKeySession(keySystem: .clearKey))
        var callbacks = 0
        engine.onFailure = { _ in callbacks += 1 }
        engine.onStateChanged = { _ in callbacks += 1 }
        engine.onTimeChanged = { callbacks += 1 }
        engine.teardown()
        engine.teardown()
        engine.play()
        XCTAssertNil(engine.player.currentItem)
        XCTAssertFalse(engine.isPlayingNow)
        XCTAssertTrue(engine.audioOptions.isEmpty)
        XCTAssertTrue(engine.subtitleOptions.isEmpty)
        XCTAssertEqual(callbacks, 0)
    }

    #if targetEnvironment(simulator)
    func testSimulatorDoesNotAdvertiseOrCreateFairPlay() {
        XCTAssertEqual(LiveTVClient.playbackCapabilities, "hls-clear")
        let channel = LiveChannel(id: "fixture", name: "Fixture", number: nil, logoUrl: nil, group: nil)
        let session = LiveSession(id: "fixture", channel: channel,
            playbackURL: URL(string: "https://fixture.invalid/live/streams/fixture/index.m3u8")!,
            connection: connection, fairPlay: configuration)
        XCTAssertThrowsError(try FairPlayLiveEngine(session: session, configuration: configuration))
    }
    #endif
}
