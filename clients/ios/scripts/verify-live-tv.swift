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
        expect(lease.fairPlay == nil, "Legacy clear-HLS tune must stay on the clear path")
        expect(requests.last?.value(forHTTPHeaderField: "X-Velvet-Client") == "ios", "Tune did not identify the native client")
        expect(requests.last?.value(forHTTPHeaderField: "X-Velvet-Playback-Capabilities") == "hls-clear,hls-fairplay", "Tune did not advertise native FairPlay")
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

        connection = original
        let drm: [String: String] = ["scheme": "fairplay", "licensePath": "/live/drm/lease-1",
                                    "certificatePath": "/live/cert/lease-1", "contentIdMode": "spectrum-content-id"]
        var protected = try JSONSerialization.jsonObject(with: tuneData) as! [String: Any]
        protected["drm"] = drm
        var protectedData = try JSONSerialization.data(withJSONObject: protected)
        LiveMockProtocol.handler = { request in
            requests.append(request)
            return request.httpMethod == "DELETE" ? (204, Data()) : (200, protectedData)
        }
        let protectedLease = try await client.tune(channelID: "sports-1")
        let fairPlay = protectedLease.fairPlay!
        expect(fairPlay.certificateURL.absoluteString == "https://Velvet.example/live/cert/lease-1", "FairPlay certificate endpoint is wrong")
        expect(fairPlay.licenseURL.absoluteString == "https://Velvet.example/live/drm/lease-1", "FairPlay license endpoint is wrong")
        for (field, bad) in [
            ("scheme", "widevine"), ("contentIdMode", "unknown"),
            ("licensePath", "https://other.example/live/drm/lease-1"),
            ("licensePath", "/live/drm/other-lease"), ("certificatePath", "/live/cert/other-lease"),
            ("licensePath", "/live/drm/lease-1?url=private"), ("licensePath", "/live/drm/lease-1#fragment"),
            ("licensePath", "/live/drm/%2e%2e/admin"), ("certificatePath", "//other.example/live/cert/lease-1")
        ] {
            var invalid = drm
            invalid[field] = bad
            protected["drm"] = invalid
            protectedData = try JSONSerialization.data(withJSONObject: protected)
            requests = []
            do { _ = try await client.tune(channelID: "sports-1"); preconditionFailure("Invalid FairPlay descriptor accepted: \(field)") }
            catch LiveTVError.invalidResponse {}
            expect(requests.last?.httpMethod == "DELETE", "Rejected DRM descriptor leaked its viewer lease")
        }
        protected["drm"] = ["scheme": "fairplay"]
        protectedData = try JSONSerialization.data(withJSONObject: protected)
        requests = []
        do { _ = try await client.tune(channelID: "sports-1"); preconditionFailure("Incomplete DRM descriptor accepted") }
        catch LiveTVError.invalidResponse {}
        expect(requests.last?.httpMethod == "DELETE", "Undecodable DRM descriptor leaked its viewer lease")

        let encodedKey = LiveFairPlayKey(identifier: "skd://velvet/key-123?ContentId=abc%2Fdef%3D")!
        expect(encodedKey.reference == "key-123", "Key reference changed")
        expect(encodedKey.contentIdentifier == Data("abc%2Fdef%3D".utf8), "ContentId was percent-decoded")
        expect(LiveFairPlayKey(identifier: "skd://velvet/k?contentid=A")?.contentIdentifier == Data("  A".utf8), "Short ID padding differs from Spectrum")
        for invalid in ["skd://other/k?ContentId=ab", "https://velvet/k?ContentId=ab", "skd://velvet/../k?ContentId=ab",
                        "skd://velvet/%2e%2e?ContentId=ab", "skd://velvet/k?ContentId=", "skd://velvet/k?Other=ab",
                        "skd://velvet/k?ContentId=ab&ContentId=cd", "skd://velvet/k?ContentId=ab#fragment",
                        "skd://velvet/k?ContentId=" + String(repeating: "x", count: 201)] {
            expect(LiveFairPlayKey(identifier: invalid) == nil, "Malformed FairPlay key identifier accepted")
        }

        let transport = LiveFairPlayTransport(configuration: fairPlay, connection: original,
                                              session: URLSession(configuration: config))
        let certificate = Data([0x30, 0x03, 0x01, 0x02, 0x03])
        let spc = Data([0, 255, 1, 128, 2, 3])
        let ckc = Data([255, 0, 128, 4, 5])
        LiveMockProtocol.handler = { request in
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer private", "License exchange lost its owning backend credential")
            if request.httpMethod == "GET" {
                expect(request.url == fairPlay.certificateURL, "Certificate requested from wrong endpoint")
                return (200, certificate)
            }
            expect(request.url?.path == "/live/drm/lease-1" && request.url?.query == "key=key-123", "License proxy did not receive only its key reference")
            expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream", "SPC content type is wrong")
            var sent = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 128)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    sent.append(contentsOf: buffer.prefix(count))
                }
            }
            expect(sent == spc, "Opaque SPC was encoded or modified")
            return (200, ckc)
        }
        let fetchedCertificate = try await transport.certificate()
        expect(fetchedCertificate == certificate, "DER certificate bytes changed")
        let fetchedLicense = try await transport.license(spc: spc, keyReference: encodedKey.reference)
        expect(fetchedLicense == ckc, "Opaque binary CKC was decoded or modified")
        LiveMockProtocol.handler = { _ in (403, Data("private upstream credentials".utf8)) }
        do { _ = try await transport.license(spc: spc, keyReference: "key-123"); preconditionFailure("Denied license accepted") }
        catch let error as LiveTVError {
            expect(!error.localizedDescription.contains("private upstream"), "License error leaked upstream details")
            expect(!error.canRetryAutomatically, "License denial should not loop")
        }
        transport.cancel()
        print("Live TV checks passed: legacy HLS, native FairPlay contract/raw exchange, private endpoint validation, lease cleanup, and bounded stale-safe lifecycle.")
    }
}
