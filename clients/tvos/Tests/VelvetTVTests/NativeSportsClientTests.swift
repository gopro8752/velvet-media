import XCTest
@testable import Velvet

@MainActor
final class NativeSportsClientTests: XCTestCase {
    func testTuneUsesCatalogIdentifiersAndBackendLease() async throws {
        let release = SportsReleaseSpy()
        let client = makeClient(release: release)
        SportsTuneProtocol.response = successfulResponse()
        let result = try await client.tune(channelID: "event-one")
        XCTAssertEqual(result.id, "lease-one")
        XCTAssertEqual(result.playbackURL.absoluteString, "https://backend.example.com/live/streams/lease-one/index.m3u8")
        let request = try XCTUnwrap(SportsTuneProtocol.request)
        XCTAssertEqual(request.url?.path, "/sports/tune")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Velvet-Client"), "tvos")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let data = try XCTUnwrap(SportsTuneProtocol.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["eventId"] as? String, "event-one")
        XCTAssertEqual(body["streamId"] as? String, "stream-one")
        XCTAssertEqual(body["source"] as? String, "streamfree")
        XCTAssertEqual(body["streamNo"] as? Int, 1)
        XCTAssertNil(body["embedUrl"])
        await client.release(result)
        XCTAssertEqual(release.released, ["lease-one"])
    }

    func testRejectsForeignPlaybackAndReleasesAllocatedLease() async throws {
        let release = SportsReleaseSpy()
        let client = makeClient(release: release)
        SportsTuneProtocol.response = successfulResponse(path: "https://elsewhere.example/stream.m3u8")
        do {
            _ = try await client.tune(channelID: "event-one")
            XCTFail("Accepted provider URL")
        } catch { }
        XCTAssertEqual(release.released, ["lease-one"])
    }

    func testRejectsMismatchedEventAndReleasesAllocatedLease() async throws {
        let release = SportsReleaseSpy()
        let client = makeClient(release: release)
        SportsTuneProtocol.response = successfulResponse(channelID: "other-event")
        do {
            _ = try await client.tune(channelID: "event-one")
            XCTFail("Accepted another event")
        } catch { }
        XCTAssertEqual(release.released, ["lease-one"])
    }

    func testBackendBridgeFailureIsVisible() async throws {
        let client = makeClient(release: SportsReleaseSpy())
        SportsTuneProtocol.status = 503
        SportsTuneProtocol.response = Data(#"{"error":"Native sports browser is not configured"}"#.utf8)
        do {
            _ = try await client.tune(channelID: "event-one")
            XCTFail("Accepted unavailable bridge")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Native sports browser is not configured")
        }
    }

    private func makeClient(release: SportsReleaseSpy) -> TVNativeSportsClient {
        SportsTuneProtocol.status = 200
        SportsTuneProtocol.request = nil
        SportsTuneProtocol.body = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SportsTuneProtocol.self]
        let event = SportsEvent(id: "event-one", title: "Away at Home", sportId: "basketball", sportName: "Basketball", startTime: .now, isLive: true, popular: true, posterUrl: nil, homeTeam: nil, awayTeam: nil, sourceCount: 1)
        let stream = SportsStream(id: "stream-one", source: "streamfree", streamNo: 1, language: "English", hd: true, embedUrl: URL(string: "https://strmfree.st/embed/basketball/event1080p")!)
        return TVNativeSportsClient(event: event, stream: stream,
                                    connection: LiveConnection(baseUrl: "https://backend.example.com", syncUrl: "https://backend.example.com", token: "fixture-token")!,
                                    releaseClient: release, session: URLSession(configuration: config))
    }

    private func successfulResponse(path: String = "/live/streams/lease-one/index.m3u8", channelID: String = "event-one") -> Data {
        try! JSONSerialization.data(withJSONObject: ["sessionId": "lease-one", "playbackPath": path,
            "mimeType": "application/vnd.apple.mpegurl", "channel": ["id": channelID, "name": "Away at Home", "group": "Live Sports"],
            "canPause": false, "canSeek": false])
    }
}

@MainActor
private final class SportsReleaseSpy: LiveTVServing {
    var released: [String] = []
    func channels() async throws -> LiveChannelCatalog { throw LiveTVError.invalidResponse }
    func guide() async throws -> LiveGuide { throw LiveTVError.invalidResponse }
    func tune(channelID: String) async throws -> LiveSession { throw LiveTVError.invalidResponse }
    func release(_ session: LiveSession) async { released.append(session.id) }
}

private final class SportsTuneProtocol: URLProtocol {
    static var status = 200
    static var response = Data()
    static var request: URLRequest?
    static var body: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        if let body = request.httpBody { Self.body = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.body = data
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
