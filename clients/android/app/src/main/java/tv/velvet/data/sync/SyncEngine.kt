package tv.velvet.data.sync

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import tv.velvet.data.local.DEFAULT_PROFILE_ID
import tv.velvet.data.local.MyListEntity
import tv.velvet.data.local.ProfileEntity
import tv.velvet.data.local.VelvetDatabase
import tv.velvet.data.local.WatchProgressEntity
import tv.velvet.data.local.WatchedEpisodeEntity
import tv.velvet.data.net.await
import tv.velvet.data.settings.SettingsRepository
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Watch-state sync against the velvet-sync server (last-write-wins per row).
 *
 * PUSH — every local mutation enqueues its full wire row (deletions = tombstones with
 * updatedAt = now), debounced ~1.5s into one POST /push. The queue lives in memory
 * only; a failed push is retried on the next trigger, and a later full reconcile
 * (first-enable full sync) heals any gaps.
 *
 * PULL — on launch/foreground, every 60s while foregrounded, and right after a
 * successful push: GET /state?since=<cursor>, apply rows that beat the local
 * timestamp (progress.updatedAt / watched.watchedAt / mylist.addedAt), advance the
 * persisted cursor to serverNow only after a fully-successful apply.
 *
 * Disabled or blank URL -> fully inert. All failures are silent-but-logged: sync
 * must NEVER break local behavior.
 */
