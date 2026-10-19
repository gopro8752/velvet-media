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
@Serializable data class SportsCatalog(val enabled: Boolean = false, val sourceName: String = "Streamed",
    val sports: List<Sport> = emptyList(), val events: List<SportsEvent> = emptyList(), val message: String? = null)
@Serializable data class SportsStream(val id: String, val source: String, val streamNo: Int, val language: String,
    val hd: Boolean, val embedUrl: String) {
    val key get() = "$source:$id:$streamNo:$embedUrl"
    val label get() = "$source $streamNo · $language · ${if (hd) "HD" else "SD"}"
}
@Serializable data class SportsStreams(val eventId: String, val streams: List<SportsStream> = emptyList(), val message: String? = null)
@Serializable private data class ApiError(val error: String)
class SportsException(message: String) : IOException(message)

/** Validate the API-provided embed, never a user-entered browser destination. */
fun isSafeEmbed(url: String): Boolean = runCatching {
    val u = URI(url)
    val host = u.host?.lowercase().orEmpty()
    u.scheme == "https" && u.userInfo == null && u.port == -1 && u.path.startsWith("/embed/") &&
        (host == "embed.st" || host == "embed.pk")
}.getOrDefault(false)
fun isEmbedNavigationAllowed(initial: String, destination: String): Boolean = runCatching {
    val a = URI(initial); val b = URI(destination)
    isSafeEmbed(destination) && a.host.equals(b.host, true) && a.path == b.path && a.query == b.query
}.getOrDefault(false)
/** Only the selected top-level document is trusted before it declares its player frames. */
fun isSportsStartupFrameAllowed(embed: String, frameUrl: String, topLevel: Boolean) =
    topLevel && isEmbedNavigationAllowed(embed, frameUrl)

/** Each exact parent may approve only its large direct player, never arbitrary links or ads. */
class SportsStartupFramePolicy(private val embed: String) {
    private val wrappers = mutableSetOf<String>()
    private val children = mutableSetOf<String>()
    private val golfId = runCatching {
        URI(embed).path.trim('/').split('/').takeIf { isSafeEmbed(embed) && it.size == 4 && it[0] == "embed" && it[1] == "golf" }?.get(2)
    }.getOrNull()
    private fun wrapper(url: String) = runCatching {
        val frame = URI(url); val query = url.toHttpUrlOrNull()
        golfId != null && frame.scheme == "https" && frame.host == "rockylive.st" && frame.port == -1 && frame.userInfo == null && frame.fragment == null &&
            frame.path in setOf("/source/streamed.php", "/source/streamed1.php") && query?.queryParameterValues("id") == listOf(golfId) &&
            query.queryParameterValues("no").let { it.size == 1 && it.single()?.matches(Regex("[1-9][0-9]{0,3}")) == true }
    }.getOrDefault(false)
    private fun ingest(url: String) = runCatching {
        val frame = URI(url)
        golfId != null && isSafeEmbed(url) && frame.query == null && frame.fragment in setOf(null, "player=clappr&autoplay=true") &&
            Regex("/embed/ingest/[A-Za-z0-9_-]{1,200}/[1-9][0-9]{0,3}/?").matches(frame.path)
    }.getOrDefault(false)
    fun accepts(url: String, topLevel: Boolean) = isSportsStartupFrameAllowed(embed, url, topLevel) || (!topLevel && (url in wrappers || url.substringBefore('#') in children))
    // Embeds are allowed to load only their own player frames, not an unbounded tree
    // of advertising documents (each origin otherwise creates a browser process).
    fun allowsFrameNavigation(url: String) = isEmbedNavigationAllowed(embed, url) || wrapper(url) || ingest(url)
    fun mayWait(url: String, topLevel: Boolean) = !topLevel && (wrapper(url) || ingest(url))
    fun register(parent: String, topLevel: Boolean, child: String, width: Int, height: Int): Boolean {
        if (width !in 320..16384 || height !in 180..16384) return false
        val destinations = when {
            topLevel && isSportsStartupFrameAllowed(embed, parent, true) && wrapper(child) -> wrappers
            !topLevel && parent in wrappers && ingest(child) -> children
            else -> return false
        }
        val identity = child.substringBefore('#')
        if (identity !in destinations && destinations.size >= 4) return false
        destinations += identity
        return true
    }
    fun clear() { wrappers.clear(); children.clear() }
}
/** Streamed's documented iframe integration, with navigation/popups guarded by the native host. */
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
