import Foundation

/// Small control requests only. The backend bounds/warms the actual ranges;
/// the phone never opens a second decoder or downloads an alternate movie.
enum StreamLookahead {
    struct Health: Decodable {
        let status: String
        let recovery: Recovery?
        let exactRecovery: ExactRecovery?
        var startup: SourceStartupReadiness? = nil
    }
    struct ExactRecovery: Decodable {
        let enabled: Bool
        let holdFallback: Bool
        let updatedAgoSeconds: Double?
        var holdsProactiveFallback: Bool {
            enabled && holdFallback && updatedAgoSeconds.map { $0.isFinite && $0 >= 0 && $0 <= 8 } == true
        }
    }
    struct Playback: Encodable {
        let sessionId: String
        let generation: Int
        let positionMs: Int64
        let durationMs: Int64
        // VLC does not expose a trustworthy media-time buffered position.
        let bufferedPositionMs: Int64 = 0
        let playing: Bool
        let stopped: Bool
    }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: LookaheadRedirectPolicy(), delegateQueue: nil)
    }()

    static func belongsToBackend(_ stream: URL, base: String) -> Bool {
        guard let backend = URL(string: base), streamId(stream) != nil else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return stream.scheme?.lowercased() == backend.scheme?.lowercased()
            && stream.host?.lowercased() == backend.host?.lowercased() && port(stream) == port(backend)
    }

    /// The session belongs only to our own media resource. Leave the selected
    /// source unchanged so handoff and source identity retain their original URL.
    static func attributedMediaURL(_ url: URL, backend: String, sessionId: String?) -> URL {
        guard let sessionId, UUID(uuidString: sessionId) != nil,
              let base = URL(string: backend), url.scheme == base.scheme, url.host == base.host,
              (url.port ?? (url.scheme == "https" ? 443 : 80)) == (base.port ?? (base.scheme == "https" ? 443 : 80)),
              url.path.range(of: #"/stream/[0-9a-f]{16}(?:/audio/[0-9]+\.wav)?$"#, options: .regularExpression) != nil,
              url.fragment == nil, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "playbackSessionId" }
        query.append(.init(name: "playbackSessionId", value: sessionId)); components.queryItems = query
        return components.url ?? url
    }

    static func playback(_ stream: StreamOption, value: Playback) async {
        guard let url = endpoint(stream, suffix: "playback") else { return }
        var request = request(url, stream: stream)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(value)
        _ = try? await session.data(for: request)
    }

    struct Recovery: Decodable {
        let status: String
        let streamId: String?
        let preparedFraction: Double?
    }

    static func streamId(_ url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[parts.count - 2] == "stream",
              let id = parts.last, !id.isEmpty, !id.contains(".") else { return nil }
        return id
    }

    static func isSibling(_ candidate: URL, of stream: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return streamId(candidate) != nil && streamId(stream) != nil
            && candidate.scheme?.lowercased() == stream.scheme?.lowercased()
            && candidate.host?.lowercased() == stream.host?.lowercased()
            && port(candidate) == port(stream)
            && candidate.deletingLastPathComponent().path == stream.deletingLastPathComponent().path
    }

    private static func endpoint(_ stream: StreamOption, suffix: String) -> URL? {
        guard streamId(stream.url) != nil,
              var url = URLComponents(url: stream.url, resolvingAgainstBaseURL: false) else { return nil }
        url.path += "/" + suffix
        return url.url
    }

    static func prepare(_ stream: StreamOption, fraction: Double) async {
        guard let url = endpoint(stream, suffix: "prepare") else { return }
        var request = request(url, stream: stream)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["fraction": min(max(fraction, 0), 1)])
        _ = try? await session.data(for: request)
    }

    static func health(_ stream: StreamOption, sessionId: String? = nil, timeout: TimeInterval = 5) async -> Health? {
        guard let endpoint = endpoint(stream, suffix: "health"),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        if let sessionId {
            var query = components.queryItems ?? []
            query.removeAll { $0.name == "sessionId" }
            query.append(URLQueryItem(name: "sessionId", value: sessionId)); components.queryItems = query
        }
        guard let url = components.url else { return nil }
        do {
            var healthRequest = request(url, stream: stream)
            healthRequest.timeoutInterval = timeout
            let (data, response) = try await session.data(for: healthRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(Health.self, from: data)
        } catch { return nil }
    }

    static func startupReadiness(_ streams: [StreamOption], backend: String, token: String, timeout: TimeInterval,
                                 session requestSession: URLSession? = nil) async
        -> (values: [String: SourceStartupReadiness]?, legacy: Bool) {
        guard let first = streams.first,
              streams.allSatisfy({ belongsToBackend($0.url, base: backend) }),
              var components = URLComponents(string: backend) else { return (nil, false) }
        let ids = streams.compactMap { streamId($0.url) }.filter {
            $0.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil
        }
        guard !ids.isEmpty else { return (nil, false) }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/streams/readiness"
        guard let url = components.url else { return (nil, false) }
        var bulkRequest = request(url, stream: first)
        bulkRequest.httpMethod = "POST"
        if !token.isEmpty { bulkRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        bulkRequest.timeoutInterval = timeout
        bulkRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        bulkRequest.httpBody = try? JSONEncoder().encode(["streamIds": Array(Set(ids)).sorted()])
        do {
            let (data, response) = try await (requestSession ?? session).data(for: bulkRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 || status == 405 { return (nil, true) }
            guard (200..<300).contains(status) else { return (nil, false) }
            struct Response: Decodable { let streams: [String: SourceStartupReadiness] }
            return (try JSONDecoder().decode(Response.self, from: data).streams, false)
        } catch { return (nil, false) }
    }

    private static func request(_ url: URL, stream: StreamOption) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

private final class LookaheadRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
