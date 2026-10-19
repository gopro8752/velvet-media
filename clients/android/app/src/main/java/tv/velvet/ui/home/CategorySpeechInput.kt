package tv.velvet.ui.home

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log

internal enum class CategorySpeechPhase { IDLE, STARTING, LISTENING, PROCESSING }

internal data class CategorySpeechState(
    val phase: CategorySpeechPhase = CategorySpeechPhase.IDLE,
    val error: String? = null,
    val partial: String = "",
)

/** One user-initiated utterance at a time. All methods are called on the main thread. */
internal class CategorySpeechInput(
    context: Context,
    private val onState: (CategorySpeechState) -> Unit,
    private val onResult: (String) -> Unit,
) {
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var generation = 0L
    private var closed = false
    private var state = CategorySpeechState()
    private var watchdog: Runnable? = null

    fun start() {
        requireMainThread()
        if (closed || recognizer != null || state.phase != CategorySpeechPhase.IDLE) return
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            publish(CategorySpeechState(error = "Allow microphone access to speak, or type your category."))
            return
        }
        val session = ++generation
        try {
            if (!SpeechRecognizer.isRecognitionAvailable(context)) {
                fail(session, "Voice input isn't available here. You can type your category.")
                return
            }
            val input = SpeechRecognizer.createSpeechRecognizer(context)
            recognizer = input
            input.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    if (!isCurrent(session)) return
                    if (state.phase != CategorySpeechPhase.STARTING) return
                    publish(state.copy(phase = CategorySpeechPhase.LISTENING))
                    armWatchdog(session, LISTEN_TIMEOUT_MS, "Voice input timed out. Try Speak again or type your category.")
                }

                override fun onBeginningOfSpeech() {
                    if (!isCurrent(session)) return
                    if (state.phase == CategorySpeechPhase.STARTING) {
                        publish(state.copy(phase = CategorySpeechPhase.LISTENING))
                        armWatchdog(session, LISTEN_TIMEOUT_MS, "Voice input timed out. Try Speak again or type your category.")
                    }
                }

                override fun onEndOfSpeech() {
                    if (!isCurrent(session)) return
                    if (state.phase == CategorySpeechPhase.PROCESSING) return
                    // The service still owns the session until onResults/onError.
                    publish(state.copy(phase = CategorySpeechPhase.PROCESSING))
                    armWatchdog(session, RESULT_TIMEOUT_MS, "Voice input didn't return a result. Try Speak again or type your category.")
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    if (!isCurrent(session)) return
                    val partial = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()?.trim()?.take(MAX_PROMPT_LENGTH).orEmpty()
                    if (partial.isNotEmpty()) publish(state.copy(partial = partial))
                }

                override fun onResults(results: Bundle?) {
                    if (!isCurrent(session)) return
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()?.trim()?.take(MAX_PROMPT_LENGTH).orEmpty()
                    if (text.length < MIN_PROMPT_LENGTH) {
                        fail(session, "I didn't catch a category. Try Speak again or type your category.")
                        return
                    }
                    Log.d(TAG, "result received")
                    releaseSession(cancel = false)
                    val completedGeneration = generation
                    publish(CategorySpeechState())
                    if (!closed && generation == completedGeneration) onResult(text)
                }

                override fun onError(error: Int) {
                    if (!isCurrent(session)) return
                    Log.d(TAG, "recognition error code=$error")
                    fail(session, errorMessage(error))
                }

                override fun onRmsChanged(rmsdB: Float) = Unit
                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onEvent(eventType: Int, params: Bundle?) = Unit
            })
            publish(CategorySpeechState(phase = CategorySpeechPhase.STARTING))
            if (!isCurrent(session)) return
            armWatchdog(session, START_TIMEOUT_MS, "The microphone didn't start. Try Speak again or type your category.")
            input.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1))
        } catch (_: SecurityException) {
            fail(session, "Allow microphone access to speak, or type your category.")
        } catch (_: RuntimeException) {
            fail(session, "Voice input couldn't start. Try Speak again or type your category.")
        }
    }

    fun cancel() {
        requireMainThread()
        if (closed) return
        Log.d(TAG, "cancel")
        releaseSession(cancel = true)
        publish(CategorySpeechState())
    }

    fun close() {
        requireMainThread()
        if (closed) return
        closed = true
        Log.d(TAG, "close")
        releaseSession(cancel = true)
    }

    private fun isCurrent(session: Long) = !closed && generation == session

    private fun fail(session: Long, message: String) {
        if (!isCurrent(session)) return
        releaseSession(cancel = true)
        publish(CategorySpeechState(error = message))
    }

    private fun releaseSession(cancel: Boolean) {
        // Invalidate before calling the service: cancel/destroy can enqueue callbacks.
        generation++
        watchdog?.let(handler::removeCallbacks)
        watchdog = null
        val previous = recognizer
        recognizer = null
        if (cancel) runCatching { previous?.cancel() }
        runCatching { previous?.destroy() }
    }

    private fun armWatchdog(session: Long, timeoutMs: Long, message: String) {
        watchdog?.let(handler::removeCallbacks)
        watchdog = Runnable {
            if (isCurrent(session)) {
                Log.d(TAG, "timeout phase=${state.phase}")
                fail(session, message)
            }
        }.also { handler.postDelayed(it, timeoutMs) }
    }

    private fun publish(next: CategorySpeechState) {
        if (closed) return
        if (state.phase != next.phase || next.error != null) {
            Log.d(TAG, "state=${next.phase} error=${next.error != null}")
        }
        state = next
        onState(next)
    }

    private fun requireMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "CategorySpeechInput must run on the main thread" }
    }

    private fun errorMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Allow microphone access to speak, or type your category."
        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "I didn't catch that. Try Speak again or type your category."
        SpeechRecognizer.ERROR_AUDIO -> "The microphone isn't available. Try Speak again or type your category."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Voice input is busy. Wait a moment, then try Speak again."
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Voice input couldn't connect. Check your connection or type your category."
        else -> "Voice input couldn't finish. Try Speak again or type your category."
    }

    private companion object {
        const val TAG = "CategoryVoice"
        const val MIN_PROMPT_LENGTH = 3
        const val MAX_PROMPT_LENGTH = 500
        const val START_TIMEOUT_MS = 10_000L
        const val LISTEN_TIMEOUT_MS = 45_000L
        const val RESULT_TIMEOUT_MS = 15_000L
    }
}
