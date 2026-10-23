package tv.velvet.data.model

import kotlinx.serialization.Serializable

enum class MediaType(val key: String) {
    MOVIE("movie"), SHOW("show");

    companion object {
        fun fromKey(key: String): MediaType = entries.first { it.key == key }
    }
}

/** A movie or show as shown on cards and rows. All image URLs are absolute. */
data class MediaItem(
    val id: Int,                       // TMDB id
    val type: MediaType,
    val title: String,
    val year: String? = null,          // "2024" or "2019–2023"
    val posterUrl: String? = null,     // ~w500, 2:3
    val backdropUrl: String? = null,   // ~w1280, 16:9
    val logoUrl: String? = null,       // transparent PNG title logo, if fetched
    val rating: Double? = null,        // TMDB 0..10
    val overview: String? = null,
    val genres: List<String> = emptyList(),
    val runtimeMinutes: Int? = null,
    val imdbId: String? = null,        // "tt0903747" — required for stream lookup
    val rankInRow: Int? = null,        // 1-based, for Top 10 numeral cards
)

data class CastMember(val name: String, val role: String?, val profileUrl: String?)

data class Season(
    val number: Int,
    val name: String,
    val episodeCount: Int,
    val posterUrl: String?,
)

data class Episode(
    val season: Int,
    val number: Int,
    val title: String,
    val overview: String? = null,
    val stillUrl: String? = null,      // 16:9 episode still
    val runtimeMinutes: Int? = null,
    val airDate: String? = null,       // "2024-03-01"
)

/** Full details for the details screen. [item] carries logoUrl + imdbId here. */
data class MediaDetails(
    val item: MediaItem,
    val tagline: String? = null,
    val certification: String? = null, // "PG-13", "TV-MA"
    val cast: List<CastMember> = emptyList(),
    val seasons: List<Season> = emptyList(),   // empty for movies
    val similar: List<MediaItem> = emptyList(),
    /**
     * False for movies still exclusively in theaters (no digital/physical release yet) —
     * nothing on usenet to stream, so heroes/billboards must not tease them.
     * Always true for shows.
     */
    val digitallyAvailable: Boolean = true,
)

/** One playable stream resolved by a stream source (e.g. usenet-streamer). */
data class StreamOption(
    val url: String,
    val title: String,                 // display line: filename or quality summary
    val quality: String? = null,       // "2160p", "1080p", "720p"
    val sizeBytes: Long? = null,
    val sourceName: String,            // which configured source produced it
    val bingeGroup: String? = null,    // same group => same release chain for autoplay
    val headers: Map<String, String> = emptyMap(),
    val sourceReadiness: SourceReadiness? = null,
    val readinessObservedAtMs: Long = 0,
)

@Serializable
data class SourceReadiness(val status: String = "unverified", val retryAfterSeconds: Long? = null)

enum class RowStyle { POSTER, LANDSCAPE, TOP10 }

/**
 * A home-screen row. The full set lives in TmdbRepository.allRows;
 * the user's enabled subset + order lives in SettingsRepository.rowOrder.
 * "continue_watching" and "my_list" are special-cased (local data, not TMDB).
 */
data class RowSpec(
    val id: String,
    val title: String,
    val style: RowStyle,
)

/** Identity of a playable thing. For movies season/episode are null. */
data class PlayTarget(
    val mediaId: Int,
    val type: MediaType,
    val season: Int? = null,
    val episode: Int? = null,
    val queueSessionId: String? = null,
    val queueIndex: Int? = null,
    val handoffId: String? = null,
)

@Serializable
data class StreamSourceConfig(
    val name: String,
    /** Base URL, no trailing slash, token included if the source needs one,
     *  e.g. "https://provider.example.com/<token>". Pasting a full .../manifest.json
     *  URL is allowed; it gets normalized on save. */
    val baseUrl: String,
    val enabled: Boolean = true,
)
