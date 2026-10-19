import Foundation

@MainActor
protocol LiveSportsServing: AnyObject {
    func events(scope: SportsScope) async throws -> SportsCatalog
    func streams(eventID: String) async throws -> SportsStreams
}

@MainActor
final class LiveSportsClient: LiveSportsServing {
    private struct Failure: Decodable { let error: String }
    private let configuration: () -> LiveConnection?
    private let session: URLSession
    init(configuration: @escaping () -> LiveConnection?, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func events(scope: SportsScope) async throws -> SportsCatalog {
        try await get(path: "sports/events", query: [URLQueryItem(name: "scope", value: scope.apiValue)])
    }

    func streams(eventID: String) async throws -> SportsStreams {
        guard !eventID.isEmpty, !eventID.contains("/"), !eventID.contains("?"), !eventID.contains("#") else {
            throw SportsError.message("This event is unavailable. Refresh the events and try again.")
        }
        let result: SportsStreams = try await get(path: "sports/events/\(eventID)/streams")
        guard result.eventId == eventID else { throw SportsError.message("The server returned a different event. Please refresh.") }
        var seen = Set<String>()
        return SportsStreams(eventId: result.eventId, streams: result.streams.filter {
            SportsEmbedPolicy.accepts($0.embedUrl) && seen.insert($0.selectionID).inserted
        }, message: result.message)
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let connection = configuration(),
              var components = URLComponents(url: connection.endpoint(path), resolvingAgainstBaseURL: false) else {
            throw SportsError.message("Connect your Velvet server in Settings to browse Live Sports.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SportsError.message("The server address is invalid.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !connection.token.isEmpty { request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw SportsError.message("Couldn't reach Live Sports. Check your connection and try again.") }
        guard let http = response as? HTTPURLResponse else { throw SportsError.message("The server returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw SportsError.message(message.map { String($0.prefix(250)) } ?? "Live Sports is unavailable right now.")
        }
        do { return try LiveDateDecoder.make().decode(T.self, from: data) }
        catch { throw SportsError.message("The server returned an invalid sports listing. Please refresh.") }
    }
}

enum SportsError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
