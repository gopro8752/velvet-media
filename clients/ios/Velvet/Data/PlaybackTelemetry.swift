import Foundation
import UIKit

/// Media position is intentionally absent: seeking does not create watch time.
struct PlaybackTelemetryClock {
    private var last: TimeInterval
    private(set) var state = "buffering"
    private(set) var playedMs: Int64 = 0
    private(set) var bufferedMs: Int64 = 0
    init(now: TimeInterval) { last = now }
    mutating func sample(now: TimeInterval, state next: String) {
        let delta = Int64(max(0, min(2, now - last)) * 1_000)
        if state == "playing" { playedMs += delta }
        if state == "buffering" { bufferedMs += delta }
        state = next; last = now
    }
}

private final class TelemetryRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Independent, short-lived best-effort requests; failures never reach the player UI.
@MainActor
final class PlaybackTelemetry {
    struct Sample { var state: String; var positionMs: Int64 = 0 }
    private let settings: SettingsStore
    private var payload: [String: Any]?
    private var clock: PlaybackTelemetryClock?
    private var sampler: (() -> Sample)?
    private var timer: Task<Void, Never>?
    private var endpoint: URL?
    private var token = ""
    private var sequence = 0
    private var openedAt: TimeInterval = 0
    private var lastSent: TimeInterval = 0
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: TelemetryRedirectPolicy(), delegateQueue: nil)
    }()
    init(settings: SettingsStore) { self.settings = settings }
    deinit { timer?.cancel() }

    func start(kind: String, mediaId: String, title: String, season: Int? = nil, episode: Int? = nil,
               profileId: String? = nil, sample: @escaping () -> Sample) {
        end()
        // This origin is the configured sync backend, never a resolved media provider.
        let base = SettingsStore.normalizeBaseUrl(settings.syncUrl)
        guard settings.syncEnabled, let url = URL(string: base + "/telemetry/playback"),
              ["https", "http"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return }
        endpoint = url; token = settings.syncToken
        let defaults = UserDefaults.standard
        let deviceId = defaults.string(forKey: "telemetry_device_id") ?? UUID().uuidString
        defaults.set(deviceId, forKey: "telemetry_device_id")
        openedAt = ProcessInfo.processInfo.systemUptime
        clock = PlaybackTelemetryClock(now: openedAt)
        sequence = 0; lastSent = 0; sampler = sample
        payload = ["sessionId": UUID().uuidString, "deviceId": deviceId,
                   "deviceName": UIDevice.current.model, "platform": "ios",
                   "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                   "profileId": profileId ?? settings.activeProfileId ?? "default", "kind": kind,
                   "mediaId": mediaId, "title": String(title.prefix(500)), "errorCount": 0, "sourceSwitches": 0]
        payload?["season"] = season; payload?["episode"] = episode
        observe(force: true)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.observe()
            }
        }
    }
    func observe(force: Bool = false) {
        guard let sample = sampler?(), var value = clock else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let changed = value.state != sample.state
        value.sample(now: now, state: sample.state); clock = value
        payload?["positionMs"] = max(0, sample.positionMs)
        if sample.state == "playing", payload?["startupMs"] == nil { payload?["startupMs"] = Int64((now - openedAt) * 1_000) }
        if force || changed || now - lastSent >= 15 { send() }
    }
    func error() { let count = (payload?["errorCount"] as? Int ?? 0) + 1; payload?["errorCount"] = count; observe(force: true) }
    func sourceSwitch() { let count = (payload?["sourceSwitches"] as? Int ?? 0) + 1; payload?["sourceSwitches"] = count; observe(force: true) }
    func end() {
        timer?.cancel(); timer = nil
        if var value = clock { value.sample(now: ProcessInfo.processInfo.systemUptime, state: "ended"); clock = value; send() }
        clock = nil; payload = nil; sampler = nil; endpoint = nil
    }
    private func send() {
        guard let endpoint, let value = clock, var data = payload else { return }
        sequence += 1
        data["sequence"] = sequence; data["state"] = value.state
        data["playedMs"] = value.playedMs; data["bufferedMs"] = value.bufferedMs
        data["timestampMs"] = Int64(Date().timeIntervalSince1970 * 1_000)
        guard let body = try? JSONSerialization.data(withJSONObject: data) else { return }
        lastSent = ProcessInfo.processInfo.systemUptime
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        Self.session.dataTask(with: request) { _, _, _ in }.resume()
    }
}
