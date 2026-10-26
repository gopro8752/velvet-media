package tv.velvet.ui.player

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderCounters
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioSink
import java.util.concurrent.atomic.AtomicLong

/** Observes VOD timing without changing playback or logging media identities or credentials. */
@OptIn(UnstableApi::class)
internal class PlaybackAudioDiagnostics(context: Context, private val player: ExoPlayer) : AnalyticsListener {
    private val app = context.applicationContext
    private val playerId = NEXT_PLAYER_ID.incrementAndGet()
    private val handler = Handler(player.applicationLooper)
    private var closed = false
    private var mediaEpoch = 0
    private var outputEpoch = 0
    private var audioSessionId = 0
    private var sinkErrors = 0L
    private var underruns = 0L
    private val lastSinkErrorLogMs = mutableMapOf<Class<out Exception>, Long>()
    private var lastUnderrunLogMs = C.TIME_UNSET
    private var lastVideoLogMs = C.TIME_UNSET
    private var videoFrames = 0L
    private var videoOffsetUs = 0L
    private var videoDrops = 0L
    private var previousVideoCounters: DecoderCounters? = null
    private var videoCounterEpoch = 0
    private var previousRenderedCount = 0
    private var previousDroppedCount = 0
    private var previousOffsetCount = 0
    private val snapshot = object : Runnable {
        override fun run() {
            if (closed) return
            if (player.playbackState != Player.STATE_IDLE) {
                val counters = player.videoDecoderCounters
                counters?.ensureUpdated()
                if (counters !== previousVideoCounters || (counters != null &&
                        (counters.renderedOutputBufferCount < previousRenderedCount ||
                            counters.droppedBufferCount < previousDroppedCount ||
                            counters.videoFrameProcessingOffsetCount < previousOffsetCount))) {
                    videoCounterEpoch++
                }
                previousVideoCounters = counters
                previousRenderedCount = counters?.renderedOutputBufferCount ?: 0
                previousDroppedCount = counters?.droppedBufferCount ?: 0
                previousOffsetCount = counters?.videoFrameProcessingOffsetCount ?: 0
                val audio = player.audioFormat
                val video = player.videoFormat
                write("snapshot state=${player.playbackState} playing=${player.isPlaying}" +
                    " playWhenReady=${player.playWhenReady} suppressionReason=${player.playbackSuppressionReason}" +
                    " bufferedMs=${player.bufferedPosition} durationMs=${player.duration} speed=${player.playbackParameters.speed}" +
                    " totalBufferedMs=${player.totalBufferedDuration}" +
                    " audioMime=${audio?.sampleMimeType?.takeIf { it in AUDIO_MIME_TYPES } ?: "other"}" +
                    " audioRate=${audio?.sampleRate} audioChannels=${audio?.channelCount}" +
                    " width=${video?.width} height=${video?.height} fps=${video?.frameRate}" +
                    " videoCounterEpoch=$videoCounterEpoch" +
                    " rendered=${counters?.renderedOutputBufferCount} dropped=${counters?.droppedBufferCount}" +
                    " skipped=${counters?.skippedOutputBufferCount}" +
                    " processingOffsetTotalUs=${counters?.totalVideoFrameProcessingOffsetUs}" +
                    " processingOffsetCount=${counters?.videoFrameProcessingOffsetCount}",
                    SystemClock.elapsedRealtime(), player.currentPosition)
            }
            handler.postDelayed(this, SNAPSHOT_INTERVAL_MS)
        }
    }

    init {
        handler.postDelayed(snapshot, SNAPSHOT_INTERVAL_MS)
    }

    fun close() {
        closed = true
        handler.removeCallbacks(snapshot)
    }

    override fun onPlayerReleased(eventTime: AnalyticsListener.EventTime) {
        close()
        flushVideo(eventTime)
        log(eventTime, "player_released sinkErrorsTotal=$sinkErrors underrunsTotal=$underruns")
    }

    override fun onPlaybackStateChanged(eventTime: AnalyticsListener.EventTime, state: Int) {
        log(eventTime, "playback_state state=$state")
    }

    override fun onIsPlayingChanged(eventTime: AnalyticsListener.EventTime, isPlaying: Boolean) {
        log(eventTime, "playing_changed playing=$isPlaying")
    }

