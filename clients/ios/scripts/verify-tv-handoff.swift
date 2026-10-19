import Foundation

final class HandoffURLProtocol: URLProtocol {
    static var replies: [(URLRequest) throws -> (Int, String)] = []
    static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url!.path)
        guard !Self.replies.isEmpty else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        do {
            let (code, body) = try Self.replies.removeFirst()(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct TVHandoffChecks {
    static func status(_ state: String, id: String = "request-1") -> String {
        "{\"protocolVersion\":2,\"id\":\"\(id)\",\"state\":\"\(state)\",\"targetName\":\"Living Room\",\"expiresAt\":9999999999999,\"error\":null}"
    }
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HandoffURLProtocol.self]
        let client = TVHandoffClient(baseURL: "https://fixture.invalid", token: "fixture", session: URLSession(configuration: configuration))
        let request = TVHandoffRequest(requestId: "request-1", targetDeviceId: "awake", targetSessionId: "session-a", profileId: "sender-profile", mediaId: 5371, type: "show", season: 6, episode: 3, positionMs: 8_731, title: "iCarly", sourceHint: .init(streamId: "0123456789abcdef", title: "release-cut", sourceName: "Configured source", bingeGroup: "group"))
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        precondition(body["positionMs"] as? Int == 8_731 && body["profileId"] as? String == "sender-profile")
        precondition(body["season"] as? Int == 6 && body["episode"] as? Int == 3)
        precondition(body["targetSessionId"] as? String == "session-a" && body["streamUrl"] == nil)
        print("PASS exact position, episode, profile, session and non-secret source hint")

        let base = "https://fixture.invalid"
        let exact = URL(string: base + "/stream/0123456789abcdef")!
        precondition(TVHandoffSource.streamId(url: exact, backendURL: base, headers: [:]) == "0123456789abcdef")
        for invalid in ["https://foreign.invalid/stream/0123456789abcdef", base + "/prefix/stream/0123456789abcdef", base + "/stream/0123456789abcdef?token=secret", base + "/stream/0123456789abcdef#x", base + "/stream/0123456789abcdef/", base + "/stream/0123456789abcdeF", "https://user:pass@fixture.invalid/stream/0123456789abcdef", base + "/stream/%30123456789abcdef"] {
            precondition(TVHandoffSource.streamId(url: URL(string: invalid)!, backendURL: base, headers: [:]) == nil)
        }
        precondition(TVHandoffSource.streamId(url: exact, backendURL: base, headers: ["Authorization":"private"]) == nil)
        precondition(TVHandoffSource.streamId(url: exact, backendURL: base + "/token", headers: [:]) == nil)
        precondition((body["sourceHint"] as? [String: Any])?["streamId"] as? String == "0123456789abcdef")
        print("PASS exact active backend stream reference, with foreign/credential/ambiguous sources rejected")

        // Production uses the public companion API while its resolver publishes
        // LAN media URLs. The authoritative API advertises that canonical base.
        let localBase = "http://192.0.2.10:8800"
        let localStream = URL(string: localBase + "/stream/0123456789abcdef")!
        precondition(TVHandoffSource.streamId(url: localStream, backendURL: base, headers: [:]) == nil)
        precondition(TVHandoffSource.streamId(url: localStream, backendURL: base,
            advertisedStreamBaseURL: localBase, headers: [:]) == "0123456789abcdef")
        precondition(TVHandoffSource.streamId(url: exact, backendURL: localBase,
            advertisedStreamBaseURL: base, headers: [:]) == "0123456789abcdef")
        precondition(TVHandoffSource.streamId(url: localStream, backendURL: base,
            advertisedStreamBaseURL: "http://192.0.2.10:8801", headers: [:]) == nil)
        precondition(TVHandoffSource.streamId(url: URL(string: "https://foreign.invalid/stream/0123456789abcdef")!,
            backendURL: base, advertisedStreamBaseURL: localBase, headers: [:]) == nil)
        print("PASS server-advertised public/LAN aliases preserve the exact ID without trusting unrelated origins")

        for invalidBase in [localBase + "?token=secret", localBase + "#x", localBase + "/token",
                            "http://user:pass@192.0.2.10:8800", "file://192.0.2.10:8800"] {
            precondition(TVHandoffSource.streamId(url: localStream, backendURL: base,
                advertisedStreamBaseURL: invalidBase, headers: [:]) == nil)
        }
        precondition(TVHandoffSource.streamId(url: localStream, backendURL: base,
            advertisedStreamBaseURL: localBase, headers: ["Authorization": "private"]) == nil)
        print("PASS advertised aliases cannot smuggle credential paths, query tokens or per-source headers")

        HandoffURLProtocol.replies = [{ _ in (200, #"{"protocolVersion":2,"serverNow":100,"streamBaseURL":"http://192.0.2.10:8800","receivers":[{"deviceId":"awake","sessionId":"a","name":"Living Room","profileId":"different-profile","expiresAt":200},{"deviceId":"awake","sessionId":"a","name":"Duplicate","profileId":"p","expiresAt":200},{"deviceId":"asleep","sessionId":"b","name":"Bedroom","profileId":"p","expiresAt":99}]}"#) }]
        let discovery = try await client.discover()
        let receivers = discovery.available
        precondition(discovery.streamBaseURL == localBase)
        precondition(receivers.count == 1 && receivers[0].name == "Living Room")
        print("PASS expired receivers excluded, duplicate sessions collapsed, cross-profile receivers retained")

        HandoffURLProtocol.paths = []
        HandoffURLProtocol.replies = [
            { req in precondition(req.value(forHTTPHeaderField: "Authorization") == "Bearer fixture"); return (200,status("pending")) },
            { _ in (200,status("claimed")) }, { _ in (200,status("started")) }
        ]
        let started = try await client.deliver(request, pollNanoseconds: 1)
        precondition(started?.state == .started && HandoffURLProtocol.paths == ["/handoff/v2","/handoff/v2/status","/handoff/v2/status"])
        print("PASS pending and claimed never count as playback success")

        HandoffURLProtocol.replies = [{ _ in (200,status("failed")) }]
        let result7 = try await client.deliver(request)
        precondition(result7?.state == .failed)
        print("PASS receiver failure remains failure")

        HandoffURLProtocol.paths = []
        HandoffURLProtocol.replies = [{ _ in (409, #"{"code":"source_unavailable"}"#) }, { _ in (200,status("cancelled")) }]
        let unavailable = try await client.deliver(request)
        precondition(unavailable?.state == .failed && unavailable?.error == TVHandoffError.sourceUnavailable.localizedDescription)
        precondition(HandoffURLProtocol.paths == ["/handoff/v2", "/handoff/v2/cancel"])
        print("PASS unavailable exact source fails visibly after confirmed cancellation without choosing another source")

        HandoffURLProtocol.paths = []
        HandoffURLProtocol.replies = [{ _ in throw URLError(.timedOut) }, { _ in (200,status("cancelled")) }]
        let result6 = try await client.deliver(request)
        precondition(result6?.state == .cancelled)
        precondition(HandoffURLProtocol.paths == ["/handoff/v2","/handoff/v2/cancel"])
        print("PASS ambiguous create cancels known request ID")

        HandoffURLProtocol.replies = [{ _ in throw URLError(.networkConnectionLost) }, { _ in (200,status("started")) }]
        let result5 = try await client.deliver(request)
        precondition(result5?.state == .started)
        print("PASS playback acknowledgement wins cancellation race")

        HandoffURLProtocol.paths = []
        HandoffURLProtocol.replies = [{ _ in (200,status("claimed")) }, { _ in (200,status("cancelled")) }]
        let result4 = try await client.deliver(request, timeout: 0)
        precondition(result4?.state == .cancelled)
        precondition(HandoffURLProtocol.paths.last == "/handoff/v2/cancel")
        print("PASS deadline cancels unresolved receiver startup")

        HandoffURLProtocol.replies = [{ _ in throw URLError(.timedOut) }, { _ in throw URLError(.notConnectedToInternet) }]
        let result3 = try await client.deliver(request)
        precondition(result3 == nil)
        print("PASS unreachable cancellation produces uncertain result, not false success/failure")

        HandoffURLProtocol.replies = [{ _ in (200,status("started",id:"stale-request")) }, { _ in (200,status("cancelled")) }]
        let result2 = try await client.deliver(request)
        precondition(result2?.state == .cancelled)
        print("PASS another attempt's acknowledgement is rejected")

        HandoffURLProtocol.replies = [{ _ in (200,status("pending")) }, { _ in throw URLError(.networkConnectionLost) }, { _ in (200,status("started")) }]
        let result1 = try await client.deliver(request, pollNanoseconds: 1)
        precondition(result1?.state == .started)
        print("PASS transient status failure retains the live attempt")

        HandoffURLProtocol.paths = []
        HandoffURLProtocol.replies = [{ _ in (404,"{}") }]
        do { _ = try await client.receivers(); preconditionFailure("old backend accepted") }
        catch TVHandoffError.unsupported { }
        precondition(HandoffURLProtocol.paths == ["/handoff/receivers"])
        print("PASS old servers fail visibly without legacy broadcast fallback")
        print("15 handoff contract checks passed")
    }
}
