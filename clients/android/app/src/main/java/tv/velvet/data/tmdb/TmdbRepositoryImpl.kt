package tv.velvet.data.tmdb

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import tv.velvet.data.model.CastMember
import tv.velvet.data.model.Episode
import tv.velvet.data.model.MediaDetails
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.RowSpec
import tv.velvet.data.model.RowStyle
import tv.velvet.data.model.Season
import tv.velvet.data.net.await
import tv.velvet.data.settings.SettingsRepository
import java.io.IOException
import java.time.LocalDate
import java.time.MonthDay
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * TMDB-backed discovery. Every endpoint + query recipe here was verified against the
 * live API with curl (2026-06-09; the v1.2.0 availability gate, popular_now, Top 10
 * filter and the five holiday keyword rows re-verified 2026-08-06) — see TmdbDtos.kt
 * for the matching response shapes.
 *
 * Home rules (v1.2.0): every movie discover row carries the availability gate so nothing
 * theatrical-only reaches Home, discover rows rotate their page daily for variety, and
 * seasonal rows are only shown inside their calendar window (see [isSeasonalRowActive]).
 *
 * Caching: synchronized LRU maps — rows ~30 min TTL per (rowId, page); movie details
 * unlimited TTL (effectively immutable), show details ~4 h TTL (the process can stay
 * resident for weeks on a TV, and returning shows gain seasons/ratings change);
 * episodes ~30 min TTL (airing shows gain episodes).
 */
