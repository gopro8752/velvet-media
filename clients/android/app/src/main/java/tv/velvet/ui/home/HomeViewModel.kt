package tv.velvet.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import tv.velvet.data.categories.Category
import tv.velvet.data.local.DEFAULT_PROFILE_ID
import tv.velvet.data.local.MyListEntity
import tv.velvet.data.local.WatchProgressEntity
import tv.velvet.data.model.MediaDetails
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget
import tv.velvet.data.model.RowSpec
import tv.velvet.data.model.RowStyle
// Star import: the seasonal-row API (isSeasonalRowActive / seasonalRowIds) lives in
// this package alongside TmdbRepository itself.
import tv.velvet.data.tmdb.*
import tv.velvet.di.AppContainer
import tv.velvet.ui.HomeRowOrder
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.ceil

/** Per-row loading state. Failed / loaded-empty rows collapse silently in the UI. */
sealed interface RowUiState {
    data object Loading : RowUiState
    data class Loaded(val items: List<MediaItem>) : RowUiState
    data object Failed : RowUiState
}

/** One Continue Watching rail entry, ready to render and to resume playback. */
data class ContinueWatchingUi(
    val item: MediaItem,
    val progressFraction: Float,
    val label: String,            // "S2 E4 · 23m left" / "48m left" / "Resume"
    val target: PlayTarget,
)

/** Which rail a long-pressed card came from — each gets its own action set. */
enum class ActionsSource { CONTINUE_WATCHING, MY_LIST, ROW }

/**
 * The long-press actions sheet's subject. [inMyList] is resolved BEFORE this is
 * published (the sheet must open with the final My List label — no flicker).
 * [cwEntry] is set only for [ActionsSource.CONTINUE_WATCHING] long-presses.
 */
data class ActionsFor(
    val item: MediaItem,
    val source: ActionsSource,
    val inMyList: Boolean,
    val cwEntry: ContinueWatchingUi? = null,
)

class HomeViewModel(container: AppContainer) : ViewModel() {

    private val categories = container.categoryRepository
    private val categoryQueue = container.categoryQueueStore
    private val tmdb = container.tmdbRepository
    private val settingsRepository = container.settingsRepository
    private val watchProgressDao = container.database.watchProgressDao()
    private val myListDao = container.database.myListDao()
    private val syncEngine = container.syncEngine

    /**
     * Active profile id, fed by [SettingsRepository.activeProfileId]. The reactive
     * rails re-filter via flatMapLatest below; mutations tag this cached value (it is
     * always populated by AppContainer's bootstrap before any write). DEFAULT_PROFILE_ID
     * is a safe fallback for the brief window before the first emission.
     */
    private val activeProfileId: StateFlow<String> =
        settingsRepository.activeProfileId
            .map { it ?: DEFAULT_PROFILE_ID }
            .stateIn(viewModelScope, SharingStarted.Eagerly, DEFAULT_PROFILE_ID)

    val halloween: StateFlow<Category?> = categories.halloween
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    @OptIn(ExperimentalCoroutinesApi::class)
    val generatedCategories: StateFlow<List<Category>> = activeProfileId
        .flatMapLatest(categories::generated)
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val queuePreparing = MutableStateFlow(false)
    val queueError = MutableStateFlow<String?>(null)
    private var queueJob: Job? = null

