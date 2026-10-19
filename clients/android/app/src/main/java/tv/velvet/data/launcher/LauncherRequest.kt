package tv.velvet.data.launcher

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicLong

/** Strict whitelist, deliberately no playback URL, arbitrary route, or resume offset. Velvet owns these. */
data class LauncherRequest(
    val id: Long,
    val destination: String,
    val profileId: String?,
    val mediaId: Int? = null,
    val type: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val categoryId: String? = null,
    val shuffle: Boolean = false,
    val gameId: String? = null,
) {
    companion object {
        private val sequence = AtomicLong()
        fun validated(destination: String?, profile: String?, mediaId: Int? = null, type: String? = null,
                      season: Int? = null, episode: Int? = null, category: String? = null, shuffle: Boolean = false, gameId: String? = null): LauncherRequest? {
            if (destination !in setOf("home", "search", "live", "sports", "create", "profiles", "details", "resume", "category", "game")) return null
            if (profile != null && (profile.isBlank() || profile.length > 100)) return null
            val media = destination in setOf("details", "resume")
            if (media && (profile == null || mediaId == null || mediaId <= 0 || type !in setOf("movie", "show"))) return null
            if (!media && (mediaId != null || type != null || season != null || episode != null)) return null
            if (media && !((season == null && episode == null) ||
                        (type == "show" && season != null && season in 0..10_000 && episode != null && episode in 1..100_000))) return null
            if (destination == "category" && (profile == null || category.isNullOrBlank() || category.length > 200)) return null
            if (destination != "category" && (category != null || shuffle)) return null
            if (destination == "game" && gameId?.matches(Regex("(nba|mlb|nfl):[0-9]{1,20}")) != true) return null
            if (destination != "game" && gameId != null) return null
            return LauncherRequest(sequence.incrementAndGet(), requireNotNull(destination), profile, mediaId, type, season, episode, category, shuffle, gameId)
        }
    }
}

/** Written only by the signature-protected trampoline, never by MainActivity intent extras. */
object LauncherNavigation {
    private val pending = MutableStateFlow<LauncherRequest?>(null)
    val request = pending.asStateFlow()
    fun submit(request: LauncherRequest) { pending.value = request }
    fun consume(id: Long) { if (pending.value?.id == id) pending.value = null }
}

/** A NavHost crossfade can keep two Home entries composed; only the new one owns the action. */
data class LauncherHomeRequest(val entryId: String, val request: LauncherRequest) {
    fun forEntry(id: String): LauncherRequest? = request.takeIf { id == entryId }
}

/** Selection belongs to one Sports entry, just as Create belongs to one Home entry. */
data class LauncherSportsSelection(
    val entryId: String, val requestId: Long, val query: String, val sportId: String?,
    val title: String?, val message: String?,
)

internal fun launcherSportsFilter(league: String): String? = when (league) {
    "nba" -> "basketball"
    "mlb" -> "baseball"
    "nfl" -> "american-football"
    else -> null
}
