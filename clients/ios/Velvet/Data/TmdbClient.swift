import Foundation

/// TMDB-backed discovery — 1:1 port of the Android TmdbRepositoryImpl.kt.
/// Every endpoint + query recipe was verified against the live API with curl
/// (2026-06-10); see TmdbDtos.swift for the matching response shapes.
///
/// Caching (TtlLruCache actor): rows ~30 min TTL per (rowId, effective page); movie
/// details unlimited TTL (effectively immutable); show details ~4 h TTL (returning
/// shows gain seasons/ratings change); episodes ~30 min TTL (airing shows gain
/// episodes). Failures are never cached: rowItems/episodes/search return [] so the
/// next visit retries; details() throws so the details screen can show retry.
final class TmdbClient: TmdbRepository {

    private static let base = "https://api.themoviedb.org/3"
    private static let img = "https://image.tmdb.org/t/p"
    private static let rowTtl: TimeInterval = 30 * 60
    private static let showDetailsTtl: TimeInterval = rowTtl * 8 // 4 h
    /// Spec §4a availability gate: a movie needs a digital/physical release AND a
    /// theatrical start at least this many days old. 45 days is what actually
    /// clears the in-theaters-only / telesync noise out of the movie rows.
    private static let availabilityGateDays = 45
    /// Spec §4e: discover rows rotate across this many pages, one step per day.
    private static let rotationPages = 3
    /// Rows whose recipe is NOT a discover query. /trending and /movie/{now_playing,
    /// upcoming} are already ranked lists — paging them deeper just shows worse
    /// entries, so they never rotate.
    private static let nonRotatingRows: Set<String> = [
        "top10_today", "trending_shows", "in_theaters", "coming_soon",
    ]
    /// Spec §4a: how many /trending entries to consider before taking the Top 10.
    private static let top10ProbeDepth = 15

    private let settings: SettingsStore
    private let session: URLSession

    private let rowCache = TtlLruCache<[MediaItem]>(maxEntries: 128, ttl: TmdbClient.rowTtl)
    private let movieDetailsCache = TtlLruCache<MediaDetails>(maxEntries: 192, ttl: nil)
    private let showDetailsCache = TtlLruCache<MediaDetails>(maxEntries: 64, ttl: TmdbClient.showDetailsTtl)
    private let episodesCache = TtlLruCache<[Episode]>(maxEntries: 128, ttl: TmdbClient.rowTtl)

