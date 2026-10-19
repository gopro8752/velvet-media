import Foundation

/// Only the unsupported soundtrack is converted. Video, release identity and
/// playback position remain on the original stream, including Send to TV.
enum AudioCompatibility {
    struct Probe: Decodable {
        let durationMs: Int64
        let audioTracks: [Track]
    }
    struct Track: Decodable {
        let index: Int
        let codec: String
        let channels: Int
        let language: String?
        let title: String?
    }
    enum Failure: LocalizedError {
        case unavailable, soundtrackChanged
        var errorDescription: String? {
            "Couldn't prepare sound for this stream. Please try again."
        }
    }

    static func soundtrack(in probe: Probe, matching requested: PlayerTrack) -> Track? {
        // VLC ES identifiers can be Matroska track numbers or MPEG-TS PIDs,
        // rather than FFmpeg stream indexes. Match the audio ordinal and check
        // codec/language before using the server's global stream index.
        guard let ordinal = requested.audioOrdinal,
              probe.audioTracks.indices.contains(ordinal) else { return nil }
        let result = probe.audioTracks[ordinal]
        guard ["truehd", "mlp"].contains(result.codec.lowercased()) else { return nil }
        if let language = PlayerTrack.languageKey(requested.language),
           let candidate = PlayerTrack.languageKey(result.language), language != candidate { return nil }
        return result
    }

    static func prepare(stream: StreamOption, track: PlayerTrack,
                        session: URLSession = .shared) async throws -> URL {
        guard track.needsAudioCompatibility,
              stream.url.path.range(of: #"/stream/[0-9a-f]{16}$"#, options: .regularExpression) != nil,
              stream.url.query == nil, stream.url.fragment == nil,
              var components = URLComponents(url: stream.url, resolvingAgainstBaseURL: false) else {
            throw Failure.unavailable
        }
        components.path += "/audio"
        guard let endpoint = components.url else { throw Failure.unavailable }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.unavailable
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard probe.durationMs > 0, let soundtrack = soundtrack(in: probe, matching: track) else {
            throw Failure.soundtrackChanged
        }
        return endpoint.appendingPathComponent("\(soundtrack.index).wav")
    }
}
