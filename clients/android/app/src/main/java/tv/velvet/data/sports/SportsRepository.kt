package tv.velvet.data.sports

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import tv.velvet.data.net.await
import tv.velvet.data.settings.SettingsRepository
import java.io.IOException
import java.net.URI
import java.time.Instant
import java.util.concurrent.TimeUnit

@Serializable data class Sport(val id: String, val name: String)
@Serializable data class SportsTeam(val name: String, val badgeUrl: String? = null)
@Serializable data class SportsEvent(val id: String, val title: String, val sportId: String, val sportName: String,
    val startTime: String, val isLive: Boolean, val popular: Boolean = false, val posterUrl: String? = null,
    val homeTeam: SportsTeam? = null, val awayTeam: SportsTeam? = null, val sourceCount: Int = 0)
@Serializable data class SportsCatalog(val enabled: Boolean = false, val sourceName: String = "StreamFree",
    val sports: List<Sport> = emptyList(), val events: List<SportsEvent> = emptyList(), val message: String? = null)
@Serializable data class SportsStream(val id: String, val source: String, val streamNo: Int, val language: String,
    val hd: Boolean, val embedUrl: String) {
    val key get() = "$source:$id:$streamNo:$embedUrl"
    val label get() = "$source $streamNo · $language · ${if (hd) "HD" else "SD"}"
}
@Serializable data class SportsStreams(val eventId: String, val streams: List<SportsStream> = emptyList(), val message: String? = null)
@Serializable private data class ApiError(val error: String)
class SportsException(message: String) : IOException(message)

/** Accept only a provider player document, never a user-entered browser destination. */
fun isSafeEmbed(url: String): Boolean = runCatching {
    val u = URI(url)
    val host = u.host?.lowercase().orEmpty()
    val parts = u.path.orEmpty().split('/')
    url.length <= 1400 && u.scheme == "https" && u.userInfo == null && u.port == -1 &&
        host in setOf("strmfree.st", "streamfree.top") && u.query == null && u.fragment == null &&
        parts.size == 4 && parts[0].isEmpty() && parts[1] == "embed" &&
        Regex("[A-Za-z0-9_-]{1,80}").matches(parts[2]) &&
        // URI decodes UTF-8 once. Unicode team names are valid, while encoded
        // slashes, dot segments, double escapes and malformed UTF-8 are not.
        Regex("[\\p{L}\\p{N}_-]{1,200}").matches(parts[3])
}.getOrDefault(false)
fun isEmbedNavigationAllowed(initial: String, destination: String): Boolean = runCatching {
    val a = URI(initial); val b = URI(destination)
    isSafeEmbed(initial) && isSafeEmbed(destination.substringBefore('#')) &&
        a.host.equals(b.host, true) && a.path == b.path && a.query == b.query
}.getOrDefault(false)
/** StreamFree's documented embed owns its JWPlayer directly; child frames are ads. */
fun isSportsStartupFrameAllowed(embed: String, frameUrl: String, topLevel: Boolean) =
    topLevel && isEmbedNavigationAllowed(embed, frameUrl)

/** StreamFree's documented iframe integration, with navigation/popups guarded by the native host. */
fun sportsEmbedDocument(url: String): String {
    require(isSafeEmbed(url))
    val escaped = url.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;").replace(">", "&gt;")
    return """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}iframe{position:fixed;inset:0;width:100%;height:100%;border:0}</style></head><body><iframe src="$escaped" allow="autoplay; fullscreen; encrypted-media" allowfullscreen referrerpolicy="no-referrer"></iframe></body></html>"""
}
fun filterSportsEvents(events: List<SportsEvent>, query: String, sportId: String?, upcomingOnly: Boolean, now: Instant): List<SportsEvent> {
    val term = query.trim()
    return events.filter { (sportId == null || it.sportId == sportId) &&
        (!upcomingOnly || (!it.isLive && runCatching { Instant.parse(it.startTime).isAfter(now) }.getOrDefault(false))) &&
        (term.isBlank() || listOfNotNull(it.title, it.sportName, it.homeTeam?.name, it.awayTeam?.name).any { s -> s.contains(term, true) }) }
        .distinctBy { it.id }
}
class SportsRepository(private val settings: SettingsRepository, client: OkHttpClient, private val json: Json) {
    private val client = client.newBuilder().callTimeout(35, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()
    private val launcherClient = client.newBuilder().callTimeout(10, TimeUnit.SECONDS).readTimeout(8, TimeUnit.SECONDS).build()
    private suspend fun get(path: String, query: Pair<String, String>? = null, transport: OkHttpClient = client,
                            bodyLimit: Long? = null): String = withContext(Dispatchers.IO) {
        val config = settings.settings.first()
        val base = config.backendUrl.trim().trimEnd('/').removeSuffix("/manifest.json").toHttpUrlOrNull()
            ?: throw SportsException("Connect Velvet Backend in Settings to browse Live Sports.")
        val sync = config.syncUrl.toHttpUrlOrNull()
        val token = config.syncToken.trim().takeIf { it.isNotEmpty() && sync != null &&
            base.scheme == sync.scheme && base.host == sync.host && base.port == sync.port }
        val url = base.newBuilder().addEncodedPathSegments(path).apply { query?.let { addQueryParameter(it.first, it.second) } }.build()
        val request = Request.Builder().url(url).apply { token?.let { header("Authorization", "Bearer $it") } }.build()
        transport.await(request).use { response ->
            val body = if (bodyLimit == null) response.body?.string().orEmpty() else {
                val source = response.body?.source() ?: throw SportsException("No event catalog")
                if (source.request(bodyLimit + 1)) throw SportsException("Event catalog is too large")
                source.readUtf8()
            }
            if (!response.isSuccessful) throw SportsException(runCatching { json.decodeFromString(ApiError.serializer(), body).error.take(240) }
                .getOrDefault("Live Sports couldn't connect. Refresh or check Settings."))
            body
        }
    }
    /** Optional launcher matching has a strict transport/body bound independent of screen browsing. */
    suspend fun launcherEvents(): SportsCatalog = json.decodeFromString(SportsCatalog.serializer(),
        get("sports/events", "scope" to "all", launcherClient, 2_000_000))
    suspend fun events(scope: String): SportsCatalog = json.decodeFromString(SportsCatalog.serializer(), get("sports/events", "scope" to scope))
    suspend fun streams(eventId: String): SportsStreams {
        // addPathSegment protects opaque event IDs from becoming another route.
        val encoded = okhttp3.HttpUrl.Builder().scheme("https").host("invalid.example").addPathSegment(eventId).build().encodedPath.removePrefix("/")
        return json.decodeFromString(SportsStreams.serializer(), get("sports/events/$encoded/streams")).let { response ->
            if (response.eventId != eventId) throw SportsException("These streams no longer match this event. Refresh and try again.")
            response.copy(streams = response.streams.filter { isSafeEmbed(it.embedUrl) }.distinctBy { it.key })
        }
    }
}
