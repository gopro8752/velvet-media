import Foundation

final class LiveMockProtocol: URLProtocol {
    static var handler: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct VerifyLiveTV {
    @MainActor
    static func main() async throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        let channel = #"{"id":"sports-1","name":"Test Sports","number":"101","logoUrl":null,"group":"Sports"}"#
        let ordinary = #"{"id":"news-1","name":"Sports Headlines","number":null,"logoUrl":null,"group":"News"}"#
        let catalogData = Data("{\"enabled\":true,\"sourceName\":\"Test\",\"channels\":[\(channel),\(channel),\(ordinary)],\"message\":null}".utf8)
        let decoded = try JSONDecoder().decode(LiveChannelCatalog.self, from: catalogData)
        expect(decoded.uniqueChannels.count == 2, "Catalog dedupe must preserve different provider channels")
        expect(decoded.uniqueChannels[0].isSports && !decoded.uniqueChannels[1].isSports,
               "Sports filter must use actual group tags, never infer from channel names")

        let original = LiveConnection(baseUrl: "https://Velvet.example/prefix", syncUrl: "https://velvet.example:443", token: " private ")!
        expect(original.token == "private", "Same-origin token lost")
        expect(original.endpoint("live/channels").absoluteString == "https://Velvet.example/prefix/live/channels", "API prefix lost")
        expect(original.playbackURL("/live/streams/cap/index.m3u8")?.absoluteString == "https://Velvet.example/live/streams/cap/index.m3u8", "Playback must resolve root-relative capability paths")
        for bad in ["https://other.example/live/streams/cap", "//other.example/live/streams/cap", "/live/streams/../../admin", "/live/streams/%2e%2e/admin", "/live/streams/cap\\index", "/not-live/file"] {
            expect(original.playbackURL(bad) == nil, "Unsafe playback path accepted: \(bad)")
        }
        expect(LiveConnection(baseUrl: "https://other.example", syncUrl: "https://velvet.example", token: "private")?.token == "", "Cross-origin credential leak")
        expect(LiveConnection(baseUrl: "http://velvet.example", syncUrl: "https://velvet.example", token: "private")?.token == "", "Credential leaked to downgraded transport")
        expect(LiveConnection(baseUrl: "https://name:password@velvet.example", syncUrl: "", token: "") == nil, "Embedded credentials accepted")

        var gate = LivePlaybackLifecycle()
        let first = gate.start()!
        let retry1 = gate.reconnect(after: first)!
        expect(!gate.accepts(first) && gate.accepts(retry1), "Old callbacks survived reconnect")
        let retry2 = gate.reconnect(after: retry1)!
        expect(gate.reconnect(after: retry2) == nil, "Automatic reconnect is unbounded")
        expect(gate.retryCount == 2, "Retry count should remain bounded until explicit user action")
        gate.suspend()
        expect(!gate.accepts(retry2), "Background playback callback accepted")
        let resumed = gate.start()!
        expect(gate.accepts(resumed), "Explicit Watch live should restart suspended channel")
        let replacement = gate.start()!
        expect(!gate.accepts(resumed) && gate.accepts(replacement), "Old channel response accepted after channel switch")
        gate.close()
        expect(!gate.accepts(replacement) && gate.start() == nil, "Closed player restarted from late response")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LiveMockProtocol.self]
        var connection = original
        let client = LiveTVClient(configuration: { connection }, session: URLSession(configuration: config))
        var requests: [URLRequest] = []
        let tuneData = Data("{\"sessionId\":\"lease-1\",\"playbackPath\":\"/live/streams/lease-1/index.m3u8\",\"mimeType\":\"application/vnd.apple.mpegurl\",\"channel\":\(channel),\"canPause\":false,\"canSeek\":false}".utf8)
        LiveMockProtocol.handler = { request in
            requests.append(request)
            switch request.httpMethod {
            case "POST": return (200, tuneData)
            case "DELETE": return (204, Data())
            default: return (200, catalogData)
            }
        }
        let channels = try await client.channels()
        expect(channels.enabled, "Live catalog did not decode")
        let lease = try await client.tune(channelID: "sports-1")
        expect(lease.channel.id == "sports-1", "Tune selected wrong channel")
        connection = LiveConnection(baseUrl: "https://changed.example", syncUrl: "https://changed.example", token: "new")!
        await client.release(lease)
        expect(requests.last?.url?.host == "Velvet.example", "Cleanup used changed Settings instead of lease owner")
        expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer private", "Cleanup used wrong server credential")
        expect(requests.last?.httpMethod == "DELETE", "Dismissal did not release session")

        requests = []
        LiveMockProtocol.handler = { request in
            requests.append(request)
            return request.httpMethod == "DELETE" ? (204, Data()) : (200, tuneData)
        }
        do { _ = try await client.tune(channelID: "wrong-channel"); preconditionFailure("Mismatched channel accepted") }
        catch LiveTVError.invalidResponse {}
        expect(requests.last?.httpMethod == "DELETE", "Invalid tune response leaked allocated session")
        LiveMockProtocol.handler = { _ in (401, Data(#"{"error":"Sign in to your provider."}"#.utf8)) }
        do { _ = try await client.channels(); preconditionFailure("Unauthorized catalog accepted") }
        catch let error as LiveTVError {
            expect(error.localizedDescription == "Sign in to your provider.", "Server guidance was lost")
            expect(!error.canRetryAutomatically, "Authentication failure should not auto-loop")
        }
        print("Live TV checks passed: catalog, actual sports tags, safe URL/auth, session ownership/cleanup, and bounded stale-safe lifecycle.")
    }
}
