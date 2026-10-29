import Foundation

struct SportCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct SportsTeam: Decodable, Hashable {
    let name: String
    let badgeUrl: URL?
}

struct SportsEvent: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let sportId: String
    let sportName: String
    let startTime: Date
    let isLive: Bool
    let popular: Bool
    let posterUrl: URL?
    let homeTeam: SportsTeam?
    let awayTeam: SportsTeam?
    let sourceCount: Int
}

struct SportsCatalog: Decodable {
    let enabled: Bool
    let sourceName: String
    let sports: [SportCategory]
    let events: [SportsEvent]
    let message: String?
}

struct SportsStream: Decodable, Hashable {
    let id: String
    let source: String
    let streamNo: Int
    let language: String
    let hd: Bool
    let embedUrl: URL

    // The upstream repeats id for its HD/SD and language variants.
    var selectionID: String { "\(source)|\(id)|\(streamNo)|\(embedUrl.absoluteString)" }
    var label: String { "\(language.isEmpty ? "Stream" : language) · \(hd ? "HD" : "SD") · \(source.capitalized) \(streamNo)" }
}

struct SportsStreams: Decodable {
    let eventId: String
    let streams: [SportsStream]
    let message: String?
}

enum SportsScope: String, CaseIterable, Identifiable {
    case live, today, upcoming
    var id: String { rawValue }
    var title: String {
        switch self { case .live: return "Live"; case .today: return "Today"; case .upcoming: return "Upcoming" }
    }
    var apiValue: String { self == .upcoming ? "all" : rawValue }
    func includes(_ event: SportsEvent, now: Date) -> Bool {
        switch self {
        case .live: return event.isLive
        case .today: return true // The server resolves its today scope.
        case .upcoming: return !event.isLive && event.startTime > now
        }
    }
}

struct SportsPlayTarget: Identifiable, Equatable {
    let id = UUID()
    let event: SportsEvent
    let streams: [SportsStream]
    let selectedID: String
}

enum LiveDateDecoder {
    static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        // The full guide contains thousands of timestamps. Keep formatters
        // local to one decode instead of constructing two for every program.
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (text.contains(".") ? fractional : plain).date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid ISO8601 date"))
        }
        return decoder
    }
}

/// Only accept web embeds, never custom URL schemes, local files, embedded
/// credentials, or local-network addresses supplied by a remote catalog.
enum SportsEmbedPolicy {
    static func accepts(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        #if DEBUG
        if url.scheme == "http", ["127.0.0.1", "localhost"].contains(host), url.port == 18881 { return true }
        #endif
        guard url.scheme?.lowercased() == "https", url.port == nil else { return false }
        // StreamFree's documented embeds contain exactly a category and key.
        // Decode each segment independently to permit real Unicode team names,
        // while rejecting encoded separators, traversal, and remote query data.
        guard ["strmfree.st", "streamfree.top"].contains(host), url.query == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "embed" else { return false }
        return parts[2...].allSatisfy { part in
            guard let value = String(part).removingPercentEncoding, !value.isEmpty,
                  value.utf8.count <= 240, value != ".", value != ".." else { return false }
            return value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
        }
    }
}
