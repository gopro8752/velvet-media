package tv.velvet.data.streams

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import java.io.EOFException
import java.net.ProtocolException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/** Only this enum and an HTTP status may enter logs; never an upstream body or URL. */
internal enum class StreamFailureReason(val wire: String) {
    MISSING_ARTICLES("missing_articles"), UNSUPPORTED_ARCHIVE("unsupported_archive"),
    INVALID_ARCHIVE("invalid_archive"), INVALID_RANGE("invalid_range"), UNKNOWN_STREAM("unknown_stream"),
    UPSTREAM_UNAVAILABLE("upstream_unavailable"), TRANSPORT("transport"), OTHER("other")
}

internal data class StreamFailure(val status: Int?, val reason: StreamFailureReason, val transient: Boolean)

@OptIn(UnstableApi::class)
internal fun streamFailure(error: Throwable): StreamFailure {
    var current: Throwable? = error
    var transport = false
    repeat(12) {
        val cause = current ?: return@repeat
        if (cause is HttpDataSource.InvalidResponseCodeException) {
            val code = cause.headerFields.entries.firstOrNull { it.key.equals("X-Velvet-Stream-Error", true) }
                ?.value?.firstOrNull()
            val known = StreamFailureReason.entries.firstOrNull { it.wire == code }
            // Compatibility with older Velvet backends. Read only the small,
            // exact permanent verdict; bodies are never exposed or logged.
            val legacyMissing = cause.responseCode == 502 && cause.responseBody.size <= 128 &&
                cause.responseBody.toString(Charsets.UTF_8).trim() == "source has missing articles"
            val reason = if (legacyMissing) StreamFailureReason.MISSING_ARTICLES else known ?: StreamFailureReason.OTHER
            val permanent = reason in setOf(StreamFailureReason.MISSING_ARTICLES, StreamFailureReason.UNSUPPORTED_ARCHIVE,
                StreamFailureReason.INVALID_ARCHIVE, StreamFailureReason.INVALID_RANGE, StreamFailureReason.UNKNOWN_STREAM)
            return StreamFailure(cause.responseCode, reason,
                !permanent && cause.responseCode in setOf(408, 429, 500, 502, 503, 504))
        }
        transport = transport || cause is SocketTimeoutException || cause is SocketException ||
            cause is EOFException || cause is UnknownHostException ||
            (cause is ProtocolException && cause.message.equals("unexpected end of stream", true))
        current = cause.cause?.takeIf { it !== cause }
    }
    return StreamFailure(null, if (transport) StreamFailureReason.TRANSPORT else StreamFailureReason.OTHER, transport)
}

/** Media3 retries its existing load/range, preserving the extractor and decoder. */
@OptIn(UnstableApi::class)
internal class StreamLoadErrorPolicy(
    private val budget: StreamRecoveryBudget,
    private val sourceGeneration: Long,
    private val nowMs: () -> Long = { android.os.SystemClock.elapsedRealtime() },
) : DefaultLoadErrorHandlingPolicy(0) {
    override fun getMinimumLoadableRetryCount(dataType: Int): Int = if (budget.isEstablished(sourceGeneration)) 2 else 0

    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
        if (!budget.isEstablished(sourceGeneration) || loadErrorInfo.errorCount !in 1..2 ||
            !streamFailure(loadErrorInfo.exception).transient || !budget.allowInPlaceRetry(sourceGeneration, nowMs())) return C.TIME_UNSET
        return if (loadErrorInfo.errorCount == 1) 250 else 750
    }
}
