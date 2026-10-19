import Foundation

/// Live channels have provider identities, independent of TMDB and watch history.
struct LiveChannel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let number: String?
    let logoUrl: URL?
    let group: String?

    var isSports: Bool {
        guard let group else { return false }
        return group.lowercased().split { !$0.isLetter }.contains("sports")
    }
}

struct LiveChannelCatalog: Decodable {
    let enabled: Bool
    let sourceName: String
    let channels: [LiveChannel]
    let message: String?

    var uniqueChannels: [LiveChannel] {
        var seen = Set<String>()
        return channels.filter { !$0.id.isEmpty && !$0.name.isEmpty && seen.insert($0.id).inserted }
    }
}

struct LiveTuneResponse: Decodable {
    let sessionId: String
    let playbackPath: String
    let mimeType: String
    let channel: LiveChannel
    let canPause: Bool
    let canSeek: Bool
}

struct LivePlayTarget: Identifiable, Hashable {
    let id = UUID()
    let channel: LiveChannel
}

/// Invalidates callbacks from every previous tune, including late network
/// replies and VLC events after switching channels, reconnecting, or closing.
struct LivePlaybackLifecycle {
    private(set) var generation = UUID()
    private(set) var retryCount = 0
    private(set) var suspended = false
    private(set) var closed = false
    let retryLimit = 2

    mutating func start() -> UUID? {
        guard !closed else { return nil }
        suspended = false
        retryCount = 0
        generation = UUID()
        return generation
    }

    func accepts(_ expected: UUID) -> Bool {
        !closed && !suspended && expected == generation
    }

    mutating func reconnect(after expected: UUID) -> UUID? {
        guard accepts(expected), retryCount < retryLimit else { return nil }
        retryCount += 1
        generation = UUID()
        return generation
    }

    mutating func suspend() {
        suspended = true
        generation = UUID()
    }

    mutating func close() {
        closed = true
        generation = UUID()
    }
}

struct LiveGuide: Decodable {
    let enabled: Bool
    let sourceName: String
    let updatedAt: Date?
    let channels: [LiveChannelSchedule]
    let message: String?
}

struct LiveChannelSchedule: Decodable, Identifiable {
    var id: String { channelId }
    let channelId: String
    let programs: [LiveProgram]

    var orderedPrograms: [LiveProgram] {
        var seen = Set<String>()
        return programs.filter { $0.endTime > $0.startTime && seen.insert($0.id).inserted }
            .sorted { $0.startTime < $1.startTime }
    }
    func now(at date: Date) -> LiveProgram? {
        orderedPrograms.first { $0.startTime <= date && date < $0.endTime }
    }
    func next(at date: Date) -> LiveProgram? {
        orderedPrograms.first { $0.startTime > date }
    }
}

struct LiveProgram: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let startTime: Date
    let endTime: Date
    let description: String?
    let episodeTitle: String?
}

/// Snapshot the server and its credential together. Session release must use
/// the server that created it even if Settings changes before dismissal.
struct LiveConnection {
    let base: URL
    let token: String

    init?(baseUrl: String, syncUrl: String, token: String) {
        guard let base = URL(string: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else { return nil }
        self.base = base
        self.token = URL(string: syncUrl).map { Self.sameOrigin(base, $0) } == true
            ? token.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    func endpoint(_ path: String) -> URL { base.appendingPathComponent(path) }

    func playbackURL(_ path: String) -> URL? {
        // Only the backend's capability route is valid. A response must never
        // redirect VLC to a provider login page or an arbitrary credential URL.
        guard path.hasPrefix("/live/streams/"), !path.contains("\\"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              Self.sameOrigin(base, url), url.user == nil, url.password == nil,
              url.fragment == nil, url.path.hasPrefix("/live/streams/"),
              !url.path.split(separator: "/").contains("..") else { return nil }
        return url
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }
}

struct LiveSession {
    let id: String
    let channel: LiveChannel
    let playbackURL: URL
    let connection: LiveConnection
}

enum LiveTVError: LocalizedError {
    case notConfigured, invalidResponse, connection, server(String, Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect your Velvet server in Settings to watch Live TV."
        case .invalidResponse: return "The server returned an invalid live channel. Try again."
        case .connection: return "Couldn't reach Live TV. Check your connection and try again."
        case .server(let message, _): return message
        }
    }

    var canRetryAutomatically: Bool {
        switch self {
        case .connection: return true
        case .server(_, let status): return status >= 500 || status == 429
        default: return false
        }
    }
}
