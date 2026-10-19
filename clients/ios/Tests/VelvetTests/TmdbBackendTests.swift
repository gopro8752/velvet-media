import XCTest
@testable import Velvet

final class TmdbBackendTests: XCTestCase {
    private func connection(backend: String = "https://backend.example.test/velvet/",
                            sync: String = "https://backend.example.test/velvet",
                            token: String = "app-token", key: String = "standalone-key") -> TmdbConnection {
        TmdbConnection(backendURL: backend, syncURL: sync, token: token, standaloneKey: key)
    }

    func testBackendKeepsQueryAndPrefixWithoutForwardingPersonalKey() throws {
        let request = try connection().request(path: "search/multi", params: [
            ("query", "Wallace & Gromit + friends / café"), ("page", "2"),
            ("append_to_response", "images,credits"), ("api_key", "old-key"), ("API_KEY", "another-key"),
            ("access_token", "old-token"), ("ACCESS_TOKEN", "another-token")
        ])
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "backend.example.test")
        XCTAssertEqual(url.path, "/velvet/metadata/tmdb/search/multi")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "query" }?.value, "Wallace & Gromit + friends / café")
        XCTAssertEqual(query.first { $0.name == "append_to_response" }?.value, "images,credits")
        XCTAssertEqual(query.first { $0.name == "page" }?.value, "2")
        XCTAssertEqual(query.first { $0.name == "language" }?.value, "en-US")
        XCTAssertFalse(query.contains { $0.name.lowercased() == "api_key" })
        XCTAssertFalse(query.contains { $0.name.lowercased() == "access_token" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer app-token")
    }

    func testTokenIsOnlyAttachedToConfiguredSyncOrigin() throws {
        for sync in ["https://different.example.test", "http://backend.example.test", "https://backend.example.test:444", ""] {
            let request = try connection(sync: sync).request(path: "tv/123/season/2", params: [])
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), sync)
        }
        let request = try connection(sync: "https://BACKEND.example.test:443/sync").request(path: "movie/123", params: [])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer app-token")
    }

    func testStandaloneUsesOnlyPersonalKeyAndHonorsExplicitLanguage() throws {
        let request = try connection(backend: " ").request(path: "discover/tv", params: [("language", "fr-FR")])
        XCTAssertEqual(request.url?.host, "api.themoviedb.org")
        XCTAssertEqual(request.url?.path, "/3/discover/tv")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "api_key" }?.value, "standalone-key")
        XCTAssertEqual(query.filter { $0.name == "language" }.map(\.value), ["fr-FR"])
        XCTAssertThrowsError(try connection(backend: "", key: "").request(path: "movie/123", params: []))
    }

    func testInvalidBackendOrResourceNeverFallsBackToDirectTMDB() {
        for backend in ["not a url", "file:///tmp", "https://user:password@backend.example.test", "https://backend.example.test?api_key=bad", "https://backend.example.test#fragment"] {
            XCTAssertThrowsError(try connection(backend: backend).request(path: "movie/123", params: []), backend)
        }
        for path in ["https://other.example.test/movie/123", "//other.example.test", "../movie/123", "movie/123?api_key=bad", "movie/%2e%2e/123"] {
            XCTAssertThrowsError(try connection().request(path: path, params: []), path)
        }
    }

    func testRedirectCannotSendBackendTokenToTMDBOrAnotherOrigin() throws {
        let original = try connection().request(path: "movie/123", params: [])
        for destination in ["https://api.themoviedb.org/3/movie/123", "https://other.example.test/movie", "http://backend.example.test/movie", "https://backend.example.test:444/movie"] {
            XCTAssertNil(TmdbRedirectPolicy.redirectedRequest(original: original, proposed: URLRequest(url: URL(string: destination)!)))
        }
        let sameOrigin = URLRequest(url: URL(string: "https://backend.example.test/velvet/metadata/tmdb/movie/124")!)
        XCTAssertEqual(TmdbRedirectPolicy.redirectedRequest(original: original, proposed: sameOrigin)?.value(forHTTPHeaderField: "Authorization"), "Bearer app-token")
    }

    @MainActor
    func testClientReadsChangedBackendAndTokenAndDoesNotFallbackOnServerFailure() async {
        let suite = "tv.velvet.tests.tmdb." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.tmdbApiKey = "unused-local-key"
        settings.setBackendUrl("https://first.example.test/prefix")
        settings.syncToken = "first-token"
        settings.syncEnabled = false // Metadata must not depend on watch-state sync.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TmdbFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = TmdbClient(settings: settings, session: session)
        TmdbFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "first.example.test")
            XCTAssertEqual(request.url?.path, "/prefix/metadata/tmdb/search/multi")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer first-token")
            XCTAssertFalse(request.url!.absoluteString.contains("unused-local-key"))
            return (503, Data())
        }
        defer { TmdbFixtureProtocol.handler = nil }
        let failed = await client.search(query: "Movie")
        XCTAssertTrue(failed.isEmpty)

        settings.setBackendUrl("https://second.example.test")
        settings.syncToken = "second-token"
        TmdbFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "second.example.test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer second-token")
            return (200, Data(#"{"results":[{"id":123,"media_type":"movie","title":"Example","release_date":"2000-01-01","poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg"}]}"#.utf8))
        }
        let results = await client.search(query: "Movie")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.posterUrl?.host, "image.tmdb.org")
        XCTAssertEqual(results.first?.backdropUrl?.host, "image.tmdb.org")
    }
}

private final class TmdbFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
