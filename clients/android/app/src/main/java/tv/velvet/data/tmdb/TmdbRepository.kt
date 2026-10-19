package tv.velvet.data.tmdb

import tv.velvet.data.model.Episode
import tv.velvet.data.model.MediaDetails
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.RowSpec

/**
 * Native TMDB-backed discovery. Implementation: TmdbRepositoryImpl in this package.
 *
 * Contract notes for the implementation:
 *  - All requests use api.themoviedb.org/3 with the api_key query param from SettingsRepository.
 *  - Image URLs are built as https://image.tmdb.org/t/p/{size}{path}
 *    (posters w500, backdrops w1280, logos w500 preferring PNG, stills w400, profiles w185).
 *  - Every MediaItem MUST have title/year/rating populated — cards always show them.
 *  - details() must fetch external_ids (imdbId) and images (logo) via append_to_response.
 *  - In-memory LRU caching per (rowId,page) and per details id; this app restarts rarely.
 *  - Availability gate: every movie discover row must send with_release_type=4|5 scoped by
 *    region=US AND release_date.lte=today (TMDB ignores with_release_type unless it is
 *    region-scoped with a release_date bound), and /trending-backed rows must drop movies
 *    whose details().digitallyAvailable is false. Home never shows what usenet can't serve.
 *  - rowItems() THROWS on fetch/parse failure — an empty list means "genuinely nothing",
 *    never "the network blipped", so the caller can render a real retry state.
 *  - Row ids are persisted in settings: "trending_movies" was renamed "popular_now" in
 *    v1.2.0 and stored orders swap it in place on read.
 */
interface TmdbRepository {

    /**
     * All rows Velvet knows how to render, in default order. Stable ids — stored in settings.
     * The seasonal/holiday rows lead the list so an ACTIVE one lands near the top of Home;
     * callers MUST hide seasonal rows that [isSeasonalRowActive] rejects.
     */
    val allRows: List<RowSpec>

    /**
     * Ids of the seasonal/holiday rows inside [allRows] — the subset governed by
     * [isSeasonalRowActive]. Everything else in [allRows] is always eligible.
     */
    fun seasonalRowIds(): List<String>

    /**
     * True when [rowId] is a seasonal row whose calendar window contains [today]
     * (device-local date). False for any non-seasonal id, so it doubles as
     * "is this row currently allowed on Home / enabled-by-default in Settings".
     * Windows: Halloween Aug 1–Oct 31, Thanksgiving Nov 1–30, Christmas Nov 15–Dec 31,
     * New Year's Dec 26–Jan 5, Valentine's Feb 1–15.
     */
    fun isSeasonalRowActive(rowId: String, today: java.time.LocalDate = java.time.LocalDate.now()): Boolean

    /**
     * Items for a TMDB-backed row. Not called for continue_watching / my_list. Page is 1-based.
     * Discover-backed rows rotate the page they actually fetch once per day for variety, so
     * page 1 is "today's slice", not literally TMDB page 1.
     */
    suspend fun rowItems(rowId: String, page: Int = 1): List<MediaItem>

    suspend fun details(id: Int, type: tv.velvet.data.model.MediaType): MediaDetails

    /**
     * Episodes of one season. THROWS on fetch/parse failure — callers must not conflate
     * "request failed" with "season has no episodes" (autoplay would skip seasons).
     */
    suspend fun episodes(showId: Int, season: Int): List<Episode>

    suspend fun search(query: String): List<MediaItem>

    /** Resolve TMDB id from an IMDb id (find endpoint) — used by deep links if ever needed. */
    suspend fun findByImdb(imdbId: String): MediaItem?
}
