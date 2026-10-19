import Foundation

/// Home-row metadata that is pure data — seasonal/holiday collections and the
/// legacy row-id migration table. Kept out of TmdbClient so the Settings screen
/// and the Home view model can reason about rows without touching the network
/// layer (the TmdbRepository protocol extension re-exports both).
///
/// Seasonal keyword ids were verified against the live TMDB API (2026-08-06):
///   /search/keyword?query=… → christmas 207317, halloween 3335,
///   thanksgiving 4543, new year 252123, "valentine's day" 160404.
/// The bare "valentine" keyword (251912) has a single gated title and
/// "valentines" (366924) has none — 160404 is the one with a real catalogue
/// (44 titles under the availability gate).
struct SeasonalRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// TMDB keyword id for `discover/movie?with_keywords=`.
    let keywordId: Int
    /// Inclusive device-local window, as (month, day). A window whose start
    /// falls later in the year than its end wraps across New Year.
    let startMonth: Int
    let startDay: Int
    let endMonth: Int
    let endDay: Int

    var spec: RowSpec { RowSpec(id: id, title: title, style: .poster) }

    /// True when `date` (device-local calendar) falls inside the window.
    func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return false }
        let today = month * 100 + day
        let start = startMonth * 100 + startDay
        let end = endMonth * 100 + endDay
        if start <= end { return today >= start && today <= end }
        return today >= start || today <= end // wraps New Year (Dec 26 – Jan 5)
    }

    /// Home order: earliest holiday first, so overlapping windows read
    /// chronologically (Nov 15–30 shows Thanksgiving above Christmas).
    ///
    /// Halloween opens Aug 1, not late September: the owner decorates early —
    /// spooky season starts in August in this house, and the row should be on
    /// Home the moment the skeletons go up, not six weeks later.
    static let all: [SeasonalRow] = [
        SeasonalRow(id: "holiday_halloween", title: "Halloween Frights",
                    keywordId: 3335, startMonth: 8, startDay: 1, endMonth: 10, endDay: 31),
        SeasonalRow(id: "holiday_thanksgiving", title: "Thanksgiving Picks",
                    keywordId: 4543, startMonth: 11, startDay: 1, endMonth: 11, endDay: 30),
        SeasonalRow(id: "holiday_christmas", title: "Christmas Movies",
                    keywordId: 207317, startMonth: 11, startDay: 15, endMonth: 12, endDay: 31),
        SeasonalRow(id: "holiday_newyear", title: "New Year's Eve",
                    keywordId: 252123, startMonth: 12, startDay: 26, endMonth: 1, endDay: 5),
        SeasonalRow(id: "holiday_valentines", title: "Valentine's Day",
                    keywordId: 160404, startMonth: 2, startDay: 1, endMonth: 2, endDay: 15),
    ]

    static let ids: [String] = all.map(\.id)

    static func find(_ rowId: String) -> SeasonalRow? {
        all.first { $0.id == rowId }
    }
}

/// Row ids are persisted in Settings→Home Rows (`SettingsStore.rowOrder`), so a
/// renamed row must be swapped in place on read or the user silently loses it.
enum RowIdMigration {
    /// old id → new id. `trending_movies` became the discover-backed
    /// `popular_now` in v1.2.0 (raw /trending/movie was full of theatrical-only
    /// titles nothing can stream).
    static let renamed: [String: String] = ["trending_movies": "popular_now"]

    /// Applies renames in place and drops duplicates (an order carrying BOTH the
    /// old and the new id collapses to one entry at the earlier position). Never
    /// ADDS or drops an id otherwise — `rowOrder` is the enabled set, and ids
    /// this build doesn't know are filtered where the rows are actually resolved
    /// (SettingsView.effectiveOrder / HomeViewModel.resolveSpecs).
    ///
    /// The single owner of the rename table: `SettingsStore.init` runs persisted
    /// `rowOrder` and `disabledRowIds` through it on load.
    static func apply(_ storedOrder: [String]) -> [String] {
        guard storedOrder.contains(where: { renamed[$0] != nil }) else { return storedOrder }
        var seen = Set<String>()
        var out: [String] = []
        for id in storedOrder {
            let mapped = renamed[id] ?? id
            if seen.insert(mapped).inserted { out.append(mapped) }
        }
        return out
    }
}
