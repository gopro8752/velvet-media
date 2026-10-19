package tv.velvet.ui.details

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import tv.velvet.data.local.DEFAULT_PROFILE_ID
import tv.velvet.data.local.MyListEntity
import tv.velvet.data.local.WatchProgressEntity
import tv.velvet.data.local.WatchedEpisodeEntity
import tv.velvet.data.model.Episode
import tv.velvet.data.model.MediaDetails
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget
import tv.velvet.di.AppContainer
import java.text.SimpleDateFormat
import java.util.Locale

data class DetailsUiState(
    val loading: Boolean = true,
    val error: String? = null,
    val details: MediaDetails? = null,
    val inMyList: Boolean = false,
    /** (season, episode) pairs the user has finished watching. */
    val watchedEpisodes: Set<Pair<Int, Int>> = emptySet(),
    /** Saved resume position for this title, if any. */
    val progress: WatchProgressEntity? = null,
    /** Label for the primary button, e.g. "Resume · 48m left" / "Play S1 E1". */
    val playLabel: String = "Play",
    /** What the primary button plays. Null only while details are loading. */
    val playTarget: PlayTarget? = null,
    /** True for movies that have a saved resume position. */
    val showStartOver: Boolean = false,
    val selectedSeason: Int? = null,
    val episodes: List<Episode> = emptyList(),
    val episodesLoading: Boolean = false,
)

