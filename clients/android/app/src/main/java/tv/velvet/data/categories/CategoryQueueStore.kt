package tv.velvet.data.categories

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import tv.velvet.data.local.DEFAULT_PROFILE_ID
import tv.velvet.data.model.PlayTarget
import tv.velvet.data.model.StreamOption
import tv.velvet.data.settings.SettingsRepository
import java.security.MessageDigest
import java.util.UUID

private val Context.queueStore by preferencesDataStore(name = "velvet_category_queue")

@Serializable
data class CategoryQueueSession(
    val id: String,
    val profileId: String,
    val title: String,
    val items: List<CategoryItem>,
    val cursor: Int = 0,
    val failures: Int = 0,
    val finished: Boolean = false,
    val notice: String? = null,
) {
    fun target(index: Int = cursor): PlayTarget? = items.getOrNull(index)
        ?.takeIf { !finished && id.isNotBlank() && profileId.isNotBlank() && failures >= 0 &&
            cursor in items.indices && it.valid && (it.type == "movie" || it.episode != null) }
        ?.playTarget()
        ?.copy(queueSessionId = id, queueIndex = index)

    /** A stable plan lets prefetch and advance agree before a new pass is persisted. */
    fun nextTarget(): PlayTarget? {
        target() ?: return null
        val nextIndex = if (cursor == items.lastIndex) 0 else cursor + 1
        val next = target(nextIndex) ?: return null
        return if (nextIndex == 0) next.copy(queueSessionId =
            UUID.nameUUIDFromBytes("velvet-category-pass:$id".toByteArray(Charsets.UTF_8)).toString())
        else next
    }

    /** Previous means the persisted playlist order, including a shuffled order. */
    fun previousTarget(): PlayTarget? {
        target() ?: return null
        if (cursor <= 0) return null
        val previous = target(cursor - 1) ?: return null
        // Revisiting an index must not revive an old player's compare-and-advance
        // identity. The deterministic plan also stays stable across cache reads.
        return previous.copy(queueSessionId = UUID.nameUUIDFromBytes(
            "velvet-category-previous:$id:$cursor".toByteArray(Charsets.UTF_8)).toString())
    }

    fun matches(profile: String, target: PlayTarget) = !finished && profileId == profile &&
        id == target.queueSessionId && cursor == target.queueIndex && target() == target
}

data class QueueAdvance(val session: CategoryQueueSession, val next: PlayTarget?, val stoppedForFailures: Boolean = false)

/** Queue countdown follows media time; it never owns advancement or consumes paused time. */
fun categoryQueueCountdownSeconds(positionMs: Long, durationMs: Long): Int? {
    if (durationMs <= 0) return null
    val remaining = durationMs - positionMs
    if (remaining > 40_000 || remaining < 0) return null
    return ((remaining + 999) / 1_000).toInt()
}

/** Compare-and-advance: repeat in order with a new pass identity and bounded source failures. */
fun advanceCategoryQueue(session: CategoryQueueSession, id: String, cursor: Int, failed: Boolean): QueueAdvance? {
    if (session.id != id || session.cursor != cursor || session.target() == null) return null
    val next = session.nextTarget() ?: return null
    val failures = if (failed) session.failures.coerceAtMost(2) + 1 else 0
    if (failures >= 3) return QueueAdvance(session.copy(failures = failures), null, true)
    val notice = if (failed) "Skipped ${session.items[cursor].title}: no playable source." else null
    val updated = session.copy(id = next.queueSessionId!!, cursor = next.queueIndex!!,
        failures = failures, notice = notice)
    return QueueAdvance(updated, updated.target())
}

/** Compare-and-retreat without wrapping before the first item of the current pass. */
fun previousCategoryQueue(session: CategoryQueueSession, id: String, cursor: Int): QueueAdvance? {
    if (session.id != id || session.cursor != cursor || session.target() == null) return null
    val previous = session.previousTarget() ?: return null
    val updated = session.copy(id = previous.queueSessionId!!, cursor = previous.queueIndex!!,
        failures = 0, notice = null)
    return QueueAdvance(updated, updated.target())
}

