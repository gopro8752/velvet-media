import Foundation

/// Companion features living on the velvet-sync server beyond watch-state sync
/// (the iOS twin of the Android data/companion/CompanionApi.kt): skip-intro
/// segment markers (report what plays, read markers back) and throw-to-TV
/// handoffs. Reuses the sync URL + token already in Settings — when sync is
/// disabled (or the URL is blank), calls are inert. Intro failures stay silent;
/// handoffs use the separate acknowledged v2 client so failures are visible
/// without breaking local playback.
@MainActor
final class CompanionApi: HomeCategoryService {
    private let settings: SettingsStore
    private let handoffSession: URLSession

    init(settings: SettingsStore, handoffSession: URLSession = .shared) {
        self.settings = settings
        self.handoffSession = handoffSession
    }

    // MARK: wire DTOs (server.py camelCase JSON)

    private struct ReportPlayBody: Encodable {
        let imdbId: String
        let season: Int
        let episode: Int
        let url: String
    }

    private struct SegmentWire: Decodable {
        let startMs: Int64
        let endMs: Int64
    }

    private struct SegmentsResponse: Decodable {
        let episodes: [String: SegmentWire]
    }

    // MARK: config (same source of truth as SyncEngine)

    private struct Config {
        let baseUrl: String
        let token: String
    }

    private var config: Config? {
        guard settings.syncEnabled else { return nil }
        let url = SettingsStore.normalizeBaseUrl(settings.syncUrl)
        guard !url.isEmpty else { return nil }
        return Config(baseUrl: url,
                      token: settings.syncToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Home catalogs use the installed backend independently of watch sync.
    /// A token configured for another origin must never leak to a stream source.
    private var categoryConfig: Config? {
        let source = settings.streamSources.first { $0.enabled }?.baseUrl ?? settings.syncUrl
        let base = SettingsStore.normalizeBaseUrl(source)
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        let sync = URL(string: SettingsStore.normalizeBaseUrl(settings.syncUrl))
        func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        let sameOrigin = sync.map {
            $0.scheme?.lowercased() == scheme && $0.host?.lowercased() == url.host?.lowercased()
                && effectivePort($0) == effectivePort(url)
        } ?? false
        return Config(baseUrl: base, token: sameOrigin
                      ? settings.syncToken.trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }

    /// Sync is on and a base URL is set — gates the Throw to TV button.
    var isEnabled: Bool { config != nil }

    // MARK: calls

    /// Tell the fingerprint worker what URL this (or the upcoming) episode
    /// plays from. Fire-and-forget; failures are silent.
    func reportPlay(imdbId: String, season: Int, episode: Int, url: String) async {
        guard let cfg = config else { return }
        let body = ReportPlayBody(imdbId: imdbId, season: season, episode: episode, url: url)
        guard let encoded = try? JSONEncoder().encode(body) else { return }
        _ = await send(cfg, path: "/report_play", method: "POST", body: encoded)
    }

    /// Intro markers for a season: episode number -> startMs...endMs.
    /// Empty on any failure (including the old server's 404).
    func introSegments(imdbId: String, season: Int) async -> [Int: ClosedRange<Int64>] {
        guard let cfg = config else { return [:] }
        guard let data = await send(cfg, path: "/segments", query: "imdb=\(imdbId)&season=\(season)"),
              let decoded = try? JSONDecoder().decode(SegmentsResponse.self, from: data) else {
            return [:]
        }
        var result: [Int: ClosedRange<Int64>] = [:]
        for (key, seg) in decoded.episodes {
            guard let episode = Int(key), seg.endMs > seg.startMs else { continue }
            result[episode] = seg.startMs...seg.endMs
        }
        return result
    }

    /// Handoffs use their own acknowledged protocol, not asynchronous progress sync.
    func handoffClient() -> TVHandoffClient? {
        guard let cfg = config else { return nil }
        return TVHandoffClient(baseURL: cfg.baseUrl, token: cfg.token, session: handoffSession)
    }

    /// A failed catalog fetch keeps the last successful rail available offline.
    func halloweenCategory() async -> HomeCategory? {
        guard let cfg = categoryConfig,
              let data = await send(cfg, path: "/catalog/halloween", timeout: 45),
              let category = try? JSONDecoder().decode(HomeCategory.self, from: data) else { return nil }
        let validated = category.validated
        return validated.items.isEmpty ? nil : validated
    }

    enum CategoryError: LocalizedError {
        case unavailable, requestFailed, server(String), empty
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Connect your companion server in Settings to create categories."
            case .requestFailed: return "Couldn't create that category. Check your connection and try again."
            case .server(let message): return message
            case .empty: return "No matching titles or episodes were found. Try describing the category another way."
            }
        }
    }

    func generateCategory(prompt: String) async throws -> HomeCategory {
        guard let cfg = categoryConfig, let url = URL(string: cfg.baseUrl + "/categories/generate") else {
            throw CategoryError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.token.isEmpty { request.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(["prompt": prompt])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw CategoryError.requestFailed }
        guard let http = response as? HTTPURLResponse else { throw CategoryError.requestFailed }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw message.map(CategoryError.server) ?? CategoryError.requestFailed
        }
        guard let category = try? JSONDecoder().decode(HomeCategory.self, from: data) else {
            throw CategoryError.requestFailed
        }
        let validated = category.validated
        guard !validated.items.isEmpty else { throw CategoryError.empty }
        return validated
    }

    func categoryQueue(_ category: HomeCategory, shuffle: Bool) async throws -> HomeCategory {
        guard PersonalHalloweenCategory.canPlay(category, profile: settings.activeProfileId ?? ProfileStore.defaultId) else {
            throw CategoryError.unavailable
        }
        guard let cfg = categoryConfig, let url = URL(string: cfg.baseUrl + "/categories/queue") else {
            throw CategoryError.unavailable
        }
        let body = CategoryQueueRequest(category: category, shuffle: shuffle)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.token.isEmpty { request.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CategoryError.requestFailed }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw message.map(CategoryError.server) ?? CategoryError.requestFailed
        }
        let queue = try JSONDecoder().decode(HomeCategory.self, from: data).validated
        // A queue must be fully resolved; never turn an unresolved show into S1E1.
        guard !queue.items.isEmpty,
              queue.items.allSatisfy({ $0.type == .movie || ($0.season != nil && $0.episode != nil) }) else {
            throw CategoryError.empty
        }
        return queue
    }

    // MARK: HTTP (fail-silent counterpart of SyncEngine.makeRequest/send)

    /// One request. nil on ANY failure — bad URL, transport error, non-2xx.
    private func send(_ cfg: Config, path: String, query: String? = nil,
                      method: String = "GET", body: Data? = nil, timeout: TimeInterval = 10) async -> Data? {
        var urlString = cfg.baseUrl + path
        if let query { urlString += "?" + query }
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !cfg.token.isEmpty {
            request.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
