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
    let drm: LiveDRMResponse?
}

struct LiveDRMResponse: Decodable {
    let scheme: String
    let licensePath: String
    let certificatePath: String
    let contentIdMode: String
}

struct LiveFairPlayConfiguration {
    let licenseURL: URL
    let certificateURL: URL

    init?(response: LiveDRMResponse, sessionID: String, connection: LiveConnection) {
        guard response.scheme == "fairplay", response.contentIdMode == "spectrum-content-id",
              Self.safeReference(sessionID),
              let license = connection.sessionResourceURL(response.licensePath, expected: "/live/drm/" + sessionID),
              let certificate = connection.sessionResourceURL(response.certificatePath, expected: "/live/cert/" + sessionID) else { return nil }
        licenseURL = license
        certificateURL = certificate
    }

    static func safeReference(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// Spectrum's ContentId is the raw query value, not a URL-decoded string.
/// The backend keeps the original provider key URI behind the opaque reference.
struct LiveFairPlayKey: Equatable {
    let reference: String
    let contentIdentifier: Data

    init?(identifier: String) {
        let prefix = "skd://velvet/"
        guard identifier.hasPrefix(prefix), !identifier.contains("#"), !identifier.contains("\\"),
              !identifier.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let query = identifier.firstIndex(of: "?") else { return nil }
        let reference = String(identifier[identifier.index(identifier.startIndex, offsetBy: prefix.count)..<query])
        guard LiveFairPlayConfiguration.safeReference(reference) else { return nil }
        let values = identifier[identifier.index(after: query)...].split(separator: "&").compactMap { field -> String? in
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pair.count == 2 && pair[0].lowercased() == "contentid" ? String(pair[1]) : nil
        }
        guard values.count == 1, let rawID = values.first, !rawID.isEmpty else { return nil }
        // Match the provider's short-ID padding while using the native FPS
        // contentIdentifier API, not WebKit's framed initialization data.
        let content = Data((rawID.utf16.count < 2 ? "  " + rawID : rawID).utf8)
        guard (2...200).contains(content.count) else { return nil }
        self.reference = reference
        contentIdentifier = content
    }
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

    func sessionResourceURL(_ path: String, expected: String) -> URL? {
        guard path == expected, !path.contains("\\"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              Self.sameOrigin(base, url), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path == expected else { return nil }
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
    let fairPlay: LiveFairPlayConfiguration?

    init(id: String, channel: LiveChannel, playbackURL: URL, connection: LiveConnection,
         fairPlay: LiveFairPlayConfiguration? = nil) {
        self.id = id
        self.channel = channel
        self.playbackURL = playbackURL
        self.connection = connection
        self.fairPlay = fairPlay
    }
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
