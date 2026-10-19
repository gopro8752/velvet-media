import Foundation

/// Mirrors the Android app's data/model/Models.kt one-for-one.

enum MediaType: String, Codable, Hashable {
    case movie
    case show
}

/// A movie or show as shown on cards and rows. All image URLs are absolute.
struct MediaItem: Identifiable, Hashable, Codable {
    let id: Int                    // TMDB id
    let type: MediaType
    let title: String
    var year: String?              // "2024" or "2019–2023"
    var posterUrl: URL?            // ~w500, 2:3
    var backdropUrl: URL?          // ~w1280, 16:9
    var logoUrl: URL?              // transparent PNG title logo, if fetched
    var rating: Double?            // TMDB 0..10
    var overview: String?
    var genres: [String] = []
    var runtimeMinutes: Int?
    var imdbId: String?            // "tt0903747" — required for stream lookup
    var rankInRow: Int?            // 1-based, Top 10 numeral cards
}

struct CastMember: Hashable {
    let name: String
    let role: String?
    let profileUrl: URL?
}

struct Season: Hashable {
    let number: Int
    let name: String
    let episodeCount: Int
    let posterUrl: URL?
}

struct Episode: Hashable {
    let season: Int
    let number: Int
    let title: String
    var overview: String?
    var stillUrl: URL?             // 16:9 episode still
    var runtimeMinutes: Int?
    var airDate: String?           // "2024-03-01"
}

/// Full details for the details screen. `item` carries logoUrl + imdbId here.
struct MediaDetails {
    var item: MediaItem
    var tagline: String?
    var certification: String?     // "PG-13", "TV-MA"
    var cast: [CastMember] = []
    var seasons: [Season] = []     // empty for movies
    var similar: [MediaItem] = []
    /// False for movies still exclusively in theaters (no digital/physical release
    /// yet) — nothing on usenet to stream, so heroes must not tease them.
    var digitallyAvailable: Bool = true
}

/// One playable stream resolved by a stream source (usenet-streamer).
struct StreamOption: Hashable, Identifiable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String              // display: filename or quality summary
    let quality: String?           // "2160p" | "1080p" | "720p" | "480p"
    let sizeBytes: Int64?
    let sourceName: String
    let bingeGroup: String?        // same group => same release chain for autoplay
    let headers: [String: String]
}

enum RowStyle: String, Codable {
    case poster
    case landscape
    case top10
}

/// A home-screen row. Full set: TmdbRepository.allRows; the user's enabled
/// subset + order: SettingsStore.rowOrder (empty = default order).
struct RowSpec: Identifiable, Hashable {
    let id: String
    let title: String
    let style: RowStyle
}

/// Identity of a playable thing. For movies season/episode are nil; for shows
/// nil season/episode means "resolve next unwatched" (player does this).
struct PlayTarget: Hashable, Identifiable {
    var id: String { "\(type.rawValue):\(mediaId):\(season ?? -1):\(episode ?? -1)" }
    let mediaId: Int
    let type: MediaType
    var season: Int?
    var episode: Int?
}

struct StreamSourceConfig: Codable, Hashable, Identifiable {
    var id: String { baseUrl }
    var name: String
    /// Base URL, no trailing slash, token included if the source needs one,
    /// e.g. "http://192.0.2.10:7000/<token>". Pasting a .../manifest.json
    /// URL is allowed; it gets normalized on save.
    var baseUrl: String
    var enabled: Bool = true
}
