package tv.velvet.data.tmdb

import tv.velvet.data.model.Episode

/**
 * Resolve an actual earlier episode, never a seek/restart of the current episode.
 * Regular seasons do not fall back into Specials (season zero). Specials can still
 * move backward within their own season. Empty seasons are skipped only after a
 * successful fetch; errors and cancellation propagate so unavailable metadata is
 * not mistaken for the beginning of the show.
 */
suspend fun findPreviousEpisode(
    season: Int,
    episode: Int,
    seasonNumbers: List<Int>,
    episodesFor: suspend (Int) -> List<Episode>,
): Episode? {
    if (season < 0 || episode <= 0) return null

    if (episode > 1) {
        val inSeason = episodesFor(season)
            .filter { it.season == season && it.number in 1 until episode }
            .maxByOrNull { it.number }
        if (inSeason != null) return inSeason
    }

    for (previousSeason in seasonNumbers.filter { it > 0 && it < season }.distinct().sortedDescending()) {
        val last = episodesFor(previousSeason)
            .filter { it.season == previousSeason && it.number > 0 }
            .maxByOrNull { it.number }
        if (last != null) return last
    }
    return null
}
