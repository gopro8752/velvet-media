import CryptoKit
import Foundation

/// Exact movie identities match Android. Credentials are never persisted.
/// Velvet's content ID survives URL/token refreshes and the mobile audio adapter.
enum MovieReleaseBlocks {
    private static let credentials: Set<String> = [
        "token", "access_token", "auth", "authorization", "signature", "sig", "expires",
        "policy", "key-pair-id", "playbacksessionid",
    ]
    private static let releasePath = try! NSRegularExpression(pattern: #"(?:^|/)stream/([0-9a-f]{16})(?:/audio/[0-9]+\.wav)?$"#)

    static func key(for url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme), parts.host != nil else { return nil }
        let path = parts.percentEncodedPath
        if let match = releasePath.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           let range = Range(match.range(at: 1), in: path) {
            return "velvet:" + path[range]
        }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        if let query = parts.queryItems {
            let retained = query.filter { !credentials.contains($0.name.lowercased()) }
            parts.queryItems = retained.isEmpty ? nil : retained
        }
        guard let canonical = parts.url?.absoluteString else { return nil }
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "url:" + digest
    }
}

@MainActor
final class MovieReleaseBlockStore {
    private let defaults: UserDefaults
    private let storageKey = "blocked_movie_releases_v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func keys(movie: String) -> Set<String> {
        Set((defaults.dictionary(forKey: storageKey) as? [String: [String]])?[movie] ?? [])
    }
    func block(movie: String, url: URL) -> Bool {
        guard !movie.isEmpty, let key = MovieReleaseBlocks.key(for: url) else { return false }
        var map = defaults.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
        map[movie] = Array(keys(movie: movie).union([key])).sorted()
        defaults.set(map, forKey: storageKey)
        return true
    }
    func reset(movie: String) {
        var map = defaults.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
        map.removeValue(forKey: movie)
        defaults.set(map, forKey: storageKey)
    }
}
