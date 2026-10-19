import Foundation

/// Stremio-protocol-compatible stream resolution — a 1:1 PORT of the Android
/// implementation at ~/velvet/app/src/main/java/tv/velvet/data/streams/StreamRepositoryImpl.kt.
/// The implementation (StreamClient.swift) must keep:
///  - endpoints: {base}/stream/movie/{imdbId}.json and
///    {base}/stream/series/{imdbId}:{season}:{episode}.json
///  - all enabled sources queried in parallel, 12s per-source timeout, any
///    failure (non-200 / parse / unreachable) = [] for that source, never throws
///  - torrent infoHash-only entries (no http url) skipped
///  - quality parsing (2160p/4k/uhd → "2160p", 1080p/fhd, 720p, 480p) and size
///    parsing from behaviorHints.videoSize or "12.3 GB" text ([TGMK]iB too)
///  - sortStreams: the backend's release::cmp_streams hierarchy — 2D before 3D,
///    preferred-quality match, resolution rank, REMUX, HDR rank (DoVi > HDR10+ >
///    HDR10/HDR), audio rank (TrueHD Atmos > DTS-X > TrueHD > DTS-HD MA > …),
///    then size desc as the final tiebreaker
///  - autoPick: exact bingeGroup match first when previousBingeGroup is given
///  - probeStreams (v1.2.0, spec §3a): parallel 128 KB Range probes, healthy ones
///    only, in the input's order; never throws; all-fail returns the input unchanged
protocol StreamRepository: Sendable {
    func streams(imdbId: String, type: MediaType, season: Int?, episode: Int?) async -> [StreamOption]
    func sortStreams(_ streams: [StreamOption], preferredQuality: String) -> [StreamOption]
    func autoPick(_ streams: [StreamOption], preferredQuality: String, previousBingeGroup: String?) -> StreamOption?
    /// Health-checks the first `limit` entries of an ALREADY-SORTED list and hands
    /// back the ones that actually serve bytes, in the same order. Call
    /// `sortStreams` first — this deliberately does not re-sort, because the
    /// preferred quality is the caller's business.
    ///
    /// A probe is `GET` + `Range: bytes=0-131071` with the stream's own headers,
    /// ~6 s, redirects followed. Healthy = 200/206 AND at least one byte of body.
    /// Anything else (4xx/5xx, timeout, reset, empty body) drops that candidate.
    /// Never throws. If EVERY probe fails the input list is returned unchanged —
    /// nzbdav lying about a live NZB is better than a "no streams" dead end.
    ///
    /// Swift forbids default arguments in a protocol requirement, hence the plain
    /// `limit:` here; the implementation defaults it to 5 and the extension below
    /// gives callers the one-argument form.
    func probeStreams(_ streams: [StreamOption], limit: Int) async -> [StreamOption]
}

extension StreamRepository {
    /// `probeStreams(sorted)` — the spec's `limit = 5` default.
    func probeStreams(_ streams: [StreamOption]) async -> [StreamOption] {
        await probeStreams(streams, limit: 5)
    }
}
