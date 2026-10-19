import Foundation

/// Only the backend knows its TMDB credential. A personal key is supported for
/// standalone discovery, and is never sent to a configured Velvet backend.
struct TmdbConnection: Sendable {
    let backendURL: String
    let syncURL: String
    let token: String
    let standaloneKey: String

    func request(path: String, params: [(String, String)]) throws -> URLRequest {
        // Callers supply a v3-relative resource, never a URL or query string.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !path.isEmpty, path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { throw URLError(.badURL) }

        let backend = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let usingBackend = !backend.isEmpty
        let base = usingBackend ? backend : "https://api.themoviedb.org/3"
        guard var components = URLComponents(string: base),
              let baseURL = components.url,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw URLError(.badURL)
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += usingBackend ? "/metadata/tmdb/\(path)" : "/\(path)"
        // An old caller cannot accidentally forward its own key to the server.
        var query = params.filter { !["api_key", "access_token"].contains($0.0.lowercased()) }
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        if !query.contains(where: { $0.name == "language" }) {
            query.insert(URLQueryItem(name: "language", value: "en-US"), at: 0)
        }
        if !usingBackend {
            let key = standaloneKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw URLError(.userAuthenticationRequired) }
            query.insert(URLQueryItem(name: "api_key", value: key), at: 0)
        }
        components.queryItems = query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if usingBackend, !bearer.isEmpty,
           let sync = URL(string: syncURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           Self.sameOrigin(baseURL, sync) {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
            && lhs.user == nil && lhs.password == nil
            && rhs.user == nil && rhs.password == nil
    }
}

/// Metadata redirects must not move backend bearer credentials to another host
/// or silently bypass the backend by redirecting a connected client to TMDB.
final class TmdbRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static func redirectedRequest(original: URLRequest, proposed: URLRequest) -> URLRequest? {
        guard let originalURL = original.url, let proposedURL = proposed.url,
              TmdbConnection.sameOrigin(originalURL, proposedURL) else { return nil }
        var safe = proposed
        safe.setValue(original.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        return safe
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest else { completionHandler(nil); return }
        completionHandler(Self.redirectedRequest(original: original, proposed: request))
    }
}