    override fun onPlayWhenReadyChanged(eventTime: AnalyticsListener.EventTime, playWhenReady: Boolean, reason: Int) {
        log(eventTime, "play_when_ready ready=$playWhenReady reason=$reason")
    }

    override fun onPlaybackSuppressionReasonChanged(eventTime: AnalyticsListener.EventTime, reason: Int) {
        log(eventTime, "playback_suppression reason=$reason")
    }

    override fun onPositionDiscontinuity(
        eventTime: AnalyticsListener.EventTime,
        oldPosition: Player.PositionInfo,
        newPosition: Player.PositionInfo,
        reason: Int,
    ) {
        log(eventTime, "position_discontinuity reason=$reason oldMs=${oldPosition.positionMs} newMs=${newPosition.positionMs}")
    }

    override fun onMediaItemTransition(eventTime: AnalyticsListener.EventTime, mediaItem: MediaItem?, reason: Int) {
        flushVideo(eventTime)
        mediaEpoch++
        log(eventTime, "media_transition reason=$reason")
    }

    override fun onAudioInputFormatChanged(
        eventTime: AnalyticsListener.EventTime,
        format: Format,
        decoderReuseEvaluation: DecoderReuseEvaluation?,
    ) {
        // Do not log Format.toString(): IDs, labels and metadata can contain private source data.
        val mime = format.sampleMimeType?.takeIf { it in AUDIO_MIME_TYPES } ?: "other"
        log(eventTime, "audio_format mime=$mime rate=${format.sampleRate} channels=${format.channelCount}" +
            " pcm=${format.pcmEncoding} bitrate=${format.bitrate} reuse=${decoderReuseEvaluation?.result}")
    }

    override fun onAudioSessionIdChanged(eventTime: AnalyticsListener.EventTime, audioSessionId: Int) {
        this.audioSessionId = audioSessionId
        log(eventTime, "audio_session")
    }

    override fun onAudioTrackInitialized(eventTime: AnalyticsListener.EventTime, audioTrackConfig: AudioSink.AudioTrackConfig) {
        outputEpoch++
        log(eventTime, "audio_output_initialized ${audioTrackConfig.fields()}")
    }

    override fun onAudioTrackReleased(eventTime: AnalyticsListener.EventTime, audioTrackConfig: AudioSink.AudioTrackConfig) {
        log(eventTime, "audio_output_released ${audioTrackConfig.fields()}" +
            " sinkErrorsTotal=$sinkErrors underrunsTotal=$underruns")
    }

    override fun onAudioPositionAdvancing(eventTime: AnalyticsListener.EventTime, playoutStartSystemTimeMs: Long) {
        log(eventTime, "audio_advancing startWallMs=$playoutStartSystemTimeMs")
    }

    override fun onAudioSinkError(eventTime: AnalyticsListener.EventTime, audioSinkError: Exception) {
        sinkErrors++
        // A broken sink can report an error for every buffer; preserve counts without flooding logcat.
        val previousLogMs = lastSinkErrorLogMs[audioSinkError.javaClass]
        if (previousLogMs != null && eventTime.realtimeMs - previousLogMs < ERROR_LOG_INTERVAL_MS) return
        lastSinkErrorLogMs[audioSinkError.javaClass] = eventTime.realtimeMs
        val details = when (audioSinkError) {
            is AudioSink.UnexpectedDiscontinuityException ->
                " actualUs=${audioSinkError.actualPresentationTimeUs}" +
                    " expectedUs=${audioSinkError.expectedPresentationTimeUs}" +
                    " deltaUs=${audioSinkError.actualPresentationTimeUs - audioSinkError.expectedPresentationTimeUs}"
            is AudioSink.InitializationException ->
                " state=${audioSinkError.audioTrackState} recoverable=${audioSinkError.isRecoverable}"
            is AudioSink.WriteException ->
                " code=${audioSinkError.errorCode} recoverable=${audioSinkError.isRecoverable}"
            else -> ""
        }
        // Exception messages/stack traces may include authenticated URLs. Log the type and numbers only.
        log(eventTime, "audio_sink_error type=${audioSinkError.javaClass.name} count=$sinkErrors$details", warning = true)
    }

