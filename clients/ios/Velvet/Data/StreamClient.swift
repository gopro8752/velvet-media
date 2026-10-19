import Foundation

/// Stremio-protocol-compatible stream resolution — 1:1 port of the Android
/// StreamRepositoryImpl.kt (+ StremioDtos.kt, inlined below).
///
/// All enabled sources are queried in parallel; each source gets its own
/// try/catch and a 12s timeout, so a dead/unauthorized source (e.g.
/// usenet-streamer answering 401 without its token) contributes an empty list
/// and never blocks or breaks the others.
final class StreamClient: StreamRepository {

    private static let sourceTimeoutNs: UInt64 = 12_000_000_000 // 12s
    private static let probeTimeoutNs: UInt64 = 6_000_000_000   // 6s (spec §3a)
    /// 128 KB − 1: `Range: bytes=0-131071` asks for exactly 131072 bytes.
    private static let probeRangeEnd = 131_071

    private let settings: SettingsStore
    private let session: URLSession
    /// Separate session for health probes: shorter timeouts, no caching (a cached
    /// 206 would make a dead NZB look alive) and ephemeral so 128 KB of video never
    /// lands in the shared URL cache.
    private let probeSession: URLSession

    init(settings: SettingsStore) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)

        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.timeoutIntervalForRequest = 6
        probeConfig.timeoutIntervalForResource = 6
        probeConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        probeConfig.httpMaximumConnectionsPerHost = 8 // all candidates probe at once
        self.probeSession = URLSession(configuration: probeConfig)
    }

    // MARK: - StreamRepository

    func streams(imdbId: String, type: MediaType, season: Int?, episode: Int?) async -> [StreamOption] {
        if imdbId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let sources = await MainActor.run { settings.streamSources }.filter(\.enabled)
        if sources.isEmpty { return [] }

        let streamPath: String
        switch type {
        case .movie:
            streamPath = "stream/movie/\(imdbId).json"
        case .show:
            guard let s = season, let e = episode else { return [] }
            streamPath = "stream/series/\(imdbId):\(s):\(e).json"
        }

        // Parallel per-source fetches; results re-assembled in source order so
        // ties in the (stable) sort behave exactly like the Android awaitAll.
        return await withTaskGroup(of: (Int, [StreamOption]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let options = await self.querySourceWithTimeout(source, streamPath)
                    return (index, options)
                }
            }
            var buckets = [[StreamOption]](repeating: [], count: sources.count)
            for await (index, options) in group {
                buckets[index] = options
            }
            return buckets.flatMap { $0 }
        }
    }

    /// THE stream ordering — the byte-for-byte twin of the backend's
    /// release::cmp_streams, so autopick, the picker order, and the server's
    /// pre-warm all agree on which release is "best":
    /// 2D > 3D, preferred-quality match, resolution, REMUX, dynamic range
    /// (DoVi > HDR10+ > HDR10/HDR), audio (TrueHD Atmos > DTS-X > TrueHD >
    /// DTS-HD MA > …), then size — size is a TIEBREAKER, not a proxy for
    /// quality: a 90 GB WEB-DL re-encode must never outrank a 60 GB UHD remux
    /// with DV and lossless audio, which is exactly what sorting size-first did.
    func sortStreams(_ streams: [StreamOption], preferredQuality: String) -> [StreamOption] {
        // Rank keys are computed ONCE per stream, up front: every StreamTags
        // helper lower-cases and regex-scans the title, and paying that inside
        // the comparator would repeat it for each of the O(n log n) comparisons.
        struct RankKey {
            let is3D: Bool
            let prefMatch: Bool
            let qualityRank: Int
            let isRemux: Bool
            let hdrRank: Int
            let audioRank: Int
            let sizeBytes: Int64
        }
        let keys: [RankKey] = streams.map { stream in
            RankKey(
                is3D: StreamTags.is3D(stream.title),
                prefMatch: stream.quality?.caseInsensitiveCompare(preferredQuality) == .orderedSame,
                qualityRank: Self.qualityRank(stream.quality),
                isRemux: StreamTags.isRemux(stream.title),
                hdrRank: StreamTags.hdrRank(stream.title),
                audioRank: StreamTags.audioRank(stream.title),
                sizeBytes: stream.sizeBytes ?? -1
            )
        }
        return streams.indices
            .sorted { li, ri in
                let l = keys[li]
                let r = keys[ri]
                // 3D (side-by-side / over-under) sinks below every 2D release:
                // it's almost never wanted on a normal screen, so a 3D release
                // only surfaces if nothing else exists.
                if l.is3D != r.is3D { return !l.is3D }
                if l.prefMatch != r.prefMatch { return l.prefMatch }
                if l.qualityRank != r.qualityRank { return l.qualityRank > r.qualityRank }
                if l.isRemux != r.isRemux { return l.isRemux }
                if l.hdrRank != r.hdrRank { return l.hdrRank > r.hdrRank }
                if l.audioRank != r.audioRank { return l.audioRank > r.audioRank }
                if l.sizeBytes != r.sizeBytes { return l.sizeBytes > r.sizeBytes }
                return li < ri // stable, like Kotlin sortedWith
            }
            .map { streams[$0] }
    }

    func autoPick(_ streams: [StreamOption], preferredQuality: String, previousBingeGroup: String?) -> StreamOption? {
        if streams.isEmpty { return nil }
        let sorted = sortStreams(streams, preferredQuality: preferredQuality)
        if let previousBingeGroup,
           !previousBingeGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let match = sorted.first(where: { $0.bingeGroup == previousBingeGroup }) {
            return match
        }
        return sorted.first
    }

    // MARK: - health probes (spec §3a)

    /// Probes the first `limit` streams IN PARALLEL and returns the healthy ones in
    /// the input's (already sorted) order. Never throws — a failed probe just drops
    /// that candidate. If every probe fails, the input list comes back unchanged:
    /// trying a maybe-dead source and failing loudly beats showing "no streams".
    func probeStreams(_ streams: [StreamOption], limit: Int = 5) async -> [StreamOption] {
        guard limit > 0, !streams.isEmpty else { return streams }
        let candidates = Array(streams.prefix(limit))
        let health = await withTaskGroup(of: (Int, Bool).self, returning: [Bool].self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    (index, await self.isHealthy(candidate))
                }
            }
            var flags = [Bool](repeating: false, count: candidates.count)
            for await (index, healthy) in group {
                flags[index] = healthy
            }
            return flags
        }
        let healthy = candidates.indices.filter { health[$0] }.map { candidates[$0] }
        return healthy.isEmpty ? streams : healthy
    }

    /// Races one probe against a 6s clock (same idiom as the per-source timeout):
    /// cancelAll() tears the socket down, and a cancelled probe reads as unhealthy.
    private func isHealthy(_ stream: StreamOption) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await self.probe(stream)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.probeTimeoutNs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }

    /// GET with the stream's own headers plus `Range: bytes=0-131071`, redirects
    /// followed (URLSession default). Healthy = 200/206 AND at least one byte of
    /// body — the body is read as an async byte stream so a server that ignores
    /// Range can't drag a whole 20 GB file down before we know the answer; the task
    /// is cancelled the moment the first byte lands.
    private func probe(_ stream: StreamOption) async -> Bool {
        var request = URLRequest(url: stream.url)
        request.httpMethod = "GET"
        for (name, value) in stream.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("bytes=0-\(Self.probeRangeEnd)", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await probeSession.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else { return false }
            var iterator = bytes.makeAsyncIterator()
            let firstByte = try await iterator.next()
            return firstByte != nil
        } catch {
            return false // 4xx/5xx handled above; timeout, reset, cancellation here
        }
    }

    // MARK: - per-source query

    /// Races the fetch against a 12s clock; timeout or any error = [] for that source.
    private func querySourceWithTimeout(_ source: StreamSourceConfig, _ streamPath: String) async -> [StreamOption] {
        await withTaskGroup(of: [StreamOption]?.self) { group in
            group.addTask {
                await self.querySource(source, streamPath)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.sourceTimeoutNs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll() // cancels the slow fetch's socket (URLSession is cancellable)
            return first ?? []
        }
    }

    private func querySource(_ source: StreamSourceConfig, _ streamPath: String) async -> [StreamOption] {
        guard let base = Self.normalizeBaseUrl(source.baseUrl),
              let url = URL(string: "\(base)/\(streamPath)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return [] // non-200 — never throw
            }
            let parsed = try JSONDecoder().decode(StremioStreamsResponse.self, from: data)
            return (parsed.streams ?? []).compactMap { option(from: $0, sourceName: source.name) }
        } catch {
            return [] // network error, bad JSON, cancellation — never throw
        }
    }

    /// Accepts pasted ".../manifest.json" URLs and trailing slashes; rejects non-http.
    private static func normalizeBaseUrl(_ raw: String) -> String? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/manifest.json") { base.removeLast("/manifest.json".count) }
        if base.hasSuffix("/") { base.removeLast() }
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else { return nil }
        return base
    }

    // MARK: - mapping & parsing

    private func option(from dto: StremioStreamDto, sourceName: String) -> StreamOption? {
        // Torrent entries carry infoHash without url — only direct http(s) URLs are playable.
        let trimmedUrl = dto.url?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedUrl,
              trimmedUrl.hasPrefix("http://") || trimmedUrl.hasPrefix("https://"),
              let playableUrl = URL(string: trimmedUrl) else { return nil }
        let haystack = [dto.behaviorHints?.filename, dto.title, dto.description, dto.name]
            .compactMap { $0 }
            .joined(separator: "\n")
        let sizeBytes: Int64?
        if let videoSize = dto.behaviorHints?.videoSize, videoSize > 0 {
            sizeBytes = Self.clampToInt64(videoSize)
        } else {
            sizeBytes = Self.parseSizeBytes(haystack)
        }
        let displayTitle = nonBlank(dto.behaviorHints?.filename)
            ?? (dto.title ?? dto.description)
                .flatMap { text -> String? in
                    text.components(separatedBy: .newlines)
                        .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            ?? dto.name
                .flatMap { name -> String? in
                    let flattened = name.replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return flattened.isEmpty ? nil : flattened
                }
            ?? "Stream"
        return StreamOption(
            url: playableUrl,
            title: displayTitle,
            quality: Self.parseQuality(haystack),
            sizeBytes: sizeBytes,
            sourceName: sourceName,
            bingeGroup: nonBlank(dto.behaviorHints?.bingeGroup),
            headers: dto.behaviorHints?.proxyHeaders?.request ?? [:]
        )
    }

    // NSRegularExpression is immutable and documented thread-safe.
    private static let quality2160 = try! NSRegularExpression(
        pattern: #"\b(2160p|4k|uhd|ultra\s*hd)\b"#, options: [.caseInsensitive])
    private static let quality1080 = try! NSRegularExpression(
        pattern: #"\b(1080p|fhd|full\s*hd)\b"#, options: [.caseInsensitive])
    private static let quality720 = try! NSRegularExpression(
        pattern: #"\b720p\b"#, options: [.caseInsensitive])
    private static let quality480 = try! NSRegularExpression(
        pattern: #"\b480p\b"#, options: [.caseInsensitive])

    /// Matches "12.3 GB", "700MB", "1,4 gb", "4.18 GiB" — first match wins.
    /// KB-and-up only: a bare "B" unit would misparse bit-depth tokens in release
    /// names ("HEVC.10b-GROUP" → 10 bytes) and silently corrupt stream sorting.
    private static let sizeText = try! NSRegularExpression(
        pattern: #"(\d+(?:[.,]\d+)?)\s*([TGMK]i?B)\b"#, options: [.caseInsensitive])

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func parseQuality(_ text: String) -> String? {
        if matches(quality2160, text) { return "2160p" }
        if matches(quality1080, text) { return "1080p" }
        if matches(quality720, text) { return "720p" }
        if matches(quality480, text) { return "480p" }
        return nil
    }

    private static func parseSizeBytes(_ text: String) -> Int64? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = sizeText.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let valueText = text[valueRange].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(valueText) else { return nil }
        // Release tooling means binary sizes whether it writes "GB" or "GiB" — 1024-based.
        let multiplier: Double
        switch text[unitRange].uppercased() {
        case "TB", "TIB": multiplier = 1_099_511_627_776
        case "GB", "GIB": multiplier = 1_073_741_824
        case "MB", "MIB": multiplier = 1_048_576
        case "KB", "KIB": multiplier = 1_024
        default: return nil
        }
        let bytes = clampToInt64(value * multiplier)
        return (bytes ?? 0) > 0 ? bytes : nil
    }

    private static func clampToInt64(_ value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        if value >= 9.2e18 { return Int64.max }
        if value <= -9.2e18 { return Int64.min }
        return Int64(value)
    }

    private static func qualityRank(_ quality: String?) -> Int {
        switch quality?.lowercased() {
        case "2160p": return 4
        case "1080p": return 3
        case "720p": return 2
        case "480p": return 1
        default: return 0
        }
    }

    private func nonBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

// MARK: - Stremio wire DTOs

/// Stremio stream-addon protocol wire shapes (port of the Android StremioDtos.kt,
/// verified against a live addon with curl):
/// GET {base}/stream/movie/{imdbId}.json → {"streams":[...]}
/// Notes from real responses:
///  - "name"/"title" frequently contain newlines and emoji-decorated metadata ("💾 6.91 GB").
///  - Torrent-only entries carry "infoHash" instead of "url" — those are not playable here.
///  - behaviorHints.videoSize is a JSON number (bytes); declared Double so integer values parse too.
struct StremioStreamsResponse: Decodable {
    let streams: [StremioStreamDto]?
}

struct StremioStreamDto: Decodable {
    let url: String?
    let name: String?
    let title: String?
    let description: String?
    let behaviorHints: StremioBehaviorHintsDto?
}

struct StremioBehaviorHintsDto: Decodable {
    let bingeGroup: String?
    let filename: String?
    let videoSize: Double?
    let proxyHeaders: StremioProxyHeadersDto?
}

struct StremioProxyHeadersDto: Decodable {
    let request: [String: String]?
}
