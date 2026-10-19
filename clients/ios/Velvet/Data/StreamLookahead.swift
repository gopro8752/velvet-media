import Foundation

/// Small control requests only. The backend bounds/warms the actual ranges;
/// the phone never opens a second decoder or downloads an alternate movie.
enum StreamLookahead {
    struct Health: Decodable {
        let status: String
        let recovery: Recovery?
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
        _ = try? await URLSession.shared.data(for: request)
    }

    static func health(_ stream: StreamOption) async -> Health? {
        guard let url = endpoint(stream, suffix: "health") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url, stream: stream))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(Health.self, from: data)
        } catch { return nil }
    }

    private static func request(_ url: URL, stream: StreamOption) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
