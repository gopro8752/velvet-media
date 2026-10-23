import XCTest
@testable import Velvet

final class ExactRecoveryTests: XCTestCase {
    @MainActor
    func testVerifiedSourceWinsOverUnknownQualityAndStickyGroup() {
        let name = "velvet-startup-selection-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let client = StreamClient(settings: SettingsStore(defaults: defaults))
        func stream(_ id: String, _ quality: String, _ status: String?) -> StreamOption {
            StreamOption(url: URL(string: "https://example.test/stream/" + id)!, title: "Example." + quality,
                         quality: quality, sizeBytes: nil, sourceName: "Fixture", bingeGroup: id, headers: [:],
                         startupReadiness: status.map { .init(status: $0, retryAfterSeconds: nil) })
        }
        let unknown = stream("unknown", "2160p", nil)
        let lower = stream("lower", "720p", "ready")
        let best = stream("best", "1080p", "ready")
        let missing = stream("missing", "2160p", "unavailable")
        XCTAssertEqual(client.sortStreams([unknown, lower, missing, best], preferredQuality: "2160p").map(\.bingeGroup),
                       ["best", "lower", "unknown", "missing"])
        XCTAssertEqual(client.autoPick([unknown, lower, missing, best], preferredQuality: "2160p", previousBingeGroup: "unknown")?.url, best.url)
        XCTAssertNil(client.autoPick([missing], preferredQuality: "2160p", previousBingeGroup: "missing"))
        XCTAssertEqual(client.autoPick([best, lower], preferredQuality: "2160p", previousBingeGroup: "lower")?.url, best.url,
                       "Release continuity cannot lower the best verified resolution.")
    }

    func testStartupCanTraverseAllCandidatesWithoutSpendingMidplayBudget() {
        for remaining in (1...80).reversed() {
            XCTAssertTrue(StreamStartupSelection.canAdvance(established: false, attempts: 4, remaining: remaining))
        }
        XCTAssertFalse(StreamStartupSelection.canAdvance(established: false, attempts: 0, remaining: 0))
        XCTAssertFalse(StreamStartupSelection.canAdvance(established: true, attempts: 4, remaining: 80))
        XCTAssertTrue(StreamStartupSelection.canAdvance(established: true, attempts: 3, remaining: 80))
    }

