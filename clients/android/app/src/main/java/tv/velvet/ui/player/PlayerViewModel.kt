package tv.velvet.ui.player

import android.util.Log
import androidx.annotation.OptIn
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem as ExoMediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import tv.velvet.data.categories.categoryQueueCountdownSeconds
import tv.velvet.data.categories.CategoryItem
import tv.velvet.data.categories.CategoryQueueSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import tv.velvet.VelvetApp
import tv.velvet.BuildConfig
import tv.velvet.data.telemetry.PlaybackSessionInterceptor
import tv.velvet.data.telemetry.SourceSwitchReason
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import tv.velvet.data.local.DEFAULT_PROFILE_ID
import tv.velvet.data.local.WatchProgressEntity
import tv.velvet.data.local.WatchedEpisodeEntity
import tv.velvet.data.model.Episode
import tv.velvet.data.model.MediaDetails
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget
import tv.velvet.data.tmdb.findPreviousEpisode
import tv.velvet.data.model.StreamOption
import tv.velvet.data.settings.SettingsRepository
import tv.velvet.data.settings.VelvetSettings
// Star import: the stream health-probe API (probeStreams) lives in this package
// alongside StreamRepository itself.
import tv.velvet.data.streams.*
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/** Which top-level UI the player screen shows. */
enum class PlayerPhase { LOADING, ERROR, PLAYING }

/** Lightweight episode descriptor for the Up Next overlay. */
data class NextEpisodeUi(
    val season: Int,
    val episode: Int,
    val title: String,
    val stillUrl: String?,
    val showTitle: String? = null,
    val isMovie: Boolean = false,
)

/**
 * One selectable entry in the subtitle/audio picker sheets.
 * [index] is the position within the player's current track groups of that type;
 * -1 is the "Off" entry (subtitles only).
 */
data class TrackOptionUi(
    val index: Int,
    val label: String,
    val selected: Boolean,
)

sealed interface UpNextUi {
    data object Hidden : UpNextUi

    /** Autoplay countdown card, bottom-right, ticking once a second. */
    data class Countdown(
        val next: NextEpisodeUi,
        val secondsLeft: Int,
        val totalSeconds: Int,
    ) : UpNextUi

    /** Static end-of-episode choice card (autoplay off or "Watch credits" was pressed). */
    data class EndChoice(val next: NextEpisodeUi) : UpNextUi
}

data class PlayerUiState(
    val phase: PlayerPhase = PlayerPhase.LOADING,
    val errorMessage: String? = null,
    val canChooseStream: Boolean = false,
    val backdropUrl: String? = null,
    val showTitle: String = "",
    /** "S2 E4 — Episode Title" for shows; null for movies. */
    val episodeLabel: String? = null,
    val isShow: Boolean = false,
    val inCategory: Boolean = false,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val positionMs: Long = 0L,
    val durationMs: Long = 0L,
    val bufferedMs: Long = 0L,
    val streams: List<StreamOption> = emptyList(),
    /** Stream url -> episode-title verdict for the picker (badges MISMATCH entries). */
    val episodeVerdicts: Map<String, EpisodeTitleVerdict> = emptyMap(),
    val currentStreamUrl: String? = null,
    /**
     * A dead source is being swapped out underneath the user — drives the brief,
     * non-blocking "Trying another source…" pill. Clears as soon as playback is ready.
     */
    val switchingSource: Boolean = false,
    val queueNotice: String? = null,
    val hasNext: Boolean = false,
    val hasPrevious: Boolean = false,
    val blockedGroups: List<ReleaseGroup> = emptyList(),
    val canBlockCurrentRelease: Boolean = false,
    val groupActionError: String? = null,
    val recoveryDiagnostics: ExactRecoveryState? = null,
    val repairDiagnostics: ExactRepairState? = null,
    /** Display name of the active embedded subtitle track; null = subtitles off. */
    val subtitleLabel: String? = null,
    val subtitleAvailable: Boolean = false,
    /** "Off" + every embedded text track; empty when the stream has none. */
    val subtitleOptions: List<TrackOptionUi> = emptyList(),
    /** Embedded audio tracks; empty until the player reports them. */
    val audioOptions: List<TrackOptionUi> = emptyList(),
    val upNext: UpNextUi = UpNextUi.Hidden,
    /** "What did they say?" is mid-flight: subs temporarily on, restore pending. */
    val replayActive: Boolean = false,
    /** Playback is inside a known intro — the Skip Intro pill should show. */
    val skipIntroVisible: Boolean = false,
)

private data class PendingSeek(val positionMs: Long, val guardNearEnd: Boolean)

/**
 * One resolved stream set. Keep [raw] so unblocking can restore previously hidden
 * groups; [all] is the visible ranked list and [candidates] is the automatic order.
 */
private data class PreparedStreams(
    val raw: List<StreamOption>,
    val all: List<StreamOption>,
    val candidates: List<StreamOption>,
    /** Stream url -> episode-title verdict; empty for movies / no episode data. */
    val verdicts: Map<String, EpisodeTitleVerdict> = emptyMap(),
)

/**
 * Hard cap on ExoPlayer's in-memory sample buffer — sized to absorb usenet's
 * bursty delivery. Logs showed 4K Dolby Vision playing fine for ~60 s then
 * rebuffering on a transient nzbdav dip a 72 MB (~11 s) buffer couldn't ride out.
 * 256 MB ≈ 20–34 s at 60–100 Mbps — long enough to swallow those dips, and with
 * largeHeap's 512 MB ceiling it leaves ~125 MB headroom over the app baseline.
 */
private const val MAX_BUFFER_BYTES = 256 * 1024 * 1024

private const val UP_NEXT_TRIGGER_MS = 40_000L
private const val UP_NEXT_RELEASE_MS = 45_000L
private const val RESUME_MIN_MS = 30_000L
private const val PROGRESS_SAVE_EVERY_TICKS = 20 // ticker runs every 500ms -> 10s

/** "What did they say?" — jump back this far with subtitles temporarily on. */
private const val REPLAY_BACK_MS = 15_000L

/**
 * Ceiling on automatic alternatives in one failure burst. Thirty seconds of
 * uninterrupted moving playback renews it; a systemic outage still stops.
 */
private const val MAX_AUTO_RETRIES = 4

private const val TAG = "PlayerViewModel"