class TmdbRepositoryImpl(
    private val client: OkHttpClient,
    private val json: Json,
    private val settings: SettingsRepository,
) : TmdbRepository {

    private companion object {
        const val BASE = "https://api.themoviedb.org/3"
        const val IMG = "https://image.tmdb.org/t/p"
        const val ROW_TTL_MS = 30L * 60L * 1000L
        const val SHOW_DETAILS_TTL_MS = ROW_TTL_MS * 8 // 4 h

        /**
         * Theatrical lag: a movie whose primary release is younger than this is still in
         * its theatrical window. NOT the availability gate any more (see [availabilityGate]
         * — the date bound alone let Toy Story 5 and every other theatrical-only title
         * through); it now only marks which rows are pure ERA rows (classics /
         * modern_classics), whose own `primary_release_date.lte` is older than this and so
         * cannot possibly contain something still in cinemas.
         */
        const val AVAILABILITY_LAG_DAYS = 45

        /** Daily page rotation window for discover rows (spec §4e): pages 1..3. */
        const val PAGE_ROTATION_SPAN = 3

        /**
         * Below this, a rotated page is a thin tail (the Valentine's keyword is three pages
         * deep) — refetch the page that was actually asked for rather than show a stub row.
         */
        const val MIN_ROTATED_ROW_ITEMS = 10

        /** Top 10: how many trending candidates we're willing to availability-check. */
        const val TOP10_CANDIDATES = 15
        const val TOP10_SIZE = 10

        // Seasonal keyword ids — verified live via /search/keyword (2026-08-06).
        // "valentine's day" (160404) is the usable one: plain "valentine" (251912) has a
        // single gated result and "valentines" (366924) has none.
        const val KEYWORD_HALLOWEEN = "3335"
        const val KEYWORD_THANKSGIVING = "4543"
        const val KEYWORD_CHRISTMAS = "207317"
        const val KEYWORD_NEW_YEAR = "252123"
        const val KEYWORD_VALENTINES = "160404"

        /**
         * The `christmas` keyword is a loose tag: any film with a Christmas SCENE carries
         * it, so popularity alone opened the row with Harry Potter and the Chamber of
         * Secrets, Iron Man 3, Die Hard and Eyes Wide Shut (verified 2026-08-06). Narrowing
         * to family/comedy/romance leaves 234 titles and a head that reads like a Christmas
         * row: Red One, The Grinch, It's a Wonderful Life, The Nightmare Before Christmas,
         * Love Actually, Christmas Vacation. The other four keywords need no such help.
         */
        const val CHRISTMAS_GENRES = "10751|35|10749"
    }

    /** A calendar window that may wrap the year boundary (New Year's does). */
    private class SeasonalWindow(private val start: MonthDay, private val end: MonthDay) {
        fun contains(day: MonthDay): Boolean =
            if (start <= end) day >= start && day <= end else day >= start || day <= end
    }

    /**
     * Seasonal rows and their active windows (device-local date, spec §4f). Iteration order
     * is the display order used in [allRows]: in the two overlaps (Nov 15–30 and Dec 26–31)
     * the nearer holiday leads.
     */
    private val seasonalWindows: Map<String, SeasonalWindow> = linkedMapOf(
        // Aug 1, not late September: spooky season starts in August in this house.
        "holiday_halloween" to SeasonalWindow(MonthDay.of(8, 1), MonthDay.of(10, 31)),
        "holiday_thanksgiving" to SeasonalWindow(MonthDay.of(11, 1), MonthDay.of(11, 30)),
        "holiday_christmas" to SeasonalWindow(MonthDay.of(11, 15), MonthDay.of(12, 31)),
        "holiday_newyear" to SeasonalWindow(MonthDay.of(12, 26), MonthDay.of(1, 5)),
        "holiday_valentines" to SeasonalWindow(MonthDay.of(2, 1), MonthDay.of(2, 15)),
    )

    private val seasonalRows: List<RowSpec> = listOf(
        RowSpec("holiday_halloween", "Halloween Frights", RowStyle.POSTER),
        RowSpec("holiday_thanksgiving", "Thanksgiving Picks", RowStyle.POSTER),
        RowSpec("holiday_christmas", "Christmas Movies", RowStyle.POSTER),
        RowSpec("holiday_newyear", "New Year's Eve", RowStyle.POSTER),
        RowSpec("holiday_valentines", "Valentine's Day", RowStyle.POSTER),
    )

    /**
     * Rows fetched from /discover — these rotate their page daily (spec §4e). Endpoint-backed
     * rows are excluded: Top 10 must be the actual top 10, /trending has no useful depth,
     * and now_playing/upcoming are already time-windowed by TMDB.
     */
    private val rotatingRows: Set<String> = setOf(
        "popular_now", "new_to_stream", "new_shows", "bingeworthy", "acclaimed", "hidden_gems",
        "action", "comedy", "thrillers", "scifi_fantasy", "horror", "feel_good", "date_night",
        "animation_family", "docs", "anime", "modern_classics", "classics",
    ) + seasonalWindows.keys

    private val rowCache = TtlLruCache<String, List<MediaItem>>(maxEntries = 128, ttlMillis = ROW_TTL_MS)
    private val movieDetailsCache = TtlLruCache<String, MediaDetails>(maxEntries = 192, ttlMillis = null)
    private val showDetailsCache = TtlLruCache<String, MediaDetails>(maxEntries = 64, ttlMillis = SHOW_DETAILS_TTL_MS)
    private val episodesCache = TtlLruCache<String, List<Episode>>(maxEntries = 128, ttlMillis = ROW_TTL_MS)

    // TMDB's official genre lists (stable ids). "Science Fiction" shortened for meta lines.
    private val movieGenres = mapOf(
        28 to "Action", 12 to "Adventure", 16 to "Animation", 35 to "Comedy", 80 to "Crime",
        99 to "Documentary", 18 to "Drama", 10751 to "Family", 14 to "Fantasy", 36 to "History",
        27 to "Horror", 10402 to "Music", 9648 to "Mystery", 10749 to "Romance",
        878 to "Sci-Fi", 10770 to "TV Movie", 53 to "Thriller", 10752 to "War", 37 to "Western",
    )
    private val tvGenres = mapOf(
        10759 to "Action & Adventure", 16 to "Animation", 35 to "Comedy", 80 to "Crime",
        99 to "Documentary", 18 to "Drama", 10751 to "Family", 10762 to "Kids",
        9648 to "Mystery", 10763 to "News", 10764 to "Reality", 10765 to "Sci-Fi & Fantasy",
        10766 to "Soap", 10767 to "Talk", 10768 to "War & Politics", 37 to "Western",
    )

    /**
     * The home funnel, ranked by intent: in-season holiday collections → what's hot →
     * what's new → what's bingeable → what's good → moods/genres → timeless →
     * not-yet-streamable parked last.
     *
     * Seasonal rows lead the list on purpose: the UI shows only the ones
     * [isSeasonalRowActive] accepts, so keeping them first puts an active holiday row
     * near the top of Home (after Continue Watching / My List) and costs nothing the
     * other ~10 months of the year.
     */
    override val allRows: List<RowSpec> = seasonalRows + listOf(
        RowSpec("top10_today", "Top 10 Today", RowStyle.TOP10),
        RowSpec("popular_now", "Popular Now", RowStyle.LANDSCAPE),
        RowSpec("trending_shows", "Trending Shows", RowStyle.LANDSCAPE),
        RowSpec("new_to_stream", "New to Stream", RowStyle.POSTER),
        RowSpec("new_shows", "New & Returning Shows", RowStyle.POSTER),
        RowSpec("bingeworthy", "Bingeworthy Shows", RowStyle.POSTER),
        RowSpec("acclaimed", "Critically Acclaimed", RowStyle.POSTER),
        RowSpec("hidden_gems", "Hidden Gems", RowStyle.POSTER),
        RowSpec("action", "Action & Adrenaline", RowStyle.POSTER),
        RowSpec("comedy", "Comedy Night", RowStyle.POSTER),
        RowSpec("thrillers", "Thrillers & Crime", RowStyle.POSTER),
        RowSpec("scifi_fantasy", "Sci-Fi & Fantasy", RowStyle.POSTER),
        RowSpec("horror", "Horror After Dark", RowStyle.POSTER),
        RowSpec("feel_good", "Feel-Good Picks", RowStyle.POSTER),
        RowSpec("date_night", "Date Night", RowStyle.POSTER),
        RowSpec("animation_family", "Animation & Family", RowStyle.POSTER),
        RowSpec("docs", "True Stories & Docs", RowStyle.POSTER),
        RowSpec("anime", "Anime", RowStyle.POSTER),
        RowSpec("modern_classics", "Modern Classics", RowStyle.POSTER),
        RowSpec("classics", "All-Time Classics", RowStyle.POSTER),
        RowSpec("in_theaters", "In Theaters Now", RowStyle.POSTER),
        RowSpec("coming_soon", "Coming Soon", RowStyle.POSTER),
    )

    override fun seasonalRowIds(): List<String> = seasonalWindows.keys.toList()

    override fun isSeasonalRowActive(rowId: String, today: LocalDate): Boolean =
        seasonalWindows[rowId]?.contains(MonthDay.from(today)) == true

    override suspend fun rowItems(rowId: String, page: Int): List<MediaItem> {
        // Spec §4f: a seasonal row outside its window is hidden ENTIRELY. The UI filters
        // them out of Home and Settings; the data layer refuses as well, so a stored row
        // order that still pins one can't put "Christmas Movies" on screen in August.
        if (rowId in seasonalWindows && !isSeasonalRowActive(rowId, LocalDate.now())) return emptyList()
        val fetchPage = rotatedPage(rowId, page)
        val cacheKey = "$rowId#$fetchPage" // rotation changes the key, so a new day refetches
        rowCache.get(cacheKey)?.let { return it }
        // Fetch failures PROPAGATE. Swallowing them here (returning emptyList) made every
        // row resolve to Loaded(empty) with TMDB unreachable, so RowUiState.Failed was
        // unreachable, homeUnavailable could never flip and the Retry state never showed —
        // Home was just a silent black page. HomeViewModel.fetchRow is the ONE place that
        // decides Failed; an empty list from here always means "genuinely nothing".
        val rotated = fetchRow(rowId, fetchPage)
        // A rotated page can overshoot a short result set (the New Year's keyword row is
        // one page deep, Valentine's three) — fall back to the page actually asked for
        // instead of collapsing the row on two days out of three. This refetch is an
        // enhancement, not the row: if IT blips, keep the page we already have.
        val items = if (rotated.size < MIN_ROTATED_ROW_ITEMS && fetchPage != page) {
            val fallback = try {
                fetchRow(rowId, page)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                emptyList()
            }
            fallback.ifEmpty { rotated }
        } else {
            rotated
        }
        if (items.isNotEmpty()) rowCache.put(cacheKey, items)
        return items
    }

    private suspend fun fetchRow(rowId: String, page: Int): List<MediaItem> = when (rowId) {
        "top10_today" -> if (page > 1) emptyList() else top10Today()

        // Was raw /trending/movie/week, which is mostly titles still in theaters (spec §4b).
        // Discover + the availability gate keeps the row hot AND watchable.
        "popular_now" -> discoverMovies(
            page,
            "sort_by" to "popularity.desc",
            "vote_count.gte" to "50",
        )

        // Compatibility alias: the row was renamed popular_now in v1.2.0 and stored row
        // orders migrate on read, but an un-migrated id must still render something.
        "trending_movies" -> fetchRow("popular_now", page)

        "trending_shows" -> listPage(
            "trending/tv/week", MediaType.SHOW, page,
            predicate = { it.originalLanguage == "en" },
        )

        // Fresh digital releases — for a usenet pipeline this is "what just hit the indexers".
        // Its own region-scoped digital window (type 4|5 released in the last 75 days, never
        // in the future) is the availability gate, only narrower, so [availabilityGate]
        // leaves it alone rather than widening release_date.gte back to the epoch. This is
        // the recipe the gate was modelled on (verified: Supergirl, primary 2026-06-24,
        // US digital 2026-07-28, is present here and in every gated row).
        "new_to_stream" -> discoverMovies(
            page,
            "with_release_type" to "4|5",
            "region" to "US",
            "release_date.gte" to isoDate(-75),
            "release_date.lte" to isoDate(0),
            "sort_by" to "popularity.desc",
            "with_original_language" to "en",
        )

        "new_shows" -> discoverShows(
            page,
            "air_date.gte" to isoDate(-14),
            "air_date.lte" to isoDate(0),
            "sort_by" to "popularity.desc",
            "with_original_language" to "en",
        )

        "bingeworthy" -> discoverShows(
            page,
            "vote_count.gte" to "1000",
            "vote_average.gte" to "7.5",
            "sort_by" to "popularity.desc",
            "with_original_language" to "en",
        )

        "acclaimed" -> discoverMovies(
            page,
            "vote_count.gte" to "1500",
            "vote_average.gte" to "7.8",
            "sort_by" to "popularity.desc",
            "with_original_language" to "en",
        )

        "hidden_gems" -> discoverMovies(
            page,
            "vote_average.gte" to "7.4",
            "vote_count.gte" to "50",
            "vote_count.lte" to "400",
            "sort_by" to "popularity.desc",
            "with_original_language" to "en",
        )

        // Mood/genre rows — popularity-ranked with quality floors so they never fill with junk.
        "action" -> movieGenreRow(page, "28|12")
        "comedy" -> movieGenreRow(page, "35")
        "thrillers" -> movieGenreRow(page, "53|80")
        "scifi_fantasy" -> movieGenreRow(page, "878|14")
        "horror" -> movieGenreRow(page, "27", minRating = "6.0")
        "feel_good" -> movieGenreRow(page, "35|10751|10402", minRating = "7.0")
        "date_night" -> movieGenreRow(page, "10749")
        "animation_family" -> movieGenreRow(page, "16|10751")
        "docs" -> movieGenreRow(page, "99", minRating = "7.0", minVotes = "100")

        "anime" -> discoverShows(
            page,
            "with_genres" to "16",
            "with_origin_country" to "JP",
            "vote_count.gte" to "200",
            "sort_by" to "popularity.desc",
        )

        "modern_classics" -> discoverMovies(
            page,
            "primary_release_date.gte" to "1995-01-01",
            "primary_release_date.lte" to "2015-12-31",
            "vote_count.gte" to "2500",
            "vote_average.gte" to "7.5",
            "sort_by" to "vote_average.desc",
            "with_original_language" to "en",
        )

        "classics" -> discoverMovies(
            page,
            "primary_release_date.lte" to "1994-12-31",
            "vote_count.gte" to "1500",
            "vote_average.gte" to "7.8",
            "sort_by" to "vote_average.desc",
            "with_original_language" to "en",
        )

        // Seasonal collections (spec §4f). Keyword ids verified live; the availability gate
        // rides along via discoverMovies, so December's picks are all actually streamable.
        "holiday_halloween" -> seasonalRow(page, KEYWORD_HALLOWEEN)
        "holiday_thanksgiving" -> seasonalRow(page, KEYWORD_THANKSGIVING)
        "holiday_christmas" -> seasonalRow(page, KEYWORD_CHRISTMAS, genres = CHRISTMAS_GENRES)
        "holiday_newyear" -> seasonalRow(page, KEYWORD_NEW_YEAR)
        "holiday_valentines" -> seasonalRow(page, KEYWORD_VALENTINES)

        "in_theaters" -> listPage(
            "movie/now_playing", MediaType.MOVIE, page,
            params = mapOf("region" to "US"),
        )

        "coming_soon" -> {
            val today = isoDate(0)
            listPage(
                "movie/upcoming", MediaType.MOVIE, page,
                params = mapOf("region" to "US"),
                predicate = { (it.releaseDate ?: "") > today }, // future dates only
            )
        }

        else -> emptyList()
    }

    override suspend fun details(id: Int, type: MediaType): MediaDetails {
        val cacheKey = "${type.key}/$id"
        val cache = if (type == MediaType.MOVIE) movieDetailsCache else showDetailsCache
        cache.get(cacheKey)?.let { return it }
        val details = when (type) {
            MediaType.MOVIE -> fetchMovieDetails(id)
            MediaType.SHOW -> fetchShowDetails(id)
        }
        cache.put(cacheKey, details)
        return details
    }

    private suspend fun fetchMovieDetails(id: Int): MediaDetails {
        val body = httpGet(
            "movie/$id",
            mapOf(
                "append_to_response" to "external_ids,images,credits,release_dates,similar",
                "include_image_language" to "en,null",
            ),
        )
        val dto = json.decodeFromString(TmdbMovieDetailsDto.serializer(), body)
        val certification = dto.releaseDates?.results
            ?.firstOrNull { it.region == "US" }
            ?.releaseDates
            ?.firstNotNullOfOrNull { it.certification.takeIf(String::isNotBlank) }
        val digitallyAvailable = isDigitallyAvailable(dto)
        val item = MediaItem(
            id = dto.id,
            type = MediaType.MOVIE,
            title = dto.title ?: dto.originalTitle ?: "Untitled",
            year = yearOf(dto.releaseDate),
            posterUrl = dto.posterPath?.let { "$IMG/w500$it" },
            backdropUrl = dto.backdropPath?.let { "$IMG/w1280$it" },
            logoUrl = pickLogo(dto.images),
            rating = dto.voteAverage.takeIf { it > 0.0 },
            overview = dto.overview?.takeIf(String::isNotBlank),
            genres = dto.genres.map { shortGenre(it.name) },
            runtimeMinutes = dto.runtime?.takeIf { it > 0 },
            imdbId = dto.externalIds?.imdbId ?: dto.imdbId,
        )
        return MediaDetails(
            item = item,
            tagline = dto.tagline?.takeIf(String::isNotBlank),
            certification = certification,
            cast = mapCast(dto.credits),
            seasons = emptyList(),
            similar = dto.similar?.results.orEmpty()
                .mapNotNull { it.toMediaItem(MediaType.MOVIE) }
                .take(20),
            digitallyAvailable = digitallyAvailable,
        )
    }

    /**
     * A movie is streamable once it has a digital/physical/TV release that's out, or its
     * theatrical run is old enough (~100 days) that a digital release certainly exists.
     * Sparse TMDB data (older/obscure titles often lack type-4 entries) gets the benefit
     * of the doubt via the age fallback on the primary release date.
     */
    private fun isDigitallyAvailable(dto: TmdbMovieDetailsDto): Boolean {
        val today = isoDate(0)
        val theatricalCutoff = isoDate(-100)
        val all = dto.releaseDates?.results.orEmpty().flatMap { it.releaseDates }
        if (all.isEmpty()) {
            val released = dto.releaseDate?.takeIf(String::isNotBlank) ?: return true
            return released <= theatricalCutoff
        }
        val out = all.filter { !it.releaseDate.isNullOrBlank() && it.releaseDate.substring(0, 10) <= today }
        if (out.any { it.type in 4..6 }) return true
        return out.any { it.type in 1..3 && it.releaseDate!!.substring(0, 10) <= theatricalCutoff }
    }

    private suspend fun fetchShowDetails(id: Int): MediaDetails {
        val body = httpGet(
            "tv/$id",
            mapOf(
                "append_to_response" to "external_ids,images,credits,content_ratings,similar",
                "include_image_language" to "en,null",
            ),
        )
        val dto = json.decodeFromString(TmdbTvDetailsDto.serializer(), body)
        val firstYear = yearOf(dto.firstAirDate)
        val lastYear = yearOf(dto.lastAirDate)
        val ended = dto.status == "Ended" || dto.status == "Canceled"
        val year = when {
            firstYear == null -> null
            ended && lastYear != null && lastYear != firstYear -> "$firstYear–$lastYear"
            else -> firstYear
        }
        val certification = dto.contentRatings?.results
            ?.firstOrNull { it.region == "US" }
            ?.rating?.takeIf(String::isNotBlank)
        val item = MediaItem(
            id = dto.id,
            type = MediaType.SHOW,
            title = dto.name ?: dto.originalName ?: "Untitled",
            year = year,
            posterUrl = dto.posterPath?.let { "$IMG/w500$it" },
            backdropUrl = dto.backdropPath?.let { "$IMG/w1280$it" },
            logoUrl = pickLogo(dto.images),
            rating = dto.voteAverage.takeIf { it > 0.0 },
            overview = dto.overview?.takeIf(String::isNotBlank),
            genres = dto.genres.map { shortGenre(it.name) },
            runtimeMinutes = dto.episodeRunTime.firstOrNull { it > 0 },
            imdbId = dto.externalIds?.imdbId,
        )
        return MediaDetails(
            item = item,
            tagline = dto.tagline?.takeIf(String::isNotBlank),
            certification = certification,
            cast = mapCast(dto.credits),
            seasons = dto.seasons
                .filter { it.seasonNumber > 0 }
                .sortedBy { it.seasonNumber }
                .map { season ->
                    Season(
                        number = season.seasonNumber,
                        name = season.name.ifBlank { "Season ${season.seasonNumber}" },
                        episodeCount = season.episodeCount,
                        posterUrl = (season.posterPath ?: dto.posterPath)?.let { "$IMG/w500$it" },
                    )
                },
            similar = dto.similar?.results.orEmpty()
                .mapNotNull { it.toMediaItem(MediaType.SHOW) }
                .take(20),
        )
    }

    override suspend fun episodes(showId: Int, season: Int): List<Episode> {
        val cacheKey = "$showId/$season"
        episodesCache.get(cacheKey)?.let { return it }
        // Failures propagate (see TmdbRepository contract): an empty result must mean
        // "this season really has no episodes", never "the network blipped".
        val body = httpGet("tv/$showId/season/$season", emptyMap())
        val episodes = json.decodeFromString(TmdbSeasonDetailsDto.serializer(), body).episodes
            .filter { it.episodeNumber > 0 }
            .map { ep ->
                Episode(
                    season = ep.seasonNumber,
                    number = ep.episodeNumber,
                    title = ep.name?.takeIf(String::isNotBlank) ?: "Episode ${ep.episodeNumber}",
                    overview = ep.overview?.takeIf(String::isNotBlank),
                    stillUrl = ep.stillPath?.let { "$IMG/w400$it" },
                    runtimeMinutes = ep.runtime?.takeIf { it > 0 },
                    airDate = ep.airDate?.takeIf(String::isNotBlank),
                )
            }
        if (episodes.isNotEmpty()) episodesCache.put(cacheKey, episodes)
        return episodes
    }

    override suspend fun search(query: String): List<MediaItem> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        return try {
            listPage(
                "search/multi", type = null, page = 1,
                params = mapOf("query" to trimmed, "include_adult" to "false"),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            emptyList()
        }
    }

    override suspend fun findByImdb(imdbId: String): MediaItem? = try {
        val body = httpGet("find/$imdbId", mapOf("external_source" to "imdb_id"))
        val dto = json.decodeFromString(TmdbFindResultsDto.serializer(), body)
        val item = dto.movieResults.firstNotNullOfOrNull { it.toMediaItem(MediaType.MOVIE, strict = false) }
            ?: dto.tvResults.firstNotNullOfOrNull { it.toMediaItem(MediaType.SHOW, strict = false) }
        item?.copy(imdbId = imdbId)
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    // ── row helpers ──────────────────────────────────────────────────────────

    /** Movie mood/genre row: popularity-ranked with rating + vote-count floors. */
    private suspend fun movieGenreRow(
        page: Int,
        genres: String,
        minRating: String = "6.3",
        minVotes: String = "300",
    ): List<MediaItem> = discoverMovies(
        page,
        "with_genres" to genres,
        "vote_average.gte" to minRating,
        "vote_count.gte" to minVotes,
        "sort_by" to "popularity.desc",
        "with_original_language" to "en",
    )

    /**
     * Holiday collection row: one verified keyword, popularity-ranked, lightly
     * quality-floored. [genres] narrows keywords that are too loose to carry a row on
     * their own (see [CHRISTMAS_GENRES]).
     */
    private suspend fun seasonalRow(
        page: Int,
        keywordId: String,
        genres: String? = null,
    ): List<MediaItem> = discoverMovies(
        page,
        *listOfNotNull(
            "with_keywords" to keywordId,
            "sort_by" to "popularity.desc",
            "vote_count.gte" to "25",
            genres?.let { "with_genres" to it },
        ).toTypedArray(),
    )

    /**
     * Top 10 Today = /trending/all/day with unavailable movies removed (spec §4a). Shows
     * always pass (an episode that aired is available); movies are checked against the
     * cached details()/digitallyAvailable rule, at most [TOP10_CANDIDATES] of them, and the
     * first [TOP10_SIZE] survivors are ranked 1..10.
     */
    private suspend fun top10Today(): List<MediaItem> =
        keepAvailable(listPage("trending/all/day", type = null, page = 1).take(TOP10_CANDIDATES))
            .take(TOP10_SIZE)
            .mapIndexed { index, item -> item.copy(rankInRow = index + 1) }

    /**
     * Drops movies that aren't out digitally yet, preserving order. Lookups run in parallel
     * (they're the cached details() call, so this is free after the first home load).
     * A lookup that FAILS keeps the item: an unproven title beats a short Top 10, and the
     * hero rotation re-checks digitallyAvailable before it teases anything anyway.
     */
    private suspend fun keepAvailable(items: List<MediaItem>): List<MediaItem> = coroutineScope {
        items.map { item ->
            async {
                if (item.type == MediaType.SHOW) {
                    item
                } else {
                    try {
                        item.takeIf { details(it.id, MediaType.MOVIE).digitallyAvailable }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        item
                    }
                }
            }
        }.awaitAll().filterNotNull()
    }

    /**
     * Deterministic daily page rotation for discover rows (spec §4e) — the same row isn't
     * the identical 20 titles every day. Only the default page-1 request rotates; explicit
     * pagination from a caller is honoured as asked.
     */
    private fun rotatedPage(rowId: String, page: Int): Int {
        if (page != 1 || rowId !in rotatingRows) return page
        val rowHash = rowId.hashCode().toLong() and 0x7fffffffL
        return 1 + ((LocalDate.now().dayOfYear + rowHash) % PAGE_ROTATION_SPAN).toInt()
    }

    private suspend fun discoverMovies(page: Int, vararg params: Pair<String, String>): List<MediaItem> {
        val requested = mapOf(*params)
        val query = requested + availabilityGate(requested) + ("include_adult" to "false")
        return listPage("discover/movie", MediaType.MOVIE, page, query)
    }

    /**
     * The movie availability gate (spec §4a), applied to EVERY movie discover row so a
     * theatrical-only title can never reach Home:
     * `with_release_type=4|5` + `region=US` + `release_date.lte=<today>`
     * — i.e. a US digital/physical release that is already out.
     *
     * The region scoping is load-bearing, not decoration. TMDB only honours
     * `with_release_type` when the query is ALSO scoped by `region` and a `release_date`
     * bound; paired with `primary_release_date.lte` alone it is a NO-OP. Verified live
     * 2026-08-06 on the popular_now recipe: with and without `with_release_type` both
     * returned byte-identical results at total_results=35890, with Toy Story 5 — whose
     * /release_dates carry ONLY theatrical types 1/2/3 — sitting at rank 6. The
     * region-scoped form above drops the same query from 35890 to 9690 results, evicts
     * Toy Story 5, and pulls in titles whose digital release is real and recent
     * (Supergirl, US digital 2026-07-28) — the date bound alone had dropped those for
     * being too NEW while happily keeping the theatrical-only ones.
     *
     * Two kinds of row opt out, both because they establish availability better than the
     * gate can:
     *  - a row that already pins its own release-type window (`new_to_stream`);
     *  - a pure ERA row whose `primary_release_date.lte` is already older than
     *    [AVAILABILITY_LAG_DAYS] (`classics`, `modern_classics`). Nothing inside a
     *    pre-2016 window can still be in cinemas, and the region gate would thin those
     *    rows purely on sparse TMDB release data — verified: it drops The Shawshank
     *    Redemption, The Godfather Part II and 12 Angry Men from All-Time Classics.
     */
    private fun availabilityGate(requested: Map<String, String>): Map<String, String> {
        if (requested.containsKey("with_release_type")) return emptyMap()
        val eraBound = requested["primary_release_date.lte"]
        if (eraBound != null && eraBound <= isoDate(-AVAILABILITY_LAG_DAYS)) return emptyMap()
        return mapOf(
            "with_release_type" to "4|5",
            "region" to "US",
            "release_date.lte" to isoDate(0),
        )
    }

    private suspend fun discoverShows(page: Int, vararg params: Pair<String, String>): List<MediaItem> =
        listPage("discover/tv", MediaType.SHOW, page, mapOf(*params) + ("include_adult" to "false"))

    /**
     * Fetches one page of a list endpoint and maps to MediaItems.
     * [type] null = mixed results, derive per item from media_type (skips persons).
     */
    private suspend fun listPage(
        path: String,
        type: MediaType?,
        page: Int,
        params: Map<String, String> = emptyMap(),
        predicate: (TmdbMediaDto) -> Boolean = { true },
    ): List<MediaItem> {
        val body = httpGet(path, params + ("page" to page.toString()))
        return json.decodeFromString(TmdbPageDto.serializer(), body).results
            .filter(predicate)
            .mapNotNull { it.toMediaItem(type) }
    }

    // ── mapping ──────────────────────────────────────────────────────────────

    /**
     * List-result → MediaItem. [strict] (default) drops items missing a year or artwork,
     * because every card must show title + year and needs an image.
     */
    private fun TmdbMediaDto.toMediaItem(
        forcedType: MediaType?,
        strict: Boolean = true,
    ): MediaItem? {
        val type = forcedType ?: when (mediaType) {
            "movie" -> MediaType.MOVIE
            "tv" -> MediaType.SHOW
            else -> return null // persons etc. in trending/all and search/multi
        }
        val displayTitle = when (type) {
            MediaType.MOVIE -> title ?: originalTitle
            MediaType.SHOW -> name ?: originalName
        } ?: return null
        val date = if (type == MediaType.MOVIE) releaseDate else firstAirDate
        val year = yearOf(date)
        if (strict && (year == null || (posterPath == null && backdropPath == null))) return null
        val genreNames = if (type == MediaType.MOVIE) movieGenres else tvGenres
        return MediaItem(
            id = id,
            type = type,
            title = displayTitle,
            year = year,
            posterUrl = posterPath?.let { "$IMG/w500$it" },
            backdropUrl = backdropPath?.let { "$IMG/w1280$it" },
            rating = voteAverage.takeIf { it > 0.0 },
            overview = overview?.takeIf(String::isNotBlank),
            genres = genreIds.mapNotNull(genreNames::get),
        )
    }

    private fun mapCast(credits: TmdbCreditsDto?): List<CastMember> =
        credits?.cast.orEmpty()
            .sortedBy { it.order }
            .take(20)
            .filter { it.name.isNotBlank() }
            .map { cast ->
                CastMember(
                    name = cast.name,
                    role = cast.character?.takeIf(String::isNotBlank),
                    profileUrl = cast.profilePath?.let { "$IMG/w185$it" },
                )
            }

    /** First English PNG in images.logos, falling back to any PNG. w500. */
    private fun pickLogo(images: TmdbImagesDto?): String? {
        val logos = images?.logos.orEmpty().filter { it.filePath.endsWith(".png", ignoreCase = true) }
        val best = logos.firstOrNull { it.iso639 == "en" } ?: logos.firstOrNull()
        return best?.let { "$IMG/w500${it.filePath}" }
    }

    private fun yearOf(date: String?): String? =
        date?.take(4)?.takeIf { it.length == 4 && it.all(Char::isDigit) }

    private fun shortGenre(name: String): String =
        if (name == "Science Fiction") "Sci-Fi" else name

    private fun isoDate(offsetDays: Int): String {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.add(Calendar.DAY_OF_YEAR, offsetDays)
        return String.format(
            Locale.US, "%04d-%02d-%02d",
            cal.get(Calendar.YEAR), cal.get(Calendar.MONTH) + 1, cal.get(Calendar.DAY_OF_MONTH),
        )
    }

    // ── http ─────────────────────────────────────────────────────────────────

    private suspend fun httpGet(path: String, params: Map<String, String>): String {
        val apiKey = settings.settings.first().tmdbApiKey
        if (apiKey.isBlank()) throw IOException("Add your TMDB API key in Settings.")
        val urlBuilder = "$BASE/$path".toHttpUrl().newBuilder()
            .addQueryParameter("api_key", apiKey)
            .addQueryParameter("language", "en-US")
        params.forEach { (key, value) -> urlBuilder.addQueryParameter(key, value) }
        val request = Request.Builder().url(urlBuilder.build()).get().build()
        // Cancellable enqueue-based call: cancelling the row/details coroutine cancels
        // the socket instead of pinning an IO thread for up to the 20 s read timeout.
        return client.await(request).use { response ->
            if (!response.isSuccessful) {
                throw IOException("TMDB /$path failed: HTTP ${response.code}")
            }
            withContext(Dispatchers.IO) { response.body?.string() }
                ?: throw IOException("TMDB /$path returned empty body")
        }
    }
}

/** Minimal synchronized LRU with optional TTL. Access-ordered LinkedHashMap under the hood. */
internal class TtlLruCache<K : Any, V : Any>(
    private val maxEntries: Int,
    private val ttlMillis: Long?,
) {
    private class Entry<V>(val value: V, val storedAt: Long)

    private val map = object : LinkedHashMap<K, Entry<V>>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, Entry<V>>): Boolean =
            size > maxEntries
    }

    @Synchronized
    fun get(key: K): V? {
        val entry = map[key] ?: return null
        if (ttlMillis != null && System.currentTimeMillis() - entry.storedAt > ttlMillis) {
            map.remove(key)
            return null
        }
        return entry.value
    }

    @Synchronized
    fun put(key: K, value: V) {
        map[key] = Entry(value, System.currentTimeMillis())
    }
}
