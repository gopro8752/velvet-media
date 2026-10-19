package tv.velvet.data.launcher

import kotlinx.serialization.Serializable
import tv.velvet.data.model.MediaItem

@Serializable
data class LauncherProfile(val id: String, val name: String, val color: String)

@Serializable
data class LauncherTitle(
    val id: Int, val type: String, val title: String,
    val posterUrl: String? = null, val backdropUrl: String? = null, val logoUrl: String? = null,
    val year: String? = null, val rating: Double? = null, val overview: String? = null,
    val season: Int? = null, val episode: Int? = null, val episodeTitle: String? = null,
    val positionMs: Long = 0, val durationMs: Long = 0,
)

@Serializable
data class LauncherCategory(val id: String, val title: String, val items: List<LauncherTitle>)

@Serializable
data class LauncherSnapshot(
    val version: Int = 1,
    val profile: LauncherProfile? = null,
    val continueWatching: List<LauncherTitle> = emptyList(),
    val myList: List<LauncherTitle> = emptyList(),
    val featured: List<LauncherTitle> = emptyList(),
    val categories: List<LauncherCategory> = emptyList(),
    val games: List<LauncherGame> = emptyList(),
    val sportsTeams: List<LauncherSportsTeam> = emptyList(),
    val sportsUpdatedAt: Long = 0,
    val sportsUnavailable: Boolean = false,
    val updatedAt: Long = System.currentTimeMillis(),
)

/** Export display metadata only. Never serialize MediaItem or app settings wholesale. */
fun MediaItem.launcherTitle() = LauncherTitle(id, type.key, title.take(300),
    launcherImage(posterUrl), launcherImage(backdropUrl), launcherImage(logoUrl), year?.take(40),
    rating, overview?.take(2_000))

/** Image credentials/query strings must never cross the companion boundary. */
internal fun launcherImage(value: String?): String? = value?.takeIf {
    it.length <= 2_048 && runCatching {
        val uri = java.net.URI(it)
        uri.scheme == "https" && uri.host == "image.tmdb.org" && uri.userInfo == null &&
            uri.query == null && uri.fragment == null && uri.path.startsWith("/t/p/")
    }.getOrDefault(false)
}

@Serializable
data class LauncherSportsTeam(
    val key: String, val league: String, val id: String, val name: String,
    val shortName: String, val abbreviation: String, val logoUrl: String? = null,
    val colorHex: String? = null,
)

@Serializable
data class LauncherGame(
    val id: String, val league: String, val homeTeam: LauncherSportsTeam, val awayTeam: LauncherSportsTeam,
    val startTime: String, val status: String, val statusDetail: String,
    val homeScore: String? = null, val awayScore: String? = null,
    val eventId: String? = null, val title: String, val updatedAt: Long = 0, val stale: Boolean = false,
) {
    fun matchesTeams(keys: Set<String>): Boolean = homeTeam.key in keys || awayTeam.key in keys
    fun isToday(now: Long = System.currentTimeMillis(), zone: java.time.ZoneId = java.time.ZoneId.systemDefault()): Boolean = runCatching {
        val start = java.time.OffsetDateTime.parse(startTime).toInstant()
        start.atZone(zone).toLocalDate() == java.time.Instant.ofEpochMilli(now).atZone(zone).toLocalDate() ||
            (!stale && status in setOf("live", "delayed") && now - updatedAt in 0..(15 * 60_000L) &&
                now - start.toEpochMilli() in 0..(12 * 60 * 60_000L))
    }.getOrDefault(false)
}