    fun playCategory(category: Category, shuffle: Boolean, navigate: (PlayTarget) -> Unit) {
        if (queuePreparing.value) return
        queuePreparing.value = true
        queueJob = viewModelScope.launch {
            queueError.value = null
            try {
                // A signed launcher can enter Home before the VM's active-profile
                // StateFlow has emitted. Read the persisted selection for the queue.
                val profile = settingsRepository.activeProfileId.first() ?: return@launch
                val expanded = categories.expandQueue(category, shuffle)
                val target = categoryQueue.start(profile, expanded)
                navigate(target)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { queueError.value = error.message?.take(240) ?: "Couldn't prepare the category. Try again." }
            finally { queuePreparing.value = false }
        }
    }

    fun playCategoryById(id: String, shuffle: Boolean, navigate: (PlayTarget) -> Unit) {
        viewModelScope.launch {
            val profile = settingsRepository.activeProfileId.first() ?: return@launch
            val category = (listOfNotNull(categories.halloween.first()) + categories.generated(profile).first())
                .firstOrNull { it.id == id }
            if (category == null) queueError.value = "This category is no longer saved. Choose another category."
            else playCategory(category, shuffle, navigate)
        }
    }

    fun dismissQueuePreparation() {
        queueJob?.cancel()
        queuePreparing.value = false
        queueError.value = null
    }

    val categoryBusy = MutableStateFlow(false)
    val categoryError = MutableStateFlow<String?>(null)
    val halloweenFailed = MutableStateFlow(false)

    fun refreshHalloween() {
        viewModelScope.launch {
            halloweenFailed.value = false
            try { categories.refreshHalloween() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { halloweenFailed.value = true }
        }
    }

    fun createCategory(prompt: String, onCreated: () -> Unit) {
        if (categoryBusy.value) return
        val profile = activeProfileId.value
        viewModelScope.launch {
            categoryBusy.value = true
            categoryError.value = null
            try {
                categories.generate(profile, prompt)
                onCreated()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                categoryError.value = error.message?.take(240) ?: "Couldn't create that category. Try again."
            } finally { categoryBusy.value = false }
        }
    }

    fun removeCategory(id: String, onRemoved: () -> Unit, onError: (String) -> Unit) {
        val profile = activeProfileId.value
        viewModelScope.launch {
            try {
                categories.remove(profile, id)
                onRemoved()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { onError("Couldn't delete this category. Try again.") }
        }
    }

    /** The active profile entity for the Home top-bar avatar; null until it resolves. */
    val activeProfile: StateFlow<tv.velvet.data.local.ProfileEntity?> =
        combine(container.profilesRepository.profiles, activeProfileId) { profiles, activeId ->
            profiles.firstOrNull { it.id == activeId } ?: profiles.firstOrNull()
        }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /**
     * Initial d-pad focus goes to the hero Play button exactly once per VM lifetime —
     * NOT on every recomposition, which would steal focus mid-browse and on
     * back-navigation from Details/Player.
     */
    var initialFocusPlaced = false

    /**
     * Hero details enrichment cache: "type:id" -> full MediaDetails (logo, runtime, …
     * plus digitallyAvailable) so the rotation never refetches an item it has seen.
     */
    private val detailsCache = ConcurrentHashMap<String, MediaDetails>()

    // ── TMDB rows ────────────────────────────────────────────────────────────

    private val _tmdbRows = MutableStateFlow<List<RowSpec>>(emptyList())
    /**
     * Resolved row specs in display order: settings.rowOrder (migrated, or allRows when
     * empty), minus out-of-window seasonal rows, with ACTIVE seasonal rows hoisted to
     * the top — i.e. right below Continue Watching / My List, above general discovery.
     */
    val tmdbRows: StateFlow<List<RowSpec>> = _tmdbRows

    /** Raw per-row fetch results, before cross-row dedupe and history filtering. */
    private val _rawRowStates = MutableStateFlow<Map<String, RowUiState>>(emptyMap())

    /** The row order last handed over by settings; re-applied on resume (date rollover). */
    private var lastRowOrder: List<String>? = null

    /**
     * Titles the ACTIVE profile has already touched: every media with a progress row,
     * plus every show with at least one watched episode. Discovery rows filter these
     * out — "new things I haven't seen" is the point of the funnel.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    private val watchHistoryKeys: StateFlow<Set<String>> =
        activeProfileId
            .flatMapLatest { profile ->
                combine(
                    watchProgressDao.progressKeys(profile),
                    watchProgressDao.watchedShowIds(profile),
                ) { progressed, watchedShows ->
                    buildSet {
                        progressed.forEach { add("${it.type}:${it.mediaId}") }
                        watchedShows.forEach { add("${MediaType.SHOW.key}:$it") }
                    }
                }
            }
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptySet())

    /**
     * What Home actually renders. Each row still fetches independently, but the states
     * are folded in DISPLAY order: a row waits (shimmer) until every row above it has
     * resolved, then drops anything already shown above it (cross-row dedupe) and
     * anything in the active profile's history. Rows that empty out collapse in the UI,
     * exactly like failed/empty ones do today.
     */
    val rowStates: StateFlow<Map<String, RowUiState>> =
        combine(_tmdbRows, _rawRowStates, watchHistoryKeys) { specs, raw, history ->
            deriveRowStates(specs, raw, history)
        }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())

    // ── Hero / featured rotation ─────────────────────────────────────────────

    /** Item pinned by d-pad focus on a first-row card; overrides the idle rotation. */
    private val pinned = MutableStateFlow<MediaItem?>(null)
    private val rotationTick = MutableStateFlow(0)

    /**
     * "type:id" keys discovered (via details enrichment) to be not digitally available —
     * theater-only movies with nothing on usenet to stream. The automatic rotation must
     * never tease them, so they are pruned from [featuredPool].
     */
    private val unavailableHeroKeys = MutableStateFlow<Set<String>>(emptySet())

    /**
     * Items the idle hero rotates through: the first non-empty row, minus known
     * not-digitally-available items, capped at 10.
     */
    private val featuredPool: StateFlow<List<MediaItem>> =
        combine(_tmdbRows, rowStates, unavailableHeroKeys) { specs, states, unavailable ->
            var pool: List<MediaItem> = emptyList()
            for (spec in specs) {
                when (val state = states[spec.id]) {
                    is RowUiState.Loaded -> {
                        val candidates = state.items.filterNot { itemKey(it) in unavailable }
                        if (candidates.isNotEmpty()) {
                            pool = candidates.take(10)
                            break
                        }
                        // empty / fully unavailable row — fall through to the next one
                    }
                    RowUiState.Failed -> {} // fall through to the next row
                    else -> break           // highest-priority row still loading — wait for it
                }
            }
            pool
        }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /**
     * The billboard item: pinned focus target if any, else the rotation pick — lazily
     * enriched with details() (logoUrl, runtime, genres) which are cached per item.
     * Rotation picks that turn out to be not digitally available are dropped (the pool
     * prunes them, which advances the rotation); a pinned item keeps mirroring the
     * card the user is pointing at regardless of availability.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    val hero: StateFlow<MediaItem?> =
        combine(pinned, featuredPool, rotationTick) { pinnedItem, pool, tick ->
            val base = pinnedItem ?: if (pool.isEmpty()) null else pool[tick % pool.size]
            base to (pinnedItem != null)
        }
            .distinctUntilChanged()
            .flatMapLatest { (base, isPinned) -> heroFlow(base, isPinned) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    @OptIn(ExperimentalCoroutinesApi::class)
    val heroInMyList: StateFlow<Boolean> =
        combine(
            hero.distinctUntilChangedBy { it?.let { item -> "${item.type.key}:${item.id}" } },
            activeProfileId,
        ) { item, profile -> item to profile }
            .flatMapLatest { (item, profile) ->
                if (item == null) flowOf(false) else myListDao.isInList(profile, item.id, item.type.key)
            }
            .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    // ── Local rails — re-filter whenever the active profile changes. ──────────

    @OptIn(ExperimentalCoroutinesApi::class)
    val continueWatching: StateFlow<List<ContinueWatchingUi>> =
        activeProfileId
            .flatMapLatest { profile -> watchProgressDao.continueWatching(profile) }
            .map { entries ->
                entries.mapNotNull { entity ->
                    runCatching { entity.toContinueWatchingUi() }.getOrNull()
                }
            }
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    @OptIn(ExperimentalCoroutinesApi::class)
    val myList: StateFlow<List<MediaItem>> =
        activeProfileId
            .flatMapLatest { profile -> myListDao.myList(profile) }
            .map { rows ->
                rows.mapNotNull { row ->
                    runCatching {
                        MediaItem(
                            id = row.mediaId,
                            type = MediaType.fromKey(row.type),
                            title = row.title,
                            year = row.year,
                            posterUrl = row.posterUrl,
                            backdropUrl = row.backdropUrl,
                            rating = row.rating,
                        )
                    }.getOrNull()
                }
            }
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /**
     * True when Home has literally nothing to show: every TMDB row failed and the
     * local rails are empty. Drives a friendly full-screen retry state instead of a
     * silent blank page (rule 3: never dead-end).
     */
    val homeUnavailable: StateFlow<Boolean> =
        combine(_tmdbRows, rowStates, continueWatching, myList) { specs, states, cw, ml ->
            specs.isNotEmpty() &&
                specs.all { states[it.id] is RowUiState.Failed } &&
                cw.isEmpty() && ml.isEmpty()
        }.stateIn(viewModelScope, SharingStarted.Eagerly, false)

    init {
        // Persist public display metadata from normal browsing for the signed launcher.
        // The launcher provider never starts a TMDB request or fetches playback sources.
        viewModelScope.launch {
            combine(activeProfileId, hero, featuredPool) { profile, hero, pool ->
                profile to (listOfNotNull(hero) + pool).distinctBy { "${it.type.key}:${it.id}" }.take(12)
            }.collect { (profile, items) ->
                runCatching { container.launcherFeaturedCache.remember(profile, items) }
            }
        }
        refreshHalloween()
        // React to row-order changes from Settings; fetch each (new) row independently.
        viewModelScope.launch {
            settingsRepository.settings
                .map { it.rowOrder }
                .distinctUntilChanged()
                .collect { order -> applyRowOrder(order) }
        }
        // Idle featured rotation: advance every 14s (long enough to actually read the
        // overview) until the user pins via first-row focus.
        viewModelScope.launch {
            while (true) {
                delay(HERO_ROTATION_MS)
                if (pinned.value == null && featuredPool.value.size > 1) {
                    rotationTick.update { it + 1 }
                }
            }
        }
    }

    // ── Long-press actions sheet ─────────────────────────────────────────────

    private val _actionsFor = MutableStateFlow<ActionsFor?>(null)
    /** Non-null while the long-press actions sheet is open. */
    val actionsFor: StateFlow<ActionsFor?> = _actionsFor

    /**
     * Open the actions sheet for [item]. My List membership is resolved here, before
     * the sheet becomes visible, so the toggle row never flickers between labels.
     */
    fun openActions(
        item: MediaItem,
        source: ActionsSource,
        cwEntry: ContinueWatchingUi? = null,
    ) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            val inList = runCatching { myListDao.isInList(profile, item.id, item.type.key).first() }
                .getOrDefault(source == ActionsSource.MY_LIST)
            _actionsFor.value = ActionsFor(item, source, inList, cwEntry)
        }
    }

