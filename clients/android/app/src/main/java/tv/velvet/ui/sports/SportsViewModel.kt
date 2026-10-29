package tv.velvet.ui.sports

import android.os.SystemClock
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import tv.velvet.data.sports.*

data class SportsState(val loading: Boolean = true, val catalog: SportsCatalog? = null, val error: String? = null)
class SportsViewModel(private val repository: SportsRepository) : ViewModel() {
    private val mutable = MutableStateFlow(SportsState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    var lastEventId: String? = null
    fun refresh(scope: String) {
        job?.cancel()
        job = viewModelScope.launch {
            mutable.value = SportsState()
            try { mutable.value = SportsState(false, repository.events(scope)) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { mutable.value = SportsState(false, error = sportsMessage(e)) }
        }
    }
}
data class SportsStreamsState(val loading: Boolean = true, val streams: List<SportsStream> = emptyList(), val message: String? = null)
class SportsStreamsViewModel(private val repository: SportsRepository, private val eventId: String) : ViewModel() {
    private val mutable = MutableStateFlow(SportsStreamsState())
    val state = mutable.asStateFlow()
    private var job: Job? = null
    init { refresh() }
    fun refresh() {
        job?.cancel()
        job = viewModelScope.launch {
            mutable.value = SportsStreamsState()
            val began = SystemClock.elapsedRealtime()
            try {
                val result = repository.streams(eventId)
                android.util.Log.d("VelvetSports", "Startup phase=sources-ready elapsedMs=${SystemClock.elapsedRealtime() - began} count=${result.streams.size}")
                mutable.value = SportsStreamsState(false, result.streams, result.message)
            }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { mutable.value = SportsStreamsState(false, message = sportsMessage(e)) }
        }
    }
}
private fun sportsMessage(e: Exception) = if (e is SportsException) e.message.orEmpty() else "Live Sports couldn't connect. Refresh and try again."