    func testStartupReadinessDecodesHintsAndLegacyHealth() throws {
        let data = Data(#"{"status":"healthy","startup":{"status":"ready","retryAfterSeconds":null}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StreamLookahead.Health.self, from: data).startup?.status, "ready")
        let legacy = Data(#"{"status":"healthy"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(StreamLookahead.Health.self, from: legacy).startup)
        let hint = Data(#"{"velvetSourceReadiness":{"status":"unavailable","retryAfterSeconds":30}}"#.utf8)
        let decoded = try JSONDecoder().decode(StremioBehaviorHintsDto.self, from: hint)
        XCTAssertEqual(decoded.velvetSourceReadiness?.rank, 2)
        XCTAssertEqual(decoded.velvetSourceReadiness?.retryAfterSeconds, 30)
    }

    func testBulkReadinessUsesBackendBearerWithoutCopyingMediaQuery() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StartupReadinessProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let stream = StreamOption(url: URL(string: "https://example.test/stream/0123456789abcdef?media-secret=fixture")!,
                                  title: "Fixture", quality: nil, sizeBytes: nil, sourceName: "Fixture", bingeGroup: nil, headers: [:])
        let result = await StreamLookahead.startupReadiness([stream, stream], backend: "https://example.test/", token: "fixture",
                                                          timeout: 1, session: session)
        XCTAssertEqual(result.values?["0123456789abcdef"]?.status, "ready")
        XCTAssertFalse(result.legacy)
        let request = try XCTUnwrap(StartupReadinessProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/streams/readiness")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(StartupReadinessProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        XCTAssertEqual(json["streamIds"], ["0123456789abcdef"], "Repeated releases must not violate the unique-ID contract.")
        StartupReadinessProtocol.lastRequest = nil
        let outside = await StreamLookahead.startupReadiness([stream], backend: "https://other.example", token: "fixture",
                                                           timeout: 1, session: session)
        XCTAssertNil(outside.values)
        XCTAssertNil(StartupReadinessProtocol.lastRequest, "Backend credentials cannot follow a source to another origin.")
    }

    @MainActor
    func testRefreshDiscardsStaleHintsOnAuthenticationFailureAndPartialResponse() async {
        let name = "velvet-startup-refresh-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); StartupReadinessProtocol.statusCode = 200 }
        let settings = SettingsStore(defaults: defaults)
        settings.syncUrl = "https://example.test"
        settings.syncToken = "fixture"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StartupReadinessProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = StreamClient(settings: settings, startupSession: session)
        let expired = StreamOption(url: URL(string: "https://example.test/stream/0123456789abcdef")!, title: "Fixture",
                                   quality: nil, sizeBytes: nil, sourceName: "Fixture", bingeGroup: nil, headers: [:],
                                   startupReadiness: .init(status: "unavailable", retryAfterSeconds: 30))
        let stale = StreamOption(url: URL(string: "https://example.test/stream/0123456789abcde0")!, title: "Fixture",
                                 quality: nil, sizeBytes: nil, sourceName: "Fixture", bingeGroup: nil, headers: [:],
                                 startupReadiness: .init(status: "ready", retryAfterSeconds: nil))
        StartupReadinessProtocol.statusCode = 401
        let failed = await client.refreshStartupReadiness([expired, stale], waitForReady: false)
        XCTAssertTrue(failed.allSatisfy { $0.startupReadiness == nil })
        StartupReadinessProtocol.statusCode = 200
        let refreshed = await client.refreshStartupReadiness([expired, stale], waitForReady: false)
        XCTAssertEqual(refreshed[0].startupReadiness?.status, "ready", "Cooldown entries can reenter automatic selection.")
        XCTAssertNil(refreshed[1].startupReadiness, "A missing SID cannot retain an old ready promise.")
    }
    func testRepairGraceRequiresFreshExplicitDecision() throws {
        func decision(_ enabled: Bool, _ hold: Bool, _ age: Double?) -> StreamLookahead.ExactRecovery {
            .init(enabled: enabled, holdFallback: hold, updatedAgoSeconds: age)
        }
        XCTAssertTrue(decision(true, true, 8).holdsProactiveFallback)
        XCTAssertFalse(decision(true, true, 8.01).holdsProactiveFallback)
        XCTAssertFalse(decision(true, true, nil).holdsProactiveFallback)
        XCTAssertFalse(decision(true, true, -.infinity).holdsProactiveFallback)
        XCTAssertFalse(decision(false, true, 0).holdsProactiveFallback)
        XCTAssertFalse(decision(true, false, 0).holdsProactiveFallback)
    }
    func testHeartbeatRemainsOnConfiguredBackendOrigin() {
        XCTAssertTrue(StreamLookahead.belongsToBackend(URL(string: "https://velvet.example/stream/abc")!, base: "https://velvet.example"))
        XCTAssertFalse(StreamLookahead.belongsToBackend(URL(string: "https://other.example/stream/abc")!, base: "https://velvet.example"))
        XCTAssertFalse(StreamLookahead.belongsToBackend(URL(string: "http://velvet.example/stream/abc")!, base: "https://velvet.example"))
    }
    func testMediaAttributionIsScopedAndPreservesOriginalQuery() {
        let session = "12345678-1234-1234-1234-123456789abc"
        let media = URL(string: "https://velvet.example/stream/0123456789abcdef?token=fixture")!
        let attributed = StreamLookahead.attributedMediaURL(media, backend: "https://velvet.example", sessionId: session)
        let query = URLComponents(url: attributed, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "playbackSessionId" }?.value, session)
        XCTAssertEqual(query.first { $0.name == "token" }?.value, "fixture")
        XCTAssertFalse(media.absoluteString.contains("playbackSessionId"))
        XCTAssertEqual(StreamLookahead.attributedMediaURL(media, backend: "https://other.example", sessionId: session), media)
        let probe = URL(string: "https://velvet.example/stream/0123456789abcdef/audio")!
        XCTAssertEqual(StreamLookahead.attributedMediaURL(probe, backend: "https://velvet.example", sessionId: session), probe)
        let wav = URL(string: "https://velvet.example/stream/0123456789abcdef/audio/0.wav")!
        XCTAssertTrue(StreamLookahead.attributedMediaURL(wav, backend: "https://velvet.example", sessionId: session).absoluteString.contains("playbackSessionId"))
    }
    func testRewindIgnoresPreSeekPlayingCallbacks() {
        let a = URL(string: "https://example.test/stream/a")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 120_000)
        metrics.sample(nowMs: 1000, state: "playing", source: a, positionMs: 120_500)
        metrics.seek(to: 60_000)
        metrics.sample(nowMs: 1100, state: "playing", source: a, positionMs: 120_600)
        metrics.didDispatchSeek()
        metrics.sample(nowMs: 1200, state: "playing", source: a, positionMs: 120_700)
        metrics.sample(nowMs: 1500, state: "buffering", source: a, positionMs: 120_700)
        XCTAssertEqual(metrics.rebufferCount, 0)
    }
    func testAttemptsOnlyBecomeSuccessfulOnReplacementPlayback() {
        let a = URL(string: "https://example.test/stream/a")!, b = URL(string: "https://example.test/stream/b")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 500)
        metrics.prepare(b, automatic: true)
        metrics.prepare(b, automatic: true)
        metrics.sample(nowMs: 1000, state: "playing", source: a, positionMs: 1000)
        XCTAssertEqual(metrics.automaticSwitchAttempts, 1)
        XCTAssertEqual(metrics.automaticSourceSwitches, 0)
        metrics.sample(nowMs: 1500, state: "playing", source: b, positionMs: 1500)
        metrics.sample(nowMs: 2000, state: "playing", source: b, positionMs: 2000)
        XCTAssertEqual(metrics.automaticSourceSwitches, 1)
    }
    func testFrozenPlayingStateCannotClaimSuccessfulReplacement() {
        let a = URL(string: "https://example.test/stream/a")!, b = URL(string: "https://example.test/stream/b")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 500)
        metrics.sample(nowMs: 1000, state: "playing", source: a, positionMs: 1000)
        metrics.prepare(b, automatic: false)
        for time in stride(from: Int64(1500), through: 5000, by: 500) {
            metrics.sample(nowMs: time, state: "playing", source: b, positionMs: 0)
        }
        XCTAssertEqual(metrics.manualSwitchAttempts, 1)
        XCTAssertEqual(metrics.manualSourceSwitches, 0)
        metrics.sample(nowMs: 5500, state: "playing", source: b, positionMs: 500)
        XCTAssertEqual(metrics.manualSourceSwitches, 1)
    }
    func testFailedSeekCannotHideBufferingIndefinitely() {
        let a = URL(string: "https://example.test/stream/a")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 500)
        metrics.sample(nowMs: 1000, state: "playing", source: a, positionMs: 1000)
        metrics.seek(to: 60_000); metrics.didDispatchSeek()
        for time in stride(from: Int64(1500), through: 15_500, by: 500) {
            metrics.sample(nowMs: time, state: "buffering", source: a, positionMs: 1000)
        }
        XCTAssertEqual(metrics.rebufferCount, 0)
        metrics.sample(nowMs: 16_000, state: "buffering", source: a, positionMs: 1000)
        XCTAssertEqual(metrics.rebufferCount, 1)
    }
    func testSeekBufferingExcludedFromNetworkStalls() {
        let a = URL(string: "https://example.test/stream/a")!
        var metrics = RecoveryPlaybackMetrics(nowMs: 0)
        metrics.prepare(a, automatic: true)
        metrics.sample(nowMs: 500, state: "playing", source: a, positionMs: 500)
        metrics.sample(nowMs: 750, state: "playing", source: a, positionMs: 750)
        metrics.seek(to: 60_000)
        metrics.didDispatchSeek()
        metrics.sample(nowMs: 1000, state: "buffering", source: a, positionMs: 500)
        XCTAssertEqual(metrics.rebufferCount, 0)
        metrics.sample(nowMs: 1500, state: "playing", source: a, positionMs: 60_000)
        metrics.sample(nowMs: 1750, state: "playing", source: a, positionMs: 60_250)
        metrics.sample(nowMs: 2000, state: "buffering", source: a, positionMs: 60_500)
        metrics.sample(nowMs: 3000, state: "playing", source: a, positionMs: 60_500)
        XCTAssertEqual(metrics.rebufferCount, 1)
        XCTAssertEqual(metrics.rebufferedMs, 1000)
        XCTAssertEqual(metrics.seekCount, 1)
    }
}

private final class StartupReadinessProtocol: URLProtocol {
    static var statusCode = 200
    static var lastRequest: URLRequest?
    static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody
        if let input = request.httpBodyStream {
            input.open()
            defer { input.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            Self.lastBody = data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"streams":{"0123456789abcdef":{"status":"ready"}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