    // TMDB's official genre lists (stable ids). "Science Fiction" shortened for meta lines.
    private static let movieGenres: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Sci-Fi", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
    ]
    private static let tvGenres: [Int: String] = [
        10759: "Action & Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 10762: "Kids",
        9648: "Mystery", 10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy",
        10766: "Soap", 10767: "Talk", 10768: "War & Politics", 37: "Western",
    ]

    init(settings: SettingsStore) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
    }

    /// The home funnel, ranked by intent: seasonal (only inside its window, spec
    /// §4f — right after the Continue Watching / My List rails and above the
    /// general discovery rows) → what's hot → what's new → what's bingeable →
    /// what's good → moods/genres → timeless → not-yet-streamable parked last.
    let allRows: [RowSpec] = SeasonalRow.all.map(\.spec) + [
        RowSpec(id: "top10_today", title: "Top 10 Today", style: .top10),
        RowSpec(id: "popular_now", title: "Popular Now", style: .landscape),
        RowSpec(id: "trending_shows", title: "Trending Shows", style: .landscape),
        RowSpec(id: "new_to_stream", title: "New to Stream", style: .poster),
        RowSpec(id: "new_shows", title: "New & Returning Shows", style: .poster),
        RowSpec(id: "bingeworthy", title: "Bingeworthy Shows", style: .poster),
        RowSpec(id: "acclaimed", title: "Critically Acclaimed", style: .poster),
        RowSpec(id: "hidden_gems", title: "Hidden Gems", style: .poster),
        RowSpec(id: "action", title: "Action & Adrenaline", style: .poster),
        RowSpec(id: "comedy", title: "Comedy Night", style: .poster),
        RowSpec(id: "thrillers", title: "Thrillers & Crime", style: .poster),
        RowSpec(id: "scifi_fantasy", title: "Sci-Fi & Fantasy", style: .poster),
        RowSpec(id: "horror", title: "Horror After Dark", style: .poster),
        RowSpec(id: "feel_good", title: "Feel-Good Picks", style: .poster),
        RowSpec(id: "date_night", title: "Date Night", style: .poster),
        RowSpec(id: "animation_family", title: "Animation & Family", style: .poster),
        RowSpec(id: "docs", title: "True Stories & Docs", style: .poster),
        RowSpec(id: "anime", title: "Anime", style: .poster),
        RowSpec(id: "modern_classics", title: "Modern Classics", style: .poster),
        RowSpec(id: "classics", title: "All-Time Classics", style: .poster),
        RowSpec(id: "in_theaters", title: "In Theaters Now", style: .poster),
        RowSpec(id: "coming_soon", title: "Coming Soon", style: .poster),
    ]

    // MARK: - TmdbRepository

    /// `page` is what the caller asked for; discover-backed rows are served from a
    /// deterministically rotated page (spec §4e) so the same row isn't the identical
    /// 20 titles every day. The cache key carries the EFFECTIVE page, so yesterday's
    /// rotation can never be served for today's row.
    func rowItems(rowId: String, page: Int) async -> [MediaItem] {
        let effectivePage = Self.rotatedPage(rowId: rowId, requestedPage: page)
        let cacheKey = "\(rowId)#\(effectivePage)"
        if let cached = await rowCache.get(cacheKey) { return cached }
        var items: [MediaItem]
        do {
            items = try await fetchRow(rowId: rowId, page: effectivePage)
            // Thin catalogues (New Year's has a single page under the availability
            // gate) run out before the rotation does — fall back rather than
            // collapse the row for two days out of three.
            if items.isEmpty, effectivePage != page {
                items = try await fetchRow(rowId: rowId, page: page)
            }
        } catch {
            return [] // never crash a home row; not cached, so the next visit retries
        }
        if !items.isEmpty { await rowCache.put(cacheKey, items) }
        return items
    }

    func details(id: Int, type: MediaType) async throws -> MediaDetails {
        let cacheKey = "\(type.rawValue)/\(id)"
        let cache = type == .movie ? movieDetailsCache : showDetailsCache
        if let cached = await cache.get(cacheKey) { return cached }
        let details: MediaDetails
        switch type {
        case .movie: details = try await fetchMovieDetails(id: id)
        case .show: details = try await fetchShowDetails(id: id)
        }
        await cache.put(cacheKey, details)
        return details
    }

    func episodes(showId: Int, season: Int) async -> [Episode] {
        let cacheKey = "\(showId)/\(season)"
        if let cached = await episodesCache.get(cacheKey) { return cached }
        let episodes: [Episode]
        do {
            let body = try await httpGet("tv/\(showId)/season/\(season)", [])
            let dto = try JSONDecoder().decode(TmdbSeasonDetailsDto.self, from: body)
            episodes = (dto.episodes ?? [])
                .filter { ($0.episodeNumber ?? 0) > 0 }
                .map { ep in
                    Episode(
                        season: ep.seasonNumber ?? 0,
                        number: ep.episodeNumber ?? 0,
                        title: nonBlank(ep.name) ?? "Episode \(ep.episodeNumber ?? 0)",
                        overview: nonBlank(ep.overview),
                        stillUrl: imageUrl("w400", ep.stillPath),
                        runtimeMinutes: ep.runtime.flatMap { $0 > 0 ? $0 : nil },
                        airDate: nonBlank(ep.airDate)
                    )
                }
        } catch {
            return [] // not cached — [] must mean "no episodes", never "the network blipped"
        }
        if !episodes.isEmpty { await episodesCache.put(cacheKey, episodes) }
        return episodes
    }

    func search(query: String) async -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        do {
            return try await listPage(
                "search/multi", type: nil, page: 1,
                params: [("query", trimmed), ("include_adult", "false")]
            )
        } catch {
            return []
        }
    }

    // MARK: - row recipes (query params copied 1:1 from the Android impl)

    private func fetchRow(rowId: String, page: Int) async throws -> [MediaItem] {
        // Seasonal/holiday collections (spec §4f). Outside its window a row yields
        // nothing at all — no request, no cache entry, and Home collapses it even
        // if the caller forgot to check isSeasonalRowActive().
        if let seasonal = SeasonalRow.find(rowId) {
            guard seasonal.isActive(on: Date()) else { return [] }
            return try await discoverMovies(page, [
                ("with_keywords", String(seasonal.keywordId)),
                ("vote_count.gte", "25"),
                ("sort_by", "popularity.desc"),
            ])
        }

        switch rowId {
        // Mixed trending, minus movies with nothing to stream yet: /trending is the
        // one row that can't express the availability gate as query params, so the
        // first 15 candidates are tested with the digitallyAvailable rule and the
        // first 10 survivors become the Top 10.
        case "top10_today":
            if page > 1 { return [] }
            let candidates = try await listPage("trending/all/day", type: nil, page: 1)
            var items = await availableTop10(Array(candidates.prefix(Self.top10ProbeDepth)))
            for index in items.indices { items[index].rankInRow = index + 1 }
            return items

        // Replaces the old raw /trending/movie/week row, which was mostly
        // theatrical-only titles ("trending_movies" is still accepted here so a
        // stale persisted row id keeps working until it is migrated).
        case "popular_now", "trending_movies":
            return try await discoverMovies(page, [
                ("vote_count.gte", "50"),
                ("sort_by", "popularity.desc"),
                ("with_original_language", "en"),
            ])

        case "trending_shows":
            return try await listPage(
                "trending/tv/week", type: .show, page: page,
                predicate: { $0.originalLanguage == "en" }
            )

        // Fresh digital releases — for a usenet pipeline this is "what just hit the indexers".
        case "new_to_stream":
            return try await discoverMovies(page, [
                ("with_release_type", "4|5"),
                ("region", "US"),
                ("release_date.gte", Self.isoDate(-75)),
                ("release_date.lte", Self.isoDate(0)),
                ("sort_by", "popularity.desc"),
                ("with_original_language", "en"),
            ])

        case "new_shows":
            return try await discoverShows(page, [
                ("air_date.gte", Self.isoDate(-14)),
                ("air_date.lte", Self.isoDate(0)),
                ("sort_by", "popularity.desc"),
                ("with_original_language", "en"),
            ])

        case "bingeworthy":
            return try await discoverShows(page, [
                ("vote_count.gte", "1000"),
                ("vote_average.gte", "7.5"),
                ("sort_by", "popularity.desc"),
                ("with_original_language", "en"),
            ])

        case "acclaimed":
            return try await discoverMovies(page, [
                ("vote_count.gte", "1500"),
                ("vote_average.gte", "7.8"),
                ("sort_by", "popularity.desc"),
                ("with_original_language", "en"),
            ])

        case "hidden_gems":
            return try await discoverMovies(page, [
                ("vote_average.gte", "7.4"),
                ("vote_count.gte", "50"),
                ("vote_count.lte", "400"),
                ("sort_by", "popularity.desc"),
                ("with_original_language", "en"),
            ])

        // Mood/genre rows — popularity-ranked with quality floors so they never fill with junk.
        case "action": return try await movieGenreRow(page, "28|12")
        case "comedy": return try await movieGenreRow(page, "35")
        case "thrillers": return try await movieGenreRow(page, "53|80")
        case "scifi_fantasy": return try await movieGenreRow(page, "878|14")
        case "horror": return try await movieGenreRow(page, "27", minRating: "6.0")
        case "feel_good": return try await movieGenreRow(page, "35|10751|10402", minRating: "7.0")
        case "date_night": return try await movieGenreRow(page, "10749")
        case "animation_family": return try await movieGenreRow(page, "16|10751")
        case "docs": return try await movieGenreRow(page, "99", minRating: "7.0", minVotes: "100")

        case "anime":
            return try await discoverShows(page, [
                ("with_genres", "16"),
                ("with_origin_country", "JP"),
                ("vote_count.gte", "200"),
                ("sort_by", "popularity.desc"),
            ])

        case "modern_classics":
            return try await discoverMovies(page, [
                ("primary_release_date.gte", "1995-01-01"),
                ("primary_release_date.lte", "2015-12-31"),
                ("vote_count.gte", "2500"),
                ("vote_average.gte", "7.5"),
                ("sort_by", "vote_average.desc"),
                ("with_original_language", "en"),
            ])

        case "classics":
            return try await discoverMovies(page, [
                ("primary_release_date.lte", "1994-12-31"),
                ("vote_count.gte", "1500"),
                ("vote_average.gte", "7.8"),
                ("sort_by", "vote_average.desc"),
                ("with_original_language", "en"),
            ])

        case "in_theaters":
            return try await listPage(
                "movie/now_playing", type: .movie, page: page,
                params: [("region", "US")]
            )

        case "coming_soon":
            let today = Self.isoDate(0)
            return try await listPage(
                "movie/upcoming", type: .movie, page: page,
                params: [("region", "US")],
                predicate: { ($0.releaseDate ?? "") > today } // future dates only
            )

        default:
            return []
        }
    }

    /// Movie mood/genre row: popularity-ranked with rating + vote-count floors.
    private func movieGenreRow(
        _ page: Int,
        _ genres: String,
        minRating: String = "6.3",
        minVotes: String = "300"
    ) async throws -> [MediaItem] {
        try await discoverMovies(page, [
            ("with_genres", genres),
            ("vote_average.gte", minRating),
            ("vote_count.gte", minVotes),
            ("sort_by", "popularity.desc"),
            ("with_original_language", "en"),
        ])
    }

    /// EVERY movie discover row goes through here, so every movie row carries the
    /// availability gate (spec §4a).
    private func discoverMovies(_ page: Int, _ params: [(String, String)]) async throws -> [MediaItem] {
        try await listPage(
            "discover/movie", type: .movie, page: page,
            params: Self.availabilityGated(params) + [("include_adult", "false")]
        )
    }

    /// Shows need no gate: an episode that aired is watchable.
    private func discoverShows(_ page: Int, _ params: [(String, String)]) async throws -> [MediaItem] {
        try await listPage("discover/tv", type: .show, page: page, params: params + [("include_adult", "false")])
    }

    /// Adds `with_release_type=4|5` (a digital or physical release exists) and
    /// `primary_release_date.lte = today − 45d` (kills in-theaters-only titles).
    /// A key the row already set is left alone: rows like `new_to_stream` scope
    /// release_type themselves, and `classics`/`modern_classics` carry a much
    /// stricter primary_release_date.lte — and TMDB rejects the WHOLE request
    /// ("Invalid parameters", status_code 5, verified with curl) if a filter is
    /// sent twice.
    private static func availabilityGated(_ params: [(String, String)]) -> [(String, String)] {
        var gated = params
        if !params.contains(where: { $0.0 == "with_release_type" }) {
            gated.append(("with_release_type", "4|5"))
        }
        if !params.contains(where: { $0.0 == "primary_release_date.lte" }) {
            gated.append(("primary_release_date.lte", isoDate(-availabilityGateDays)))
        }
        return gated
    }

    /// Keeps the first 10 trending entries that are actually watchable, in trending
    /// order. Shows always pass; movies are tested with the same digitallyAvailable
    /// rule the hero uses, via details() — whose movie cache never expires, so a
    /// refresh costs nothing after the first pass. A details() failure passes: an
    /// unknown title beats a half-empty Top 10.
    private func availableTop10(_ candidates: [MediaItem]) async -> [MediaItem] {
        let movieIds = Set(candidates.filter { $0.type == .movie }.map(\.id))
        if movieIds.isEmpty { return Array(candidates.prefix(10)) }
        let verdicts = await withTaskGroup(
            of: (Int, Bool).self,
            returning: [Int: Bool].self
        ) { group in
            for id in movieIds {
                group.addTask {
                    guard let details = try? await self.details(id: id, type: .movie) else {
                        return (id, true)
                    }
                    return (id, details.digitallyAvailable)
                }
            }
            var collected: [Int: Bool] = [:]
            for await (id, available) in group { collected[id] = available }
            return collected
        }
        var kept: [MediaItem] = []
        for item in candidates {
            if item.type == .movie, verdicts[item.id] == false { continue }
            kept.append(item)
            if kept.count == 10 { break }
        }
        return kept
    }

    /// Deterministic per-day page rotation (spec §4e): `page + (dayOfYear +
    /// rowIdHash) % 3`. The hash is Kotlin's String.hashCode algorithm — Swift's
    /// own hashValue is seeded per process, which would reshuffle every row on
    /// every launch and diverge from Android.
    private static func rotatedPage(rowId: String, requestedPage: Int) -> Int {
        guard !nonRotatingRows.contains(rowId) else { return requestedPage }
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let hash = Int(stableHash(rowId))
        let offset = (((dayOfYear &+ hash) % rotationPages) + rotationPages) % rotationPages
        return requestedPage + offset
    }

    private static func stableHash(_ text: String) -> Int32 {
        var hash: Int32 = 0
        for unit in text.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return hash
    }

    /// Fetches one page of a list endpoint and maps to MediaItems.
    /// `type` nil = mixed results, derive per item from media_type (skips persons).
    private func listPage(
        _ path: String,
        type: MediaType?,
        page: Int,
        params: [(String, String)] = [],
        predicate: (TmdbMediaDto) -> Bool = { _ in true }
    ) async throws -> [MediaItem] {
        let body = try await httpGet(path, params + [("page", String(page))])
        let dto = try JSONDecoder().decode(TmdbPageDto.self, from: body)
        return (dto.results ?? [])
            .filter(predicate)
            .compactMap { mediaItem(from: $0, forcedType: type) }
    }

    // MARK: - details

    private func fetchMovieDetails(id: Int) async throws -> MediaDetails {
        let body = try await httpGet("movie/\(id)", [
            ("append_to_response", "external_ids,images,credits,release_dates,similar"),
            ("include_image_language", "en,null"),
        ])
        let dto = try JSONDecoder().decode(TmdbMovieDetailsDto.self, from: body)
        let certification = (dto.releaseDates?.results ?? [])
            .first { $0.region == "US" }
            .flatMap { region in
                (region.releaseDates ?? []).compactMap { nonBlank($0.certification) }.first
            }
        let digitallyAvailable = isDigitallyAvailable(dto)
        let voteAverage = dto.voteAverage ?? 0
        let item = MediaItem(
            id: dto.id ?? id,
            type: .movie,
            title: dto.title ?? dto.originalTitle ?? "Untitled",
            year: yearOf(dto.releaseDate),
            posterUrl: imageUrl("w500", dto.posterPath),
            backdropUrl: imageUrl("w1280", dto.backdropPath),
            logoUrl: pickLogo(dto.images),
            rating: voteAverage > 0 ? voteAverage : nil,
            overview: nonBlank(dto.overview),
            genres: (dto.genres ?? []).map { shortGenre($0.name ?? "") },
            runtimeMinutes: dto.runtime.flatMap { $0 > 0 ? $0 : nil },
            imdbId: dto.externalIds?.imdbId ?? dto.imdbId
        )
        return MediaDetails(
            item: item,
            tagline: nonBlank(dto.tagline),
            certification: certification,
            cast: mapCast(dto.credits),
            seasons: [],
            similar: Array(
                (dto.similar?.results ?? [])
                    .compactMap { mediaItem(from: $0, forcedType: .movie) }
                    .prefix(20)
            ),
            digitallyAvailable: digitallyAvailable
        )
    }

    /// A movie is streamable once it has a digital/physical/TV release that's out, or its
    /// theatrical run is old enough (~100 days) that a digital release certainly exists.
    /// Sparse TMDB data (older/obscure titles often lack type-4 entries) gets the benefit
    /// of the doubt via the age fallback on the primary release date.
    private func isDigitallyAvailable(_ dto: TmdbMovieDetailsDto) -> Bool {
        let today = Self.isoDate(0)
        let theatricalCutoff = Self.isoDate(-100)
        let all = (dto.releaseDates?.results ?? []).flatMap { $0.releaseDates ?? [] }
        if all.isEmpty {
            guard let released = nonBlank(dto.releaseDate) else { return true }
            return released <= theatricalCutoff
        }
        let out = all.filter { rd in
            guard let date = nonBlank(rd.releaseDate), date.count >= 10 else { return false }
            return String(date.prefix(10)) <= today
        }
        if out.contains(where: { (4...6).contains($0.type ?? 0) }) { return true }
        return out.contains { rd in
            guard (1...3).contains(rd.type ?? 0), let date = rd.releaseDate else { return false }
            return String(date.prefix(10)) <= theatricalCutoff
        }
    }

    private func fetchShowDetails(id: Int) async throws -> MediaDetails {
        let body = try await httpGet("tv/\(id)", [
            ("append_to_response", "external_ids,images,credits,content_ratings,similar"),
            ("include_image_language", "en,null"),
        ])
        let dto = try JSONDecoder().decode(TmdbTvDetailsDto.self, from: body)
        let firstYear = yearOf(dto.firstAirDate)
        let lastYear = yearOf(dto.lastAirDate)
        let ended = dto.status == "Ended" || dto.status == "Canceled"
        let year: String?
        if firstYear == nil {
            year = nil
        } else if ended, let lastYear, lastYear != firstYear {
            year = "\(firstYear!)–\(lastYear)" // en dash
        } else {
            year = firstYear
        }
        let certification = (dto.contentRatings?.results ?? [])
            .first { $0.region == "US" }
            .flatMap { nonBlank($0.rating) }
        let voteAverage = dto.voteAverage ?? 0
        let item = MediaItem(
            id: dto.id ?? id,
            type: .show,
            title: dto.name ?? dto.originalName ?? "Untitled",
            year: year,
            posterUrl: imageUrl("w500", dto.posterPath),
            backdropUrl: imageUrl("w1280", dto.backdropPath),
            logoUrl: pickLogo(dto.images),
            rating: voteAverage > 0 ? voteAverage : nil,
            overview: nonBlank(dto.overview),
            genres: (dto.genres ?? []).map { shortGenre($0.name ?? "") },
            runtimeMinutes: (dto.episodeRunTime ?? []).first { $0 > 0 },
            imdbId: dto.externalIds?.imdbId
        )
        return MediaDetails(
            item: item,
            tagline: nonBlank(dto.tagline),
            certification: certification,
            cast: mapCast(dto.credits),
            seasons: (dto.seasons ?? [])
                .filter { ($0.seasonNumber ?? 0) > 0 }
                .sorted { ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }
                .map { season in
                    let number = season.seasonNumber ?? 0
                    return Season(
                        number: number,
                        name: nonBlank(season.name) ?? "Season \(number)",
                        episodeCount: season.episodeCount ?? 0,
                        posterUrl: imageUrl("w500", season.posterPath ?? dto.posterPath)
                    )
                },
            similar: Array(
                (dto.similar?.results ?? [])
                    .compactMap { mediaItem(from: $0, forcedType: .show) }
                    .prefix(20)
            )
        )
    }

    // MARK: - mapping

    /// List-result → MediaItem. `strict` (default) drops items missing a year or artwork,
    /// because every card must show title + year and needs an image.
    private func mediaItem(
        from dto: TmdbMediaDto,
        forcedType: MediaType?,
        strict: Bool = true
    ) -> MediaItem? {
        let type: MediaType
        if let forcedType {
            type = forcedType
        } else {
            switch dto.mediaType {
            case "movie": type = .movie
            case "tv": type = .show
            default: return nil // persons etc. in trending/all and search/multi
            }
        }
        let displayTitle: String?
        switch type {
        case .movie: displayTitle = dto.title ?? dto.originalTitle
        case .show: displayTitle = dto.name ?? dto.originalName
        }
        guard let title = displayTitle else { return nil }
        let date = type == .movie ? dto.releaseDate : dto.firstAirDate
        let year = yearOf(date)
        if strict && (year == nil || (dto.posterPath == nil && dto.backdropPath == nil)) { return nil }
        let genreNames = type == .movie ? Self.movieGenres : Self.tvGenres
        let voteAverage = dto.voteAverage ?? 0
        return MediaItem(
            id: dto.id ?? 0,
            type: type,
            title: title,
            year: year,
            posterUrl: imageUrl("w500", dto.posterPath),
            backdropUrl: imageUrl("w1280", dto.backdropPath),
            rating: voteAverage > 0 ? voteAverage : nil,
            overview: nonBlank(dto.overview),
            genres: (dto.genreIds ?? []).compactMap { genreNames[$0] }
        )
    }

    private func mapCast(_ credits: TmdbCreditsDto?) -> [CastMember] {
        (credits?.cast ?? [])
            .enumerated()
            .sorted { lhs, rhs in
                let lo = lhs.element.order ?? Int.max
                let ro = rhs.element.order ?? Int.max
                return lo != ro ? lo < ro : lhs.offset < rhs.offset // stable, like Kotlin sortedBy
            }
            .map(\.element)
            .prefix(20)
            .filter { nonBlank($0.name) != nil }
            .map { cast in
                CastMember(
                    name: cast.name ?? "",
                    role: nonBlank(cast.character),
                    profileUrl: imageUrl("w185", cast.profilePath)
                )
            }
    }

    /// First English PNG in images.logos, falling back to any PNG. w500.
    private func pickLogo(_ images: TmdbImagesDto?) -> URL? {
        let logos = (images?.logos ?? []).filter { ($0.filePath ?? "").lowercased().hasSuffix(".png") }
        let best = logos.first { $0.iso639 == "en" } ?? logos.first
        return imageUrl("w500", best?.filePath)
    }

    private func imageUrl(_ size: String, _ path: String?) -> URL? {
        guard let path else { return nil }
        return URL(string: "\(Self.img)/\(size)\(path)")
    }

    private func yearOf(_ date: String?) -> String? {
        guard let date else { return nil }
        let year = String(date.prefix(4))
        guard year.count == 4, year.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return year
    }

    private func shortGenre(_ name: String) -> String {
        name == "Science Fiction" ? "Sci-Fi" : name
    }

    private func nonBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// Today + offsetDays as "yyyy-MM-dd" in UTC (matches the Android Calendar math).
    private static func isoDate(_ offsetDays: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = calendar.date(byAdding: .day, value: offsetDays, to: Date()) ?? Date()
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - http

    private func httpGet(_ path: String, _ params: [(String, String)]) async throws -> Data {
        let apiKey = await MainActor.run { settings.tmdbApiKey }
        guard var components = URLComponents(string: "\(Self.base)/\(path)") else {
            throw URLError(.badURL)
        }
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "en-US"),
        ]
        for (name, value) in params {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Minimal actor-isolated LRU with optional TTL — the Swift twin of the Android
/// TtlLruCache (access-ordered LinkedHashMap). Access order is tracked with a
/// monotonically increasing tick; eviction drops the least-recently-used entry.
actor TtlLruCache<Value: Sendable> {
    private struct Entry {
        let value: Value
        let storedAt: Date
        var lastAccess: UInt64
    }

    private let maxEntries: Int
    private let ttl: TimeInterval?
    private var tick: UInt64 = 0
    private var entries: [String: Entry] = [:]

    init(maxEntries: Int, ttl: TimeInterval?) {
        self.maxEntries = maxEntries
        self.ttl = ttl
    }

    func get(_ key: String) -> Value? {
        guard var entry = entries[key] else { return nil }
        if let ttl, Date().timeIntervalSince(entry.storedAt) > ttl {
            entries[key] = nil
            return nil
        }
        tick += 1
        entry.lastAccess = tick
        entries[key] = entry
        return entry.value
    }

    func put(_ key: String, _ value: Value) {
        tick += 1
        entries[key] = Entry(value: value, storedAt: Date(), lastAccess: tick)
        if entries.count > maxEntries,
           let eldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            entries[eldest.key] = nil
        }
    }
}
