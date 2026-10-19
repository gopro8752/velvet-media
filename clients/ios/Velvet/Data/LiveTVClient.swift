import Foundation

@MainActor
protocol LiveTVServing: AnyObject {
    func channels() async throws -> LiveChannelCatalog
    func guide() async throws -> LiveGuide
    func tune(channelID: String) async throws -> LiveSession
    func release(_ session: LiveSession) async
}

/// Live TV is independent of the watch-sync toggle. No provider credentials or
/// playback capability URLs are persisted on the device.
@MainActor
final class LiveTVClient: LiveTVServing {
    static var playbackCapabilities: String {
        #if targetEnvironment(simulator)
        return "hls-clear"
        #else
        return "hls-clear,hls-fairplay"
        #endif
    }
    private let configuration: () -> LiveConnection?
    private let session: URLSession

    init(configuration: @escaping () -> LiveConnection?, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func channels() async throws -> LiveChannelCatalog {
        guard let connection = configuration() else { throw LiveTVError.notConfigured }
        let data = try await send(connection, path: "live/channels", method: "GET", timeout: 30)
        do { return try JSONDecoder().decode(LiveChannelCatalog.self, from: data) }
        catch { throw LiveTVError.invalidResponse }
    }

    func guide() async throws -> LiveGuide {
        guard let connection = configuration() else { throw LiveTVError.notConfigured }
        let data = try await send(connection, path: "live/guide", method: "GET", timeout: 30)
        do {
            return try await Task.detached(priority: .userInitiated) {
                try LiveDateDecoder.make().decode(LiveGuide.self, from: data)
            }.value
        }
        catch { throw LiveTVError.invalidResponse }
    }

    func tune(channelID: String) async throws -> LiveSession {
        guard let connection = configuration() else { throw LiveTVError.notConfigured }
        let body = try JSONEncoder().encode(["channelId": channelID])
        let data = try await send(connection, path: "live/tune", method: "POST", body: body, timeout: 45)
        struct AllocatedSession: Decodable { let sessionId: String }
        guard let allocated = try? JSONDecoder().decode(AllocatedSession.self, from: data),
              !allocated.sessionId.isEmpty else { throw LiveTVError.invalidResponse }
        guard let response = try? JSONDecoder().decode(LiveTuneResponse.self, from: data) else {
            await releaseID(allocated.sessionId, connection: connection)
            throw LiveTVError.invalidResponse
        }
        let fairPlay = response.drm.flatMap {
            LiveFairPlayConfiguration(response: $0, sessionID: response.sessionId, connection: connection)
        }
        guard response.channel.id == channelID,
              response.mimeType == "application/vnd.apple.mpegurl",
              response.drm == nil || fairPlay != nil,
              let url = connection.playbackURL(response.playbackPath) else {
            // A malformed playback response can still have allocated a server
            // session. Release that lease instead of leaving its tuner running.
            await releaseID(response.sessionId, connection: connection)
            throw LiveTVError.invalidResponse
        }
        return LiveSession(id: response.sessionId, channel: response.channel,
                           playbackURL: url, connection: connection, fairPlay: fairPlay)
    }

    func release(_ live: LiveSession) async {
        await releaseID(live.id, connection: live.connection)
    }

    private func releaseID(_ id: String, connection: LiveConnection) async {
        guard !id.isEmpty, !id.contains("/"), !id.contains("?"), !id.contains("#") else { return }
        _ = try? await send(connection, path: "live/sessions/" + id, method: "DELETE", timeout: 10)
    }

    private func send(_ connection: LiveConnection, path: String, method: String,
                      body: Data? = nil, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: connection.endpoint(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = body
        if path == "live/tune" {
            request.setValue("ios", forHTTPHeaderField: "X-Velvet-Client")
            request.setValue(Self.playbackCapabilities, forHTTPHeaderField: "X-Velvet-Playback-Capabilities")
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !connection.token.isEmpty {
            request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw LiveTVError.connection }
        guard let http = response as? HTTPURLResponse else { throw LiveTVError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw LiveTVError.server(message.flatMap { $0.isEmpty ? nil : String($0.prefix(250)) }
                ?? "Live TV is unavailable right now. Try again.", http.statusCode)
        }
        return data
    }
}
