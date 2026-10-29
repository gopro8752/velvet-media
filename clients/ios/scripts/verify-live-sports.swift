import Foundation

final class SportsMockProtocol: URLProtocol {
    static var handler: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct VerifyLiveSports {
    @MainActor static func main() async throws {
        func expect(_ value: @autoclosure () -> Bool, _ description: String) { precondition(value(), description) }
        let eventData = Data(#"{"id":"event","title":"Tigers vs Bears","sportId":"basketball","sportName":"Basketball","startTime":"2026-10-12T19:30:00Z","isLive":true,"popular":false,"sourceCount":2}"#.utf8)
        let event = try LiveDateDecoder.make().decode(SportsEvent.self, from: eventData)
        expect(event.homeTeam == nil && event.posterUrl == nil, "Optional catalog fields must be optional")
        expect(SportsScope.live.includes(event, now: Date()), "Explicit live flag must decide live status")
        expect(!SportsScope.upcoming.includes(event, now: event.startTime.addingTimeInterval(-60)), "Live event cannot also be upcoming")
        let fractional = String(data: eventData, encoding: .utf8)!.replacingOccurrences(of: "19:30:00Z", with: "19:30:00.123Z")
        _ = try LiveDateDecoder.make().decode(SportsEvent.self, from: Data(fractional.utf8))
        for path in ["https://strmfree.st/embed/basketball/a1080p", "https://streamfree.top/embed/soccer/cf-montr%C3%A9al1080p"] {
            expect(SportsEmbedPolicy.accepts(URL(string: path)!), "Official embed rejected")
        }
        for path in ["http://strmfree.st/embed/basketball/a", "https://strmfree.st.evil.example/embed/basketball/a", "https://name:pass@strmfree.st/embed/basketball/a", "https://strmfree.st:8443/embed/basketball/a", "https://strmfree.st/login", "file:///tmp/video", "javascript:alert(1)", "https://127.0.0.1/embed/basketball/a", "https://strmfree.st/embed/basketball/a?redirect=ad", "https://strmfree.st/embed/basketball/a#player", "https://strmfree.st/embed/basketball/a%2fb", "https://strmfree.st/embed/basketball/a%252fb", "https://strmfree.st/embed/basketball/%2e%2e", "https://strmfree.st/embed/basketball/a/", "https://embed.st/embed/golf/a/1"] {
            expect(!SportsEmbedPolicy.accepts(URL(string: path)!), "Unsafe embed accepted: \(path)")
        }
        let original = URL(string: "https://strmfree.st/embed/soccer/cf-montr%C3%A9al1080p")!
        var recovery = SportsEmbedRecovery(original)
        expect(recovery.retryDNSFailure(failedURL: original, isDNSFailure: false, playbackStarted: false, remainingMilliseconds: 20000) == nil, "TLS/network errors cannot trigger a mirror")
        expect(recovery.retryDNSFailure(failedURL: original, isDNSFailure: true, playbackStarted: true, remainingMilliseconds: 20000) == nil, "Mid-game must not trigger hidden playback")
        expect(recovery.retryDNSFailure(failedURL: original, isDNSFailure: true, playbackStarted: false, remainingMilliseconds: 1000) == nil, "Mirror must honor total startup budget")
        for bad in ["https://strmfree.st/ad.html", "https://strmfree.st/embed/soccer/cf-montr%C3%A9al1080p2", "https://strmfree.st/embed/soccer/cf-montr%C3%A9al1080p?redirect=ad"] {
            expect(recovery.retryDNSFailure(failedURL: URL(string: bad), isDNSFailure: true, playbackStarted: false, remainingMilliseconds: 20000) == nil, "Only exact selected document may recover")
        }
        let alternate = recovery.retryDNSFailure(failedURL: original, isDNSFailure: true, playbackStarted: false, remainingMilliseconds: 20000)
        expect(alternate?.absoluteString == "https://streamfree.top/embed/soccer/cf-montr%C3%A9al1080p", "Mirror must preserve exact encoded path")
        expect(recovery.currentURL == alternate, "Origin validation must follow the selected mirror")
        expect(recovery.retryDNSFailure(failedURL: alternate, isDNSFailure: true, playbackStarted: false, remainingMilliseconds: 15000) == nil, "Only one DNS retry is allowed")
        let guide = try LiveDateDecoder.make().decode(LiveGuide.self, from: Data(#"{"enabled":true,"sourceName":"Spectrum","updatedAt":null,"channels":[{"channelId":"tv","programs":[{"id":"next","title":"Next","startTime":"2026-10-12T20:00:00Z","endTime":"2026-10-12T21:00:00Z"},{"id":"now","title":"Current","startTime":"2026-10-12T19:00:00Z","endTime":"2026-10-12T20:00:00Z"}]}]}"#.utf8))
        let schedule = guide.channels[0]
        expect(schedule.now(at: event.startTime)?.title == "Current", "Current program must use exact time interval")
        expect(schedule.next(at: event.startTime)?.title == "Next", "Schedule order must not change Now/Next")
        expect(schedule.now(at: schedule.orderedPrograms.last!.endTime) == nil, "Expired guide must not invent currently airing programs")

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SportsMockProtocol.self]
        let client = LiveSportsClient(configuration: { LiveConnection(baseUrl: "https://velvet.example", syncUrl: "https://velvet.example", token: "private") }, session: URLSession(configuration: config))
        var lastRequest: URLRequest?
        SportsMockProtocol.handler = { request in
            lastRequest = request
            return (200, Data(#"{"eventId":"event","streams":[{"id":"same","source":"golf","streamNo":1,"language":"English","hd":true,"embedUrl":"https://strmfree.st/embed/basketball/a1080p"},{"id":"same","source":"golf","streamNo":2,"language":"Spanish","hd":false,"embedUrl":"https://strmfree.st/embed/basketball/a1080p2"},{"id":"bad","source":"golf","streamNo":3,"language":"English","hd":true,"embedUrl":"https://evil.example/player"}]}"#.utf8))
        }
        let streams = try await client.streams(eventID: "event")
        expect(streams.streams.count == 2, "HD/language variants must survive dedupe; invalid hosts must be removed")
        expect(Set(streams.streams.map(\.selectionID)).count == 2, "Variant selection identity collision")
        expect(lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer private", "Backend credential policy lost")
        do { _ = try await client.streams(eventID: "other"); preconditionFailure("Wrong event accepted") } catch is SportsError { }
        SportsMockProtocol.handler = { request in
            lastRequest = request
            return (200, Data(#"{"enabled":true,"sourceName":"StreamFree","sports":[],"events":[]}"#.utf8))
        }
        _ = try await client.events(scope: .upcoming)
        expect(lastRequest?.url?.query == "scope=all", "Upcoming must request full catalog then filter future events")
        print("Sports/guide checks passed: dates, scope, optional metadata, exact guide intervals, embed allowlist, stream variants and backend auth.")
    }
}