class SyncEngine(
    database: VelvetDatabase,
    private val settingsRepository: SettingsRepository,
    private val okHttpClient: OkHttpClient,
    json: Json,
) {
    /**
     * encodeDefaults so defaulted fields (positionMs=0, watchedAt=0, deleted=false)
     * always travel — the server INSERTs every column explicitly, and an omitted
     * field would become NULL in a NOT NULL column.
     */
    private val wireJson: Json = Json(from = json) { encodeDefaults = true }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val progressDao = database.watchProgressDao()
    private val myListDao = database.myListDao()
    private val profileDao = database.profileDao()

    /** Human-readable last-sync result for the Settings screen. */
    private val _status = MutableStateFlow("Not synced yet")
    val status: StateFlow<String> = _status.asStateFlow()

    /**
     * Flips true once the first pull of this foreground session has finished (or as
     * soon as we know sync is off). The player awaits it before reading progress so a
     * resume position pushed from the phone seconds ago isn't missed. Reset on every
     * foreground so a fresh launch really does wait for fresh state.
     */
    private val _pullSettled = MutableStateFlow(false)

    /**
     * True while the Home screen is the visible destination — pulls tighten to 20s so
     * Continue Watching is current the moment he looks at it. Everything else (player,
     * details, settings, background) stays on the 60s cadence.
     */
    @Volatile private var homeForegrounded = false

    // ── pending push queue (latest row per key wins locally) ───────────────────
    // Data queues are keyed by (profileId, …natural key…); profiles by their id.
    private val queueLock = Any()
    private val pendingProgress = LinkedHashMap<ProgressKey, SyncProgressRow>()
    private val pendingWatched = LinkedHashMap<WatchedKey, SyncWatchedRow>()
    private val pendingMyList = LinkedHashMap<MyListKey, SyncMyListRow>()
    private val pendingProfiles = LinkedHashMap<String, SyncProfileRow>()
    private var pushJob: Job? = null
    private var tickerJob: Job? = null

    /** Serializes pushes/pulls so a ticker pull never races a debounced push-pull. */
    private val syncMutex = Mutex()

    /**
     * Cheap enqueue gate mirroring settings. Defaults to true so mutations landing
     * before the first settings emission are never dropped while sync is enabled;
     * spurious rows queued while disabled are harmless (push is a no-op).
     */
    @Volatile private var enqueueHint = true

    private data class SyncConfig(val baseUrl: String, val token: String)

    // Composite identities for the pending queues + LWW lookups (profileId leads).
    private data class ProgressKey(val profileId: String, val mediaId: Int, val type: String)
    private data class WatchedKey(val profileId: String, val mediaId: Int, val season: Int, val episode: Int)
    private data class MyListKey(val profileId: String, val mediaId: Int, val type: String)

    init {
        // Watch for disabled->enabled and URL changes: both trigger the full
        // reconcile (push EVERYTHING with stored timestamps, then pull since=0) —
        // this is how a device's existing history floods onto a new one.
        scope.launch {
            var prev: Pair<Boolean, String>? = null
            settingsRepository.settings
                .map { it.syncEnabled to it.syncUrl.trim().trimEnd('/') }
                .distinctUntilChanged()
                .collect { (enabled, url) ->
                    val before = prev
                    prev = enabled to url
                    enqueueHint = enabled && url.isNotBlank()
                    if (!enabled || url.isBlank()) {
                        _status.value = "Sync is off"
                        return@collect
                    }
                    // First emission is just the persisted state at launch — the
                    // launch pull comes from onAppForegrounded, not from here.
                    if (before == null) return@collect
                    if (!before.first || before.second != url) fullSync()
                }
        }
    }

    // ── mutation recording API (call AFTER the local DAO write; never throws) ──
    // Data mutations carry the profileId they were written under (the active profile).

    fun recordProgressUpsert(entity: WatchProgressEntity) = enqueue {
        pendingProgress[ProgressKey(entity.profileId, entity.mediaId, entity.type)] = entity.toSyncRow()
    }

    fun recordProgressDelete(profileId: String, mediaId: Int, typeKey: String) = enqueue {
        pendingProgress[ProgressKey(profileId, mediaId, typeKey)] =
            SyncProgressRow(profileId = profileId, mediaId = mediaId, type = typeKey, updatedAt = now(), deleted = true)
    }

    fun recordWatched(profileId: String, mediaId: Int, season: Int, episode: Int, watchedAt: Long) = enqueue {
        pendingWatched[WatchedKey(profileId, mediaId, season, episode)] =
            SyncWatchedRow(profileId, mediaId, season, episode, watchedAt = watchedAt, updatedAt = watchedAt)
    }

    fun recordUnwatched(profileId: String, mediaId: Int, season: Int, episode: Int) = enqueue {
        pendingWatched[WatchedKey(profileId, mediaId, season, episode)] =
            SyncWatchedRow(profileId, mediaId, season, episode, updatedAt = now(), deleted = true)
    }

    fun recordWatchedBatch(episodes: List<WatchedEpisodeEntity>) = enqueue {
        episodes.forEach { ep ->
            pendingWatched[WatchedKey(ep.profileId, ep.mediaId, ep.season, ep.episode)] = ep.toSyncRow()
        }
    }

    fun recordSeasonCleared(profileId: String, mediaId: Int, season: Int, episodes: List<Int>) = enqueue {
        val ts = now()
        episodes.forEach { ep ->
            pendingWatched[WatchedKey(profileId, mediaId, season, ep)] =
                SyncWatchedRow(profileId, mediaId, season, ep, updatedAt = ts, deleted = true)
        }
    }

    fun recordAllCleared(profileId: String, mediaId: Int, episodes: List<Pair<Int, Int>>) = enqueue {
        val ts = now()
        episodes.forEach { (season, episode) ->
            pendingWatched[WatchedKey(profileId, mediaId, season, episode)] =
                SyncWatchedRow(profileId, mediaId, season, episode, updatedAt = ts, deleted = true)
        }
    }

    fun recordMyListAdd(entity: MyListEntity) = enqueue {
        pendingMyList[MyListKey(entity.profileId, entity.mediaId, entity.type)] = entity.toSyncRow()
    }

    fun recordMyListRemove(profileId: String, mediaId: Int, typeKey: String) = enqueue {
        pendingMyList[MyListKey(profileId, mediaId, typeKey)] =
            SyncMyListRow(profileId = profileId, mediaId = mediaId, type = typeKey, updatedAt = now(), deleted = true)
    }

    // ── profile mutation recording (global; tombstone delete = updatedAt now) ──

    fun recordProfileUpsert(entity: ProfileEntity) = enqueue {
        pendingProfiles[entity.id] = entity.toSyncRow()
    }

    fun recordProfileDelete(id: String) = enqueue {
        pendingProfiles[id] =
            SyncProfileRow(id = id, updatedAt = now(), deleted = true)
    }

    // ── lifecycle + manual trigger ─────────────────────────────────────────────

    /** MainActivity.onStart: immediate sync (covers app launch) + the pull ticker. */
    fun onAppForegrounded() {
        tickerJob?.cancel()
        _pullSettled.value = false
        tickerJob = scope.launch {
            while (isActive) {
                syncMutex.withLock {
                    val cfg = currentConfig()
                    if (cfg != null && flushPending(cfg)) pullAndApply(cfg)
                }
                // Even a failed/disabled attempt settles the gate: the player must
                // never block on a server that isn't answering.
                _pullSettled.value = true
                // Wait in slices so a Home foreground/background flip re-times the
                // CURRENT wait too (60s -> 20s), not merely the next one.
                var waited = 0L
                while (isActive && waited < pullIntervalMs()) {
                    delay(TICK_SLICE_MS)
                    waited += TICK_SLICE_MS
                }
            }
        }
    }

    /** MainActivity.onStop: stop the pull ticker; queued pushes survive in memory. */
    fun onAppBackgrounded() {
        tickerJob?.cancel()
        tickerJob = null
        homeForegrounded = false
    }

    /**
     * Home became the visible destination (ON_RESUME): pull right now — he may have
     * just walked up to a TV that never left Home — and tighten the ticker to 20s.
     */
    fun onHomeForegrounded() {
        homeForegrounded = true
        pullNow()
    }

    /** Home is no longer visible (player/details/settings/background): back to 60s. */
    fun onHomeBackgrounded() {
        homeForegrounded = false
    }

    /**
     * A cheap cursor-based delta pull (flush anything queued first). Never resets the
     * cursor and never triggers the full reconcile — safe to call on every Home resume.
     */
    fun pullNow() {
        scope.launch {
            syncMutex.withLock {
                val cfg = currentConfig()
                if (cfg != null && flushPending(cfg)) pullAndApply(cfg)
                _pullSettled.value = true
            }
        }
    }

    /**
     * Suspends until this foreground session's first pull has finished, at most
     * [timeoutMs]. The player calls this before reading watch progress so a position
     * written on another device moments ago wins over the stale local row.
     */
    suspend fun awaitPullSettled(timeoutMs: Long = PULL_SETTLE_TIMEOUT_MS) {
        if (_pullSettled.value) return
        withTimeoutOrNull(timeoutMs) { _pullSettled.first { it } }
    }

    private fun pullIntervalMs(): Long =
        if (homeForegrounded) HOME_PULL_INTERVAL_MS else PULL_INTERVAL_MS

    /** Settings "Sync now": flush pending pushes, then pull. */
    fun syncNow() {
        scope.launch {
            syncMutex.withLock {
                val cfg = currentConfig()
                if (cfg == null) {
                    _status.value = "Sync is off"
                    return@withLock
                }
                _status.value = "Syncing…"
                if (flushPending(cfg)) pullAndApply(cfg)
            }
        }
    }

    // ── internals ──────────────────────────────────────────────────────────────

    private inline fun enqueue(block: () -> Unit) {
        if (!enqueueHint) return
        synchronized(queueLock) { block() }
        schedulePush()
    }

    private fun schedulePush() {
        synchronized(queueLock) {
            pushJob?.cancel()
            pushJob = scope.launch {
                delay(PUSH_DEBOUNCE_MS)
                syncMutex.withLock {
                    val cfg = currentConfig() ?: return@withLock
                    // Pull right after a successful push batch so cross-device
                    // changes land while the user is still active.
                    if (flushPending(cfg)) pullAndApply(cfg)
                }
            }
        }
    }

    /** Null when sync is disabled or the URL is blank — every network op gates on this. */
    private suspend fun currentConfig(): SyncConfig? {
        val s = runCatching { settingsRepository.settings.first() }.getOrNull() ?: return null
        if (!s.syncEnabled) return null
        val url = s.syncUrl.trim().trimEnd('/')
        if (url.isBlank()) return null
        return SyncConfig(url, s.syncToken.trim())
    }

    /**
     * Push the queued rows. Successfully-pushed entries are removed unless a newer
     * row for the same key arrived mid-flight; failures keep the queue intact for
     * the next trigger. Returns true when there was nothing to push or push landed.
     */
    private suspend fun flushPending(cfg: SyncConfig): Boolean {
        val progress: Map<ProgressKey, SyncProgressRow>
        val watched: Map<WatchedKey, SyncWatchedRow>
        val mylist: Map<MyListKey, SyncMyListRow>
        val profiles: Map<String, SyncProfileRow>
        synchronized(queueLock) {
            progress = pendingProgress.toMap()
            watched = pendingWatched.toMap()
            mylist = pendingMyList.toMap()
            profiles = pendingProfiles.toMap()
        }
        if (progress.isEmpty() && watched.isEmpty() && mylist.isEmpty() && profiles.isEmpty()) return true
        val ok = push(
            cfg,
            SyncPushBody(
                profiles = profiles.values.toList(),
                progress = progress.values.toList(),
                watched = watched.values.toList(),
                mylist = mylist.values.toList(),
            ),
        )
        if (ok) {
            synchronized(queueLock) {
                progress.forEach { (k, v) -> if (pendingProgress[k] == v) pendingProgress.remove(k) }
                watched.forEach { (k, v) -> if (pendingWatched[k] == v) pendingWatched.remove(k) }
                mylist.forEach { (k, v) -> if (pendingMyList[k] == v) pendingMyList.remove(k) }
                profiles.forEach { (k, v) -> if (pendingProfiles[k] == v) pendingProfiles.remove(k) }
            }
        }
        return ok
    }

    private suspend fun push(cfg: SyncConfig, body: SyncPushBody): Boolean {
        return try {
            val request = Request.Builder()
                .url("${cfg.baseUrl}/push")
                .post(wireJson.encodeToString(SyncPushBody.serializer(), body).toRequestBody(JSON_MEDIA))
                .authorized(cfg)
                .build()
            okHttpClient.await(request).use { response ->
                val responseBody = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    Log.w(TAG, "push failed: HTTP ${response.code}")
                    _status.value = "Push failed (HTTP ${response.code}) · ${timeNow()}"
                    return false
                }
                runCatching { wireJson.decodeFromString(SyncPushResponse.serializer(), responseBody) }
                    .onSuccess { Log.d(TAG, "pushed, applied=${it.applied}") }
                true
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            Log.w(TAG, "push failed", t)
            _status.value = "Push failed (${t.message ?: "network error"}) · ${timeNow()}"
            false
        }
    }

    /**
     * GET /state and apply. The cursor advances to serverNow ONLY after every row
     * applied cleanly — a partial apply re-pulls the same window next time.
     */
    private suspend fun pullAndApply(cfg: SyncConfig, sinceOverride: Long? = null): Boolean {
        return try {
            val since = sinceOverride
                ?: runCatching { settingsRepository.syncCursor.first() }.getOrDefault(0L)
            val request = Request.Builder()
                .url("${cfg.baseUrl}/state?since=$since")
                .get()
                .authorized(cfg)
                .build()
            val bodyText = okHttpClient.await(request).use { response ->
                if (!response.isSuccessful) {
                    Log.w(TAG, "pull failed: HTTP ${response.code}")
                    _status.value = "Sync failed (HTTP ${response.code}) · ${timeNow()}"
                    return false
                }
                response.body?.string().orEmpty()
            }
            val state = wireJson.decodeFromString(SyncStateResponse.serializer(), bodyText)
            applyRemote(state)
            settingsRepository.setSyncCursor(state.serverNow)
            // Self-heal AFTER every successful pull: this is the moment a second
            // device's duplicate profile first becomes visible here.
            healDuplicateProfiles()
            _status.value = "Synced · ${timeNow()}"
            true
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            Log.w(TAG, "pull failed", t)
            _status.value = "Sync failed (${t.message ?: "error"}) · ${timeNow()}"
            false
        }
    }

    /** LWW apply: a remote row lands only when it beats the local row's own timestamp. */
    private suspend fun applyRemote(state: SyncStateResponse) {
        // Profiles first: a brand-new profile must exist before any of its data rows.
        if (state.profiles.isNotEmpty()) {
            val local = profileDao.allProfiles().associateBy { it.id }
            for (row in state.profiles) {
                val existing = local[row.id]
                if (existing != null && row.updatedAt <= existing.updatedAt) continue
                // Tombstones are stored, not deleted — a hidden profile keeps its id so
                // a later un-delete (or LWW resolution) still resolves. liveProfiles()
                // filters tombstones out for display.
                profileDao.upsert(row.toEntity())
            }
        }
        if (state.progress.isNotEmpty()) {
            val local = progressDao.allProgress().associateBy { ProgressKey(it.profileId, it.mediaId, it.type) }
            for (row in state.progress) {
                val key = ProgressKey(row.profileId, row.mediaId, row.type)
                val existing = local[key]
                if (existing != null && row.updatedAt <= existing.updatedAt) continue
                if (row.deleted) {
                    if (existing != null) progressDao.remove(row.profileId, row.mediaId, row.type)
                } else {
                    progressDao.upsert(row.toEntity())
                }
            }
        }
        if (state.watched.isNotEmpty()) {
            val local = progressDao.allWatchedEpisodes()
                .associateBy { WatchedKey(it.profileId, it.mediaId, it.season, it.episode) }
            for (row in state.watched) {
                val key = WatchedKey(row.profileId, row.mediaId, row.season, row.episode)
                val existing = local[key]
                if (existing != null && row.updatedAt <= existing.watchedAt) continue
                if (row.deleted) {
                    if (existing != null) progressDao.unmarkWatched(row.profileId, row.mediaId, row.season, row.episode)
                } else {
                    progressDao.markWatched(row.toEntity())
                }
            }
        }
        if (state.mylist.isNotEmpty()) {
            val local = myListDao.allEntries().associateBy { MyListKey(it.profileId, it.mediaId, it.type) }
            for (row in state.mylist) {
                val key = MyListKey(row.profileId, row.mediaId, row.type)
                val existing = local[key]
                if (existing != null && row.updatedAt <= existing.addedAt) continue
                if (row.deleted) {
                    if (existing != null) myListDao.remove(row.profileId, row.mediaId, row.type)
                } else {
                    myListDao.add(row.toEntity())
                }
            }
        }
    }

    // ── duplicate-profile self-heal ────────────────────────────────────────────
    //
    // Two devices creating the same profile name before sync bridged them left two
    // records. Every bucket of live
    // profiles sharing a name (case-insensitive, trimmed) collapses into one:
    //   keeper = "default" if present, else smallest createdAt (tie: smallest id);
    //   every live watch row under a loser is re-tagged to the keeper KEEPING its own
    //   timestamp (so LWW picks the freshest when both had the title), the original is
    //   tombstoned, and finally the losing profile row is tombstoned. Everything is
    //   enqueued so every device converges on the same keeper. Never throws: a merge
    //   failure must not fail the pull.

    private suspend fun healDuplicateProfiles() {
        try {
            val live = profileDao.liveProfiles()
            val duplicateGroups = live
                // A blank name is a malformed/partial wire row, never a real duplicate.
                .filter { it.name.isNotBlank() }
                .groupBy { it.name.trim().lowercase(Locale.US) }
                .filterValues { it.size > 1 }
            if (duplicateGroups.isEmpty()) return
            val activeId = runCatching { settingsRepository.activeProfileId.first() }.getOrNull()
            for ((name, dupes) in duplicateGroups) {
                val keeper = pickKeeper(dupes)
                val losers = dupes.filter { it.id != keeper.id }
                if (losers.isEmpty()) continue
                for (loser in losers) mergeProfileInto(loser, keeper)
                Log.i(
                    TAG,
                    "profile merge: '$name' -> keeper=${keeper.id}, merged=${losers.map { it.id }}",
                )
                if (activeId != null && losers.any { it.id == activeId }) {
                    settingsRepository.setActiveProfileId(keeper.id)
                    Log.i(TAG, "profile merge: active profile repointed to ${keeper.id}")
                }
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            Log.w(TAG, "duplicate-profile merge failed", t)
        }
    }

    /** "default" always wins; otherwise oldest createdAt, tie-broken by smallest id. */
    private fun pickKeeper(dupes: List<ProfileEntity>): ProfileEntity =
        dupes.firstOrNull { it.id == DEFAULT_PROFILE_ID }
            ?: dupes.sortedWith(compareBy<ProfileEntity>({ it.createdAt }, { it.id })).first()

    /** Move [loser]'s watch rows onto [keeper], then tombstone the loser everywhere. */
    private suspend fun mergeProfileInto(loser: ProfileEntity, keeper: ProfileEntity) {
        // ── progress ──────────────────────────────────────────────────────────
        val allProgress = progressDao.allProgress()
        val keeperProgress = allProgress
            .filter { it.profileId == keeper.id }
            .associateBy { it.mediaId to it.type }
        for (row in allProgress.filter { it.profileId == loser.id }) {
            val existing = keeperProgress[row.mediaId to row.type]
            if (existing == null || row.updatedAt > existing.updatedAt) {
                val moved = row.copy(profileId = keeper.id) // keeps its own updatedAt
                progressDao.upsert(moved)
                recordProgressUpsert(moved)
            }
            progressDao.remove(row.profileId, row.mediaId, row.type)
            recordProgressDelete(row.profileId, row.mediaId, row.type)
        }

        // ── watched episodes (watchedAt doubles as the LWW timestamp) ─────────
        val allWatched = progressDao.allWatchedEpisodes()
        val keeperWatched = allWatched
            .filter { it.profileId == keeper.id }
            .associateBy { Triple(it.mediaId, it.season, it.episode) }
        for (row in allWatched.filter { it.profileId == loser.id }) {
            val existing = keeperWatched[Triple(row.mediaId, row.season, row.episode)]
            if (existing == null || row.watchedAt > existing.watchedAt) {
                val moved = row.copy(profileId = keeper.id)
                progressDao.markWatched(moved)
                recordWatched(moved.profileId, moved.mediaId, moved.season, moved.episode, moved.watchedAt)
            }
            progressDao.unmarkWatched(row.profileId, row.mediaId, row.season, row.episode)
            recordUnwatched(row.profileId, row.mediaId, row.season, row.episode)
        }

        // ── my list (addedAt doubles as the LWW timestamp) ───────────────────
        val allMyList = myListDao.allEntries()
        val keeperMyList = allMyList
            .filter { it.profileId == keeper.id }
            .associateBy { it.mediaId to it.type }
        for (row in allMyList.filter { it.profileId == loser.id }) {
            val existing = keeperMyList[row.mediaId to row.type]
            if (existing == null || row.addedAt > existing.addedAt) {
                val moved = row.copy(profileId = keeper.id)
                myListDao.add(moved)
                recordMyListAdd(moved)
            }
            myListDao.remove(row.profileId, row.mediaId, row.type)
            recordMyListRemove(row.profileId, row.mediaId, row.type)
        }

        // ── the losing profile row itself ────────────────────────────────────
        profileDao.upsert(loser.copy(deleted = true, updatedAt = now()))
        recordProfileDelete(loser.id)
    }

    /**
     * First-enable (or URL-change) reconcile: push EVERY local row with its stored
     * timestamp, then pull everything since=0. LWW on both ends makes this safe to
     * repeat — it converges instead of duplicating.
     */
    private suspend fun fullSync() {
        syncMutex.withLock {
            val cfg = currentConfig() ?: return
            _status.value = "Syncing…"
            val body = runCatching {
                SyncPushBody(
                    profiles = profileDao.allProfiles().map { it.toSyncRow() },
                    progress = progressDao.allProgress().map { it.toSyncRow() },
                    watched = progressDao.allWatchedEpisodes().map { it.toSyncRow() },
                    mylist = myListDao.allEntries().map { it.toSyncRow() },
                )
            }.getOrElse { t ->
                Log.w(TAG, "full sync: reading local tables failed", t)
                return
            }
            val empty = body.profiles.isEmpty() && body.progress.isEmpty() &&
                body.watched.isEmpty() && body.mylist.isEmpty()
            if (!empty && !push(cfg, body)) return
            flushPending(cfg) // anything queued during the table read
            pullAndApply(cfg, sinceOverride = 0L)
        }
    }

    private fun Request.Builder.authorized(cfg: SyncConfig): Request.Builder = apply {
        if (cfg.token.isNotEmpty()) header("Authorization", "Bearer ${cfg.token}")
    }

    private fun now(): Long = System.currentTimeMillis()

    private fun timeNow(): String = SimpleDateFormat("h:mm a", Locale.US).format(Date())

    private companion object {
        const val TAG = "SyncEngine"
        const val PUSH_DEBOUNCE_MS = 1_500L
        const val PULL_INTERVAL_MS = 60_000L
        /** Home is where Continue Watching lives — pull 3x more often while it's up. */
        const val HOME_PULL_INTERVAL_MS = 20_000L
        const val TICK_SLICE_MS = 1_000L
        /** Hard ceiling on how long playback may wait for the launch pull. */
        const val PULL_SETTLE_TIMEOUT_MS = 2_500L
        val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    }
}