@OptIn(UnstableApi::class)
class PlayerViewModel(
    app: VelvetApp,
    private val target: PlayTarget,
) : ViewModel() {

    private val container = app.container
    private val tmdb = container.tmdbRepository
    private val streamRepo = container.streamRepository
    private val settingsRepo = container.settingsRepository
    private val telemetry = tv.velvet.data.telemetry.PlaybackTelemetry(app, settingsRepo)
    private var telemetryIdentity: String? = null
    private val handoffLease = container.tvHandoffSession.get(target.handoffId)
    @Volatile private var handoffAccepted = target.handoffId == null
    private var handoffFinished = target.handoffId == null
    private var handoffAborted = false
    private var handoffPrepareJob: Job? = null
    private val progressDao = container.database.watchProgressDao()
    private val queueStore = container.categoryQueueStore
    private val isQueue = target.queueSessionId != null
    private var queueSession: CategoryQueueSession? = null
    private var queueAdvancing = false
    private var queueClosed = false
    private var queueAdvanceJob: Job? = null
    @Volatile private var queueDetached = false
    private var queueFailureJob: Job? = null
    private var queuePrefetchJob: Job? = null
    private var queuePlayingTicks = 0
    private var queueReportedPlaying = false
    private val progressMutex = Mutex()
    private val queueChannel = Channel<PlayTarget>(Channel.BUFFERED)
    val queueEvents = queueChannel.receiveAsFlow()
    private val syncEngine = container.syncEngine

    /**
     * The profile this playback session writes under — captured once at start so a
     * mid-session profile switch (if it ever happened) can never re-attribute progress.
     * Resolved in load(); the DEFAULT_PROFILE_ID fallback covers the pre-resolution gap.
     */
    @Volatile private var activeProfileId: String = DEFAULT_PROFILE_ID

    /** Survives onCleared so final progress writes always land. */
    private val persistScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _state = MutableStateFlow(PlayerUiState(isShow = target.type == MediaType.SHOW, inCategory = isQueue))
    val state: StateFlow<PlayerUiState> = _state.asStateFlow()

    /** Emitted when the screen should pop itself (movie finished, no next episode, ...). */
    private val _exitEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val exitEvents: SharedFlow<Unit> = _exitEvents.asSharedFlow()

    // ---- media identity ------------------------------------------------------------------
    private var details: MediaDetails? = null
    private var imdbId: String? = null
    private var curSeason: Int? = target.season
    private var curEpisode: Int? = target.episode
    private var currentEpisodeMeta: Episode? = null
    private val episodesCache = ConcurrentHashMap<Int, List<Episode>>()

    // ---- playback bookkeeping ------------------------------------------------------------
    @Volatile private var settings: VelvetSettings = VelvetSettings(
        tmdbApiKey = SettingsRepository.DEFAULT_TMDB_KEY,
        streamSources = emptyList(),
        rowOrder = emptyList(),
        autoplayNext = true,
        autoplayCountdownSecs = 8,
        preferredQuality = "2160p",
        tunneledPlayback = false,
    )
    private var currentStream: StreamOption? = null
    private var allResolvedStreams: List<StreamOption> = emptyList()
    private var blockedGroups: List<ReleaseGroup> = emptyList()
    private val failoverWatchdog = StreamFailoverWatchdog()
    private var hostStopped = false
    private var recoveryJob: Job? = null
    private var preparedFallback: StreamOption? = null
    private var recoveryPrepareRequested = false
    private var recoveryRevision = 0L

    /**
     * Ordered fallback list for THIS media: ranked streams with release-group continuity
     * first. Playback availability is bounded by the stall watchdog. Index 0 plays;
     * a PlaybackException walks down the list without leaving the screen.
     */
    private var candidates: List<StreamOption> = emptyList()

    /** URLs that failed playback this session — never picked again by the failover. */
    private val blacklistedUrls: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** Consecutive failures renew only after sustained, moving playback. */
    private val recoveryBudget = StreamRecoveryBudget(MAX_AUTO_RETRIES)

    private var lastBingeGroup: String? = null

    /**
     * Sticky release group for THIS show (imdbId-keyed, DataStore-persisted): set when
     * the user hand-picks a stream from the picker, loaded back in load(). Outranks
     * [lastBingeGroup] session continuity in [prepareStreams] — a manual pick after an
     * autopick had issues means "this group works, stay on it for the whole show". When
     * an episode has no stream in the group, it silently falls through to best quality.
     * Autopick and failover NEVER write it.
     */
    @Volatile private var manualGroup: String? = null
    private var pendingSeek: PendingSeek? = null
    @Volatile private var lastKnownPositionMs: Long = 0L
    @Volatile private var lastKnownDurationMs: Long = 0L
    @Volatile private var markedWatched = false
    private var endedHandled = false

    // ---- up-next bookkeeping --------------------------------------------------------------
    @Volatile private var nextEpisode: Episode? = null
    @Volatile private var nextResolved = false
    private var pendingNextEpisode: Episode? = null
    /** (season, episode) -> streams already resolved AND health-probed for the swap. */
    private var prefetchedStreams: Triple<Int, Int, PreparedStreams>? = null
    private var upNextArming = false
    private var upNextCancelled = false
    private var upNextJob: Job? = null
    private var loadJob: Job? = null
    private var swapping = false

    // ---- subtitles -------------------------------------------------------------------------
    private var subtitlesEnabled = false
    private var subtitleGroupIndex = -1

    // ---- "What did they say?" --------------------------------------------------------------
    /** Position playback must pass before the temporary subtitles turn back off; -1 = idle. */
    private var replayRestoreAtMs = -1L
    /** Whether finishing the replay should switch subtitles back OFF (they were off). */
    private var replayTurnSubsOff = false

    private val companion = container.companionApi

    // ---- skip intro ------------------------------------------------------------------------
    @Volatile private var introRangeMs: LongRange? = null
    @Volatile private var introDismissed = false
    private var segmentsJob: Job? = null

    // Actual playback is the availability check. Do not multiply a dead socket's
    // deadline with same-URL retries before trying a different release.
    private val playbackHttpClient = container.okHttpClient.newBuilder()
        .connectTimeout(6, TimeUnit.SECONDS)
        .readTimeout(6, TimeUnit.SECONDS)
        .apply {
            if (BuildConfig.EXACT_RECOVERY) addNetworkInterceptor(PlaybackSessionInterceptor { settings.syncUrl })
        }
        .build()
    private val httpDataSourceFactory = OkHttpDataSource.Factory(playbackHttpClient)

    /**
     * Memory-bounded buffering. ExoPlayer's default LoadControl buffers by TIME
     * (~50s), so a high-bitrate Dolby Vision stream (~60–100 Mbps) holds
     * 400–600 MB of compressed samples on the Java heap and OOM-kills the app —
     * the Shield's heap growth limit is only ~192 MB. Capping targetBufferBytes
     * makes memory bounded regardless of bitrate (the cap binds first for fat
     * streams; the time targets still apply for light ones). Paired with
     * android:largeHeap so the cap + decoder + UI have comfortable headroom.
     */
    private val loadControl = DefaultLoadControl.Builder()
        .setTargetBufferBytes(MAX_BUFFER_BYTES)
        .setBufferDurationsMs(
            /* minBufferMs = */ 30_000,
            /* maxBufferMs = */ 120_000, // for high-bitrate the byte cap binds first (~20-34s);
                                          // lighter streams pre-buffer up to 2 min of cushion
            /* bufferForPlaybackMs = */ 2_500,
            /* bufferForPlaybackAfterRebufferMs = */ 5_000,
        )
        .setPrioritizeTimeOverSizeThresholds(false) // honor the byte cap over the time target
        .build()

    val player: ExoPlayer = ExoPlayer.Builder(app)
        .setMediaSourceFactory(
            DefaultMediaSourceFactory(httpDataSourceFactory),
        )
        .setLoadControl(loadControl)
        .setSeekBackIncrementMs(10_000)
        .setSeekForwardIncrementMs(10_000)
        .build()

    private val playerListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            telemetry.observe()
            when (playbackState) {
                Player.STATE_READY -> {
                    // Playback is live again — the failover pill has served its purpose.
                    _state.update { it.copy(isBuffering = false, switchingSource = false) }
                    applyPendingSeek()
                }
                Player.STATE_BUFFERING -> _state.update { it.copy(isBuffering = true) }
                Player.STATE_ENDED -> {
                    _state.update { it.copy(isBuffering = false, isPlaying = false) }
                    if (!handoffFinished) abortHandoff("The stream ended before the requested position could play.")
                    else handleEnded()
                }
                else -> Unit
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (!isPlaying) recoveryBudget.interrupt()
            _state.update { it.copy(isPlaying = isPlaying) }
            telemetry.observe()
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (BuildConfig.EXACT_RECOVERY) telemetry.observe()
        }

        override fun onPlaybackSuppressionReasonChanged(playbackSuppressionReason: Int) {
            if (BuildConfig.EXACT_RECOVERY) telemetry.observe()
        }

        override fun onPlayerError(error: PlaybackException) {
            handlePlayerError(error)
        }

        override fun onTracksChanged(tracks: Tracks) {
            handleTracksChanged(tracks)
        }
    }

    init {
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            /* handleAudioFocus = */ true,
        )
        player.playWhenReady = true
        player.addListener(playerListener)
        // Subtitles start off; the picker enables a specific embedded text track.
        // Multi-language releases default to English audio; a manual pick from the
        // audio picker overrides this for the session.
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            .setPreferredAudioLanguages("en", "eng")
            .build()

        viewModelScope.launch { settingsRepo.settings.collect { settings = it } }
        viewModelScope.launch {
            settingsRepo.blockedReleaseGroups.collect { stored ->
                if (target.type == MediaType.SHOW && imdbId != null)
                    applyBlockedGroups(blockedReleaseGroupsForShow(stored, imdbId))
            }
        }
        startTicker()
        monitorHandoff()
        load()
    }

    // =====================================================================================
    // Pipeline: identity -> streams -> play
    // =====================================================================================

    /** Receipt means moving playback after the explicit seek, not just a loaded screen. */
    private fun monitorHandoff() {
        val lease = handoffLease ?: return
        viewModelScope.launch {
            val deadline = android.os.SystemClock.elapsedRealtime() + 115_000
            var previousPosition: Long? = null
            while (isActive && !handoffFinished) {
                if (!container.tvHandoffSession.isEligible(lease)) {
                    abortHandoff("The TV is no longer active.")
                    break
                }
                if (android.os.SystemClock.elapsedRealtime() >= deadline) {
                    abortHandoff("The TV couldn't start this stream in time.")
                    break
                }
                try {
                    val status = container.tvHandoffApi.status(lease.handoff.id)
                    if (status.state == "started") {
                        acceptHandoff()
                        break
                    }
                    if (status.state != "claimed") {
                        abortHandoff("Send to TV was cancelled or expired.")
                        break
                    }
                    val pos = player.currentPosition
                    val reached = tv.velvet.data.companion.handoffPlaybackReached(
                        pos, lease.handoff.positionMs, player.isPlaying, pendingSeek != null,
                    )
                    if (reached && previousPosition != null && pos > previousPosition + 100 &&
                        container.tvHandoffSession.isEligible(lease)) {
                        val receipt = container.tvHandoffApi.ack(lease, "started")
                        if (receipt.accepted && receipt.status.state == "started") acceptHandoff()
                        else abortHandoff("Send to TV was cancelled before playback began.")
                        break
                    }
                    previousPosition = pos.takeIf { reached }
                } catch (cancelled: CancellationException) { throw cancelled
                } catch (_: Exception) { /* A lost receipt is resolved through status on the next pass. */ }
                delay(500)
            }
        }
    }

    private fun acceptHandoff() {
        if (handoffAccepted) return
        handoffAccepted = true
        _state.update { it.copy(canBlockCurrentRelease = canBlockCurrentRelease()) }
        handoffFinished = true
        handoffLease?.let { container.tvHandoffSession.forget(it.handoff.id) }
        Log.i("Handoff", "Playback acknowledged at ${player.currentPosition}ms")
        resolveNextEagerly()
        // Only after the transferred stream is playing, restore ordinary recovery
        // choices for future failures. This never replaces the current media item.
        val source = currentStream ?: return
        if (target.type == MediaType.SHOW) reportPlayAndWatchForIntro(source)
        watchRecovery(source)
        val season = curSeason
        val episode = curEpisode
        val id = imdbId ?: return
        viewModelScope.launch {
            try {
                val streams = streamRepo.streamsFor(id, target.type, season, episode)
                if (curSeason == season && curEpisode == episode && currentStream == source) {
                    allResolvedStreams = (listOf(source) + streams).distinctBy { it.url }
                    candidates = (listOf(source) + streamRepo.sortStreams(streams, settings.preferredQuality))
                        .distinctBy { it.url }.filterNot { it.url in blacklistedUrls || isBlocked(it) }
                    _state.update { it.copy(streams = candidates) }
                }
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (_: Exception) { /* The working transferred stream remains untouched. */ }
        }
    }

    private fun failHandoff(message: String) {
        if (handoffFinished) return
        handoffFinished = true
        handoffPrepareJob?.cancel()
        handoffLease?.let { lease ->
            container.tvHandoffSession.forget(lease.handoff.id)
            persistScope.launch {
                try { container.tvHandoffApi.ack(lease, "failed", message) } catch (_: Exception) { }
            }
        }
    }

    private fun abortHandoff(message: String) {
        handoffAborted = true
        handoffPrepareJob?.cancel()
        loadJob?.cancel()
        recoveryJob?.cancel()
        upNextJob?.cancel()
        player.stop()
        showError(message, false)
    }

    private fun load() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            _state.update { it.copy(phase = PlayerPhase.LOADING, errorMessage = null) }
            try {
                settings = settingsRepo.settings.first()
                if (target.handoffId != null && handoffLease == null) {
                    showError("This Send to TV request has ended. Send it again from your phone.", false)
                    return@launch
                }
                if (handoffAborted) return@launch
                activeProfileId = handoffLease?.handoff?.profileId
                    ?: settingsRepo.activeProfileId.first() ?: DEFAULT_PROFILE_ID
                if (handoffLease != null && !handoffFinished) {
                    if (!container.tvHandoffSession.isEligible(handoffLease) ||
                        container.tvHandoffApi.status(handoffLease.handoff.id).state != "claimed") {
                        abortHandoff("This Send to TV request is no longer active.")
                        return@launch
                    }
                    var profile = container.database.profileDao().profileById(activeProfileId)
                    if (profile == null) {
                        syncEngine.pullNow()
                        repeat(15) {
                            if (profile == null) { delay(200); profile = container.database.profileDao().profileById(activeProfileId) }
                        }
                    }
                    if (profile == null || profile!!.deleted) {
                        showError("The phone's profile is unavailable on this TV.", false)
                        return@launch
                    }
                    settingsRepo.setActiveProfileId(activeProfileId)
                }
                if (isQueue) {
                    queueSession = queueStore.current(target)
                    val session = queueSession
                    if (session == null) {
                        showError("This category has ended or the profile changed. Start it again from Home.", false)
                        return@launch
                    }
                    val current = session.items[session.cursor]
                    _state.update { it.copy(hasNext = session.nextTarget() != null, hasPrevious = session.previousTarget() != null,
                        queueNotice = session.notice, showTitle = current.title,
                        backdropUrl = current.stillUrl ?: current.backdropUrl ?: current.posterUrl) }
                    if (session.notice != null) viewModelScope.launch {
                        delay(8_000); _state.update { it.copy(queueNotice = null) }
                    }
                }
                applyTunnelingIfEnabled()
                val d = details ?: tmdb.details(target.mediaId, target.type).also { details = it }
                // Stream key: the imdb id when TMDB knows it, else a `tmdb:<id>`
                // pseudo-id the backend resolves by TITLE. Day-one titles (Monster:
                // The Lizzie Borden Story aired 2 days before this was written) often
                // have NO imdb mapping anywhere yet — bailing here made them
                // unwatchable exactly during the week everyone wants them.
                imdbId = d.item.imdbId?.takeIf { it.isNotBlank() } ?: "tmdb:${target.mediaId}"
                _state.update {
                    it.copy(
                        backdropUrl = d.item.backdropUrl ?: d.item.posterUrl,
                        showTitle = d.item.title,
                    )
                }
                if (target.type == MediaType.SHOW) {
                    // Restore this show's sticky release group (see [manualGroup]) before
                    // the first prepareStreams runs, so episode one already honors it.
                    manualGroup = runCatching {
                        settingsRepo.manualBingeGroups.first()[imdbId]
                    }.getOrNull()
                    applyBlockedGroups(blockedReleaseGroupsForShow(settingsRepo.blockedReleaseGroups.first(), imdbId))
                    val (s, e) = resolveEpisodeTarget(d)
                    curSeason = s
                    curEpisode = e
                    val ep = runCatching { episodesFor(s) }.getOrDefault(emptyList())
                        .firstOrNull { it.number == e }
                    currentEpisodeMeta = ep
                    _state.update { it.copy(episodeLabel = formatEpisodeLabel(s, e, ep?.title)) }
                }
                // Cross-device resume: read the progress row only AFTER this session's
                // launch pull has settled (bounded wait), so a position written on the
                // phone seconds ago wins over the stale local row.
                if (!isQueue && handoffLease == null) syncEngine.awaitPullSettled()
                pendingSeek = if (isQueue) null else if (handoffLease != null && !handoffFinished)
                    PendingSeek(handoffLease.handoff.positionMs, guardNearEnd = false) else computeResume()
                startTelemetry()
                startStreamsAndPlay()
                resolveNextEagerly()
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                showError(
                    "Couldn't load this title. Check your connection and try again.",
                    canChoose = _state.value.streams.isNotEmpty(),
                )
            }
        }
    }

    /**
     * For shows launched without a season/episode: first episode (scanning seasons in order)
     * that is not in the watched set. Defaults to S1E1.
     */
    private suspend fun resolveEpisodeTarget(d: MediaDetails): Pair<Int, Int> {
        val ts = target.season
        val te = target.episode
        if (ts != null && te != null) return ts to te
        val watched = progressDaoWatchedSet()
        val seasonNumbers = d.seasons.map { it.number }.filter { it > 0 }.sorted()
            .let { all -> if (ts != null) all.filter { it == ts } else all }
        for (sn in seasonNumbers) {
            val eps = runCatching { episodesFor(sn) }.getOrDefault(emptyList())
            val hit = eps.sortedBy { it.number }.firstOrNull { (sn to it.number) !in watched }
            if (hit != null) return sn to hit.number
        }
        return (ts ?: 1) to (te ?: 1)
    }

    private suspend fun progressDaoWatchedSet(): Set<Pair<Int, Int>> =
        runCatching {
            progressDao.watchedEpisodes(activeProfileId, target.mediaId).first()
                .map { it.season to it.episode }.toSet()
        }.getOrDefault(emptySet())

    private suspend fun computeResume(): PendingSeek? {
        val row = runCatching { progressDao.progressFor(activeProfileId, target.mediaId, target.type.key) }
            .getOrNull() ?: return null
        if (target.type == MediaType.SHOW &&
            (row.season != curSeason || row.episode != curEpisode)
        ) return null
        if (row.positionMs < RESUME_MIN_MS) return null
        if (row.durationMs > 0 && row.positionMs >= row.durationMs * 95 / 100) return null
        return PendingSeek(row.positionMs, guardNearEnd = true)
    }

    private suspend fun startStreamsAndPlay() {
        if (handoffLease != null && !handoffFinished) {
            val exact = container.tvHandoffApi.playbackStream(handoffLease.handoff)
            if (isBlocked(exact)) {
                abortHandoff("This release group is blocked for this show on the TV. Choose another stream on your phone.")
                return
            }
            allResolvedStreams = listOf(exact)
            candidates = listOf(exact)
            _state.update { it.copy(streams = candidates, episodeVerdicts = emptyMap()) }
            play(exact)
            return
        }
        val id = imdbId
        if (id.isNullOrBlank()) {
            showError("No stream source for this title.", canChoose = false)
            return
        }
        val identity = curSeason to curEpisode
        val streams = queueStore.takeStreams(target) ?: runCatching {
            streamRepo.streamsFor(id, target.type, identity.first, identity.second)
        }.getOrDefault(emptyList())
        if (identity != curSeason to curEpisode) return
        if (streams.isEmpty()) {
            showError(
                "No streams found from your sources. Check Settings → Stream Sources.",
                canChoose = false,
            )
            return
        }
        allResolvedStreams = streams
        val prepared = prepareStreams(streams, curSeason, curEpisode)
        if (identity != curSeason to curEpisode) return
        candidates = prepared.candidates.filterNot(::isBlocked)
        _state.update { it.copy(streams = prepared.all.filterNot(::isBlocked), episodeVerdicts = prepared.verdicts) }
        val pick = candidates.firstOrNull()
        if (pick == null) showError("No unblocked streams are available. Open Playback options to reset blocked releases.", true)
        else play(pick)
    }

    /** Rank immediately; playback and its bounded watchdog replace serial preflight probes. */
    private suspend fun prepareStreams(
        streams: List<StreamOption>,
        season: Int?,
        episode: Int?,
    ): PreparedStreams {
        // Episode-title cross-check (EpisodeMatch.kt): demote releases whose filename
        // carries a DIFFERENT episode's title (off-by-one numbering), boost ones carrying
        // the requested title. Movies / missing episode data => empty map => every rank is
        // UNKNOWN (1) and the re-rank below is a no-op, so behavior is unchanged.
        val verdicts: Map<String, EpisodeTitleVerdict> =
            if (target.type == MediaType.SHOW && season != null && episode != null) {
                val eps = runCatching { episodesFor(season) }.getOrDefault(emptyList())
                    .map { EpisodeMatch.SeasonEpisodeRef(it.number, it.title) }
                if (eps.isEmpty()) emptyMap()
                else streams.associate { s ->
                    s.url to EpisodeMatch.classify(s.title, season, episode, eps)
                }
            } else emptyMap()
        fun rankOf(s: StreamOption): Int = verdicts[s.url]?.sortRank ?: 1

        // Quality sort first, then a STABLE verdict re-rank: CONFIRMED first, UNKNOWN keeps
        // today's ordering, MISMATCH sinks last. sortedBy is stable.
        val sorted: List<StreamOption> =
            runCatching { streamRepo.sortStreams(streams.filterNot(::isBlocked), settings.preferredQuality) }
                .getOrDefault(streams.filterNot(::isBlocked))
                .sortedBy(::rankOf)
        val healthy = sorted
        // Keep explicit group continuity without delaying first playback on probe batches.
        val hint = handoffLease?.handoff?.sourceHint?.takeIf { !handoffFinished }
        val promoted = hint?.let { source ->
            healthy.firstOrNull { it.title == source.title && it.sourceName == source.sourceName && rankOf(it) != 2 }
                ?: source.bingeGroup?.let { group -> healthy.firstOrNull { it.bingeGroup == group && rankOf(it) != 2 } }
        } ?: manualGroup?.let { group ->
            healthy.firstOrNull { it.bingeGroup == group && rankOf(it) != 2 }
        } ?: lastBingeGroup?.let { group ->
            healthy.firstOrNull { it.bingeGroup == group && rankOf(it) != 2 }
        }
        val ordered =
            if (promoted == null) healthy
            else listOf(promoted) + healthy.filterNot { it.url == promoted.url }
        return PreparedStreams(
            raw = streams,
            all = sorted,
            candidates = ordered
                .distinctBy { it.url }
                .filterNot { it.url in blacklistedUrls },
            verdicts = verdicts,
        )
    }

    private fun play(stream: StreamOption, reason: SourceSwitchReason = SourceSwitchReason.AUTOMATIC) {
        if (handoffAborted || (handoffFinished && !handoffAccepted)) return
        val lease = handoffLease
        if (lease != null && !handoffFinished) {
            handoffPrepareJob?.cancel()
            handoffPrepareJob = viewModelScope.launch {
                try {
                    val status = container.tvHandoffApi.status(lease.handoff.id)
                    if (!container.tvHandoffSession.isEligible(lease) ||
                        status.state !in setOf("claimed", "started") || handoffAborted) {
                        abortHandoff("Send to TV is no longer active.")
                    } else {
                        if (status.state == "started") acceptHandoff()
                        prepareStream(stream, reason)
                    }
                } catch (cancelled: CancellationException) { throw cancelled
                } catch (_: Exception) { abortHandoff("Couldn't confirm Send to TV. Please try again.") }
            }
        } else prepareStream(stream, reason)
    }

    private fun prepareStream(stream: StreamOption, reason: SourceSwitchReason) {
        if (handoffAccepted && isBlocked(stream)) return
        if (handoffAborted || (handoffFinished && !handoffAccepted)) return
        if (BuildConfig.EXACT_RECOVERY) telemetry.sourcePrepared(stream.url, reason)
        else if (currentStream != null && currentStream?.url != stream.url) telemetry.sourceSwitch()
        currentStream = stream
        val sourceGeneration = recoveryBudget.sourceChanged()
        failoverWatchdog.reset(android.os.SystemClock.elapsedRealtime())
        stream.bingeGroup?.let { lastBingeGroup = it }
        if (target.type == MediaType.SHOW && handoffAccepted) reportPlayAndWatchForIntro(stream)
        val mediaHeaders = if (BuildConfig.EXACT_RECOVERY) {
            val headers = stream.headers.filterKeys { !it.equals(PlaybackSessionInterceptor.HEADER, true) }.toMutableMap()
            val url = stream.url.toHttpUrlOrNull()
            val watchId = telemetry.sessionId
            if (watchId != null && url != null && PlaybackSessionInterceptor.allowsAttribution(settings.syncUrl, url)) {
                headers[PlaybackSessionInterceptor.HEADER] = watchId
            }
            headers
        } else stream.headers
        httpDataSourceFactory.setDefaultRequestProperties(mediaHeaders)
        val mediaSource = DefaultMediaSourceFactory(httpDataSourceFactory)
            .setLoadErrorHandlingPolicy(StreamLoadErrorPolicy(recoveryBudget, sourceGeneration))
            .createMediaSource(ExoMediaItem.fromUri(stream.url))
        val explicitStart = pendingSeek?.takeIf { !it.guardNearEnd }
        if (explicitStart != null) {
            // Begin loading at the transferred position, without briefly playing from zero.
            pendingSeek = null
            player.setMediaSource(mediaSource, explicitStart.positionMs.coerceAtLeast(0))
        } else player.setMediaSource(mediaSource)
        // Only now can the OLD item no longer emit STATE_ENDED — re-arming any earlier
        // (e.g. at the top of swapToEpisode) lets a late ENDED corrupt the new episode's
        // watched-state while streams are still being fetched.
        endedHandled = false
        player.prepare()
        if (handoffAccepted) watchRecovery(stream)
        player.playWhenReady = true
        _state.update {
            it.copy(
                phase = PlayerPhase.PLAYING,
                errorMessage = null,
                canChooseStream = false,
                currentStreamUrl = stream.url,
                recoveryDiagnostics = null,
                repairDiagnostics = null,
                canBlockCurrentRelease = canBlockCurrentRelease(),
                isBuffering = true,
            )
        }
    }

    private fun applyPendingSeek() {
        val seek = pendingSeek ?: return
        pendingSeek = null
        val dur = player.duration
        if (seek.guardNearEnd && dur > 0 && seek.positionMs >= dur * 95 / 100) return
        player.seekTo(seek.positionMs.coerceAtLeast(0L))
        resetStallDeadline()
        requestRecoveryPreparation()
    }

    /**
     * settings.tunneledPlayback — required by some Dolby Vision profiles on Shield.
     * Tunneling lives on [DefaultTrackSelector.Parameters] (ExoPlayer's default selector),
     * not on the common TrackSelectionParameters, hence the safe-cast: buildUpon() on the
     * player's parameters returns the covariant DefaultTrackSelector builder at runtime.
     */
    private fun applyTunnelingIfEnabled() {
        if (!settings.tunneledPlayback) return
        val builder = player.trackSelectionParameters.buildUpon()
        (builder as? DefaultTrackSelector.Parameters.Builder)?.setTunnelingEnabled(true)
        player.trackSelectionParameters = builder.build()
    }

    private fun showError(message: String, canChoose: Boolean) {
        failHandoff(message)
        recoveryJob?.cancel()
        queueFailureJob?.cancel()
        upNextJob?.cancel()
        _state.update {
            it.copy(
                phase = PlayerPhase.ERROR,
                errorMessage = message,
                // Saved blocks remain manageable even when the resolver returns no sources.
                canChooseStream = (canChoose && it.streams.isNotEmpty()) || it.blockedGroups.isNotEmpty(),
                isBuffering = false,
                switchingSource = false,
                upNext = UpNextUi.Hidden,
            )
        }
        scheduleQueueSkip()
    }

    private fun scheduleQueueSkip() {
        if (!isQueue || queueSession == null || queueAdvancing || queueDetached) return
        queueFailureJob = viewModelScope.launch {
            _state.update { it.copy(queueNotice = "This item is unavailable. Trying the next item in a moment…") }
            delay(2_500)
            advanceQueue(failed = true)
        }
    }

    /**
     * A stream died (dead/incomplete NZB, source dropped out). Blacklist it and swap to
     * the next healthy candidate AT THE SAME POSITION inside this same player session —
     * same machinery as the autoplay-next swap: no navigation, no lost progress row, no
     * re-resolution of the episode identity. The error screen is the last resort, once
     * the candidates are exhausted (or [MAX_AUTO_RETRIES] auto-swaps have been spent).
     */
    private fun handlePlayerError(error: PlaybackException) {
        if (!BuildConfig.EXACT_RECOVERY || !(swapping || queueAdvancing || queueDetached || queueClosed || hostStopped)) {
            telemetry.error()
        }
        if (handoffLease != null && !handoffFinished) {
            Log.w("Handoff", "The phone's exact stream failed on TV (${error.errorCodeName})")
            abortHandoff("The phone's stream couldn't play on this TV. Playback can continue on your phone.")
            return
        }
        // A late error from the OLD media item while swapToEpisode is in flight belongs to
        // an episode we have already left — same reasoning as handleEnded/maybeTriggerUpNext.
        // Acting on it would blacklist the old URL, burn an auto-retry, and (via failoverTo)
        // arm a pendingSeek at the PREVIOUS episode's position, which applyPendingSeek then
        // fires on the new episode's STATE_READY. The swap is already re-preparing the
        // player, so there is nothing to recover here.
        if (swapping || queueAdvancing || queueDetached || queueClosed || hostStopped) return
        val failure = streamFailure(error)
        Log.w(TAG, "Playback failed: ${error.errorCodeName}; HTTP=${failure.status ?: "none"}; reason=${failure.reason.wire}")
        val pos = player.currentPosition
        if (pos > 0) lastKnownPositionMs = pos
        val failedUrl = currentStream?.url
        if (failedUrl != null) blacklistedUrls.add(failedUrl)
        val next = preparedFallback?.takeIf { it.url != failedUrl && it.url !in blacklistedUrls && !isBlocked(it) }
            ?: candidates.firstOrNull { it.url != failedUrl && it.url !in blacklistedUrls && !isBlocked(it) }
        if (next != null && recoveryBudget.tryAutomaticSwitch()) {
            Log.w(
                TAG,
                "stream failed (${error.errorCodeName}) — failover ${recoveryBudget.automaticAttempts}/$MAX_AUTO_RETRIES " +
                    "to ${next.sourceName} at ${lastKnownPositionMs}ms",
            )
            failoverTo(next)
            return
        }
        val reason = streamFailure(error)
        val message = when (reason.reason) {
            StreamFailureReason.MISSING_ARTICLES -> "This source is missing part of the video."
            StreamFailureReason.UNSUPPORTED_ARCHIVE -> "This source uses an unsupported archive format."
            StreamFailureReason.INVALID_ARCHIVE -> "This source's archive could not be read."
            StreamFailureReason.UNKNOWN_STREAM -> "This stream is no longer available."
            StreamFailureReason.UPSTREAM_UNAVAILABLE, StreamFailureReason.TRANSPORT -> "The video source stopped responding."
            else -> "This source couldn't continue playing."
        }
        showError("$message Choose another stream or try again.", canChoose = true)
        // A watchdog timeout is synthesized while ExoPlayer is still loading.
        // Cancel that load so it cannot start later underneath the error screen.
        player.stop()
        val dur = lastKnownDurationMs
        val p = lastKnownPositionMs
        val season = curSeason
        val episode = curEpisode
        val meta = currentEpisodeMeta
        if (!isQueue) persistScope.launch { persistProgress(p, dur, season, episode, meta) }
    }

    private fun requestRecoveryPreparation() {
        recoveryRevision++
        recoveryPrepareRequested = true
        preparedFallback = null
        if (BuildConfig.EXACT_RECOVERY) _state.update { it.copy(recoveryDiagnostics = null, repairDiagnostics = null) }
    }

    /** Report playback for exact recovery and keep an alternate available as ordinary fallback. */
    private fun watchRecovery(stream: StreamOption) {
        if (!handoffAccepted) return
        recoveryJob?.cancel()
        requestRecoveryPreparation()
        // Capture this watch before launching: a late stop from the old episode
        // must never cancel or attribute bytes to the next episode's session.
        val recoverySessionId = telemetry.sessionId
        recoveryJob = viewModelScope.launch {
            var lastPrepareAt = 0L
            var prepareJob: Job? = null
            var preparedRevision = -1L
            var requestedFraction = 0.0
            var lastPlayback: RecoveryPlaybackPosition? = null
            try {
                while (isActive && currentStream?.url == stream.url) {
                    val revision = recoveryRevision
                    val duration = player.duration.takeIf { it > 0 }
                        ?: lastKnownDurationMs.takeIf { it > 0 }
                        ?: currentEpisodeMeta?.runtimeMinutes?.toLong()?.times(60_000)
                        ?: details?.item?.runtimeMinutes?.toLong()?.times(60_000) ?: 0L
                    val position = pendingSeek?.positionMs ?: player.currentPosition
                    val fraction = if (duration > 0) position.toDouble() / duration else 0.0
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (prepareJob?.isActive != true && (recoveryPrepareRequested || now - lastPrepareAt >= 30_000)) {
                        recoveryPrepareRequested = false
                        lastPrepareAt = now
                        preparedRevision = revision
                        requestedFraction = fraction.coerceIn(0.0, 0.999)
                        prepareJob = launch { container.streamRecoveryApi.prepare(stream, fraction) }
                    }
                    if (BuildConfig.EXACT_RECOVERY && recoverySessionId != null) {
                        val sample = RecoveryPlaybackPosition(
                            positionMs = position.coerceAtLeast(0),
                            // Only measured player duration belongs in the server's timing map.
                            durationMs = player.duration.takeIf { it > 0 && it != C.TIME_UNSET } ?: 0L,
                            bufferedPositionMs = player.bufferedPosition.coerceAtLeast(0),
                            playing = player.playWhenReady && !hostStopped,
                            sessionId = recoverySessionId,
                            generation = revision,
                        )
                        lastPlayback = sample
                        container.streamRecoveryApi.playback(stream, sample)
                    }
                    val health = container.streamRecoveryApi.health(stream, recoverySessionId?.takeIf { BuildConfig.EXACT_RECOVERY })
                    if (currentStream?.url != stream.url) break
                    // A seek while the request was in flight invalidates the old warm point.
                    if (revision != recoveryRevision) continue
                    val exactRecovery = health?.exactRecovery?.takeIf { BuildConfig.EXACT_RECOVERY }
                    _state.update { it.copy(recoveryDiagnostics = exactRecovery, repairDiagnostics = health?.repair?.takeIf { BuildConfig.EXACT_RECOVERY }) }
                    preparedFallback = health?.takeIf { preparedRevision == revision }?.let {
                        StreamRecoveryApi.preparedCandidate(stream, it, candidates, requestedFraction)
                            ?.takeIf { candidate -> candidate.url !in blacklistedUrls && !isBlocked(candidate) }
                    }
                    val next = preparedFallback
                    if (health?.status == "incomplete" && exactRecovery?.shouldHoldProactiveFallback() != true &&
                        next != null && !swapping && !queueAdvancing && !queueDetached && !queueClosed &&
                        !hostStopped && player.playWhenReady && player.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE &&
                        _state.value.phase == PlayerPhase.PLAYING && recoveryBudget.tryAutomaticSwitch()) {
                        blacklistedUrls.add(stream.url)
                        // Best-effort timeline seek: different release cuts may not match exactly.
                        failoverTo(next)
                        return@launch
                    }
                    delay(if (player.playbackState == Player.STATE_BUFFERING) 1_000 else 3_000)
                }
            } finally {
                // Captured values avoid touching a released player. A lower generation stop
                // cannot cancel a later seek/resume heartbeat for the same session.
                lastPlayback?.let { last ->
                    withContext(NonCancellable) {
                        container.streamRecoveryApi.playback(stream, last.copy(playing = false, stopped = true))
                    }
                }
            }
        }
    }

    /** Swap to [next] at the last known position, showing the brief non-blocking pill. */
    private fun failoverTo(next: StreamOption, reason: SourceSwitchReason = SourceSwitchReason.AUTOMATIC) {
        val shouldPlay = player.playWhenReady
        val resumeAt = player.currentPosition.takeIf { it > 1_000 } ?: lastKnownPositionMs
        if (resumeAt > 1_000) pendingSeek = PendingSeek(resumeAt, guardNearEnd = false)
        endedHandled = false
        _state.update { it.copy(switchingSource = true, errorMessage = null) }
        play(next, reason)
        player.playWhenReady = shouldPlay
    }

    // =====================================================================================
    // Public controls API
    // =====================================================================================

    fun togglePlayPause() {
        if (player.isPlaying) pause() else resumePlay()
    }

    fun pause() {
        player.pause()
        saveProgressNow()
    }

    fun resumePlay() {
        hostStopped = false
        resetStallDeadline()
        if (recoveryJob?.isActive != true) currentStream?.let(::watchRecovery)
        // Leaving playback cancels expensive repair. If that interrupted a paused
        // network read, prepare the same resource/position when the viewer resumes.
        if (BuildConfig.EXACT_RECOVERY && currentStream != null && player.playerError != null) player.prepare()
        player.play()
    }

    fun seekTo(positionMs: Long) {
        // The phone's position remains authoritative until playback is acknowledged.
        if (!handoffAccepted) return
        val wasEnded = player.playbackState == Player.STATE_ENDED
        val dur = player.duration.takeIf { it > 0 }
        val clamped = positionMs.coerceIn(0L, dur ?: Long.MAX_VALUE)
        recoveryBudget.interrupt()
        if (BuildConfig.EXACT_RECOVERY) telemetry.seek(clamped)
        player.seekTo(clamped)
        if (BuildConfig.EXACT_RECOVERY) telemetry.seekDispatched()
        resetStallDeadline()
        requestRecoveryPreparation()
        // Seeking out of the ended/credits zone resumes playback (playWhenReady is true):
        // let the episode end "again" later, and drop a stale EndChoice card.
        if (wasEnded || (dur != null && clamped < dur * 95 / 100)) {
            endedHandled = false
            if (_state.value.upNext is UpNextUi.EndChoice) {
                _state.update { it.copy(upNext = UpNextUi.Hidden) }
            }
        }
        _state.update { it.copy(positionMs = clamped) }
    }

    fun seekBy(deltaMs: Long) = seekTo(player.currentPosition + deltaMs)

    /**
     * "What did they say?" — jump back 15s with subtitles temporarily on; they turn
     * back off on their own once playback passes the point where the button was
     * pressed. Pressing again mid-replay rewinds further but keeps the original
     * restore point. If subtitles were already on, this is just a 15s replay.
     */
    fun replayWithSubtitles() {
        val pos = player.currentPosition
        if (replayRestoreAtMs < 0) replayTurnSubsOff = !subtitlesEnabled
        replayRestoreAtMs = maxOf(replayRestoreAtMs, pos)
        val groups = textGroups()
        if (!subtitlesEnabled && groups.isNotEmpty()) {
            subtitleGroupIndex = preferredTextGroupIndex(groups)
            applySubtitleSelection(groups)
        }
        _state.update { it.copy(replayActive = true) }
        seekTo((pos - REPLAY_BACK_MS).coerceAtLeast(0L))
    }

    /** Skip Intro pill pressed: land just past the intro's end. */
    fun skipIntro() {
        val intro = introRangeMs ?: return
        introDismissed = true
        _state.update { it.copy(skipIntroVisible = false) }
        seekTo(intro.last)
    }

    fun holdQueueSkip() { queueFailureJob?.cancel() }

    fun retry() {
        // A manually requested retry is ordinary TV playback after the transfer has failed.
        if (handoffAborted || (handoffFinished && !handoffAccepted)) {
            handoffAborted = false
            handoffAccepted = true
        }
        queueFailureJob?.cancel()
        _state.update { it.copy(queueNotice = null) }
        endedHandled = false
        recoveryBudget.resetBurst()
        val s = currentStream
        if (s != null && !isBlocked(s)) {
            if (lastKnownPositionMs > 1_000) {
                pendingSeek = PendingSeek(lastKnownPositionMs, guardNearEnd = false)
            }
            play(s)
        } else if (imdbId != null) {
            viewModelScope.launch { startStreamsAndPlay() }
        } else load()
    }

    /**
     * Switch streams, preserving the current position. This is the ONLY user-initiated
     * pick (the picker sheet's onPick lands here) — so it is also the one place a show's
     * sticky release group gets written. Failover and autopick go through play() directly
     * and never reach this.
     */
    fun switchStream(option: StreamOption) {
        if (!handoffAccepted || isBlocked(option)) return
        queueFailureJob?.cancel()
        _state.update { it.copy(queueNotice = null) }
        if (option.url == currentStream?.url && _state.value.phase == PlayerPhase.PLAYING) return
        recoveryBudget.resetBurst()
        blacklistedUrls.remove(option.url)
        val group = option.bingeGroup
        val id = imdbId
        if (target.type == MediaType.SHOW && !group.isNullOrBlank() && !id.isNullOrBlank()) {
            manualGroup = group // in-memory first: the next episode swap must already see it
            prefetchedStreams = null
            persistScope.launch { runCatching { settingsRepo.setManualBingeGroup(id, group) } }
        }
        val pos = player.currentPosition.takeIf { it > 0 } ?: lastKnownPositionMs
        if (pos > 1_000) pendingSeek = PendingSeek(pos, guardNearEnd = false)
        endedHandled = false
        play(option, SourceSwitchReason.MANUAL)
    }

    private fun isBlocked(stream: StreamOption) = target.type == MediaType.SHOW && stream.isReleaseGroupBlocked(blockedGroups)

    private fun canBlockCurrentRelease(): Boolean = target.type == MediaType.SHOW && handoffAccepted &&
        currentStream?.let { it.releaseGroupForBlocking() != null && !isBlocked(it) } == true

    fun blockCurrentRelease() { currentStream?.let(::blockReleaseGroup) }

    private fun applyBlockedGroups(groups: List<ReleaseGroup>) {
        if (blockedGroups != groups) {
            prefetchedStreams = null
            requestRecoveryPreparation()
        }
        blockedGroups = groups
        candidates = candidates.filterNot(::isBlocked)
        _state.update {
            val visibleStreams = (allResolvedStreams.takeIf { all -> all.isNotEmpty() } ?: it.streams).filterNot(::isBlocked)
            it.copy(blockedGroups = groups, canBlockCurrentRelease = canBlockCurrentRelease(),
                streams = visibleStreams,
                canChooseStream = it.canChooseStream && (visibleStreams.isNotEmpty() || groups.isNotEmpty()))
        }
    }

    fun blockReleaseGroup(option: StreamOption) {
        val id = imdbId ?: return
        if (target.type != MediaType.SHOW || !handoffAccepted) return
        val group = option.releaseGroupForBlocking() ?: return
        viewModelScope.launch {
            try {
                settingsRepo.blockReleaseGroup(id, group)
                applyBlockedGroups(blockedReleaseGroupsForShow(settingsRepo.blockedReleaseGroups.first(), id))
                if (manualGroup == group.key) manualGroup = null
                if (lastBingeGroup == group.key) lastBingeGroup = null
                _state.update { it.copy(groupActionError = null) }
                if (currentStream?.let(::isBlocked) == true) {
                    val next = candidates.firstOrNull { it.url !in blacklistedUrls && !isBlocked(it) }
                    if (next != null) failoverTo(next, SourceSwitchReason.MANUAL)
                    else { saveProgressNow(); player.stop(); showError("This release is blocked for this show. Choose another stream or reset blocked releases in Playback options.", true) }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { _state.update { it.copy(groupActionError = "Couldn't block this release. Try again.") } }
        }
    }

    fun unblockReleaseGroup(key: String) {
        val id = imdbId ?: return
        if (target.type != MediaType.SHOW || !handoffAccepted) return
        viewModelScope.launch {
            try {
                settingsRepo.unblockReleaseGroup(id, key)
                applyBlockedGroups(blockedReleaseGroupsForShow(settingsRepo.blockedReleaseGroups.first(), id))
                val identity = curSeason to curEpisode
                val prepared = prepareStreams(allResolvedStreams, identity.first, identity.second)
                if (identity != curSeason to curEpisode) return@launch
                candidates = prepared.candidates.filterNot(::isBlocked)
                _state.update { it.copy(streams = prepared.all.filterNot(::isBlocked), groupActionError = null) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { _state.update { it.copy(groupActionError = "Couldn't reset blocked releases. Try again.") } }
        }
    }

    private fun resetStallDeadline() = failoverWatchdog.reset(android.os.SystemClock.elapsedRealtime(),
        player.currentPosition.coerceAtLeast(0), player.bufferedPosition.coerceAtLeast(0), player.duration.coerceAtLeast(0),
        establishedPlayback = recoveryBudget.sourceEstablished)

    private suspend fun resolvePreviousEpisode(): Episode? {
        val s = curSeason ?: return null
        val e = curEpisode ?: return null
        return try { findPreviousEpisode(s, e, details?.seasons?.map { it.number }.orEmpty(), ::episodesFor) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { null }
    }

    fun playPreviousEpisode() {
        if (!handoffAccepted || swapping || queueAdvancing || queueDetached || queueClosed) return
        if (isQueue) {
            if (queueSession?.previousTarget() != null) advanceQueue(backward = true)
            return
        }
        viewModelScope.launch {
            val identity = curSeason to curEpisode
            val previous = resolvePreviousEpisode() ?: return@launch
            if (identity == curSeason to curEpisode) swapToEpisode(previous, markCurrentWatched = false)
        }
    }

    /** Apply a subtitle pick from the picker sheet. [index] into textGroups; -1 = off. */
    fun selectSubtitleTrack(index: Int) {
        // An explicit pick outlives any pending "What did they say?" auto-restore.
        cancelReplay()
        val groups = textGroups()
        subtitleGroupIndex = if (index in groups.indices) index else -1
        applySubtitleSelection(groups)
    }

    /**
     * Apply an audio pick from the picker sheet: override the chosen group immediately,
     * and prefer its language for the rest of the session (so the choice survives
     * episode swaps, where the override's TrackGroup no longer matches).
     */
    fun selectAudioTrack(index: Int) {
        val groups = audioGroups()
        val group = groups.getOrNull(index) ?: return
        val builder = player.trackSelectionParameters.buildUpon()
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, 0))
        group.mediaTrackGroup.getFormat(0).language?.takeIf { it.isNotBlank() }?.let { lang ->
            builder.setPreferredAudioLanguages(lang, "en", "eng")
        }
        player.trackSelectionParameters = builder.build()
        // Optimistic check-mark; onTracksChanged reconciles when the selection lands.
        _state.update { st ->
            st.copy(audioOptions = st.audioOptions.map { it.copy(selected = it.index == index) })
        }
    }

    /** Play the next episode now (controls button, Up Next "Play now", countdown end). */
    fun playNextEpisode() {
        if (!handoffAccepted) return
        if (isQueue) { advanceQueue(); return }
        viewModelScope.launch {
            val next = pendingNextEpisode ?: awaitNextEpisode() ?: return@launch
            swapToEpisode(next)
        }
    }

    /** "Watch credits": cancel the countdown; the choice card returns at ENDED. */
    fun watchCredits() {
        upNextJob?.cancel()
        upNextCancelled = true
        upNextArming = false
        _state.update { it.copy(upNext = UpNextUi.Hidden) }
    }

    /** Back press while the countdown overlay shows == watch credits. */
    fun dismissUpNext() = watchCredits()

    /** Returning re-enables recovery, while leaving playback paused until requested. */
    fun onHostResume() {
        hostStopped = false
        resetStallDeadline()
    }

    /** Pause + persist when the host activity stops (HDMI off, home button, ...). */
    fun onHostStop() {
        hostStopped = true
        telemetry.observe(true)
        resetStallDeadline()
        if (!handoffFinished) abortHandoff("The TV left Velvet before playback started.")
        recoveryJob?.cancel()
        if (isQueue) {
            upNextJob?.cancel()
            upNextArming = false
            queueFailureJob?.cancel()
            _state.update { it.copy(upNext = UpNextUi.Hidden) }
        }
        player.pause()
        saveProgressNow()
    }

    /**
     * Snapshot position AND episode identity on the main thread, persist off it —
     * a concurrent swapToEpisode must never re-attribute the old episode's position
     * to the new episode. Safe to call anytime.
     */
    fun saveProgressNow() {
        if (isQueue) return
        val pos = player.currentPosition.takeIf { it > 0 } ?: lastKnownPositionMs
        val dur = player.duration.takeIf { it > 0 } ?: lastKnownDurationMs
        val season = curSeason
        val episode = curEpisode
        val meta = currentEpisodeMeta
        persistScope.launch { persistProgress(pos, dur, season, episode, meta) }
    }

    // =====================================================================================
    // Ticker: position state, periodic saves, up-next trigger
    // =====================================================================================

    private fun startTelemetry() {
        val identity = "${target.type}:${target.mediaId}:$curSeason:$curEpisode"
        if (identity == telemetryIdentity) return
        telemetryIdentity = identity
        telemetry.start(if (target.type == MediaType.SHOW) "tv" else "movie", target.mediaId.toString(),
            details?.item?.title ?: _state.value.showTitle, curSeason, curEpisode, activeProfileId,
            trackRecovery = BuildConfig.EXACT_RECOVERY) {
            val status = when {
                hostStopped -> "paused"
                player.playerError != null || _state.value.phase == PlayerPhase.ERROR -> "error"
                player.playbackState == Player.STATE_ENDED -> "ended"
                player.isPlaying -> "playing"
                player.playbackState == Player.STATE_BUFFERING || _state.value.phase == PlayerPhase.LOADING || currentStream == null -> "buffering"
                else -> "paused"
            }
            tv.velvet.data.telemetry.PlaybackTelemetry.Sample(status, player.currentPosition,
                sourceId = player.currentMediaItem?.localConfiguration?.uri?.toString(),
                rebufferEligible = player.playWhenReady && !hostStopped && !swapping && !queueAdvancing &&
                    !queueDetached && !queueClosed && player.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE)
        }
    }

    private fun startTicker() {
        viewModelScope.launch {
            var saveTick = 0
            while (isActive) {
                delay(500)
                if (_state.value.phase != PlayerPhase.PLAYING) continue
                val pos = player.currentPosition.coerceAtLeast(0L)
                val dur = player.duration.takeIf { it > 0 && it != C.TIME_UNSET } ?: 0L
                val buf = player.bufferedPosition.coerceAtLeast(0L)
                if (recoveryBudget.observe(android.os.SystemClock.elapsedRealtime(), pos,
                        player.isPlaying && !hostStopped && !swapping && !queueAdvancing)) {
                    Log.i(TAG, "Sustained playback renewed the automatic recovery budget")
                }
                if (pos > 0) lastKnownPositionMs = pos
                if (dur > 0) lastKnownDurationMs = dur
                _state.update { it.copy(positionMs = pos, durationMs = dur, bufferedMs = buf) }
                if (failoverWatchdog.shouldFailover(
                        nowMs = android.os.SystemClock.elapsedRealtime(), positionMs = pos,
                        bufferedPositionMs = buf, durationMs = dur,
                        buffering = player.playbackState == Player.STATE_BUFFERING,
                        inPlaceRetryUntilMs = recoveryBudget.retryUntilMs,
                        isPlaying = player.isPlaying, playWhenReady = player.playWhenReady,
                        suppressed = player.playbackSuppressionReason != Player.PLAYBACK_SUPPRESSION_REASON_NONE,
                        eligible = handoffAccepted && !hostStopped && !swapping && !queueAdvancing && !queueDetached && !queueClosed,
                    )) {
                    handlePlayerError(PlaybackException("Source made no playback progress", null, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT))
                    continue
                }
                if (handoffAccepted) maybeTriggerUpNext(pos, dur)
                if (replayRestoreAtMs >= 0 && pos >= replayRestoreAtMs) finishReplay()
                updateSkipIntroVisibility(pos)
                if (isQueue && player.isPlaying && !queueReportedPlaying) {
                    queuePlayingTicks++
                    if (queuePlayingTicks >= 10) {
                        queueReportedPlaying = true
                        viewModelScope.launch { queueStore.markPlaying(target) }
                    }
                }
                saveTick++
                if (saveTick >= PROGRESS_SAVE_EVERY_TICKS) {
                    saveTick = 0
                    if (!isQueue && player.isPlaying) {
                        persistProgress(pos, dur, curSeason, curEpisode, currentEpisodeMeta)
                    }
                }
            }
        }
    }

    // =====================================================================================
    // Progress persistence
    // =====================================================================================

    /**
     * Writes the resume row. At >=95%: mark episode watched (shows) and advance the row to
     * the next episode, or remove the row entirely (movies / definitively-last episode).
     * Identity (season/episode/meta) is passed in, snapshotted at the same moment as the
     * position — persistProgress may run on the IO persistScope racing an episode swap.
     */
    private suspend fun persistProgress(
        positionMs: Long, durationMs: Long, season: Int?, episode: Int?, episodeMeta: Episode?,
    ) = progressMutex.withLock {
        // Category channels never alter normal viewing history, including old resume rows.
        if (!isQueue && handoffAccepted) persistProgressLocked(positionMs, durationMs, season, episode, episodeMeta)
    }

    private suspend fun persistProgressLocked(
        positionMs: Long,
        durationMs: Long,
        season: Int?,
        episode: Int?,
        episodeMeta: Episode?,
    ) {
        if (isQueue || details == null) return
        if (positionMs < 5_000) return
        runCatching {
            if (durationMs > 0 && positionMs >= durationMs * 95 / 100) {
                if (target.type == MediaType.SHOW) {
                    markWatched(season, episode)
                    val next = awaitNextEpisode()
                    when {
                        next != null -> upsertProgressRow(
                            progressRow(next.season, next.number, next.title,
                                positionMs = 0L, durationMs = runtimeMs(next), still = next.stillUrl)
                        )
                        nextResolved ->
                            // Definitively the last episode — the show is finished.
                            removeProgressRow()
                        else ->
                            // Resolution FAILED (network blip) — keep the row pointed at
                            // the current episode instead of deleting Continue Watching.
                            upsertProgressRow(
                                progressRow(season, episode, episodeMeta?.title,
                                    positionMs = positionMs, durationMs = durationMs,
                                    still = episodeMeta?.stillUrl)
                            )
                    }
                } else {
                    removeProgressRow()
                }
            } else {
                upsertProgressRow(
                    progressRow(season, episode, episodeMeta?.title,
                        positionMs = positionMs, durationMs = durationMs,
                        still = episodeMeta?.stillUrl)
                )
            }
        }
    }

    /** Local write first, then enqueue for sync — sync can never break the local write. */
    private suspend fun upsertProgressRow(row: WatchProgressEntity) {
        if (isQueue || !handoffAccepted) return
        progressDao.upsert(row)
        syncEngine.recordProgressUpsert(row)
    }

    private suspend fun removeProgressRow() {
        if (isQueue || !handoffAccepted) return
        progressDao.remove(activeProfileId, target.mediaId, target.type.key)
        syncEngine.recordProgressDelete(activeProfileId, target.mediaId, target.type.key)
    }

    private fun progressRow(
        season: Int?,
        episode: Int?,
        episodeTitle: String?,
        positionMs: Long,
        durationMs: Long,
        still: String?,
    ): WatchProgressEntity {
        val item = details?.item
        return WatchProgressEntity(
            profileId = activeProfileId,
            mediaId = target.mediaId,
            type = target.type.key,
            imdbId = imdbId,
            title = item?.title ?: _state.value.showTitle,
            posterUrl = item?.posterUrl,
            backdropUrl = still ?: item?.backdropUrl,
            season = season,
            episode = episode,
            episodeTitle = episodeTitle,
            positionMs = positionMs,
            durationMs = durationMs,
            updatedAt = System.currentTimeMillis(),
            year = item?.year,
            rating = item?.rating,
        )
    }

    /** Explicit (season, episode) — callers snapshot the identity at the call site. */
    private suspend fun markWatched(season: Int?, episode: Int?) {
        if (isQueue || !handoffAccepted || markedWatched) return
        val s = season ?: return
        val e = episode ?: return
        if (target.type != MediaType.SHOW) return
        markedWatched = true
        runCatching {
            val entity = WatchedEpisodeEntity(activeProfileId, target.mediaId, s, e, System.currentTimeMillis())
            progressDao.markWatched(entity)
            syncEngine.recordWatched(entity.profileId, entity.mediaId, entity.season, entity.episode, entity.watchedAt)
        }
    }

    private fun runtimeMs(ep: Episode): Long = (ep.runtimeMinutes ?: 0).toLong() * 60_000L

    // =====================================================================================
    // "What did they say?" internals
    // =====================================================================================

    /** First English text track, else the first — the replay's auto-pick. */
    private fun preferredTextGroupIndex(groups: List<Tracks.Group>): Int {
        val en = groups.indexOfFirst {
            it.mediaTrackGroup.getFormat(0).language
                ?.lowercase(Locale.US)?.startsWith("en") == true
        }
        return if (en >= 0) en else 0
    }

    /** Playback passed the replay's return point — restore the previous subtitle state. */
    private fun finishReplay() {
        if (replayTurnSubsOff) {
            subtitleGroupIndex = -1
            applySubtitleSelection(textGroups())
        }
        cancelReplay()
    }

    /** Drop replay bookkeeping without touching the player (manual pick already applied). */
    private fun cancelReplay() {
        replayRestoreAtMs = -1L
        replayTurnSubsOff = false
        if (_state.value.replayActive) _state.update { it.copy(replayActive = false) }
    }

    /**
     * Episode swap mid-replay: the temporary subtitles must not leak into the next
     * episode. No player call needed — the new media item starts fresh, and
     * handleTracksChanged re-applies from [subtitlesEnabled].
     */
    private fun resetReplayForSwap() {
        if (replayTurnSubsOff) {
            subtitlesEnabled = false
            subtitleGroupIndex = -1
            _state.update { it.copy(subtitleLabel = null) }
        }
        cancelReplay()
    }

    // =====================================================================================
    // Skip intro (velvet-sync /report_play + /segments, velvet-intro worker)
    // =====================================================================================

    /**
     * Report the URL this episode plays from (the worker fingerprints exactly what we
     * watch) and start polling for its intro marker. Failover/stream-switch re-report
     * the replacement URL — the worker keys per episode and takes the latest.
     */
    private fun reportPlayAndWatchForIntro(stream: StreamOption) {
        val id = imdbId ?: return
        val season = curSeason ?: return
        val episode = curEpisode ?: return
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { companion.reportPlay(id, season, episode, stream.url) }
        }
        startSegmentsPolling(id, season, episode)
    }

    /**
     * Fetch the intro marker: once at start, then slow retries while the worker may
     * still be crunching the first episodes of a season. Gives up quietly — no marker
     * just means no pill.
     */
    private fun startSegmentsPolling(imdb: String, season: Int, episode: Int) {
        segmentsJob?.cancel()
        introRangeMs = null
        introDismissed = false
        _state.update { it.copy(skipIntroVisible = false) }
        segmentsJob = viewModelScope.launch(Dispatchers.IO) {
            repeat(6) { attempt ->
                val range = runCatching { companion.introSegments(imdb, season)[episode] }
                    .getOrNull()
                if (range != null) {
                    introRangeMs = range
                    return@launch
                }
                delay(if (attempt == 0) 20_000L else 45_000L)
            }
        }
    }

    private fun updateSkipIntroVisibility(pos: Long) {
        val intro = introRangeMs
        val show = intro != null && !introDismissed &&
            pos >= intro.first + 1_500 && pos < intro.last - 4_000
        if (show != _state.value.skipIntroVisible) {
            _state.update { it.copy(skipIntroVisible = show) }
        }
    }

    /**
     * At episode start, also resolve the NEXT episode's streams and report the
     * would-be autopick URL, so the worker has its fingerprint ready BEFORE that
     * episode plays — the Skip Intro pill then works from its first second.
     */
    private suspend fun reportNextEpisodeUrl(next: Episode) {
        val id = imdbId ?: return
        if (!companion.isEnabled()) return
        runCatching {
            val streams = streamRepo.streamsFor(id, MediaType.SHOW, next.season, next.number)
            if (streams.isEmpty()) return
            val sorted = streamRepo.sortStreams(streams.filterNot(::isBlocked), settings.preferredQuality)
            // Mirror prepareStreams' group precedence (manual pick, then session binge)
            // so the URL the worker fingerprints is the one that will actually play.
            val pick = manualGroup?.let { g -> sorted.firstOrNull { it.bingeGroup == g } }
                ?: lastBingeGroup?.let { g -> sorted.firstOrNull { it.bingeGroup == g } }
                ?: sorted.firstOrNull() ?: return
            companion.reportPlay(id, next.season, next.number, pick.url)
        }
    }

    private fun queueNextItem(): CategoryItem? = queueSession?.let { session ->
        session.nextTarget()?.queueIndex?.let { session.items.getOrNull(it) }
    }

    private fun CategoryItem.queueUi() = NextEpisodeUi(season ?: 0, episode ?: 0,
        episodeTitle ?: title, stillUrl ?: backdropUrl ?: posterUrl, title, type == "movie")

    private fun prefetchQueueNext() {
        val session = queueSession ?: return
        val next = queueNextItem() ?: return
        val nextTarget = session.nextTarget() ?: return
        queuePrefetchJob?.cancel()
        queuePrefetchJob = viewModelScope.launch {
            try {
                val type = nextTarget.type
                val details = tmdb.details(next.mediaId, type)
                if (type == MediaType.SHOW) tmdb.episodes(next.mediaId, next.season!!)
                val key = next.imdbId ?: details.item.imdbId ?: "tmdb:${next.mediaId}"
                val streams = streamRepo.streamsFor(key, type, next.season, next.episode)
                queueStore.saveStreams(nextTarget, streams)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* Actual playback will retry under its own identity. */ }
        }
    }

    private fun maybeTriggerQueueUpNext(pos: Long, dur: Long) {
        if (queueAdvancing || queueDetached || _state.value.phase != PlayerPhase.PLAYING) return
        val next = queueNextItem() ?: return
        val seconds = categoryQueueCountdownSeconds(pos, dur)
        if (seconds == null || upNextCancelled) {
            if (_state.value.upNext !is UpNextUi.Hidden) _state.update { it.copy(upNext = UpNextUi.Hidden) }
            return
        }
        // Informational only: pausing freezes media time; STATE_ENDED advances the queue.
        _state.update { it.copy(upNext = UpNextUi.Countdown(next.queueUi(), seconds, 40)) }
    }

    /** Entry is gated before suspension, so ENDED, countdown, and Next cannot skip twice. */
    private fun advanceQueue(failed: Boolean = false, backward: Boolean = false) {
        if (queueAdvancing || queueDetached || queueClosed || queueSession == null) return
        queueAdvancing = true
        queueFailureJob?.cancel()
        upNextJob?.cancel()
        recoveryJob?.cancel()
        queuePrefetchJob?.cancel()
        player.pause()
        queueDetached = true
        queueAdvanceJob = viewModelScope.launch {
            try {
                ensureActive()
                if (queueClosed) return@launch
                val advance = if (backward) queueStore.previous(target) else queueStore.advance(target, failed)
                ensureActive()
                if (queueClosed) return@launch
                if (advance == null) {
                    queueSession = null
                    _state.update { it.copy(hasNext = false, hasPrevious = false, queueNotice = null) }
                    queueDetached = false
                    queueAdvancing = false
                    showError("This category has ended or the profile changed. Start it again from Home.", false)
                } else if (advance.stoppedForFailures) {
                    queueSession = advance.session
                    queueDetached = false
                    queueAdvancing = false
                    _state.update { it.copy(phase = PlayerPhase.ERROR, upNext = UpNextUi.Hidden,
                        queueNotice = null, isBuffering = false,
                        errorMessage = if (it.hasNext) "Three items in a row were unavailable. Retry this item or use Next to continue."
                            else "Three items in a row were unavailable. Retry this item or go back.") }
                } else if (advance.next != null) {
                    queueChannel.send(advance.next)
                } else {
                    _exitEvents.tryEmit(Unit)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                queueDetached = false
                queueAdvancing = false
                _state.update { it.copy(phase = PlayerPhase.ERROR, isBuffering = false,
                    errorMessage = "Couldn't advance this category. Try again.") }
            }
        }
    }

    fun leaveQueue() {
        if (!isQueue || queueClosed) return
        queueClosed = true
        queueDetached = true
        queueAdvanceJob?.cancel()
        queueFailureJob?.cancel()
        queuePrefetchJob?.cancel()
        recoveryJob?.cancel()
        upNextJob?.cancel()
        loadJob?.cancel()
        player.pause()
        persistScope.launch {
            queueStore.cancel(target)
        }
    }

    // =====================================================================================
    // Next-episode resolution + Up Next
    // =====================================================================================

    private suspend fun episodesFor(season: Int): List<Episode> =
        episodesCache[season] ?: tmdb.episodes(target.mediaId, season).also {
            episodesCache[season] = it
        }

    /**
     * Next episode, or null when the show is definitively over. THROWS when a season
     * fetch fails — "fetch failed" must never read as "season empty", or a TMDB blip
     * at a season boundary would silently skip a whole season (or end the show).
     */
    private suspend fun findNextEpisode(): Episode? {
        if (target.type != MediaType.SHOW) return null
        val s = curSeason ?: return null
        val e = curEpisode ?: return null
        val inSeason = episodesFor(s).filter { it.number > e }.minByOrNull { it.number }
        if (inSeason != null) return inSeason
        val d = details ?: return null
        val laterSeasons = d.seasons.map { it.number }.filter { it > s }.sorted()
        for (ns in laterSeasons) {
            // A failed fetch propagates: never advance PAST a season we couldn't read.
            val first = episodesFor(ns).minByOrNull { it.number }
            if (first != null) return first
        }
        return null
    }

    /**
     * Cached next-episode resolution. Returns null both when there is no next episode
     * AND when resolution failed — distinguish via [nextResolved]: failures leave it
     * false so a later call retries instead of poisoning the session.
     */
    private suspend fun awaitNextEpisode(): Episode? {
        if (nextResolved) return nextEpisode
        val identity = curSeason to curEpisode
        val resolved = try {
            findNextEpisode()
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Throwable) {
            return null // unknown — leave nextResolved=false
        }
        if (identity != curSeason to curEpisode) return null
        nextEpisode = resolved
        nextResolved = true
        _state.update { it.copy(hasNext = resolved != null) }
        return resolved
    }

    private fun resolveNextEagerly() {
        if (!handoffAccepted) return
        if (isQueue) { prefetchQueueNext(); return }
        viewModelScope.launch {
            val identity = curSeason to curEpisode
            val previous = resolvePreviousEpisode()
            if (identity == curSeason to curEpisode) _state.update { it.copy(hasPrevious = previous != null) }
        }
        viewModelScope.launch {
            val next = awaitNextEpisode()
            // Skip-intro prefetch: hand the worker next episode's URL now, not at play time.
            if (next != null) reportNextEpisodeUrl(next)
        }
    }

    private fun maybeTriggerUpNext(pos: Long, dur: Long) {
        if (isQueue) { maybeTriggerQueueUpNext(pos, dur); return }
        // Mid-swap, pos/dur can still belong to the OLD item while identity and the
        // up-next flags already belong to the NEW one — arming in that window starts a
        // countdown ~at episode start and SKIPS the episode. Never arm while swapping.
        if (swapping) return
        val s = _state.value
        if (!s.isShow || dur <= 0 || s.phase != PlayerPhase.PLAYING) return
        val remaining = dur - pos
        if (s.upNext !is UpNextUi.Hidden && remaining > UP_NEXT_RELEASE_MS) {
            // User scrubbed back out of the credits window — hide (Countdown AND a
            // stale EndChoice left over from a post-ENDED rewind) and re-arm.
            upNextJob?.cancel()
            upNextArming = false
            _state.update { it.copy(upNext = UpNextUi.Hidden) }
            return
        }
        if (remaining <= UP_NEXT_TRIGGER_MS &&
            s.upNext is UpNextUi.Hidden &&
            !upNextCancelled &&
            !upNextArming &&
            settings.autoplayNext
        ) {
            armUpNext()
        }
    }

    private fun armUpNext() {
        upNextArming = true
        val identity = curSeason to curEpisode
        viewModelScope.launch {
            // Any exit that doesn't reach startCountdown must clear the arming flag,
            // or maybeTriggerUpNext blocks the overlay for the rest of the episode.
            var countdownStarted = false
            try {
                val next = awaitNextEpisode()
                if (next == null || !isActive || identity != curSeason to curEpisode) return@launch
                pendingNextEpisode = next
                prefetchNextStreams(next)
                // Conditions may have changed while prefetching (cancelled, errored,
                // a swap started, or ENDED already swapped us onto this very episode).
                if (identity != curSeason to curEpisode || swapping || upNextCancelled ||
                    _state.value.phase != PlayerPhase.PLAYING) return@launch
                if (curSeason == next.season && curEpisode == next.number) return@launch
                startCountdown(next)
                countdownStarted = true
            } finally {
                if (!countdownStarted) upNextArming = false
            }
        }
    }

    /**
     * Resolve and rank the next episode ahead of the swap without blocking on byte probes.
     */
    private suspend fun prefetchNextStreams(ep: Episode) {
        val id = imdbId ?: return
        val cached = prefetchedStreams
        if (cached != null && cached.first == ep.season && cached.second == ep.number) return
        prefetchedStreams = runCatching {
            val streams = streamRepo.streamsFor(id, MediaType.SHOW, ep.season, ep.number)
            Triple(ep.season, ep.number, prepareStreams(streams, ep.season, ep.number))
        }.getOrNull()
    }

    private fun startCountdown(next: Episode) {
        upNextJob?.cancel()
        val total = settings.autoplayCountdownSecs.coerceAtLeast(1)
        upNextJob = viewModelScope.launch {
            for (secs in total downTo 1) {
                _state.update { it.copy(upNext = UpNextUi.Countdown(next.toUi(), secs, total)) }
                delay(1_000)
            }
            // A last-instant "Watch credits" can land after the final delay resumes:
            // ensureActive() honors a post-resume cancel, and the upNextCancelled gate
            // covers playNextEpisode escaping into viewModelScope.
            ensureActive()
            if (!upNextCancelled) playNextEpisode()
        }
    }

    private fun handleEnded() {
        if (isQueue) {
            if (queueAdvancing || endedHandled || queueDetached) return
            endedHandled = true
            // Watch credits hides the card; the explicit category still continues at true end.
            advanceQueue()
            return
        }
        // A late ENDED from the OLD item while swapToEpisode is in flight (identity
        // already advanced, media item not yet set) must be ignored — handling it would
        // mark the not-yet-played episode watched and advance progress to ep+2.
        if (swapping) return
        if (endedHandled) return
        endedHandled = true
        // Snapshot identity before any suspension point.
        val endedSeason = curSeason
        val endedEpisode = curEpisode
        viewModelScope.launch {
            if (target.type == MediaType.MOVIE) {
                runCatching { removeProgressRow() }
                _exitEvents.tryEmit(Unit)
                return@launch
            }
            markWatched(endedSeason, endedEpisode)
            if (endedSeason != curSeason || endedEpisode != curEpisode) return@launch
            val next = awaitNextEpisode()
            if (endedSeason != curSeason || endedEpisode != curEpisode) return@launch
            when {
                next == null -> {
                    // Only clear Continue Watching when "no next" is definitive; on a
                    // resolution failure keep the row and just return to Details.
                    if (nextResolved) {
                        runCatching { removeProgressRow() }
                    }
                    _exitEvents.tryEmit(Unit)
                }
                settings.autoplayNext && !upNextCancelled -> {
                    upNextJob?.cancel()
                    swapToEpisode(next)
                }
                else -> {
                    pendingNextEpisode = next
                    runCatching {
                        upsertProgressRow(
                            progressRow(next.season, next.number, next.title,
                                positionMs = 0L, durationMs = runtimeMs(next), still = next.stillUrl)
                        )
                    }
                    _state.update { it.copy(upNext = UpNextUi.EndChoice(next.toUi())) }
                }
            }
        }
    }

    /** The flagship: swap to the next episode inside the SAME screen. */
    private suspend fun swapToEpisode(ep: Episode, markCurrentWatched: Boolean = true) {
        if (swapping || !handoffAccepted) return
        if (curSeason == ep.season && curEpisode == ep.number &&
            _state.value.phase == PlayerPhase.PLAYING && !endedHandled
        ) return
        recoveryJob?.cancel()
        preparedFallback = null
        swapping = true
        try {
            upNextJob?.cancel()
            if (markCurrentWatched) markWatched(curSeason, curEpisode)
            else persistProgress(player.currentPosition, player.duration.coerceAtLeast(0), curSeason, curEpisode, currentEpisodeMeta)
            player.stop() // Old media must not continue while a backward/forward target resolves.
            resetReplayForSwap()

            curSeason = ep.season
            curEpisode = ep.number
            currentEpisodeMeta = ep
            currentStream = null
            startTelemetry()
            markedWatched = false
            // endedHandled is reset inside play() — only once the old media item is
            // replaced and can no longer emit a late STATE_ENDED.
            upNextCancelled = false
            upNextArming = false
            nextEpisode = null
            nextResolved = false
            pendingNextEpisode = null
            pendingSeek = null
            lastKnownPositionMs = 0L
            lastKnownDurationMs = 0L
            // A new episode also starts a fresh failure burst. Known bad source
            // URLs stay blacklisted; successful playback never revives them.
            recoveryBudget.resetBurst()

            _state.update {
                it.copy(
                    upNext = UpNextUi.Hidden,
                    episodeLabel = formatEpisodeLabel(ep.season, ep.number, ep.title),
                    hasNext = false,
                    hasPrevious = false,
                    positionMs = 0L,
                    durationMs = 0L,
                    bufferedMs = 0L,
                )
            }

            // Continue Watching should point at the new episode immediately.
            runCatching {
                upsertProgressRow(
                    progressRow(ep.season, ep.number, ep.title,
                        positionMs = 0L, durationMs = runtimeMs(ep), still = ep.stillUrl)
                )
            }

            val pre = prefetchedStreams
                ?.takeIf { it.first == ep.season && it.second == ep.number }
                ?.third
            prefetchedStreams = null
            if (pre != null && pre.all.isNotEmpty()) {
                allResolvedStreams = pre.raw
                candidates = pre.candidates.filterNot { it.url in blacklistedUrls || isBlocked(it) }
                _state.update { it.copy(streams = pre.all.filterNot(::isBlocked), episodeVerdicts = pre.verdicts) }
                val pick = candidates.firstOrNull()
                if (pick != null) play(pick)
                else startStreamsAndPlay()
            } else {
                _state.update { it.copy(phase = PlayerPhase.LOADING, errorMessage = null) }
                startStreamsAndPlay()
            }
            resolveNextEagerly()
        } finally {
            swapping = false
        }
    }

    private fun Episode.toUi() = NextEpisodeUi(
        season = season,
        episode = number,
        title = title,
        stillUrl = stillUrl,
    )

    private fun formatEpisodeLabel(season: Int, episode: Int, title: String?): String =
        "S$season E$episode" + (title?.takeIf { it.isNotBlank() }?.let { " — $it" } ?: "")

    // =====================================================================================
    // Tracks (subtitles + audio)
    // =====================================================================================

    private fun textGroups(): List<Tracks.Group> =
        player.currentTracks.groups.filter { it.type == C.TRACK_TYPE_TEXT && it.isSupported }

    private fun audioGroups(): List<Tracks.Group> =
        player.currentTracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO && it.isSupported }

    private fun applySubtitleSelection(groups: List<Tracks.Group>) {
        val builder = player.trackSelectionParameters.buildUpon()
        if (subtitleGroupIndex < 0 || subtitleGroupIndex >= groups.size) {
            subtitlesEnabled = false
            subtitleGroupIndex = -1
            builder.clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            _state.update { it.copy(subtitleLabel = null) }
        } else {
            subtitlesEnabled = true
            val group = groups[subtitleGroupIndex]
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, 0))
            _state.update { it.copy(subtitleLabel = subtitleLabelFor(group)) }
        }
        player.trackSelectionParameters = builder.build()
        rebuildTrackOptions()
    }

    private fun subtitleLabelFor(group: Tracks.Group): String {
        val format = group.mediaTrackGroup.getFormat(0)
        return format.label?.takeIf { it.isNotBlank() }
            ?: languageDisplayName(format.language)
            ?: "Subtitles"
    }

    private fun handleTracksChanged(tracks: Tracks) {
        val groups = tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT && it.isSupported }
        _state.update { it.copy(subtitleAvailable = groups.isNotEmpty()) }
        if (groups.isEmpty()) {
            _state.update { it.copy(subtitleLabel = null) }
        } else if (subtitlesEnabled) {
            val selected = groups.firstOrNull { it.isSelected }
            if (selected != null) {
                // Keep the index synced with reality so the picker checks the right row.
                subtitleGroupIndex = groups.indexOf(selected)
                _state.update { it.copy(subtitleLabel = subtitleLabelFor(selected)) }
            } else {
                // Re-apply across episode swaps so subtitles stay on while binging.
                subtitleGroupIndex = subtitleGroupIndex.coerceIn(0, groups.size - 1)
                applySubtitleSelection(groups)
            }
        }
        rebuildTrackOptions()
    }

    /** Rebuild the picker option lists from the player's current tracks. */
    private fun rebuildTrackOptions() {
        val tGroups = textGroups()
        val subtitleOptions = if (tGroups.isEmpty()) emptyList() else buildList {
            add(
                TrackOptionUi(
                    index = -1,
                    label = "Off",
                    selected = subtitleGroupIndex !in tGroups.indices,
                )
            )
            tGroups.forEachIndexed { i, g ->
                add(TrackOptionUi(i, subtitleOptionLabel(g, i), selected = i == subtitleGroupIndex))
            }
        }
        val audioOptions = audioGroups().mapIndexed { i, g ->
            TrackOptionUi(i, audioOptionLabel(g, i), selected = g.isSelected)
        }
        _state.update { it.copy(subtitleOptions = subtitleOptions, audioOptions = audioOptions) }
    }

    /** "English", "English (SDH)" (format label preferred), "(Forced)" flagged. */
    private fun subtitleOptionLabel(group: Tracks.Group, index: Int): String {
        val format = group.mediaTrackGroup.getFormat(0)
        val base = format.label?.takeIf { it.isNotBlank() }
            ?: languageDisplayName(format.language)
            ?: "Track ${index + 1}"
        val forced = (format.selectionFlags and C.SELECTION_FLAG_FORCED) != 0
        return if (forced && !base.contains("forced", ignoreCase = true)) "$base (Forced)" else base
    }

    /** "English · 7.1 · TrueHD" — each part dropped gracefully when unknown. */
    private fun audioOptionLabel(group: Tracks.Group, index: Int): String {
        val format = group.mediaTrackGroup.getFormat(0)
        val name = languageDisplayName(format.language)
            ?: format.label?.takeIf { it.isNotBlank() }
            ?: "Track ${index + 1}"
        val channels = when (format.channelCount) {
            1 -> "Mono"
            2 -> "Stereo"
            6 -> "5.1"
            8 -> "7.1"
            else -> format.channelCount.takeIf { it > 0 }?.let { "${it}ch" }
        }
        return listOfNotNull(name, channels, audioCodecName(format)).joinToString(" · ")
    }

    /** Pretty codec name from sampleMimeType/codecs; null when unrecognized. */
    private fun audioCodecName(format: Format): String? {
        val raw = listOfNotNull(format.sampleMimeType, format.codecs)
            .joinToString(" ")
            .lowercase(Locale.US)
        if (raw.isBlank()) return null
        return when {
            // Order matters: "eac3" contains "ac3".
            "eac3-joc" in raw || "ec+3" in raw -> "Dolby Digital+ / Atmos"
            "eac3" in raw || "ec-3" in raw -> "Dolby Digital+"
            "true-hd" in raw || "truehd" in raw || "mlp" in raw -> "TrueHD"
            "dts.uhd" in raw || "dtsx" in raw -> "DTS:X"
            "dts.hd" in raw || "dtshd" in raw || "dts-hd" in raw -> "DTS-HD"
            "dts" in raw -> "DTS"
            "ac-3" in raw || "ac3" in raw -> "Dolby Digital"
            "aac" in raw || "mp4a" in raw -> "AAC"
            "flac" in raw -> "FLAC"
            "opus" in raw -> "Opus"
            "mpeg" in raw || "mp3" in raw -> "MP3"
            else -> null
        }
    }

    private fun languageDisplayName(language: String?): String? {
        val lang = language?.takeIf { it.isNotBlank() } ?: return null
        val display = Locale(lang).displayLanguage
        return display.takeIf { it.isNotBlank() }
            ?.replaceFirstChar { it.uppercase(Locale.US) }
    }

    // =====================================================================================

    override fun onCleared() {
        telemetry.end()
        failHandoff("The TV player was closed before playback started.")
        val pos = player.currentPosition.takeIf { it > 0 } ?: lastKnownPositionMs
        val dur = player.duration.takeIf { it > 0 } ?: lastKnownDurationMs
        val season = curSeason
        val episode = curEpisode
        val meta = currentEpisodeMeta
        if (!isQueue) persistScope.launch { persistProgress(pos, dur, season, episode, meta) }
        player.removeListener(playerListener)
        player.release()
    }
}
