package tv.velvet.ui.live

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import tv.velvet.data.live.LiveGuide
import tv.velvet.data.live.LiveCatalog
import tv.velvet.data.live.LiveException
import tv.velvet.data.live.LiveRepository

data class LiveBrowseState(val loading: Boolean = true, val catalog: LiveCatalog? = null, val error: String? = null, val guide: LiveGuide? = null, val guideError: String? = null)

class LiveViewModel(private val repository: LiveRepository) : ViewModel() {
    private val _state = MutableStateFlow(LiveBrowseState(catalog = repository.cachedCatalog))
    val state = _state.asStateFlow()
    val lastChannelId = repository.lastChannelId
    private var load: Job? = null
    private var guideLoad: Job? = null

    fun refresh() {
        guideLoad?.cancel()
        guideLoad = viewModelScope.launch {
            try {
                repeat(3) { attempt ->
                    if (attempt > 0) delay(30_000)
                    val guide = repository.guide()
                    _state.value = _state.value.copy(guide = guide, guideError = null)
                    if (!guide.enabled || guide.updatedAt != null) return@launch
                }
            }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { _state.value = _state.value.copy(guideError = "Program guide couldn't refresh. Channels are still available.") }
        }
        load?.cancel()
        load = viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            try { val catalog = repository.channels(); _state.value = _state.value.copy(loading = false, catalog = catalog) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                _state.value = _state.value.copy(loading = false, error = liveMessage(error))
            }
        }
    }
}

internal fun liveMessage(error: Throwable) = if (error is LiveException) error.message.orEmpty()
    else "Couldn't connect to Live TV. Check the connection and try again."
