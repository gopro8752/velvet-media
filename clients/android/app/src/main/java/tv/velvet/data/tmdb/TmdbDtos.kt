package tv.velvet.data.tmdb

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Wire DTOs for TMDB v3. Field names verified against live responses (curl) on 2026-06-09:
 * trending/{all,movie,tv}, discover/{movie,tv}, movie & tv details with append_to_response,
 * tv season, find/{imdb_id}, search/multi. Unknown keys are ignored by the shared Json.
 */

@Serializable
internal data class TmdbPageDto(
    val page: Int = 1,
    val results: List<TmdbMediaDto> = emptyList(),
    @SerialName("total_pages") val totalPages: Int = 1,
)

/** One entry of any TMDB list/discover/trending/search result. Movie OR tv fields populated. */
@Serializable
internal data class TmdbMediaDto(
    val id: Int = 0,
    val title: String? = null,                                   // movies
    val name: String? = null,                                    // tv
    @SerialName("original_title") val originalTitle: String? = null,
    @SerialName("original_name") val originalName: String? = null,
    @SerialName("original_language") val originalLanguage: String? = null,
    @SerialName("media_type") val mediaType: String? = null,     // trending/all, search/multi, find
    @SerialName("release_date") val releaseDate: String? = null, // movies "2024-03-01"
    @SerialName("first_air_date") val firstAirDate: String? = null, // tv
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("backdrop_path") val backdropPath: String? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
    @SerialName("vote_count") val voteCount: Int = 0,
    val overview: String? = null,
    @SerialName("genre_ids") val genreIds: List<Int> = emptyList(),
)

@Serializable
internal data class TmdbGenreDto(val id: Int = 0, val name: String = "")

@Serializable
internal data class TmdbExternalIdsDto(@SerialName("imdb_id") val imdbId: String? = null)

@Serializable
internal data class TmdbImageDto(
    @SerialName("file_path") val filePath: String = "",
    @SerialName("iso_639_1") val iso639: String? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
)

@Serializable
internal data class TmdbImagesDto(val logos: List<TmdbImageDto> = emptyList())

@Serializable
internal data class TmdbCastDto(
    val name: String = "",
    val character: String? = null,
    @SerialName("profile_path") val profilePath: String? = null,
    val order: Int = Int.MAX_VALUE,
)

@Serializable
internal data class TmdbCreditsDto(val cast: List<TmdbCastDto> = emptyList())

@Serializable
internal data class TmdbReleaseDatesDto(val results: List<TmdbReleaseDatesRegionDto> = emptyList())

@Serializable
internal data class TmdbReleaseDatesRegionDto(
    @SerialName("iso_3166_1") val region: String = "",
    @SerialName("release_dates") val releaseDates: List<TmdbReleaseDateDto> = emptyList(),
)

@Serializable
internal data class TmdbReleaseDateDto(
    val certification: String = "",
    // 1 premiere, 2 limited theatrical, 3 theatrical, 4 digital, 5 physical, 6 TV
    val type: Int = 0,
    @SerialName("release_date") val releaseDate: String? = null,
)

@Serializable
internal data class TmdbContentRatingsDto(val results: List<TmdbContentRatingDto> = emptyList())

@Serializable
internal data class TmdbContentRatingDto(
    @SerialName("iso_3166_1") val region: String = "",
    val rating: String = "",
)

@Serializable
internal data class TmdbSeasonSummaryDto(
    @SerialName("season_number") val seasonNumber: Int = 0,
    val name: String = "",
    @SerialName("episode_count") val episodeCount: Int = 0,
    @SerialName("poster_path") val posterPath: String? = null,
)

@Serializable
internal data class TmdbMovieDetailsDto(
    val id: Int = 0,
    val title: String? = null,
    @SerialName("original_title") val originalTitle: String? = null,
    @SerialName("release_date") val releaseDate: String? = null,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("backdrop_path") val backdropPath: String? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
    val overview: String? = null,
    val genres: List<TmdbGenreDto> = emptyList(),
    val runtime: Int? = null,
    val tagline: String? = null,
    @SerialName("imdb_id") val imdbId: String? = null,
    @SerialName("external_ids") val externalIds: TmdbExternalIdsDto? = null,
    val images: TmdbImagesDto? = null,
    val credits: TmdbCreditsDto? = null,
    @SerialName("release_dates") val releaseDates: TmdbReleaseDatesDto? = null,
    val similar: TmdbPageDto? = null,
)

@Serializable
internal data class TmdbTvDetailsDto(
    val id: Int = 0,
    val name: String? = null,
    @SerialName("original_name") val originalName: String? = null,
    @SerialName("first_air_date") val firstAirDate: String? = null,
    @SerialName("last_air_date") val lastAirDate: String? = null,
    val status: String? = null,                       // "Ended", "Returning Series", "Canceled"
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("backdrop_path") val backdropPath: String? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
    val overview: String? = null,
    val genres: List<TmdbGenreDto> = emptyList(),
    @SerialName("episode_run_time") val episodeRunTime: List<Int> = emptyList(),
    val tagline: String? = null,
    @SerialName("external_ids") val externalIds: TmdbExternalIdsDto? = null,
    val images: TmdbImagesDto? = null,
    val credits: TmdbCreditsDto? = null,
    @SerialName("content_ratings") val contentRatings: TmdbContentRatingsDto? = null,
    val similar: TmdbPageDto? = null,
    val seasons: List<TmdbSeasonSummaryDto> = emptyList(),
)

@Serializable
internal data class TmdbSeasonDetailsDto(val episodes: List<TmdbEpisodeDto> = emptyList())

@Serializable
internal data class TmdbEpisodeDto(
    @SerialName("season_number") val seasonNumber: Int = 0,
    @SerialName("episode_number") val episodeNumber: Int = 0,
    val name: String? = null,
    val overview: String? = null,
    @SerialName("still_path") val stillPath: String? = null,
    val runtime: Int? = null,
    @SerialName("air_date") val airDate: String? = null,
)

@Serializable
internal data class TmdbFindResultsDto(
    @SerialName("movie_results") val movieResults: List<TmdbMediaDto> = emptyList(),
    @SerialName("tv_results") val tvResults: List<TmdbMediaDto> = emptyList(),
)
