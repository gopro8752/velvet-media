package tv.velvet.data.live

import androidx.media3.common.MimeTypes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import tv.velvet.data.net.await
import tv.velvet.data.settings.SettingsRepository
import java.io.IOException
import java.util.concurrent.TimeUnit

@Serializable
data class LiveChannel(val id: String, val name: String, val number: String? = null,
    val logoUrl: String? = null, val group: String? = null) {
    val isSports get() = group?.contains("sport", ignoreCase = true) == true
}

@Serializable
data class LiveCatalog(val enabled: Boolean = false, val sourceName: String = "Live TV",
    val channels: List<LiveChannel> = emptyList(), val message: String? = null) {
    fun validated() = copy(channels = channels.filter { it.id.isNotBlank() && it.name.isNotBlank() }.distinctBy { it.id })
}

@Serializable private data class TuneRequest(val channelId: String)
@Serializable internal data class TuneResponse(val sessionId: String, val playbackPath: String,
    val mimeType: String, val channel: LiveChannel, val canPause: Boolean = false, val canSeek: Boolean = false,
    val drm: LiveDrmResponse? = null)
@Serializable internal data class LiveDrmResponse(val scheme: String, val licensePath: String, val multiSession: Boolean = false)
@Serializable private data class LiveError(val error: String = "Live TV is unavailable. Try again.")

/** Session credentials are kept in memory and never appear in a navigation URL or watch history. */
class LiveSession(val id: String, val channel: LiveChannel, val playbackUrl: String,
    val mimeType: String, internal val releaseUrl: String, internal val bearer: String?,
    val drm: LiveWidevine? = null)

/** Device CDM handles the keys. This is only an expiring backend license capability. */
class LiveWidevine internal constructor(val licenseUrl: String, val multiSession: Boolean)

interface LiveService {
    suspend fun tune(channelId: String): LiveSession
    suspend fun release(session: LiveSession)
}

class LiveException(message: String) : IOException(message)

/** A stalled broadcast retries the same station; it never silently changes channels. */
class LiveReconnectBudget {
    private var attempts = 0
    fun take(): Boolean = if (attempts < 2) { attempts++; true } else false
    fun reset() { attempts = 0 }
}

/** Media3 treats an explicit Apple HLS MIME alias as progressive; normalize the validated wire format. */
internal fun livePlayerMimeType(wireMimeType: String): String {
    return when (wireMimeType) {
        "application/vnd.apple.mpegurl", MimeTypes.APPLICATION_M3U8 -> MimeTypes.APPLICATION_M3U8
        MimeTypes.APPLICATION_MPD -> MimeTypes.APPLICATION_MPD
        else -> throw IllegalArgumentException("This live stream format isn't supported.")
    }
}

internal fun liveWidevine(base: HttpUrl, drm: LiveDrmResponse?, sessionId: String, playbackPath: String): LiveWidevine? {
    if (drm == null) return null
    require(drm.scheme == "widevine") { "This live protection format isn't supported on this device." }
    // A license URI embedded in provider metadata must never override this
    // same-origin, session-scoped relay or receive the backend's bearer token.
    require(Regex("^[a-f0-9]{48}$").matches(sessionId) && drm.licensePath == "/live/drm/$sessionId") { "Invalid live license address." }
    require(Regex("^/live/streams/$sessionId/[A-Za-z0-9_-]+\\.(m3u8|mpd)$").matches(playbackPath)) { "Invalid protected live playback address." }
    val url = base.resolve(drm.licensePath) ?: error("Invalid live license address.")
    require(url.scheme == base.scheme && url.host == base.host && url.port == base.port &&
        url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null) { "Invalid live license address." }
    return LiveWidevine(url.toString(), drm.multiSession)
}

internal fun livePlaybackUrl(base: HttpUrl, path: String): HttpUrl {
    require(path.startsWith("/live/streams/") && !path.contains('#')) { "Invalid live playback address." }
    val url = base.resolve(path) ?: error("Invalid live playback address.")
    require(url.scheme == base.scheme && url.host == base.host && url.port == base.port &&
        url.encodedPath.startsWith("/live/streams/")) { "Invalid live playback address." }
    return url
}

fun filterLiveChannels(channels: List<LiveChannel>, query: String, sportsOnly: Boolean): List<LiveChannel> {
    val term = query.trim()
    return channels.filter { (!sportsOnly || it.isSports) && (term.isBlank() ||
        it.name.contains(term, true) || it.number?.contains(term, true) == true || it.group?.contains(term, true) == true) }
}

