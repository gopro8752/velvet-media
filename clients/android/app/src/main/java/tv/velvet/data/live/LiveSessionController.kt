package tv.velvet.data.live

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Main-thread owner of one viewer session. Stale tune responses are released, never played. */
class LiveSessionController(private val service: LiveService, dispatcher: CoroutineDispatcher) {
    private val lifetime = SupervisorJob()
    private val scope = CoroutineScope(lifetime + dispatcher)
    private var pending: Job? = null
    private var generation = 0L
    private var closed = false
    var active: LiveSession? = null
        private set

    fun tune(channelId: String, onReady: (LiveSession) -> Unit, onError: (Throwable) -> Unit) {
        if (closed) return
        val ticket = ++generation
        pending?.cancel()
        val previous = active
        active = null
        val retiring = previous?.let { scope.launch { withContext(NonCancellable) { runCatching { service.release(it) } } } }
        pending = scope.launch {
            // Finish an allocated request even after cancellation so its returned
            // ID can be revoked. HTTP calls are bounded; server TTL covers process death.
            withContext(NonCancellable) {
                retiring?.join()
                if (closed || generation != ticket) return@withContext
                try {
                    val session = service.tune(channelId)
                    if (closed || generation != ticket) runCatching { service.release(session) }
                    else { active = session; onReady(session) }
                } catch (error: Throwable) {
                    if (!closed && generation == ticket) onError(error)
                }
            }
        }
    }

    fun stop() {
        generation++
        pending?.cancel()
        val session = active
        active = null
        if (session != null) scope.launch { withContext(NonCancellable) { runCatching { service.release(session) } } }
    }

    fun close() {
        if (closed) return
        closed = true
        stop()
        lifetime.complete() // finish in-flight cleanup; no permanent background scope
    }
}
