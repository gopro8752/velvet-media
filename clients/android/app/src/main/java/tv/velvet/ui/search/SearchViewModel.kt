package tv.velvet.ui.search

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import tv.velvet.data.local.DEFAULT_PROFILE_ID
import tv.velvet.data.local.MyListEntity
import tv.velvet.data.model.MediaItem
import tv.velvet.di.AppContainer

/**
 * UI state for the search screen.
 *
 * [query] is what the user typed (kept verbatim for the text field).
 * [resultsFor] is the trimmed query the current [results] belong to — empty until the
 * first search completes, used for the "No results for X" empty state.
 */
data class SearchUiState(
    val query: String = "",
    val resultsFor: String = "",
    val results: List<MediaItem> = emptyList(),
    val searching: Boolean = false,
)

/**
 * Subject of the long-press actions sheet. [inMyList] is resolved BEFORE this is
 * published so the sheet opens with the final My List label — no flicker.
 */
data class SearchActionsFor(
    val item: MediaItem,
    val inMyList: Boolean,
)

@OptIn(FlowPreview::class)
class SearchViewModel(private val container: AppContainer) : ViewModel() {

    private val myListDao = container.database.myListDao()
    private val syncEngine = container.syncEngine

    /** Active profile — the My List toggle reads/writes under it. */
    private val activeProfileId: StateFlow<String> =
        container.settingsRepository.activeProfileId
            .map { it ?: DEFAULT_PROFILE_ID }
            .stateIn(viewModelScope, SharingStarted.Eagerly, DEFAULT_PROFILE_ID)

    private val _state = MutableStateFlow(SearchUiState())
    val state: StateFlow<SearchUiState> = _state.asStateFlow()

    private val _actionsFor = MutableStateFlow<SearchActionsFor?>(null)
    /** Non-null while the long-press actions sheet is open. */
    val actionsFor: StateFlow<SearchActionsFor?> = _actionsFor.asStateFlow()

    private val queryFlow = MutableStateFlow("")

    init {
        viewModelScope.launch {
            queryFlow
                .debounce(DEBOUNCE_MS)
                .map { it.trim() }
                .distinctUntilChanged()
                .collectLatest { query -> runSearch(query) }
        }
    }

    fun onQueryChange(query: String) {
        _state.update { it.copy(query = query) }
        queryFlow.value = query
    }

    /**
     * Open the actions sheet for a long-pressed result. My List membership is
     * resolved here, before the sheet becomes visible (same pattern as Home).
     */
    fun openActions(item: MediaItem) {
        viewModelScope.launch {
            val inList = runCatching { myListDao.isInList(activeProfileId.value, item.id, item.type.key).first() }
                .getOrDefault(false)
            _actionsFor.value = SearchActionsFor(item, inList)
        }
    }

    fun dismissActions() {
        _actionsFor.value = null
    }

    /** Add/remove [item] from My List (the sheet's toggle action). */
    fun toggleMyList(item: MediaItem) {
        viewModelScope.launch {
            val profile = activeProfileId.value
            val inList = runCatching { myListDao.isInList(profile, item.id, item.type.key).first() }
                .getOrDefault(false)
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

    private suspend fun runSearch(query: String) {
        if (query.length < MIN_QUERY_LENGTH) {
            _state.update { it.copy(results = emptyList(), resultsFor = "", searching = false) }
            return
        }
        _state.update { it.copy(searching = true) }
        val results = runCatching { container.tmdbRepository.search(query) }
            .getOrDefault(emptyList())
            // Guarantee unique (type, id) pairs — they are used as LazyVerticalGrid keys.
            .distinctBy { it.type to it.id }
        _state.update { it.copy(results = results, resultsFor = query, searching = false) }
    }

    private companion object {
        const val DEBOUNCE_MS = 350L
        const val MIN_QUERY_LENGTH = 2
    }
}