    override fun onAudioUnderrun(
        eventTime: AnalyticsListener.EventTime,
        bufferSize: Int,
        bufferSizeMs: Long,
        elapsedSinceLastFeedMs: Long,
    ) {
        underruns++
        if (lastUnderrunLogMs != C.TIME_UNSET && eventTime.realtimeMs - lastUnderrunLogMs < ERROR_LOG_INTERVAL_MS) return
        lastUnderrunLogMs = eventTime.realtimeMs
        log(eventTime, "audio_underrun count=$underruns bufferBytes=$bufferSize bufferMs=$bufferSizeMs" +
            " sinceFeedMs=$elapsedSinceLastFeedMs", warning = true)
    }

    override fun onVideoInputFormatChanged(
        eventTime: AnalyticsListener.EventTime,
        format: Format,
        decoderReuseEvaluation: DecoderReuseEvaluation?,
    ) {
        log(eventTime, "video_format width=${format.width} height=${format.height} fps=${format.frameRate}" +
            " reuse=${decoderReuseEvaluation?.result}")
    }

    override fun onVideoFrameProcessingOffset(eventTime: AnalyticsListener.EventTime, totalProcessingOffsetUs: Long, frameCount: Int) {
        videoOffsetUs += totalProcessingOffsetUs
        videoFrames += frameCount
        maybeLogVideo(eventTime)
    }

    override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
        videoDrops += droppedFrames
        maybeLogVideo(eventTime)
    }

    override fun onVideoDisabled(eventTime: AnalyticsListener.EventTime, decoderCounters: DecoderCounters) {
        flushVideo(eventTime)
    }

    private fun maybeLogVideo(eventTime: AnalyticsListener.EventTime) {
        if (lastVideoLogMs == C.TIME_UNSET || eventTime.realtimeMs - lastVideoLogMs >= VIDEO_LOG_INTERVAL_MS) {
            flushVideo(eventTime)
        }
    }

    private fun flushVideo(eventTime: AnalyticsListener.EventTime) {
        if (videoFrames == 0L && videoDrops == 0L) return
        // This is the renderer's scheduling offset, not a measurement of audible A/V skew.
        val averageUs = if (videoFrames > 0) videoOffsetUs / videoFrames else C.TIME_UNSET
        log(eventTime, "video_timing frames=$videoFrames averageProcessingOffsetUs=$averageUs dropped=$videoDrops")
        lastVideoLogMs = eventTime.realtimeMs
        videoFrames = 0
        videoOffsetUs = 0
        videoDrops = 0
    }

    private fun AudioSink.AudioTrackConfig.fields() =
        "encoding=$encoding rate=$sampleRate channelMask=$channelConfig bufferBytes=$bufferSize" +
            " tunneling=$tunneling offload=$offload"

    private fun log(eventTime: AnalyticsListener.EventTime, message: String, warning: Boolean = false) {
        write("eventPositionMs=${eventTime.eventPlaybackPositionMs} $message", eventTime.realtimeMs,
            eventTime.currentPlaybackPositionMs, warning)
    }

    private fun write(message: String, realtimeMs: Long, positionMs: Long, warning: Boolean = false) {
        val line = "player=$playerId media=$mediaEpoch output=$outputEpoch session=$audioSessionId" +
            " realtimeMs=$realtimeMs positionMs=$positionMs $message"
        if (warning) Log.w(TAG, line) else Log.i(TAG, line)
        PlaybackDiagnosticLog.append(app, warning, line)
    }

    private companion object {
        const val TAG = "VelvetAVSync"
        const val ERROR_LOG_INTERVAL_MS = 5_000L
        const val VIDEO_LOG_INTERVAL_MS = 30_000L
        const val SNAPSHOT_INTERVAL_MS = 10_000L
        val NEXT_PLAYER_ID = AtomicLong()
        val AUDIO_MIME_TYPES = setOf(
            "audio/ac3", "audio/eac3", "audio/eac3-joc", "audio/vnd.dts", "audio/vnd.dts.hd",
            "audio/vnd.dts.uhd;profile=p2", "audio/true-hd", "audio/raw", "audio/mp4a-latm",
            "audio/mpeg", "audio/opus", "audio/vorbis", "audio/flac", "audio/alac",
        )
    }
}
