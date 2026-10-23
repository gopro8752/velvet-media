package tv.velvet.data.streams

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import tv.velvet.data.model.StreamOption
import tv.velvet.data.net.await
import tv.velvet.data.settings.SettingsRepository
import java.util.concurrent.TimeUnit
import kotlin.math.abs

@Serializable data class RecoveryState(
    val status: String = "idle",
    val streamId: String? = null,
    val preparedFraction: Double? = null,
)
@Serializable data class ExactRecoveryState(
    val enabled: Boolean = false,
    val status: String = "idle",
    // Null means there is no trustworthy media-time mapping. Never derive this from file fraction.
    val verifiedAheadSeconds: Double? = null,
    val indexStatus: String = "pending",
    val holdFallback: Boolean = false,
    val lookaheadTargetSeconds: Double = 0.0,
    val updatedAgoSeconds: Double? = null,
) {
    /** Only a fresh server decision can defer speculative switching; player errors still fail over. */
    fun shouldHoldProactiveFallback(): Boolean = enabled && holdFallback &&
        updatedAgoSeconds?.let { it.isFinite() && it >= 0.0 && it <= 8.0 } == true
}

@Serializable data class ExactRepairState(
    val phase: String = "idle",
    @SerialName("charged_download_bytes") val chargedDownloadBytes: Long = 0,
)

@Serializable data class StreamHealth(
    val status: String = "unverified",
    val recovery: RecoveryState = RecoveryState(),
    val exactRecovery: ExactRecoveryState? = null,
    val repair: ExactRepairState? = null,
)

@Serializable data class RecoveryPlaybackPosition(
    val positionMs: Long,
    val durationMs: Long,
    val bufferedPositionMs: Long,
    val playing: Boolean,
    val stopped: Boolean = false,
    val sessionId: String,
    val generation: Long,
)
@Serializable private data class PrepareRecovery(val fraction: Double)

/** Optional backend extension; unsupported sources continue using ordinary error recovery. */
class StreamRecoveryApi(client: OkHttpClient, private val settings: SettingsRepository, private val json: Json) {
    private val client = client.newBuilder().callTimeout(5, TimeUnit.SECONDS).readTimeout(5, TimeUnit.SECONDS).build()

    suspend fun prepare(stream: StreamOption, fraction: Double) {
        val url = endpoint(stream.url, "prepare") ?: return
        safely {
            val body = json.encodeToString(PrepareRecovery.serializer(), PrepareRecovery(fraction.coerceIn(0.0, 1.0)))
                .toRequestBody("application/json".toMediaType())
            client.await(request(stream, url).post(body).build()).use { }
        }
    }

    suspend fun playback(stream: StreamOption, position: RecoveryPlaybackPosition) {
        val url = endpoint(stream.url, "playback") ?: return
        if (position.positionMs < 0 || position.durationMs < 0 || position.bufferedPositionMs < 0 ||
            position.generation < 0 || position.sessionId.isBlank()) return
        safely {
            val body = json.encodeToString(RecoveryPlaybackPosition.serializer(), position)
                .toRequestBody("application/json".toMediaType())
            client.await(request(stream, url).post(body).build()).use { }
        }
    }

    suspend fun health(stream: StreamOption, sessionId: String? = null): StreamHealth? {
        val base = endpoint(stream.url, "health") ?: return null
        val url = if (sessionId == null) base else base.newBuilder()
            .setQueryParameter("sessionId", sessionId).build()
        return safely {
            client.await(request(stream, url).get().build()).use { response ->
                if (!response.isSuccessful) null
                else json.decodeFromString(StreamHealth.serializer(), response.body?.string().orEmpty())
            }
        }
    }

    private suspend fun request(stream: StreamOption, url: HttpUrl): Request.Builder {
        val builder = Request.Builder().url(url)
        stream.headers.forEach { (key, value) -> builder.header(key, value) }
        val config = settings.settings.first()
        val sync = config.syncUrl.toHttpUrlOrNull()
        if (stream.headers.keys.none { it.equals("Authorization", true) } && sync != null &&
            sameOrigin(sync, url) && config.syncToken.isNotBlank()) {
            builder.header("Authorization", "Bearer ${config.syncToken.trim()}")
        }
        return builder
    }

    private suspend fun <T> safely(block: suspend () -> T): T? = withContext(Dispatchers.IO) {
        try { block() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
    }

    companion object {
        internal fun endpoint(raw: String, action: String): HttpUrl? {
            val url = raw.toHttpUrlOrNull() ?: return null
            val parts = url.pathSegments
            if (parts.size < 2 || parts[parts.size - 2] != "stream" || parts.last().isBlank()) return null
            return url.newBuilder().addPathSegment(action).build()
        }
        private fun sameOrigin(a: HttpUrl, b: HttpUrl) = a.scheme == b.scheme && a.host == b.host && a.port == b.port

        /**
         * Never invent a playback URL or leave the current source. When the caller
         * requested a preparation position, only accept that preparation: health
         * may still describe an older seek. The strict tolerance matches the backend.
         */
        fun preparedCandidate(
            current: StreamOption,
            health: StreamHealth,
            candidates: List<StreamOption>,
            requestedFraction: Double? = null,
        ): StreamOption? {
            if (health.recovery.status != "ready") return null
            if (requestedFraction != null) {
                val preparedFraction = health.recovery.preparedFraction ?: return null
                if (!requestedFraction.isFinite() || !preparedFraction.isFinite() ||
                    abs(preparedFraction - requestedFraction) >= .002) return null
            }
            val id = health.recovery.streamId?.takeIf { it.isNotBlank() } ?: return null
            val currentUrl = endpoint(current.url, "health") ?: return null
            return candidates.firstOrNull { candidate ->
                if (candidate.url == current.url) false
                else candidate.url.toHttpUrlOrNull()?.let { url ->
                    sameOrigin(currentUrl, url) && url.pathSegments ==
                        currentUrl.pathSegments.dropLast(2) + id
                } ?: false
            }
        }
    }
}