    fun dismissActions() {
        _actionsFor.value = null
    }

    /** Drop [item]'s Continue Watching entry (resume position); watched marks stay. */
    fun removeFromContinueWatching(item: MediaItem) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            runCatching {
                watchProgressDao.remove(profile, item.id, item.type.key)
                syncEngine.recordProgressDelete(profile, item.id, item.type.key)
            }
        }
    }

    /**
     * Nuke all watch state for [item]: the resume entry, plus (for shows) every
     * per-episode watched mark — the show plays from S1E1 like new.
     */
    fun clearAllProgress(item: MediaItem) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            runCatching {
                watchProgressDao.remove(profile, item.id, item.type.key)
                syncEngine.recordProgressDelete(profile, item.id, item.type.key)
                if (item.type == MediaType.SHOW) {
                    // Snapshot the watched list BEFORE wiping so the sync tombstones
                    // can name every (season, episode) being cleared.
                    val watched = watchProgressDao.watchedEpisodes(profile, item.id).first()
                        .map { it.season to it.episode }
                    watchProgressDao.clearWatchedFor(profile, item.id)
                    syncEngine.recordAllCleared(profile, item.id, watched)
                }
            }
        }
    }

    /** Remove [item] from My List (the My List rail's destructive action). */
    fun removeFromMyList(item: MediaItem) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            runCatching {
                myListDao.remove(profile, item.id, item.type.key)
                syncEngine.recordMyListRemove(profile, item.id, item.type.key)
            }
        }
    }

    /**
     * Restart from the beginning: drop the saved resume position, then play the same
     * target — the movie, or (for shows) the exact episode the entry was on.
     */
    fun startOver(entry: ContinueWatchingUi, navigate: (PlayTarget) -> Unit) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            runCatching {
                watchProgressDao.remove(profile, entry.item.id, entry.item.type.key)
                syncEngine.recordProgressDelete(profile, entry.item.id, entry.item.type.key)
            }
            navigate(entry.target)
        }
    }

    // ── Intents ──────────────────────────────────────────────────────────────

    /** Called when a card in the FIRST row gains focus — the hero follows it. */
    fun onHeroCandidateFocused(item: MediaItem) {
        pinned.value = item
    }

    /**
     * Hero ▶ Play: movies → plain target (player resolves resume position);
     * shows → saved season/episode from watch progress, else null/null
     * (Details/Player resolve to next unwatched).
     */
    fun play(item: MediaItem, navigate: (PlayTarget) -> Unit) {
        viewModelScope.launch {
            val target = when (item.type) {
                MediaType.MOVIE -> PlayTarget(mediaId = item.id, type = MediaType.MOVIE)
                MediaType.SHOW -> {
                    val progress = runCatching {
                        watchProgressDao.progressFor(activeProfileId.value, item.id, MediaType.SHOW.key)
                    }.getOrNull()
                    PlayTarget(
                        mediaId = item.id,
                        type = MediaType.SHOW,
                        season = progress?.season,
                        episode = progress?.episode,
                    )
                }
            }
            navigate(target)
        }
    }

    /** Re-fetch every row that failed (the full-screen "Can't reach TMDB" Retry). */
    fun retryFailedRows() {
        val failedIds = _rawRowStates.value.filterValues { it is RowUiState.Failed }.keys
        failedIds.forEach { id ->
            _rawRowStates.update { it + (id to RowUiState.Loading) }
            viewModelScope.launch { fetchRow(id) }
        }
    }

    /**
     * Home became the visible destination. Pulls sync state immediately (and tightens
     * the pull cadence to 20s) so Continue Watching shows the position from the phone
     * without waiting for a timer, and re-resolves the row order in case a seasonal
     * window opened/closed while the box sat on Home for days.
     */
    fun onHomeResumed() {
        syncEngine.onHomeForegrounded()
        lastRowOrder?.let(::applyRowOrder)
    }

    /** Home left the foreground (player, details, settings, background). */
    fun onHomePaused() {
        syncEngine.onHomeBackgrounded()
    }

    fun toggleHeroMyList() {
        hero.value?.let(::toggleMyList)
    }

    /** Add/remove [item] from My List — shared by the hero button and actions sheet. */
    fun toggleMyList(item: MediaItem) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            val inList = myListDao.isInList(profile, item.id, item.type.key).first()
            if (inList) {
                myListDao.remove(profile, item.id, item.type.key)
                syncEngine.recordMyListRemove(profile, item.id, item.type.key)
            } else {
                val entity = MyListEntity(
                    profileId = profile,
                    mediaId = item.id,
                    type = item.type.key,
                    title = item.title,
                    posterUrl = item.posterUrl,
                    backdropUrl = item.backdropUrl,
                    year = item.year,
                    rating = item.rating,
                    addedAt = System.currentTimeMillis(),
                )
                myListDao.add(entity)
                syncEngine.recordMyListAdd(entity)
            }
        }
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /**
     * Resolve the display order: migrate renamed ids (trending_movies -> popular_now),
     * APPEND ids introduced after the stored order was written (spec §4g — without this
     * the five v1.2.0 holiday rows are invisible to anyone who ever touched Settings →
     * Home Rows), drop seasonal rows outside their window entirely, and hoist the ACTIVE
     * seasonal rows to the top of the discovery block. Rows already fetched keep their
     * state — re-applying (settings edit, date rollover) never re-fetches what we have.
     *
     * The append is recomputed on every READ, so Home surfaces a newly in-window seasonal
     * row whether or not Settings ever persisted its id.
     */
    private fun applyRowOrder(order: List<String>) {
        lastRowOrder = order
        val all = tmdb.allRows
        val migrated = HomeRowOrder.migrateAndAppend(order, all.map { it.id })
        val requested =
            if (migrated.isEmpty()) all
            else migrated.mapNotNull { id -> all.firstOrNull { it.id == id } }
        val seasonalIds: Set<String> =
            runCatching { tmdb.seasonalRowIds().toSet() }.getOrDefault(emptySet())
        val visible = requested.filter { spec ->
            spec.id !in seasonalIds || tmdb.isSeasonalRowActive(spec.id)
        }
        val specs = visible.filter { it.id in seasonalIds } + visible.filterNot { it.id in seasonalIds }
        _tmdbRows.value = specs
        specs.forEach { spec ->
            if (!_rawRowStates.value.containsKey(spec.id)) {
                _rawRowStates.update { it + (spec.id to RowUiState.Loading) }
                viewModelScope.launch { fetchRow(spec.id) }
            }
        }
    }

    private suspend fun fetchRow(rowId: String) {
        val state = try {
            RowUiState.Loaded(tmdb.rowItems(rowId))
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Throwable) {
            RowUiState.Failed
        }
        _rawRowStates.update { it + (rowId to state) }
    }

    /**
     * Fold the raw row states into what Home shows, walking specs in DISPLAY order:
     *  - an item shown in an earlier row is suppressed in every later row;
     *  - anything in the active profile's history is suppressed everywhere here
     *    (Continue Watching / My List are separate rails and never pass through this);
     *  - a row below one that hasn't resolved yet stays Loading, so the dedupe result
     *    can't depend on which network response happened to land first;
     *  - Top-10 rank numerals are renumbered after filtering so they never show gaps.
     */
    private fun deriveRowStates(
        specs: List<RowSpec>,
        raw: Map<String, RowUiState>,
        history: Set<String>,
    ): Map<String, RowUiState> {
        val out = LinkedHashMap<String, RowUiState>(specs.size.coerceAtLeast(1))
        val shown = HashSet<String>()
        var awaitingEarlierRow = false
        for (spec in specs) {
            val rawState = raw[spec.id] ?: RowUiState.Loading
            when {
                awaitingEarlierRow -> out[spec.id] = RowUiState.Loading
                rawState is RowUiState.Loaded -> {
                    val kept = rawState.items.filter { item ->
                        val key = itemKey(item)
                        key !in history && shown.add(key)
                    }
                    out[spec.id] = RowUiState.Loaded(
                        if (spec.style == RowStyle.TOP10) {
                            kept.mapIndexed { i, item -> item.copy(rankInRow = i + 1) }
                        } else {
                            kept
                        }
                    )
                }
                rawState is RowUiState.Failed -> out[spec.id] = RowUiState.Failed
                else -> {
                    out[spec.id] = RowUiState.Loading
                    awaitingEarlierRow = true
                }
            }
        }
        return out
    }

    /** Stable cross-row identity for an item ("movie:1234"): dedupe + hero bookkeeping. */
    private fun itemKey(item: MediaItem) = "${item.type.key}:${item.id}"

    private fun heroFlow(base: MediaItem?, isPinned: Boolean): Flow<MediaItem?> {
        if (base == null) return flowOf(null)
        return flow {
            val key = itemKey(base)
            val cached = detailsCache[key]
            if (cached != null) {
                if (!cached.digitallyAvailable && !isPinned) {
                    // Known-unavailable item reached the rotation (cache warmed before
                    // the pool pruned it) — never feature it; marking it shrinks the
                    // pool, which advances the rotation to the next candidate.
                    markHeroUnavailable(key)
                    return@flow
                }
                emit(mergeHero(base, cached.item))
                return@flow
            }
            emit(base)
            try {
                val details = tmdb.details(base.id, base.type)
                detailsCache[key] = details
                if (!details.digitallyAvailable) {
                    markHeroUnavailable(key)
                    // Pinned = the user is pointing at this card, so keep mirroring it;
                    // a rotation pick is dropped instead (pool prune swaps the hero).
                    if (isPinned) emit(mergeHero(base, details.item))
                } else {
                    emit(mergeHero(base, details.item))
                }
            } catch (ce: CancellationException) {
                throw ce
            } catch (_: Throwable) {
                // keep showing the un-enriched hero; nothing else to do
            }
        }
    }

    private fun markHeroUnavailable(key: String) {
        unavailableHeroKeys.update { it + key }
    }

    /** Prefer row data for imagery (no backdrop flicker), details data for the rest. */
    private fun mergeHero(base: MediaItem, enriched: MediaItem): MediaItem = base.copy(
        title = enriched.title.ifBlank { base.title },
        year = base.year ?: enriched.year,
        posterUrl = base.posterUrl ?: enriched.posterUrl,
        backdropUrl = base.backdropUrl ?: enriched.backdropUrl,
        logoUrl = enriched.logoUrl ?: base.logoUrl,
        rating = base.rating ?: enriched.rating,
        overview = base.overview ?: enriched.overview,
        genres = enriched.genres.ifEmpty { base.genres },
        runtimeMinutes = enriched.runtimeMinutes ?: base.runtimeMinutes,
        imdbId = enriched.imdbId ?: base.imdbId,
    )

    private fun WatchProgressEntity.toContinueWatchingUi(): ContinueWatchingUi {
        val mediaType = MediaType.fromKey(type)
        val item = MediaItem(
            id = mediaId,
            type = mediaType,
            title = title,
            year = year,
            posterUrl = posterUrl,
            backdropUrl = backdropUrl,
            rating = rating,
            imdbId = imdbId,
        )
        val fraction =
            if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
        return ContinueWatchingUi(
            item = item,
            progressFraction = fraction,
            label = progressLabel(mediaType, season, episode, positionMs, durationMs),
            target = PlayTarget(mediaId, mediaType, season, episode),
        )
    }

    private fun progressLabel(
        type: MediaType,
        season: Int?,
        episode: Int?,
        positionMs: Long,
        durationMs: Long,
    ): String {
        val left = if (durationMs <= 0L) {
            "Resume"
        } else {
            val minutesLeft = ceil((durationMs - positionMs).coerceAtLeast(0L) / 60_000.0).toInt()
            when {
                minutesLeft >= 60 && minutesLeft % 60 == 0 -> "${minutesLeft / 60}h left"
                minutesLeft >= 60 -> "${minutesLeft / 60}h ${minutesLeft % 60}m left"
                minutesLeft >= 1 -> "${minutesLeft}m left"
                else -> "Almost done"
            }
        }
        return if (type == MediaType.SHOW && season != null && episode != null) {
            "S$season E$episode · $left"
        } else {
            left
        }
    }

    private companion object {
        const val HERO_ROTATION_MS = 14_000L
    }
}