class DetailsViewModel(
    private val container: AppContainer,
    private val type: MediaType,
    private val id: Int,
) : ViewModel() {

    private val progressDao = container.database.watchProgressDao()
    private val myListDao = container.database.myListDao()
    private val syncEngine = container.syncEngine
    private val settingsRepository = container.settingsRepository

    /**
     * Active profile id. All reads filter by it and all mutations tag it; the reactive
     * collectors below re-key on it via flatMapLatest so a profile switch refreshes the
     * checkmarks and the Play/Resume label live. AppContainer bootstraps it before any
     * screen opens, so the DEFAULT_PROFILE_ID fallback is only for the first emission gap.
     */
    private val activeProfileId: StateFlow<String> =
        settingsRepository.activeProfileId
            .map { it ?: DEFAULT_PROFILE_ID }
            .stateIn(viewModelScope, SharingStarted.Eagerly, DEFAULT_PROFILE_ID)

    /**
     * Initial d-pad focus goes to the Play button once per backstack entry — the flag
     * survives the round trip to the Player so returning doesn't yank focus (and the
     * LazyColumn scroll) away from the episode the user was on.
     */
    var initialFocusPlaced = false

    private val _state = MutableStateFlow(DetailsUiState())
    val state: StateFlow<DetailsUiState> = _state.asStateFlow()

    /** Episodes already fetched, by season number — avoids refetching when chip-hopping. */
    private val episodeCache = mutableMapOf<Int, List<Episode>>()

    @OptIn(ExperimentalCoroutinesApi::class)
    private val inMyListFlow = activeProfileId.flatMapLatest { profile ->
        myListDao.isInList(profile, id, type.key)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private val watchedFlow = activeProfileId.flatMapLatest { profile ->
        progressDao.watchedEpisodes(profile, id).map { profile to it }
    }

    init {
        load()
        viewModelScope.launch {
            inMyListFlow.collect { inList ->
                _state.update { it.copy(inMyList = inList) }
            }
        }
        viewModelScope.launch {
            watchedFlow.collect { (profile, eps) ->
                _state.update { s ->
                    s.copy(watchedEpisodes = eps.map { e -> e.season to e.episode }.toSet())
                }
                // A profile switch can change the saved resume row too — re-read it so
                // the Play/Resume label matches the now-active profile. Use the profile
                // this emission re-keyed on (not the separately-lagging activeProfileId
                // stateIn) so the watched set and the resume row are always read under
                // the same profile.
                _state.update { it.copy(progress = progressDao.progressFor(profile, id, type.key)) }
                recomputePlayState()
            }
        }
    }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            val profile = activeProfileId.value
            val progress = progressDao.progressFor(profile, id, type.key)
            val watched = runCatching {
                progressDao.watchedEpisodes(profile, id).first().map { it.season to it.episode }.toSet()
            }.getOrDefault(emptySet())
            runCatching { container.tmdbRepository.details(id, type) }
                .onSuccess { details ->
                    _state.update {
                        it.copy(
                            loading = false,
                            details = details,
                            progress = progress,
                            watchedEpisodes = watched,
                        )
                    }
                    recomputePlayState()
                    if (type == MediaType.SHOW && _state.value.selectedSeason == null) {
                        val initialSeason = _state.value.playTarget?.season
                            ?: details.seasons.firstOrNull { s -> s.number >= 1 }?.number
                            ?: details.seasons.firstOrNull()?.number
                        if (initialSeason != null) selectSeason(initialSeason)
                    }
                    prewarmStreams()
                }
                .onFailure { e ->
                    if (e is CancellationException) throw e
                    _state.update {
                        it.copy(loading = false, error = e.message ?: "Couldn't load details right now.")
                    }
                }
        }
    }

    fun selectSeason(season: Int) {
        episodeCache[season]?.let { cached ->
            _state.update { it.copy(selectedSeason = season, episodes = cached, episodesLoading = false) }
            return
        }
        val current = _state.value
        if (current.selectedSeason == season && current.episodesLoading) return
        _state.update { it.copy(selectedSeason = season, episodes = emptyList(), episodesLoading = true) }
        viewModelScope.launch {
            val result = runCatching { container.tmdbRepository.episodes(id, season) }
            result.exceptionOrNull()?.let { if (it is CancellationException) throw it }
            if (_state.value.selectedSeason != season) return@launch
            result
                .onSuccess { eps ->
                    episodeCache[season] = eps
                    _state.update { it.copy(episodes = eps, episodesLoading = false) }
                }
                .onFailure {
                    _state.update { it.copy(episodes = emptyList(), episodesLoading = false) }
                }
        }
    }

    fun toggleMyList() {
        val details = _state.value.details ?: return
        val inList = _state.value.inMyList
        viewModelScope.launch {
            val profile = activeProfileId.value
            if (inList) {
                myListDao.remove(profile, id, type.key)
                syncEngine.recordMyListRemove(profile, id, type.key)
            } else {
                val entity = MyListEntity(
                    profileId = profile,
                    mediaId = id,
                    type = type.key,
                    title = details.item.title,
                    posterUrl = details.item.posterUrl,
                    backdropUrl = details.item.backdropUrl,
                    year = details.item.year,
                    rating = details.item.rating,
                    addedAt = System.currentTimeMillis(),
                )
                myListDao.add(entity)
                syncEngine.recordMyListAdd(entity)
            }
        }
    }

    // ── long-press sheet actions ───────────────────────────────────────────
    // All watched-set writes land in Room; the watchedEpisodes Flow collector in
    // init re-emits the set AND calls recomputePlayState(), so episode checkmarks
    // and the "Play S1 E1"/"Resume…" button refresh on their own. Only `progress`
    // is a plain snapshot — the one mutation below that touches it (clearEpisode-
    // Progress) updates state + recomputes explicitly, mirroring startOver().

    fun markEpisodeWatched(episode: Episode) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            val entity =
                WatchedEpisodeEntity(profile, id, episode.season, episode.number, System.currentTimeMillis())
            progressDao.markWatched(entity)
            syncEngine.recordWatched(profile, id, entity.season, entity.episode, entity.watchedAt)
        }
    }

    fun unmarkEpisodeWatched(episode: Episode) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            progressDao.unmarkWatched(profile, id, episode.season, episode.number)
            syncEngine.recordUnwatched(profile, id, episode.season, episode.number)
        }
    }

    /**
     * "Mark all up to here watched": every episode of every season BEFORE this
     * episode's season, plus episodes 1..N of its own season, in one batch write.
     * Earlier seasons are fetched on demand; a season whose fetch fails is skipped
     * (best effort) while the rest still get marked.
     */
    fun markWatchedUpTo(episode: Episode) {
        val details = _state.value.details ?: return
        viewModelScope.launch {
            val profile = activeProfileId.value
            val now = System.currentTimeMillis()
            val entities = mutableListOf<WatchedEpisodeEntity>()
            details.seasons
                .filter { it.number in 1 until episode.season }
                .sortedBy { it.number }
                .forEach { season ->
                    episodesForSeason(season.number)?.forEach { ep ->
                        entities += WatchedEpisodeEntity(profile, id, ep.season, ep.number, now)
                    }
                }
            // The long-pressed row came from a loaded list, so this is normally a
            // cache hit; if not, fall back to plain 1..N episode numbers.
            val currentSeason = episodesForSeason(episode.season)
                ?.filter { it.number <= episode.number }
                ?.map { WatchedEpisodeEntity(profile, id, it.season, it.number, now) }
                ?: (1..episode.number).map { WatchedEpisodeEntity(profile, id, episode.season, it, now) }
            entities += currentSeason
            if (entities.isNotEmpty()) {
                progressDao.markWatchedAll(entities)
                syncEngine.recordWatchedBatch(entities)
            }
        }
    }

    fun markSeasonWatched(seasonNumber: Int) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            val episodes = episodesForSeason(seasonNumber) ?: return@launch
            if (episodes.isEmpty()) return@launch
            val now = System.currentTimeMillis()
            val entities = episodes.map { WatchedEpisodeEntity(profile, id, it.season, it.number, now) }
            progressDao.markWatchedAll(entities)
            syncEngine.recordWatchedBatch(entities)
        }
    }

    fun clearSeasonHistory(seasonNumber: Int) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            // Snapshot the watched rows BEFORE deleting so tombstones name each episode.
            val cleared = runCatching {
                progressDao.watchedEpisodes(profile, id).first()
                    .filter { it.season == seasonNumber }
                    .map { it.episode }
            }.getOrDefault(emptyList())
            progressDao.clearWatchedSeason(profile, id, seasonNumber)
            syncEngine.recordSeasonCleared(profile, id, seasonNumber, cleared)
        }
    }

    /**
     * Shows only: drop the saved resume position (the sheet offers this only when
     * the long-pressed episode IS the in-progress one). Same local refresh as
     * startOver — `progress` isn't a Flow.
     */
    fun clearEpisodeProgress() {
        viewModelScope.launch {
            val profile = activeProfileId.value
            progressDao.remove(profile, id, type.key)
            syncEngine.recordProgressDelete(profile, id, type.key)
            _state.update { it.copy(progress = null) }
            recomputePlayState()
        }
    }

    /** Resolves whether a More Like This item is in My List, then calls back on Main. */
    fun resolveInMyList(item: MediaItem, onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            val inList = runCatching { myListDao.isInList(activeProfileId.value, item.id, item.type.key).first() }
                .getOrDefault(false)
            onResult(inList)
        }
    }

    /** My List toggle for a More Like This item (not the details title itself). */
    fun toggleMyListFor(item: MediaItem, currentlyInList: Boolean) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            if (currentlyInList) {
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

    /**
     * Episodes for one season: cache first (selectSeason fills it), then network.
     * Null = fetch failed — callers treat that season as best-effort skipped.
     */
    private suspend fun episodesForSeason(seasonNumber: Int): List<Episode>? {
        episodeCache[seasonNumber]?.let { return it }
        val result = runCatching { container.tmdbRepository.episodes(id, seasonNumber) }
        result.exceptionOrNull()?.let { if (it is CancellationException) throw it }
        return result.getOrNull()?.also { episodeCache[seasonNumber] = it }
    }

    /**
     * Movies only: clear the saved resume position, then hand back a fresh
     * PlayTarget so the caller can navigate to the player from 0:00.
     */
    fun startOver(onReady: (PlayTarget) -> Unit) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            progressDao.remove(profile, id, type.key)
            syncEngine.recordProgressDelete(profile, id, type.key)
            _state.update { it.copy(progress = null) }
            recomputePlayState()
            onReady(PlayTarget(mediaId = id, type = type))
        }
    }

    // ── play-state resolution ──────────────────────────────────────────────

    /**
     * Once per details-page open. The prewarm is pure signal — the backend pre-warms
     * its top candidate whenever the resolve endpoint is hit, so touching the same
     * stream-list fetch Play would issue means the file is already assembling by the
     * time the user actually presses Play. Guarded to one shot per open (retry-load
     * included), skipped when no source is configured, result discarded, every error
     * swallowed — this must never affect the details UI.
     */
    private var prewarmFired = false

    /**
     * Fire-and-forget the exact fetch pressing Play would issue: for shows the resume /
     * next-unwatched episode [recomputePlayState] just resolved into [DetailsUiState
     * .playTarget], for movies the movie itself.
     */
    private fun prewarmStreams() {
        if (prewarmFired) return
        val item = _state.value.details?.item
        val playTarget = _state.value.playTarget
        if (item == null || playTarget == null) return
        // Same stream-key rule as the player: imdb when known, else the tmdb
        // pseudo-id the backend resolves by title (day-one titles lack imdb).
        val imdb = item.imdbId?.takeIf { it.isNotBlank() } ?: "tmdb:${item.id}"
        prewarmFired = true
        viewModelScope.launch {
            val hasSource = runCatching {
                settingsRepository.settings.first().streamSources.any { it.enabled }
            }.getOrDefault(false)
            if (!hasSource) return@launch
            runCatching {
                container.streamRepository.streamsFor(imdb, type, playTarget.season, playTarget.episode)
            }
        }
    }

    private fun recomputePlayState() {
        val s = _state.value
        val details = s.details ?: return
        when (type) {
            MediaType.MOVIE -> {
                val left = s.progress?.let { minutesLeftLabel(it) }
                if (left != null) {
                    _state.update {
                        it.copy(
                            playLabel = "Resume · $left",
                            playTarget = PlayTarget(mediaId = id, type = type),
                            showStartOver = true,
                        )
                    }
                } else {
                    _state.update {
                        it.copy(
                            playLabel = "Play",
                            playTarget = PlayTarget(mediaId = id, type = type),
                            showStartOver = false,
                        )
                    }
                }
            }
            MediaType.SHOW -> {
                val p = s.progress
                if (p?.season != null && p.episode != null) {
                    val left = minutesLeftLabel(p)?.let { " · $it" } ?: ""
                    _state.update {
                        it.copy(
                            playLabel = "Resume S${p.season} E${p.episode}$left",
                            playTarget = PlayTarget(id, type, p.season, p.episode),
                            showStartOver = false,
                        )
                    }
                } else {
                    val (season, episode) = nextUnwatched(details, s.watchedEpisodes)
                    _state.update {
                        it.copy(
                            playLabel = "Play S$season E$episode",
                            playTarget = PlayTarget(id, type, season, episode),
                            showStartOver = false,
                        )
                    }
                }
            }
        }
    }

    /**
     * First episode not in the watched set, scanning seasons in order
     * (specials/season 0 skipped). Fresh show or everything watched → S1 E1.
     */
    private fun nextUnwatched(details: MediaDetails, watched: Set<Pair<Int, Int>>): Pair<Int, Int> {
        val seasons = details.seasons.filter { it.number >= 1 }.sortedBy { it.number }
        for (season in seasons) {
            for (ep in 1..season.episodeCount) {
                if ((season.number to ep) !in watched) return season.number to ep
            }
        }
        return (seasons.firstOrNull()?.number ?: 1) to 1
    }

    private fun minutesLeftLabel(p: WatchProgressEntity): String? {
        if (p.durationMs <= 0 || p.positionMs <= 0) return null
        val minutes = ((p.durationMs - p.positionMs) / 60_000L).toInt().coerceAtLeast(1)
        return "${formatRuntime(minutes)} left"
    }
}

// ── shared formatting helpers (used by the screen too) ───────────────────────

internal fun formatRuntime(minutes: Int): String {
    val h = minutes / 60
    val m = minutes % 60
    return when {
        h > 0 && m > 0 -> "${h}h ${m}m"
        h > 0 -> "${h}h"
        else -> "${m}m"
    }
}

internal fun formatAirDate(raw: String): String = runCatching {
    val parsed = SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(raw)
    SimpleDateFormat("MMM d, yyyy", Locale.US).format(parsed!!)
}.getOrDefault(raw)
