import Foundation

/// Wire DTOs for TMDB v3 — a 1:1 port of the Android TmdbDtos.kt. Field names
/// verified against live responses with curl (2026-06-10): trending/{all,movie,tv},
/// discover/{movie,tv}, movie & tv details with append_to_response, tv season,
/// search/multi, movie/{now_playing,upcoming}. Every field is optional so a sparse
/// or null-heavy entry never fails the whole page (mirrors kotlinx defaults).

struct TmdbPageDto: Decodable {
    let page: Int?
    let results: [TmdbMediaDto]?
    let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case page
        case results
        case totalPages = "total_pages"
    }
}

/// One entry of any TMDB list/discover/trending/search result. Movie OR tv fields populated.
struct TmdbMediaDto: Decodable {
    let id: Int?
    let title: String?                 // movies
    let name: String?                  // tv
    let originalTitle: String?
    let originalName: String?
    let originalLanguage: String?
    let mediaType: String?             // trending/all, search/multi, find
    let releaseDate: String?           // movies "2024-03-01"
    let firstAirDate: String?          // tv
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let voteCount: Int?
    let overview: String?
    let genreIds: [Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case originalTitle = "original_title"
        case originalName = "original_name"
        case originalLanguage = "original_language"
        case mediaType = "media_type"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case overview
        case genreIds = "genre_ids"
    }
}

struct TmdbGenreDto: Decodable {
    let id: Int?
    let name: String?
}

struct TmdbExternalIdsDto: Decodable {
    let imdbId: String?

    enum CodingKeys: String, CodingKey {
        case imdbId = "imdb_id"
    }
}

struct TmdbImageDto: Decodable {
    let filePath: String?
    let iso639: String?
    let voteAverage: Double?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case iso639 = "iso_639_1"
        case voteAverage = "vote_average"
    }
}

struct TmdbImagesDto: Decodable {
    let logos: [TmdbImageDto]?
}

struct TmdbCastDto: Decodable {
    let name: String?
    let character: String?
    let profilePath: String?
    let order: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case character
        case profilePath = "profile_path"
        case order
    }
}

struct TmdbCreditsDto: Decodable {
    let cast: [TmdbCastDto]?
}

struct TmdbReleaseDatesDto: Decodable {
    let results: [TmdbReleaseDatesRegionDto]?
}

struct TmdbReleaseDatesRegionDto: Decodable {
    let region: String?
    let releaseDates: [TmdbReleaseDateDto]?

    enum CodingKeys: String, CodingKey {
        case region = "iso_3166_1"
        case releaseDates = "release_dates"
    }
}

struct TmdbReleaseDateDto: Decodable {
    let certification: String?
    /// 1 premiere, 2 limited theatrical, 3 theatrical, 4 digital, 5 physical, 6 TV
    let type: Int?
    let releaseDate: String?           // full ISO timestamp "2016-01-07T00:00:00.000Z"

    enum CodingKeys: String, CodingKey {
        case certification
        case type
        case releaseDate = "release_date"
    }
}

struct TmdbContentRatingsDto: Decodable {
    let results: [TmdbContentRatingDto]?
}

struct TmdbContentRatingDto: Decodable {
    let region: String?
    let rating: String?

    enum CodingKeys: String, CodingKey {
        case region = "iso_3166_1"
        case rating
    }
}

struct TmdbSeasonSummaryDto: Decodable {
    let seasonNumber: Int?
    let name: String?
    let episodeCount: Int?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case seasonNumber = "season_number"
        case name
        case episodeCount = "episode_count"
        case posterPath = "poster_path"
    }
}

struct TmdbMovieDetailsDto: Decodable {
    let id: Int?
    let title: String?
    let originalTitle: String?
    let releaseDate: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let overview: String?
    let genres: [TmdbGenreDto]?
    let runtime: Int?
    let tagline: String?
    let imdbId: String?
    let externalIds: TmdbExternalIdsDto?
    let images: TmdbImagesDto?
    let credits: TmdbCreditsDto?
    let releaseDates: TmdbReleaseDatesDto?
    let similar: TmdbPageDto?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case overview
        case genres
        case runtime
        case tagline
        case imdbId = "imdb_id"
        case externalIds = "external_ids"
        case images
        case credits
        case releaseDates = "release_dates"
        case similar
    }
}

struct TmdbTvDetailsDto: Decodable {
    let id: Int?
    let name: String?
    let originalName: String?
    let firstAirDate: String?
    let lastAirDate: String?
    let status: String?                // "Ended", "Returning Series", "Canceled"
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let overview: String?
    let genres: [TmdbGenreDto]?
    let episodeRunTime: [Int]?
    let tagline: String?
    let externalIds: TmdbExternalIdsDto?
    let images: TmdbImagesDto?
    let credits: TmdbCreditsDto?
    let contentRatings: TmdbContentRatingsDto?
    let similar: TmdbPageDto?
    let seasons: [TmdbSeasonSummaryDto]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case originalName = "original_name"
        case firstAirDate = "first_air_date"
        case lastAirDate = "last_air_date"
        case status
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case overview
        case genres
        case episodeRunTime = "episode_run_time"
        case tagline
        case externalIds = "external_ids"
        case images
        case credits
        case contentRatings = "content_ratings"
        case similar
        case seasons
    }
}

struct TmdbSeasonDetailsDto: Decodable {
    let episodes: [TmdbEpisodeDto]?
}

struct TmdbEpisodeDto: Decodable {
    let seasonNumber: Int?
    let episodeNumber: Int?
    let name: String?
    let overview: String?
    let stillPath: String?
    let runtime: Int?
    let airDate: String?

    enum CodingKeys: String, CodingKey {
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case name
        case overview
        case stillPath = "still_path"
        case runtime
        case airDate = "air_date"
    }
}
