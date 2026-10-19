import Foundation

/// Resolve the nearest actual earlier episode. A failed season fetch propagates
/// so a temporary metadata outage cannot skip an entire season.
func findPreviousEpisode(
    season: Int,
    episode: Int,
    seasonNumbers: [Int],
    episodesFor: (Int) async throws -> [Episode]
) async throws -> Episode? {
    guard season >= 0, episode > 0 else { return nil }
    try Task.checkCancellation()
    if episode > 1 {
        let current = try await episodesFor(season)
        try Task.checkCancellation()
        if let previous = current.filter({ $0.season == season && $0.number > 0 && $0.number < episode })
            .max(by: { $0.number < $1.number }) {
            return previous
        }
    }
    // Specials can navigate within season zero, but regular seasons never
    // cross into specials. S1 E1 therefore has no chronological predecessor.
    let earlierSeasons = Set(seasonNumbers.filter { $0 > 0 && $0 < season }).sorted(by: >)
    for earlierSeason in earlierSeasons {
        try Task.checkCancellation()
        let episodes = try await episodesFor(earlierSeason)
        try Task.checkCancellation()
        if let previous = episodes.filter({ $0.season == earlierSeason && $0.number > 0 })
            .max(by: { $0.number < $1.number }) {
            return previous
        }
    }
    return nil
}