/** One disk-backed queue per profile; navigation carries only its opaque id and cursor. */
class CategoryQueueStore(private val context: Context, private val settings: SettingsRepository, private val json: Json) {
    private fun key(profile: String) = stringPreferencesKey("queue_" +
        MessageDigest.getInstance("SHA-256").digest(profile.toByteArray()).joinToString("") { "%02x".format(it) })
    private fun decode(raw: String?) = raw?.let { runCatching { json.decodeFromString(CategoryQueueSession.serializer(), it) }.getOrNull() }
    private suspend fun profile() = settings.activeProfileId.first() ?: DEFAULT_PROFILE_ID

    suspend fun start(profile: String, category: Category): PlayTarget {
        require(profile == profile()) { "Profile changed. Start the category again." }
        val items = category.validated().items
        require(items.isNotEmpty() && items.all { it.type == "movie" || (it.season != null && it.episode != null) }) {
            "The category couldn't be expanded into playable episodes."
        }
        val session = CategoryQueueSession(UUID.randomUUID().toString(), profile, category.title, items)
        context.queueStore.edit { it[key(profile)] = json.encodeToString(CategoryQueueSession.serializer(), session) }
        synchronized(this) { prefetched = null }
        return session.target()!!
    }

    suspend fun current(target: PlayTarget): CategoryQueueSession? {
        val profile = profile()
        return decode(context.queueStore.data.first()[key(profile)])?.takeIf { it.matches(profile, target) }
    }

    suspend fun advance(target: PlayTarget, failed: Boolean): QueueAdvance? {
        val profile = profile()
        var result: QueueAdvance? = null
        context.queueStore.edit { preferences ->
            val current = decode(preferences[key(profile)]) ?: return@edit
            if (!current.matches(profile, target)) return@edit
            result = advanceCategoryQueue(current, target.queueSessionId ?: return@edit, target.queueIndex ?: return@edit, failed)
            result?.let { preferences[key(profile)] = json.encodeToString(CategoryQueueSession.serializer(), it.session) }
        }
        return result
    }

    suspend fun previous(target: PlayTarget): QueueAdvance? {
        val profile = profile()
        var result: QueueAdvance? = null
        context.queueStore.edit { preferences ->
            val current = decode(preferences[key(profile)]) ?: return@edit
            if (!current.matches(profile, target)) return@edit
            result = previousCategoryQueue(current, target.queueSessionId ?: return@edit,
                target.queueIndex ?: return@edit)
            result?.let { preferences[key(profile)] = json.encodeToString(CategoryQueueSession.serializer(), it.session) }
        }
        if (result != null) synchronized(this) { prefetched = null }
        return result
    }

    suspend fun markPlaying(target: PlayTarget) {
        val profile = profile()
        context.queueStore.edit { preferences ->
            val session = decode(preferences[key(profile)]) ?: return@edit
            if (session.matches(profile, target) && session.failures > 0) {
                preferences[key(profile)] = json.encodeToString(CategoryQueueSession.serializer(), session.copy(failures = 0, notice = null))
            }
        }
    }

    suspend fun cancel(target: PlayTarget) {
        val profile = profile()
        context.queueStore.edit { preferences ->
            if (decode(preferences[key(profile)])?.id == target.queueSessionId) preferences.remove(key(profile))
        }
        synchronized(this) { prefetched = null }
    }

    private data class Prefetched(val target: PlayTarget, val at: Long, val streams: List<StreamOption>)
    private var prefetched: Prefetched? = null
    @Synchronized fun saveStreams(target: PlayTarget, streams: List<StreamOption>) {
        if (streams.isNotEmpty()) prefetched = Prefetched(target, System.currentTimeMillis(), streams)
    }
    @Synchronized fun takeStreams(target: PlayTarget): List<StreamOption>? {
        val cached = prefetched ?: return null
        if (cached.target != target || System.currentTimeMillis() - cached.at > 600_000) return null
        prefetched = null
        return cached.streams
    }
}
