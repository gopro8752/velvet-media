package tv.velvet.data.settings

import android.content.Context
import android.util.Log
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import tv.velvet.data.model.StreamSourceConfig
import tv.velvet.data.streams.ReleaseGroup
import tv.velvet.data.streams.withBlockedReleaseGroup
import tv.velvet.data.streams.withoutBlockedReleaseGroup

private val Context.dataStore by preferencesDataStore(name = "velvet_settings")

data class VelvetSettings(
    val tmdbApiKey: String,
    val streamSources: List<StreamSourceConfig>,
    /** Ordered, enabled row ids for the home screen. Empty = use defaults from TmdbRepository. */
    val rowOrder: List<String>,
    val autoplayNext: Boolean,
    val autoplayCountdownSecs: Int,
    val preferredQuality: String, // "2160p" | "1080p" | "720p"
    /** Tunneled video playback — required by some Dolby Vision profiles on Shield. */
    val tunneledPlayback: Boolean,
    /** Watch-state sync (velvet-sync server). Defaulted so existing constructors compile. */
    val syncEnabled: Boolean = false,
    val syncUrl: String = SettingsRepository.DEFAULT_SYNC_URL,
    val syncToken: String = "",
    /**
     * The single velvet-backend URL that powers BOTH streaming and sync. Setting it
     * (via [SettingsRepository.setBackendUrl]) writes the stream source AND the sync
     * URL together, so the user types one link. Falls back to the legacy syncUrl for
     * installs that predate this field.
     */
    val backendUrl: String = "",
)

class SettingsRepository(private val context: Context, private val json: Json) {

    private object Keys {
        val TMDB_KEY = stringPreferencesKey("tmdb_api_key")
        val SOURCES = stringPreferencesKey("stream_sources_json")
        val ROW_ORDER = stringPreferencesKey("row_order_csv")
        val AUTOPLAY = booleanPreferencesKey("autoplay_next")
        val COUNTDOWN = intPreferencesKey("autoplay_countdown_secs")
        val QUALITY = stringPreferencesKey("preferred_quality")
        val TUNNELED = booleanPreferencesKey("tunneled_playback")
        val SYNC_ENABLED = booleanPreferencesKey("sync_enabled")
        val SYNC_URL = stringPreferencesKey("sync_url")
        val SYNC_TOKEN = stringPreferencesKey("sync_token")
        val SYNC_CURSOR = longPreferencesKey("sync_cursor")
        val ACTIVE_PROFILE_ID = stringPreferencesKey("active_profile_id")
        val DOZE_MARKER = stringPreferencesKey("doze_marker_json")
        val BACKEND_URL = stringPreferencesKey("backend_url")
        val MANUAL_GROUPS = stringPreferencesKey("manual_binge_groups_json")
        val BLOCKED_GROUPS = stringPreferencesKey("blocked_release_groups_by_show_json")
        val HANDOFF_DEVICE_ID = stringPreferencesKey("handoff_device_id")
        val HANDOFF_SEQUENCE = longPreferencesKey("handoff_presence_sequence")
    }

    companion object {
        // Credentials are entered at runtime in Settings and are never bundled.
        const val DEFAULT_TMDB_KEY = ""
        const val DEFAULT_SYNC_URL = ""
        private const val TAG = "SettingsRepository"
        private val MANUAL_GROUPS_SERIALIZER =
            MapSerializer(String.serializer(), String.serializer())
        private val BLOCKED_GROUPS_SERIALIZER =
            MapSerializer(String.serializer(), ListSerializer(ReleaseGroup.serializer()))
    }

    val settings: Flow<VelvetSettings> = context.dataStore.data.map { p ->
        VelvetSettings(
            tmdbApiKey = p[Keys.TMDB_KEY] ?: DEFAULT_TMDB_KEY,
            // NOTE: keep every future StreamSourceConfig field defaulted so old JSON
            // keeps decoding — a decode failure here silently drops all sources.
            streamSources = p[Keys.SOURCES]?.let { raw ->
                runCatching {
                    json.decodeFromString(ListSerializer(StreamSourceConfig.serializer()), raw)
                }.getOrElse { e ->
                    Log.e(TAG, "Corrupt stream_sources_json — sources need re-adding", e)
                    emptyList()
                }
            } ?: emptyList(),
            rowOrder = p[Keys.ROW_ORDER]?.split(',')?.filter { it.isNotBlank() } ?: emptyList(),
            autoplayNext = p[Keys.AUTOPLAY] ?: true,
            autoplayCountdownSecs = p[Keys.COUNTDOWN] ?: 8,
            preferredQuality = p[Keys.QUALITY] ?: "2160p",
            tunneledPlayback = p[Keys.TUNNELED] ?: false,
            syncEnabled = p[Keys.SYNC_ENABLED] ?: false,
            syncUrl = p[Keys.SYNC_URL] ?: DEFAULT_SYNC_URL,
            syncToken = p[Keys.SYNC_TOKEN] ?: "",
            // Prefer the unified backend URL; fall back to the legacy sync URL / first
            // stream source so upgrading installs show their existing value.
            backendUrl = p[Keys.BACKEND_URL]
                ?: p[Keys.SYNC_URL]
                ?: "",
        )
    }

