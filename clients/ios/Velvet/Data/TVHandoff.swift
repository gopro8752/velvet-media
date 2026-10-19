import Foundation

struct TVHandoffReceiver: Decodable, Identifiable, Equatable {
    let deviceId: String
    let sessionId: String
    let name: String
    let profileId: String
    let expiresAt: Int64
    var id: String { deviceId + ":" + sessionId }
}

struct TVHandoffReceivers: Decodable {
    let protocolVersion: Int
    let serverNow: Int64
    let receivers: [TVHandoffReceiver]
    /// Canonical media address advertised by this same authenticated backend.
    /// A LAN API address and its public media address can belong to one server.
    let streamBaseURL: String?

    var available: [TVHandoffReceiver] {
        guard protocolVersion == 2 else { return [] }
        var seen = Set<String>()
        return receivers.filter {
            !$0.deviceId.isEmpty && !$0.sessionId.isEmpty && $0.expiresAt > serverNow && seen.insert($0.id).inserted
        }
    }
}

struct TVHandoffRequest: Encodable {
    struct SourceHint: Encodable {
        let streamId: String
        let title: String
        let sourceName: String
        let bingeGroup: String?
    }
    let requestId: String
    let targetDeviceId: String
    let targetSessionId: String
    let profileId: String
    let mediaId: Int
    let type: String
    let season: Int?
    let episode: Int?
    let positionMs: Int64
    let title: String?
    let sourceHint: SourceHint?
}

struct TVHandoffStatus: Decodable {
    enum State: String, Decodable { case pending, claimed, started, failed, cancelled, expired }
    let protocolVersion: Int
    let id: String
    let state: State
    let targetName: String?
    let expiresAt: Int64
    let error: String?
    var isTerminal: Bool { state != .pending && state != .claimed }
}

enum TVHandoffError: LocalizedError {
    case unavailable, noReceiver, receiverUnavailable, receiverBusy, sourceUnavailable, exactSourceUnsupported, requestFailed, unsupported, invalidResponse
    var errorDescription: String? {
        switch self {
        case .exactSourceUnsupported: return "This stream can't be sent directly to this TV. Playback will stay on your phone."
        case .sourceUnavailable: return "This exact stream is no longer available on the server."
        case .unavailable: return "Connect your companion server in Settings to send to a TV."
        case .noReceiver: return "No awake TV has Velvet open. Open Velvet on the TV and try again."
        case .receiverBusy: return "That TV is already starting another handoff. Try again shortly."
        case .receiverUnavailable: return "That TV is no longer available. Open Velvet on it and try again."
        case .unsupported: return "Update the companion server and TV app to use Send to TV."
        case .requestFailed, .invalidResponse: return "Couldn't reach the TV. Try again."
        }
    }
}

/// Only the backend's opaque stream reference crosses devices. Reject foreign
/// origins, token paths/queries, credentials and per-source request headers.
/// The backend may publish media on a different origin from its LAN API.
enum TVHandoffSource {
    static func streamId(url: URL, backendURL: String, advertisedStreamBaseURL: String? = nil,
                         headers: [String: String]) -> String? {
        let trustedBases = [backendURL, advertisedStreamBaseURL].compactMap { $0 }
        return trustedBases.contains { matches(url: url, baseURL: $0, headers: headers) }
            ? String(url.path.suffix(16)) : nil
    }

    private static func matches(url: URL, baseURL: String, headers: [String: String]) -> Bool {
        guard headers.isEmpty,
              let source = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let backend = URLComponents(string: baseURL),
              let scheme = source.scheme?.lowercased(), ["http", "https"].contains(scheme),
              source.user == nil, source.password == nil, source.query == nil, source.fragment == nil,
              backend.user == nil, backend.password == nil, backend.query == nil, backend.fragment == nil,
              ["", "/"].contains(backend.path),
              backend.scheme?.lowercased() == scheme,
              source.host?.lowercased() == backend.host?.lowercased(), source.host != nil,
              effectivePort(source) == effectivePort(backend),
              source.percentEncodedPath.range(of: #"^/stream/[0-9a-f]{16}$"#, options: .regularExpression) != nil else { return false }
        return true
    }
    private static func effectivePort(_ url: URLComponents) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}

/// Captures one server configuration for the whole attempt. Changing Settings
/// cannot send a status/cancel request (or its bearer token) to another server.
struct TVHandoffClient {
    let baseURL: String
    let token: String
    var session: URLSession = .shared

