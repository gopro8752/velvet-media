package tv.velvet.ui.live

import android.app.Application
import android.util.Log
import androidx.annotation.OptIn
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import tv.velvet.data.live.LiveChannel
import tv.velvet.data.live.LiveReconnectBudget
import tv.velvet.data.live.LiveRepository
import tv.velvet.data.live.LiveSessionController
import tv.velvet.data.live.LiveWindowRecovery
import tv.velvet.data.live.adjacentLiveChannel
import tv.velvet.data.live.mediaItem
import tv.velvet.data.settings.SettingsRepository
import java.util.concurrent.TimeUnit

enum class LivePhase { LOADING, PLAYING, ERROR, SUSPENDED }
data class LivePlayerState(val phase: LivePhase = LivePhase.LOADING, val channel: LiveChannel? = null,
    val canChangeChannel: Boolean = false, val error: String? = null, val buffering: Boolean = true,
    val reconnecting: Boolean = false, val captionsAvailable: Boolean = false, val captionsEnabled: Boolean = false)

/** Live-only playback: deliberately has no TMDB, database, progress, or sync dependency. */
@OptIn(UnstableApi::class)
class LivePlayerViewModel(app: Application, private val repository: LiveRepository,
    private val settings: SettingsRepository, initialChannelId: String) : ViewModel() {
    private val telemetry = tv.velvet.data.telemetry.PlaybackTelemetry(app, settings)
    private var telemetryChannel: String? = null
    private val _state = MutableStateFlow(LivePlayerState())
    val state = _state.asStateFlow()
    private val sessions = LiveSessionController(repository, Dispatchers.Main.immediate)
    private val retryBudget = LiveReconnectBudget()
    private val liveWindowRecovery = LiveWindowRecovery()
    private var lastBandwidthLogMs = 0L
    private var channels = emptyList<LiveChannel>()
    private var channelId = initialChannelId
    private var closed = false
    private var suspended = false
    private var loading: Job? = null
    private var retry: Job? = null
    private var channelSwitch: Job? = null
    private var watchdog: Job? = null
    private var healthy: Job? = null

    // PrismCast's first playlist can take up to 60s while its browser tunes.
    // Playback uses capability URLs only; catalog bearer credentials never enter this client.
    private val playbackClient = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(75, TimeUnit.SECONDS).build()
    val player: ExoPlayer = ExoPlayer.Builder(app)
        .setMediaSourceFactory(DefaultMediaSourceFactory(OkHttpDataSource.Factory(playbackClient))
            .setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(1)))
        .setLoadControl(DefaultLoadControl.Builder().setTargetBufferBytes(32 * 1024 * 1024)
            .setBufferDurationsMs(10_000, 30_000, 1_500, 3_000).setPrioritizeTimeOverSizeThresholds(false).build())
        .build()

    private fun ownsPlayback() = !closed && !suspended && sessions.active?.id != null &&
        sessions.active?.id == player.currentMediaItem?.mediaId

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            telemetry.observe()
            if (!ownsPlayback()) return
            when (playbackState) {
                Player.STATE_READY -> {
                    watchdog?.cancel()
                    _state.update { it.copy(phase = LivePhase.PLAYING, buffering = false, reconnecting = false) }
                }
                Player.STATE_BUFFERING -> { _state.update { it.copy(buffering = true) }; startWatchdog() }
                Player.STATE_ENDED -> recover()
            }
        }
        override fun onPlayerError(error: PlaybackException) {
            if (ownsPlayback()) {
                // Error codes help diagnose device DRM without logging a
                // capability URL, provider response, or license payload.
                Log.w("VelvetLive", "Playback failed: ${error.errorCodeName}")
                logLiveTiming("Playback error")
                if (liveWindowRecovery.take(error.errorCode)) rejoinLiveWindow() else recover()
            }
        }
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            telemetry.observe()
            healthy?.cancel()
            if (isPlaying && ownsPlayback()) healthy = viewModelScope.launch {
                val id = sessions.active?.id
                delay(60_000)
                if (ownsPlayback() && sessions.active?.id == id && player.isPlaying) {
                    retryBudget.reset()
                    liveWindowRecovery.reset()
                }
            }
        }
        override fun onTracksChanged(tracks: Tracks) {
            if (ownsPlayback()) _state.update { it.copy(captionsAvailable = tracks.groups.any { group ->
                group.type == C.TRACK_TYPE_TEXT && group.isSupported }) }
        }
    }

    init {
        player.setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setPreferredAudioLanguages("en", "eng").setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
        player.addListener(listener)
        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onDrmKeysLoaded(eventTime: AnalyticsListener.EventTime) {
                if (ownsPlayback()) Log.i("VelvetLive", "Device DRM keys loaded")
            }
            override fun onRenderedFirstFrame(eventTime: AnalyticsListener.EventTime, output: Any, renderTimeMs: Long) {
                if (ownsPlayback()) {
                    Log.i("VelvetLive", "Live video first frame rendered")
                    logLiveTiming("First frame")
                }
            }
            override fun onVideoInputFormatChanged(eventTime: AnalyticsListener.EventTime, format: Format,
                decoderReuseEvaluation: DecoderReuseEvaluation?) {
                if (ownsPlayback()) Log.i("VelvetLive", "Video format: ${format.width}x${format.height}" +
                    " fps=${format.frameRate} bitrate=${format.bitrate}")
            }
            override fun onBandwidthEstimate(eventTime: AnalyticsListener.EventTime, totalLoadTimeMs: Int,
                totalBytesLoaded: Long, bitrateEstimate: Long) {
                if (ownsPlayback() && eventTime.realtimeMs - lastBandwidthLogMs >= 30_000) {
                    lastBandwidthLogMs = eventTime.realtimeMs
                    Log.i("VelvetLive", "Bandwidth: estimate=$bitrateEstimate bytes=$totalBytesLoaded loadMs=$totalLoadTimeMs")
                    logLiveTiming("Bandwidth sample")
                }
            }
        })
        load()
        viewModelScope.launch {
            val profile = settings.activeProfileId.first()
            settings.activeProfileId.collect {
                if (it != profile) {
                    _state.update { state -> state.copy(phase = LivePhase.ERROR, buffering = false,
                        error = "Your profile changed. Return to channels to continue.") }
                    close()
                }
            }
        }
    }

    private fun load(refresh: Boolean = false) {
        loading?.cancel()
        loading = viewModelScope.launch {
            try {
                val catalog = if (refresh) repository.channels() else repository.cachedCatalog ?: repository.channels()
                channels = if (catalog.enabled) catalog.channels else emptyList()
                val selected = channels.firstOrNull { it.id == channelId }
                if (selected == null) {
                    _state.update { it.copy(phase = LivePhase.ERROR, buffering = false,
                        error = catalog.message ?: "This channel is no longer available. Choose another channel.") }
                } else if (!closed && !suspended) tune(selected, resetRetries = true)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { _state.update { it.copy(phase = LivePhase.ERROR, buffering = false, error = liveMessage(error)) } }
        }
    }

    private fun tune(channel: LiveChannel, resetRetries: Boolean) {
        if (closed || suspended) return
        channelSwitch?.cancel(); channelSwitch = null
        retry?.cancel(); watchdog?.cancel(); healthy?.cancel()
        if (resetRetries) retryBudget.reset()
        liveWindowRecovery.reset()
        lastBandwidthLogMs = 0L
        channelId = channel.id
        player.stop(); player.clearMediaItems()
        _state.value = LivePlayerState(channel = channel, canChangeChannel = channels.size > 1,
            reconnecting = !resetRetries, captionsEnabled = _state.value.captionsEnabled)
        if (telemetryChannel != channel.id) {
            telemetryChannel = channel.id
            telemetry.start("live_tv", channel.id, channel.name) {
                tv.velvet.data.telemetry.PlaybackTelemetry.Sample(when {
                    suspended -> "paused"
                    _state.value.phase == LivePhase.ERROR -> "error"
                    player.isPlaying -> "playing"
                    _state.value.buffering -> "buffering"
                    else -> "paused"
                }, player.currentPosition)
            }
        } else if (!resetRetries) telemetry.sourceSwitch()
        sessions.tune(channel.id, onReady = { session ->
            if (!closed && !suspended) {
                repository.lastChannelId.value = channel.id
                player.setMediaItem(session.mediaItem())
                player.prepare()
                player.seekToDefaultPosition()
                player.playWhenReady = true
                startWatchdog()
            }
        }, onError = { error ->
            if (!closed && !suspended) _state.update { it.copy(phase = LivePhase.ERROR,
                buffering = false, error = liveMessage(error)) }
        })
    }

    private fun startWatchdog() {
        watchdog?.cancel()
        watchdog = viewModelScope.launch { delay(90_000); if (ownsPlayback()) recover() }
    }

    private fun rejoinLiveWindow() {
        // The channel and its license are still valid. Seeking to the default
        // live position lets the refreshed timeline discard expired segments.
        telemetry.error()
        watchdog?.cancel(); healthy?.cancel()
        _state.update { it.copy(phase = LivePhase.LOADING, buffering = true, reconnecting = true, error = null) }
        Log.i("VelvetLive", "Rejoining live window in the existing session")
        player.seekToDefaultPosition()
        player.prepare()
        player.playWhenReady = true
        startWatchdog()
    }

    private fun logLiveTiming(reason: String) {
        if (!ownsPlayback()) return
        val timeline = player.currentTimeline
        if (timeline.isEmpty) return
        val window = timeline.getWindow(player.currentMediaItemIndex, Timeline.Window())
        // Numeric playback diagnostics only: never log media IDs, capability
        // URLs, provider responses, or DRM payloads.
        Log.i("VelvetLive", "$reason: liveOffsetMs=${player.currentLiveOffset}" +
            " bufferedMs=${player.totalBufferedDuration} windowMs=${window.durationMs}" +
            " defaultMs=${window.defaultPositionMs} targetMs=${window.liveConfiguration?.targetOffsetMs}")
    }

    private fun recover() {
        if (closed || suspended || retry?.isActive == true) return
        telemetry.error()
        watchdog?.cancel(); healthy?.cancel()
        sessions.stop()
        player.stop(); player.clearMediaItems()
        if (!retryBudget.take()) {
            _state.update { it.copy(phase = LivePhase.ERROR, buffering = false, reconnecting = false,
                error = "This channel stopped responding. Retry or choose another channel.") }
            return
        }
        _state.update { it.copy(phase = LivePhase.LOADING, buffering = true, reconnecting = true) }
        retry = viewModelScope.launch {
            delay(1_500)
            retry = null
            channels.firstOrNull { it.id == channelId }?.let { tune(it, resetRetries = false) }
        }
    }

    fun retry() {
        if (closed) return
        val channel = channels.firstOrNull { it.id == channelId }
        if (channel == null) { _state.update { it.copy(phase = LivePhase.LOADING, error = null) }; load(refresh = true) }
        else tune(channel, resetRetries = true)
    }

    fun changeChannel(direction: Int) {
        if (closed || suspended) return
        val next = adjacentLiveChannel(channels, channelId, direction) ?: return
        channelId = next.id
        channelSwitch?.cancel(); retry?.cancel(); watchdog?.cancel(); healthy?.cancel()
        sessions.stop()
        player.stop(); player.clearMediaItems()
        _state.value = LivePlayerState(channel = next, canChangeChannel = true, captionsEnabled = _state.value.captionsEnabled)
        // Holding Channel Up/Down should select the final station, not create a
        // new browser/tuner request for every remote repeat event.
        channelSwitch = viewModelScope.launch {
            delay(300)
            channelSwitch = null
            tune(next, resetRetries = true)
        }
    }

    fun toggleCaptions() {
        if (closed) return
        val enabled = !_state.value.captionsEnabled
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, !enabled).build()
        _state.update { it.copy(captionsEnabled = enabled) }
    }

    fun onHostStop() {
        if (closed) return
        suspended = true
        telemetry.observe(true)
        loading?.cancel(); channelSwitch?.cancel(); retry?.cancel(); watchdog?.cancel(); healthy?.cancel()
        sessions.stop()
        player.stop(); player.clearMediaItems()
        _state.update { it.copy(phase = LivePhase.SUSPENDED, buffering = false) }
    }

    fun onHostResume() {
        if (!closed && suspended) { suspended = false; retry() }
    }

    fun close() {
        if (closed) return
        telemetry.end()
        closed = true
        loading?.cancel(); channelSwitch?.cancel(); retry?.cancel(); watchdog?.cancel(); healthy?.cancel()
        sessions.close()
        player.removeListener(listener)
        player.release()
    }

    override fun onCleared() { close() }
}