    /**
     * Sync pull cursor: the velvet-sync serverNow of the last fully-applied pull.
     * Internal to the SyncEngine — not part of [VelvetSettings].
     */
    val syncCursor: Flow<Long> = context.dataStore.data.map { it[Keys.SYNC_CURSOR] ?: 0L }

    suspend fun setSyncCursor(serverNow: Long) =
        context.dataStore.edit { it[Keys.SYNC_CURSOR] = serverNow }

    /**
     * The profile whose watch state is shown on THIS device. Per-device, never synced.
     * null until first chosen/bootstrapped — the picker gates on that (see spec). Kept
     * out of [VelvetSettings]: it changes far more often and only the profile layer reads it.
     */
    val activeProfileId: Flow<String?> =
        context.dataStore.data.map { it[Keys.ACTIVE_PROFILE_ID] }

    suspend fun setActiveProfileId(id: String) =
        context.dataStore.edit { it[Keys.ACTIVE_PROFILE_ID] = id }

    /** Device identity and ordering survive process death; neither is watch-state sync. */
    suspend fun nextHandoffPresence(): Pair<String, Long> {
        var result: Pair<String, Long>? = null
        context.dataStore.edit { p ->
            val id = p[Keys.HANDOFF_DEVICE_ID] ?: java.util.UUID.randomUUID().toString()
            val sequence = (p[Keys.HANDOFF_SEQUENCE] ?: 0L) + 1L
            p[Keys.HANDOFF_DEVICE_ID] = id
            p[Keys.HANDOFF_SEQUENCE] = sequence
            result = id to sequence
        }
        return requireNotNull(result)
    }

    suspend fun setTmdbApiKey(key: String) =
        context.dataStore.edit { it[Keys.TMDB_KEY] = key.trim() }

    suspend fun setStreamSources(sources: List<StreamSourceConfig>) =
        context.dataStore.edit {
            it[Keys.SOURCES] = json.encodeToString(
                ListSerializer(StreamSourceConfig.serializer()), sources
            )
        }

    suspend fun setRowOrder(rowIds: List<String>) =
        context.dataStore.edit { it[Keys.ROW_ORDER] = rowIds.joinToString(",") }

    suspend fun setAutoplayNext(enabled: Boolean) =
        context.dataStore.edit { it[Keys.AUTOPLAY] = enabled }

    suspend fun setAutoplayCountdownSecs(secs: Int) =
        context.dataStore.edit { it[Keys.COUNTDOWN] = secs }

    suspend fun setPreferredQuality(quality: String) =
        context.dataStore.edit { it[Keys.QUALITY] = quality }

    suspend fun setTunneledPlayback(enabled: Boolean) =
        context.dataStore.edit { it[Keys.TUNNELED] = enabled }

    suspend fun setSyncEnabled(enabled: Boolean) =
        context.dataStore.edit { it[Keys.SYNC_ENABLED] = enabled }

    suspend fun setSyncUrl(url: String) =
        context.dataStore.edit { it[Keys.SYNC_URL] = url.trim().trimEnd('/') }

    suspend fun setSyncToken(token: String) =
        context.dataStore.edit { it[Keys.SYNC_TOKEN] = token.trim() }

    /**
     * The one URL the user types. Points the stream resolver AND watch-state sync
     * at the same velvet-backend, so there's a single field instead of two. Writes
     * the stream source list (one "Velvet Backend" entry) and the sync url/enabled
     * flag atomically; a blank url clears the source and turns sync off.
     */
    suspend fun setBackendUrl(url: String) {
        var clean = url.trim().trimEnd('/')
        if (clean.endsWith("/manifest.json")) clean = clean.removeSuffix("/manifest.json").trimEnd('/')
        val sources = if (clean.isBlank()) emptyList()
        else listOf(StreamSourceConfig(name = "Velvet Backend", baseUrl = clean, enabled = true))
        context.dataStore.edit { p ->
            p[Keys.BACKEND_URL] = clean
            p[Keys.SOURCES] = json.encodeToString(
                ListSerializer(StreamSourceConfig.serializer()), sources
            )
            p[Keys.SYNC_URL] = clean
            p[Keys.SYNC_ENABLED] = clean.isNotBlank()
        }
    }

