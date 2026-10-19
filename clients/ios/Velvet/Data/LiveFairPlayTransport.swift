import Foundation

private final class LiveDRMRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never send the backend credential or a CDM challenge to a redirect.
        completionHandler(nil)
    }
}

/// Exchanges only provider certificates and opaque CDM messages. No key data,
/// URLs or response bodies are logged or persisted by this transport.
final class LiveFairPlayTransport: @unchecked Sendable {
    private let configuration: LiveFairPlayConfiguration
    private let connection: LiveConnection
    private let session: URLSession

    init(configuration: LiveFairPlayConfiguration, connection: LiveConnection, session: URLSession? = nil) {
        self.configuration = configuration
        self.connection = connection
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.urlCache = nil
            settings.httpCookieStorage = nil
            settings.urlCredentialStorage = nil
            settings.httpShouldSetCookies = false
            self.session = URLSession(configuration: settings, delegate: LiveDRMRedirectBlocker(), delegateQueue: nil)
        }
    }

    func certificate() async throws -> Data {
        let data = try await send(url: configuration.certificateURL, body: nil, maximum: 64 * 1024)
        guard data.first == 0x30 else { throw LiveTVError.invalidResponse }
        return data
    }

    func license(spc: Data, keyReference: String) async throws -> Data {
        guard !spc.isEmpty, spc.count <= 1024 * 1024,
              LiveFairPlayConfiguration.safeReference(keyReference),
              var parts = URLComponents(url: configuration.licenseURL, resolvingAgainstBaseURL: false) else {
            throw LiveTVError.invalidResponse
        }
        parts.queryItems = [URLQueryItem(name: "key", value: keyReference)]
        guard let url = parts.url else { throw LiveTVError.invalidResponse }
        return try await send(url: url, body: spc, maximum: 1024 * 1024)
    }

    func cancel() { session.invalidateAndCancel() }

    private func send(url: URL, body: Data?, maximum: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        if !connection.token.isEmpty { request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw LiveTVError.connection }
        guard let http = response as? HTTPURLResponse else { throw LiveTVError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // License services can include private provider details in errors.
            throw LiveTVError.server("The protected live channel could not be authorized.", http.statusCode)
        }
        guard !data.isEmpty, data.count <= maximum else { throw LiveTVError.invalidResponse }
        return data
    }
}
