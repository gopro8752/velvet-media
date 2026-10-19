package tv.velvet.data.companion

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import tv.velvet.data.net.await
import tv.velvet.data.model.StreamOption
import tv.velvet.data.settings.SettingsRepository

@Serializable
data class HandoffSourceHint(val title: String, val sourceName: String, val bingeGroup: String? = null,
    val streamId: String? = null)

@Serializable
data class TvHandoff(
    val id: String,
    val profileId: String,
    val mediaId: Int,
    val type: String,
    val season: Int? = null,
    val episode: Int? = null,
    val positionMs: Long,
    val title: String? = null,
    val sourceHint: HandoffSourceHint? = null,
    val playbackPath: String? = null,
)

@Serializable
data class TvHandoffStatus(val id: String, val state: String, val error: String? = null)

@Serializable
data class ReceiverPresence(
    val deviceId: String, val sessionId: String, val name: String,
    val profileId: String, val sequence: Long, val available: Boolean,
)
@Serializable private data class PresenceResult(val accepted: Boolean)
@Serializable private data class ClaimReceiver(val deviceId: String, val sessionId: String)
@Serializable private data class ReceiverClaim(val handoff: TvHandoff? = null)
@Serializable private data class ReceiverAck(
    val id: String, val deviceId: String, val sessionId: String,
    val state: String, val error: String? = null,
)
@Serializable data class ReceiverAckResult(val accepted: Boolean, val status: TvHandoffStatus)

/** Separate v2 paths prevent old/background receivers from consuming these requests. */
class TvHandoffApi(client: OkHttpClient, private val settings: SettingsRepository, json: Json) {
    private val client = client.newBuilder().callTimeout(5, TimeUnit.SECONDS).build()
    private val json = Json(json) { encodeDefaults = true }

    private suspend fun request(path: String, body: String? = null): String = withContext(Dispatchers.IO) {
        val cfg = settings.settings.first()
        check(cfg.syncEnabled && cfg.syncUrl.isNotBlank()) { "Device sync is disabled" }
        val builder = Request.Builder().url(cfg.syncUrl.trimEnd('/') + path)
        if (cfg.syncToken.isNotBlank()) builder.header("Authorization", "Bearer ${cfg.syncToken.trim()}")
        if (body != null) builder.post(body.toRequestBody("application/json".toMediaType()))
        client.await(builder.build()).use {
            if (!it.isSuccessful) throw IOException("TV handoff HTTP ${it.code}")
            it.body?.string() ?: throw IOException("Empty TV handoff response")
        }
    }

    suspend fun presence(body: ReceiverPresence): Boolean =
        json.decodeFromString<PresenceResult>(request("/handoff/presence", json.encodeToString(body))).accepted

    suspend fun claim(deviceId: String, sessionId: String): TvHandoff? =
        json.decodeFromString<ReceiverClaim>(request("/handoff/v2/claim", json.encodeToString(ClaimReceiver(deviceId, sessionId)))).handoff

    suspend fun status(id: String): TvHandoffStatus = json.decodeFromString(request("/handoff/v2/status?id=$id"))

    /** The server resolves this opaque ID; never re-search or probe another release. */
    suspend fun playbackStream(handoff: TvHandoff): StreamOption {
        val cfg = settings.settings.first()
        val path = requireNotNull(exactHandoffPath(handoff)) { "The phone's exact stream is unavailable. Send it again from the updated app." }
        check(cfg.syncEnabled && cfg.syncUrl.isNotBlank())
        return StreamOption(
            url = cfg.syncUrl.trimEnd('/') + path,
            title = handoff.sourceHint?.title ?: handoff.title.orEmpty(),
            sourceName = handoff.sourceHint?.sourceName ?: "Velvet Backend",
            bingeGroup = handoff.sourceHint?.bingeGroup,
            headers = if (cfg.syncToken.isBlank()) emptyMap() else mapOf("Authorization" to "Bearer ${cfg.syncToken.trim()}"),
        )
    }

    suspend fun ack(lease: HandoffLease, state: String, error: String? = null): ReceiverAckResult =
        json.decodeFromString(request("/handoff/v2/ack", json.encodeToString(
            ReceiverAck(lease.handoff.id, lease.deviceId, lease.sessionId, state, error?.take(240)),
        )))
}

data class HandoffLease(val handoff: TvHandoff, val deviceId: String, val sessionId: String)

/** Foreground identity is local and short lived, never resurrected by a restored route. */
class TvHandoffSession {
    @Volatile var sessionId: String? = null
    var visible: () -> Boolean = { false }
    private val leases = java.util.concurrent.ConcurrentHashMap<String, HandoffLease>()
    fun register(lease: HandoffLease) { leases[lease.handoff.id] = lease }
    fun get(id: String?): HandoffLease? = id?.let(leases::get)
    fun isEligible(lease: HandoffLease) = sessionId == lease.sessionId && visible()
    fun forget(id: String) { leases.remove(id) }
}

/** A transfer is allowed even in the first 30 seconds or the last 5% of a title. */
internal fun handoffPlaybackReached(positionMs: Long, targetMs: Long, playing: Boolean, seekPending: Boolean): Boolean =
    playing && !seekPending && positionMs >= (targetMs - 2_000).coerceAtLeast(0) && positionMs <= targetMs + 15_000

internal fun exactHandoffPath(handoff: TvHandoff): String? {
    val id = handoff.sourceHint?.streamId ?: return null
    if (!id.matches(Regex("[0-9a-f]{16}"))) return null
    return handoff.playbackPath?.takeIf { it == "/stream/$id" }
}