    func discover() async throws -> TVHandoffReceivers {
        let value: TVHandoffReceivers = try await send(path: "/handoff/receivers")
        guard value.protocolVersion == 2 else { throw TVHandoffError.unsupported }
        return value
    }

    func receivers() async throws -> [TVHandoffReceiver] {
        try await discover().available
    }

    func submit(_ request: TVHandoffRequest) async throws -> TVHandoffStatus {
        try await checked(send(path: "/handoff/v2", body: JSONEncoder().encode(request)), id: request.requestId)
    }

    func status(id: String) async throws -> TVHandoffStatus {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return try await checked(send(path: "/handoff/v2/status?" + (components.percentEncodedQuery ?? "")), id: id)
    }

    func cancel(id: String) async throws -> TVHandoffStatus {
        try await checked(send(path: "/handoff/v2/cancel", body: JSONEncoder().encode(["id": id])), id: id)
    }

    /// Acceptance/claim is not playback. Transient status failures keep polling;
    /// an ambiguous create or timeout is resolved by an idempotent cancellation.
    /// A started response wins a cancellation race and remains a success.
    func deliver(_ request: TVHandoffRequest, timeout: TimeInterval = 140,
                 pollNanoseconds: UInt64 = 1_000_000_000) async throws -> TVHandoffStatus? {
        var rejection: TVHandoffError?
        do {
            var result = try await submit(request)
            let deadline = Date().addingTimeInterval(timeout)
            while !result.isTerminal && Date() < deadline {
                try await Task.sleep(nanoseconds: pollNanoseconds)
                do { result = try await status(id: request.requestId) }
                catch { if Task.isCancelled { throw CancellationError() } }
            }
            if result.isTerminal { return result }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? TVHandoffError {
                switch error {
                case .sourceUnavailable, .noReceiver, .receiverUnavailable, .receiverBusy, .unsupported:
                    rejection = error
                default: break
                }
            }
        }
        try Task.checkCancellation()
        let cancellation = try? await cancel(id: request.requestId)
        // Surface a definite rejection only after cancellation is confirmed.
        // A racing started acknowledgement still wins; an unreachable server
        // remains uncertain, preserving the known request for another cancel.
        if let rejection, let cancellation,
           [.failed, .cancelled, .expired].contains(cancellation.state) {
            return TVHandoffStatus(protocolVersion: cancellation.protocolVersion,
                id: cancellation.id, state: .failed, targetName: cancellation.targetName,
                expiresAt: cancellation.expiresAt, error: rejection.localizedDescription)
        }
        return cancellation
    }

    private func checked(_ value: TVHandoffStatus, id: String) throws -> TVHandoffStatus {
        guard value.protocolVersion == 2, value.id == id else { throw TVHandoffError.invalidResponse }
        return value
    }

    private struct Failure: Decodable { let code: String? }

    private func send<T: Decodable>(path: String, body: Data? = nil) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw TVHandoffError.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw TVHandoffError.requestFailed }
        guard let http = response as? HTTPURLResponse else { throw TVHandoffError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.code
            switch code {
            case "no_receiver": throw TVHandoffError.noReceiver
            case "receiver_unavailable": throw TVHandoffError.receiverUnavailable
            case "receiver_busy": throw TVHandoffError.receiverBusy
            case "source_unavailable": throw TVHandoffError.sourceUnavailable
            default: throw http.statusCode == 404 ? TVHandoffError.unsupported : TVHandoffError.requestFailed
            }
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw TVHandoffError.invalidResponse }
        return value
    }
}
