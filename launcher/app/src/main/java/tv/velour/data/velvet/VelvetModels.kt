package tv.velour.data.velvet

import kotlinx.serialization.Serializable

@Serializable
data class VelvetProfile(val id: String, val name: String, val color: String = "#8B7CF6")

@Serializable
data class VelvetTitle(
    val id: Int,
    val type: String,
    val title: String,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val logoUrl: String? = null,
    val year: String? = null,
    val rating: Double? = null,
    val overview: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
) {
    val key: String get() = "$type:$id:${season ?: -1}:${episode ?: -1}"
    val progress: Float get() = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    val episodeLabel: String? get() = if (season != null && episode != null) "S$season E$episode" else null
    val remainingMinutes: Long? get() = if (durationMs > positionMs) ((durationMs - positionMs + 59_999) / 60_000) else null
    val valid: Boolean get() = id > 0 && type in setOf("movie", "show") && title.isNotBlank() &&
        ((season == null && episode == null) || (type == "show" && season != null && season >= 0 && episode != null && episode > 0))
}

@Serializable
data class VelvetCategory(val id: String, val title: String, val items: List<VelvetTitle>)

enum class VelvetConnection { CONNECTED, NOT_INSTALLED, UPDATE_REQUIRED, UNAVAILABLE }

@Serializable
data class VelvetSnapshot(
    val version: Int = 1,
    val profile: VelvetProfile? = null,
    val continueWatching: List<VelvetTitle> = emptyList(),
    val myList: List<VelvetTitle> = emptyList(),
    val featured: List<VelvetTitle> = emptyList(),
    val categories: List<VelvetCategory> = emptyList(),
    val updatedAt: Long = 0,
    val games: List<VelvetGame> = emptyList(),
    val sportsTeams: List<VelvetSportsTeam> = emptyList(),
    val sportsUpdatedAt: Long = 0,
    val sportsUnavailable: Boolean = false,
    val connection: VelvetConnection = VelvetConnection.CONNECTED,
) {
    val connected: Boolean get() = connection == VelvetConnection.CONNECTED
}

sealed interface VelvetAction {
    data object Home : VelvetAction
    data object Search : VelvetAction
    data object LiveTV : VelvetAction
    data object LiveSports : VelvetAction
    data object CreateCategory : VelvetAction
    data object Profiles : VelvetAction
    data class SportsGame(val game: VelvetGame) : VelvetAction
    data class Details(val title: VelvetTitle) : VelvetAction
    data class Resume(val title: VelvetTitle) : VelvetAction
    data class Category(val id: String, val shuffle: Boolean = false) : VelvetAction
}

@Serializable
data class VelvetSportsTeam(
    val key: String, val league: String, val id: String, val name: String,
    val shortName: String, val abbreviation: String, val logoUrl: String? = null,
    val colorHex: String? = null,
)

@Serializable
data class VelvetGame(
    val id: String, val league: String, val homeTeam: VelvetSportsTeam, val awayTeam: VelvetSportsTeam,
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
