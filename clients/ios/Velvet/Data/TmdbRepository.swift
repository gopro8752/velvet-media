import Foundation

/// Native TMDB-backed discovery — a 1:1 PORT of the Android implementation at
/// ~/velvet/app/src/main/java/tv/velvet/data/tmdb/TmdbRepositoryImpl.kt.
/// The implementation (TmdbClient.swift) must keep:
///  - the exact same row ids, titles, styles, ORDER, and discover recipes
///  - the same image sizes (posters w500, backdrops w1280, logos w500 first
///    English PNG, stills w400, profiles w185)
///  - strict card mapping: list items missing a year or all artwork are dropped
///  - the genre-id maps ("Science Fiction" shortened to "Sci-Fi")
///  - show year "2019–2023" (en dash) only for Ended/Canceled, else first-air year
///  - details() fetching external_ids + images + credits + release_dates /
///    content_ratings + similar via append_to_response
///  - the digitallyAvailable rule (digital/physical type 4-6 released, or
///    theatrical ≥100 days old, sparse-data fallbacks)
///  - caching: rows ~30 min TTL per (rowId, effective page); movie details no TTL;
///    show details ~4 h; episodes ~30 min
///  - error contract: rowItems/episodes/search return [] on failure (not cached);
///    details() THROWS so the details screen can show retry
///
/// v1.2.0 (spec §4) additions, identical on both platforms:
///  - availability gate on EVERY movie discover row (with_release_type=4|5 +
///    primary_release_date.lte = today − 45d)
///  - `trending_movies` replaced by the discover-backed `popular_now`
///  - top10_today drops movies failing digitallyAvailable (shows always pass)
///  - deterministic per-day page rotation for discover-backed rows
///  - five seasonal/holiday rows, hidden outside their calendar window
protocol TmdbRepository: Sendable {
    var allRows: [RowSpec] { get }
    func rowItems(rowId: String, page: Int) async -> [MediaItem]
    func details(id: Int, type: MediaType) async throws -> MediaDetails
    func episodes(showId: Int, season: Int) async -> [Episode]
    func search(query: String) async -> [MediaItem]
}

// Row-calendar helpers. Pure functions of the row id, so they live in the
// protocol extension: every conformer gets them, and callers holding a
// `TmdbRepository` can gate rows without knowing the concrete client.
extension TmdbRepository {

    /// The seasonal/holiday row ids, in Home order (spec §4f). These are the only
    /// ids `isSeasonalRowActive` can answer `false` for.
    func seasonalRowIds() -> [String] {
        SeasonalRow.ids
    }

    /// Whether `rowId` may be shown on `today`'s device-local date.
    /// Seasonal rows are active only inside their window — Halloween Aug 1–Oct 31
    /// (the owner decorates early), Thanksgiving Nov 1–30, Christmas Nov 15–Dec 31,
    /// New Year's Dec 26–Jan 5, Valentine's Feb 1–15. NOTE: any NON-seasonal row id
    /// answers `true` (there is nothing to gate), so
    /// `allRows.filter { tmdb.isSeasonalRowActive($0.id) }` is the whole Home-row
    /// filter. Belt and braces: TmdbClient also returns [] for a seasonal row
    /// fetched outside its window, so a caller that forgets this check still can't
    /// put Christmas movies on Home in July.
    func isSeasonalRowActive(_ rowId: String, today: Date = Date()) -> Bool {
        guard let seasonal = SeasonalRow.find(rowId) else { return true }
        return seasonal.isActive(on: today)
    }
}