fun adjacentLiveChannel(channels: List<LiveChannel>, currentId: String, direction: Int): LiveChannel? {
    if (channels.size < 2) return null
    val index = channels.indexOfFirst { it.id == currentId }
    if (index < 0) return null
    return channels[(index + if (direction < 0) channels.size - 1 else 1) % channels.size]
}

class LiveRepository(private val settings: SettingsRepository, client: OkHttpClient, private val json: Json) : LiveService {
    private val client = client.newBuilder().callTimeout(25, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).build()
    private val releaseClient = client.newBuilder().callTimeout(8, TimeUnit.SECONDS).build()
    @Volatile var cachedCatalog: LiveCatalog? = null
        private set
    val lastChannelId = MutableStateFlow<String?>(null)

    private suspend fun endpoint(): Pair<HttpUrl, String?> {
        val config = settings.settings.first()
        val base = config.backendUrl.trim().trimEnd('/').removeSuffix("/manifest.json").toHttpUrlOrNull()
            ?: throw LiveException("Connect Velvet Backend in Settings to use Live TV.")
        val sync = config.syncUrl.toHttpUrlOrNull()
        val bearer = config.syncToken.trim().takeIf { it.isNotBlank() && sync != null &&
            sync.scheme == base.scheme && sync.host == base.host && sync.port == base.port }
        return base to bearer
    }

    suspend fun channels(): LiveCatalog = withContext(Dispatchers.IO) {
        val (base, token) = endpoint()
        val request = Request.Builder().url(base.toString().trimEnd('/') + "/live/channels").authenticated(token).build()
        client.await(request).use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw apiError(response.code, body)
            json.decodeFromString(LiveCatalog.serializer(), body).validated().also { cachedCatalog = it }
        }
    }

    suspend fun guide(): LiveGuide = withContext(Dispatchers.IO) {
        val (base, token) = endpoint()
        val request = Request.Builder().url(base.toString().trimEnd('/') + "/live/guide").authenticated(token).build()
        client.await(request).use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw apiError(response.code, body)
            json.decodeFromString(LiveGuide.serializer(), body)
        }
    }

    override suspend fun tune(channelId: String): LiveSession = withContext(Dispatchers.IO) {
        val (base, token) = endpoint()
        val request = Request.Builder().url(base.toString().trimEnd('/') + "/live/tune").authenticated(token)
            // Headers keep older backends compatible: their existing tune body
            // denies unknown fields, while unrecognized headers are harmless.
            .header("X-Velvet-Client", "android")
            .header("X-Velvet-Playback-Capabilities", "hls-clear,dash-widevine,hls-fmp4-widevine")
            .post(json.encodeToString(TuneRequest.serializer(), TuneRequest(channelId)).toRequestBody("application/json".toMediaType())).build()
        client.await(request).use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) throw apiError(response.code, body)
            val tuned = json.decodeFromString(TuneResponse.serializer(), body)
            require(tuned.sessionId.isNotBlank() && tuned.channel.id == channelId) { "The channel response was invalid. Try again." }
            val session = LiveSession(tuned.sessionId, tuned.channel, "", tuned.mimeType,
                base.newBuilder().addPathSegments("live/sessions").addPathSegment(tuned.sessionId).build().toString(), token)
            try {
                val playerMimeType = livePlayerMimeType(tuned.mimeType)
                LiveSession(session.id, session.channel, livePlaybackUrl(base, tuned.playbackPath).toString(),
                    playerMimeType, session.releaseUrl, token, liveWidevine(base, tuned.drm, tuned.sessionId, tuned.playbackPath))
            } catch (error: Exception) { runCatching { release(session) }; throw error }
        }
    }

    override suspend fun release(session: LiveSession) = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(session.releaseUrl).authenticated(session.bearer).delete().build()
        releaseClient.await(request).use { }
    }

    private fun Request.Builder.authenticated(token: String?) = apply { if (token != null) header("Authorization", "Bearer $token") }
    private fun apiError(code: Int, body: String): LiveException {
        val message = runCatching { json.decodeFromString(LiveError.serializer(), body).error }.getOrNull()
        return LiveException(message?.takeIf { it.isNotBlank() }?.take(240) ?: when (code) {
            401, 403 -> "Live TV couldn't connect. Check the backend token in Settings."
            404 -> "Live TV needs an updated Velvet Backend."
            else -> "Live TV is unavailable. Check the connection and try again."
        })
    }
}