    /**
     * Sticky release group per show: imdbId -> bingeGroup, written ONLY when the user
     * hand-picks a stream from the picker (never by autopick or failover — a manual pick
     * after an autopick had issues is the owner saying "this group works, stay on it").
     * The player reads it so every later episode of that show, this session and the
     * next, prefers the same group when it exists. Kept out of [VelvetSettings]: only
     * the player reads it, and it grows per-show rather than being app-wide config.
     */
    val manualBingeGroups: Flow<Map<String, String>> =
        context.dataStore.data.map { decodeManualGroups(it[Keys.MANUAL_GROUPS]) }

    /** Upsert one show's manual group — read-modify-write inside a single edit. */
    suspend fun setManualBingeGroup(imdbId: String, bingeGroup: String) =
        context.dataStore.edit { p ->
            val merged = decodeManualGroups(p[Keys.MANUAL_GROUPS]) + (imdbId to bingeGroup)
            p[Keys.MANUAL_GROUPS] = json.encodeToString(MANUAL_GROUPS_SERIALIZER, merged)
        }

    suspend fun clearManualBingeGroup(imdbId: String) =
        context.dataStore.edit { p ->
            p[Keys.MANUAL_GROUPS] = json.encodeToString(
                MANUAL_GROUPS_SERIALIZER, decodeManualGroups(p[Keys.MANUAL_GROUPS]) - imdbId.trim()
            )
        }

    /** Device-local, durable exclusions for one show; unrelated shows remain untouched. */
    val blockedReleaseGroups: Flow<Map<String, List<ReleaseGroup>>> =
        context.dataStore.data.map { decodeBlockedGroups(it[Keys.BLOCKED_GROUPS]) }

    /** Persist the block and retire a conflicting sticky pick in one atomic edit. */
    suspend fun blockReleaseGroup(imdbId: String, group: ReleaseGroup) =
        context.dataStore.edit { p ->
            val previous = decodeBlockedGroups(p[Keys.BLOCKED_GROUPS])
            val updated = withBlockedReleaseGroup(previous, imdbId, group)
            if (updated != previous) {
                p[Keys.BLOCKED_GROUPS] = json.encodeToString(BLOCKED_GROUPS_SERIALIZER, updated)
            }
            val manual = decodeManualGroups(p[Keys.MANUAL_GROUPS])
            val show = imdbId.trim()
            if (updated[show].orEmpty().any { it.key == manual[show]?.trim() }) {
                p[Keys.MANUAL_GROUPS] = json.encodeToString(MANUAL_GROUPS_SERIALIZER, manual - show)
            }
        }

    suspend fun unblockReleaseGroup(imdbId: String, groupKey: String) =
        context.dataStore.edit { p ->
            val updated = withoutBlockedReleaseGroup(decodeBlockedGroups(p[Keys.BLOCKED_GROUPS]), imdbId, groupKey)
            if (updated.isEmpty()) p.remove(Keys.BLOCKED_GROUPS)
            else p[Keys.BLOCKED_GROUPS] = json.encodeToString(BLOCKED_GROUPS_SERIALIZER, updated)
        }

    private fun decodeBlockedGroups(raw: String?): Map<String, List<ReleaseGroup>> =
        raw?.let {
            runCatching { json.decodeFromString(BLOCKED_GROUPS_SERIALIZER, it) }.getOrElse { emptyMap() }
        } ?: emptyMap()

    /**
     * NOTE: mirrors the streamSources decode above — a corrupt blob silently resets to
     * empty rather than wedging every settings read; losing sticky groups just means
     * the next manual pick re-learns them.
     */
    private fun decodeManualGroups(raw: String?): Map<String, String> =
        raw?.let {
            runCatching { json.decodeFromString(MANUAL_GROUPS_SERIALIZER, it) }
                .getOrElse { emptyMap() }
        } ?: emptyMap()

    /** Retire only the old per-device sleep bookmark; watch history is untouched. */
    suspend fun clearLegacySleepMarker() =
        context.dataStore.edit { it.remove(Keys.DOZE_MARKER) }
}
