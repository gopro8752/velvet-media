package tv.velvet.data.companion

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import tv.velvet.data.net.await
import tv.velvet.data.settings.SettingsRepository

/**
 * One handoff, as posted by a phone and claimed by a TV. [positionMs] is
 * informational — the receiving device resumes from the synced progress row
 * (the sender flushes it before posting), which survives even if the claim
 * happens after the row lands.
 */
@Serializable
data class HandoffPayload(
    val id: Long? = null,
    val profileId: String,
    val mediaId: Int,
    val type: String,
    val season: Int? = null,
    val episode: Int? = null,
    val positionMs: Long = 0,
    val title: String? = null,
)

@Serializable
private data class SegmentWire(val startMs: Long = 0, val endMs: Long = 0)

@Serializable
private data class SegmentsResponse(val episodes: Map<String, SegmentWire> = emptyMap())

@Serializable
private data class PendingResponse(val handoff: HandoffPayload? = null)

@Serializable
private data class ClaimResponse(val claimed: Boolean = false)

@Serializable
private data class ReportPlayBody(val imdbId: String, val season: Int, val episode: Int, val url: String)

@Serializable
private data class ClaimBody(val id: Long)

/**
 * Companion features living on the velvet-sync server beyond watch-state sync:
 * skip-intro segment markers (report what plays, read markers back) and
 * throw-to-TV handoffs. Reuses the sync URL + token from Settings — when sync is
 * off every call is an inert no-op, and every failure is swallowed: none of these
 * features may ever break playback.
 */
class CompanionApi(
    private val client: OkHttpClient,
    private val settingsRepository: SettingsRepository,
    json: Json,
) {
    private val wire = Json(from = json) { encodeDefaults = true }

    private data class Config(val baseUrl: String, val token: String)

    private suspend fun config(): Config? {
        val s = runCatching { settingsRepository.settings.first() }.getOrNull() ?: return null
        if (!s.syncEnabled) return null
        val url = s.syncUrl.trim().trimEnd('/')
        if (url.isBlank()) return null
        return Config(url, s.syncToken.trim())
    }

    suspend fun isEnabled(): Boolean = config() != null

    // Every public call hops to Dispatchers.IO itself: await() resumes with a LAZY
    // body, so response.body.string() does socket reads on the CALLING thread — from
    // a main-thread coroutine that's NetworkOnMainThreadException. (It slipped through
    // emulator testing because localhost delivers the body pre-buffered with the
    // headers; real LAN does not.)

    /** Tell the worker what URL this (or the upcoming) episode plays from. */
    suspend fun reportPlay(imdbId: String, season: Int, episode: Int, url: String) {
        val cfg = config() ?: return
        withContext(Dispatchers.IO) {
            runCatching {
                post(cfg, "/report_play", wire.encodeToString(
                    ReportPlayBody.serializer(), ReportPlayBody(imdbId, season, episode, url))
                ).use { }
            }
        }
    }

    /** Intro markers for a season: episode number -> startMs..endMs. Empty on any failure. */
    suspend fun introSegments(imdbId: String, season: Int): Map<Int, LongRange> {
        val cfg = config() ?: return emptyMap()
        return withContext(Dispatchers.IO) {
            runCatching {
                val request = Request.Builder()
                    .url("${cfg.baseUrl}/segments?imdb=$imdbId&season=$season")
                    .get().authorized(cfg).build()
                client.await(request).use { response ->
                    if (!response.isSuccessful) emptyMap()
                    else wire.decodeFromString(
                        SegmentsResponse.serializer(), response.body?.string().orEmpty()
                    ).episodes.mapNotNull { (ep, seg) ->
                        val n = ep.toIntOrNull() ?: return@mapNotNull null
                        if (seg.endMs <= seg.startMs) return@mapNotNull null
                        n to (seg.startMs..seg.endMs)
                    }.toMap()
                }
            }.getOrDefault(emptyMap())
        }
    }

    /** Phone side: post a handoff. True when the server accepted it. */
    suspend fun postHandoff(payload: HandoffPayload): Boolean {
        val cfg = config() ?: return false
        return withContext(Dispatchers.IO) {
            runCatching {
                post(cfg, "/handoff", wire.encodeToString(HandoffPayload.serializer(), payload))
                    .use { it.isSuccessful }
            }.getOrDefault(false)
        }
    }

    /** TV side: the newest unclaimed handoff for [profileId], or null. */
    suspend fun pendingHandoff(profileId: String): HandoffPayload? {
        val cfg = config() ?: return null
        return withContext(Dispatchers.IO) {
            runCatching {
                val request = Request.Builder()
                    .url("${cfg.baseUrl}/handoff/pending?profileId=$profileId")
                    .get().authorized(cfg).build()
                client.await(request).use { response ->
                    if (!response.isSuccessful) null
                    else wire.decodeFromString(
                        PendingResponse.serializer(), response.body?.string().orEmpty()
                    ).handoff
                }
            }.onFailure {
                android.util.Log.w("CompanionApi", "pendingHandoff failed", it)
            }.getOrNull()
        }
    }

    /** TV side: atomically claim [id]. False when another device won (or expired). */
    suspend fun claimHandoff(id: Long): Boolean {
        val cfg = config() ?: return false
        return withContext(Dispatchers.IO) {
            runCatching {
                post(cfg, "/handoff/claim", wire.encodeToString(ClaimBody.serializer(), ClaimBody(id)))
                    .use { response ->
                        if (!response.isSuccessful) false
                        else wire.decodeFromString(
                            ClaimResponse.serializer(), response.body?.string().orEmpty()
                        ).claimed
                    }
            }.getOrDefault(false)
        }
    }

    private suspend fun post(cfg: Config, path: String, body: String) =
        client.await(
            Request.Builder()
                .url(cfg.baseUrl + path)
                .post(body.toRequestBody(JSON_MEDIA))
                .authorized(cfg)
                .build()
        )

    private fun Request.Builder.authorized(cfg: Config): Request.Builder = apply {
        if (cfg.token.isNotEmpty()) header("Authorization", "Bearer ${cfg.token}")
    }

    private companion object {
        val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    }
}
