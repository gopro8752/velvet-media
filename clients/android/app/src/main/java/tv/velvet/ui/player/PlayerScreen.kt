package tv.velvet.ui.player

import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.focusable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import tv.velvet.VelvetApp
import tv.velvet.data.model.PlayTarget
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.components.velvetOutlinedButtonBorder
import tv.velvet.ui.theme.VelvetColors

/**
 * Velvet player. Resolves identity + streams, plays via ExoPlayer, persists progress,
 * and autoplays the next episode within this same screen. D-pad only.
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(
    target: PlayTarget,
    onExit: () -> Unit,
    onQueueNext: (PlayTarget) -> Unit,
) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: PlayerViewModel = viewModel(
        key = "${target.type.key}:${target.mediaId}:${target.season}:${target.episode}:${target.queueSessionId}:${target.queueIndex}:${target.handoffId}",
        factory = viewModelFactory { initializer { PlayerViewModel(app, target) } }
    )
    val state by vm.state.collectAsStateWithLifecycle()
    val exit = { vm.leaveQueue(); onExit() }
    LaunchedEffect(vm) { vm.queueEvents.collect(onQueueNext) }

    var controlsVisible by remember { mutableStateOf(false) }
    var panel by remember { mutableStateOf<PlayerPanel?>(null) }
    var returnControl by remember { mutableStateOf(PlayerControl.PLAY) }
    var optionFocus by remember { mutableStateOf(PlaybackOption.AUDIO) }
    var interactionStamp by remember { mutableLongStateOf(0L) }
    var rootHasFocus by remember { mutableStateOf(false) }
    val anyPickerOpen = panel != null

    // Error/Up Next controls never remain focusable underneath a sheet. Keep queue
    // failures here while the user changes playback options or resets saved blocks.
    LaunchedEffect(panel, state.phase) {
        if (panel != null) vm.holdQueueSkip()
    }

    fun openPanel(next: PlayerPanel) {
        returnControl = if (next == PlayerPanel.STREAMS) PlayerControl.STREAMS else PlayerControl.OPTIONS
        controlsVisible = false
        panel = next
    }

    fun closePanel() {
        panel = null
        if (state.phase == PlayerPhase.PLAYING) {
            controlsVisible = true
            interactionStamp = System.currentTimeMillis()
        }
    }

    val rootFocus = remember { FocusRequester() }
    val playPauseFocus = remember { FocusRequester() }
    val streamsFocus = remember { FocusRequester() }
    val optionsFocus = remember { FocusRequester() }
    fun controlsFocus() = when (returnControl) {
        PlayerControl.PLAY -> playPauseFocus
        PlayerControl.STREAMS -> streamsFocus
        PlayerControl.OPTIONS -> optionsFocus
    }
    val upNextFocus = remember { FocusRequester() }
    val retryFocus = remember { FocusRequester() }

    val upNextVisible = state.upNext !is UpNextUi.Hidden

    // Auto-exit when the VM decides playback is finished (movie done / no next episode).
    LaunchedEffect(Unit) { vm.exitEvents.collect { exit() } }

    // Pause + save when the activity stops; final save on dispose.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) vm.onHostStop()
            if (event == Lifecycle.Event.ON_RESUME) vm.onHostResume()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            vm.saveProgressNow()
        }
    }

    // Show controls briefly when playback first starts so there is a focus anchor.
    LaunchedEffect(state.phase) {
        if (state.phase == PlayerPhase.PLAYING) controlsVisible = true
    }

    // Hide controls while an Up Next overlay is on screen.
    LaunchedEffect(upNextVisible) {
        if (upNextVisible) controlsVisible = false
    }

    // Auto-hide 4s after the last interaction, only while actually playing.
    // Pickers pause the auto-hide while open.
    LaunchedEffect(controlsVisible, interactionStamp, state.isPlaying, anyPickerOpen) {
        if (controlsVisible && state.isPlaying && !anyPickerOpen) {
            kotlinx.coroutines.delay(4_000)
            controlsVisible = false
        }
    }

    // Route focus to whatever layer is on top.
    LaunchedEffect(state.phase, controlsVisible, upNextVisible, anyPickerOpen) {
        withFrameNanos { }
        when {
            anyPickerOpen -> Unit // each picker requests its own focus
            state.phase == PlayerPhase.ERROR -> runCatching { retryFocus.requestFocus() }
            state.phase != PlayerPhase.PLAYING -> runCatching { rootFocus.requestFocus() }
            upNextVisible -> runCatching { upNextFocus.requestFocus() }
            controlsVisible -> runCatching { controlsFocus().requestFocus() }
            else -> runCatching { rootFocus.requestFocus() }
        }
    }

    fun handleBack() {
        when {
            panel == PlayerPanel.AUDIO || panel == PlayerPanel.SUBTITLES -> panel = PlayerPanel.OPTIONS
            panel != null -> closePanel()
            controlsVisible && state.phase == PlayerPhase.PLAYING -> controlsVisible = false
            state.upNext is UpNextUi.Countdown -> vm.dismissUpNext()
            state.upNext is UpNextUi.EndChoice -> {
                vm.saveProgressNow()
                exit()
            }
            else -> {
                vm.saveProgressNow()
                exit()
            }
        }
    }

    BackHandler { handleBack() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onPreviewKeyEvent { event ->
                // TV focus handling can consume Back by merely clearing a Surface's
                // focus. Own the full remote key so one press changes the visible layer.
                if (event.key == Key.Back) {
                    if (event.type == KeyEventType.KeyUp) handleBack()
                    return@onPreviewKeyEvent true
                }
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                interactionStamp = System.currentTimeMillis()

                // Skip Intro: while the pill is up (controls hidden), OK skips directly.
                if (state.skipIntroVisible && state.phase == PlayerPhase.PLAYING &&
                    !controlsVisible && !upNextVisible && !anyPickerOpen &&
                    (event.key == Key.DirectionCenter || event.key == Key.Enter ||
                        event.key == Key.NumPadEnter)
                ) {
                    vm.skipIntro()
                    return@onPreviewKeyEvent true
                }

                // Dedicated media keys always work, even with controls hidden.
                val mediaHandled = when (event.key) {
                    Key.MediaPlayPause -> { vm.togglePlayPause(); true }
                    Key.MediaPlay -> { vm.resumePlay(); true }
                    Key.MediaPause -> { vm.pause(); true }
                    Key.MediaFastForward -> { vm.seekBy(10_000); true }
                    Key.MediaRewind -> { vm.seekBy(-10_000); true }
                    Key.MediaPrevious -> { if (state.hasPrevious) vm.playPreviousEpisode(); true }
                    Key.MediaNext -> { if (state.hasNext) vm.playNextEpisode(); true }
                    else -> false
                }
                if (mediaHandled) {
                    if (state.phase == PlayerPhase.PLAYING && !upNextVisible && !anyPickerOpen) {
                        controlsVisible = true
                    }
                    return@onPreviewKeyEvent true
                }

                val isDpad = event.key in DPAD_KEYS
                // If focus fell back to the root while an interactive layer is up, recover it.
                if (rootHasFocus && isDpad) {
                    when {
                        anyPickerOpen -> return@onPreviewKeyEvent false
                        upNextVisible -> {
                            runCatching { upNextFocus.requestFocus() }
                            return@onPreviewKeyEvent true
                        }
                        controlsVisible && state.phase == PlayerPhase.PLAYING -> {
                            runCatching { controlsFocus().requestFocus() }
                            return@onPreviewKeyEvent true
                        }
                    }
                }
                // Any key recalls the controls while watching.
                if (state.phase == PlayerPhase.PLAYING && !controlsVisible &&
                    !upNextVisible && !anyPickerOpen && isDpad
                ) {
                    controlsVisible = true
                    return@onPreviewKeyEvent true
                }
                false
            }
            .focusRequester(rootFocus)
            .onFocusChanged { rootHasFocus = it.isFocused }
            .focusable()
    ) {
        // Video surface stays mounted once the first stream is set — overlays draw above it.
        if (state.currentStreamUrl != null) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        useController = false
                        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                        keepScreenOn = true
                        isFocusable = false
                        isFocusableInTouchMode = false
                        setShutterBackgroundColor(android.graphics.Color.BLACK)
                        player = vm.player
                    }
                },
                update = { it.player = vm.player },
                onRelease = { it.player = null },
                modifier = Modifier.fillMaxSize(),
            )
        }

        when (state.phase) {
            PlayerPhase.LOADING -> LoadingOverlay(state)
            // Hidden while any picker is up (mirrors the upNext guard below):
            // a same-window overlay leaves these buttons focusable behind the scrim,
            // so d-pad LEFT could invisibly land on Retry/Back.
            PlayerPhase.ERROR -> if (!anyPickerOpen) ErrorOverlay(
                state = state,
                retryFocus = retryFocus,
                onRetry = { vm.retry() },
                streamActionLabel = if (state.streams.isEmpty() && state.blockedGroups.isNotEmpty()) "Playback options" else "Streams",
                onChooseStream = {
                    vm.holdQueueSkip()
                    openPanel(if (state.streams.isEmpty() && state.blockedGroups.isNotEmpty()) PlayerPanel.OPTIONS else PlayerPanel.STREAMS)
                },
                onNext = if (target.queueSessionId != null && state.hasNext) ({ vm.playNextEpisode() }) else null,
                onBack = {
                    vm.saveProgressNow()
                    exit()
                },
            )
            PlayerPhase.PLAYING -> {
                if (state.isBuffering && !controlsVisible && !upNextVisible) {
                    VelvetSpinner(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .size(52.dp)
                    )
                }
                AnimatedVisibility(
                    visible = controlsVisible && !anyPickerOpen,
                    enter = fadeIn(tween(180)),
                    exit = fadeOut(tween(180)),
                ) {
                    PlayerControls(
                        state = state,
                        playPauseFocusRequester = playPauseFocus,
                        onPlayPause = { vm.togglePlayPause() },
                        onSeekTo = { vm.seekTo(it) },
                        onNextEpisode = { vm.playNextEpisode() },
                        onPreviousEpisode = { vm.playPreviousEpisode() },
                        onReplayWithSubtitles = { vm.replayWithSubtitles() },
                        onOpenPlaybackOptions = { openPanel(PlayerPanel.OPTIONS) },
                        streamsFocusRequester = streamsFocus,
                        optionsFocusRequester = optionsFocus,
                        onOpenStreamPicker = { openPanel(PlayerPanel.STREAMS) },
                        onInteraction = { interactionStamp = System.currentTimeMillis() },
                    )
                }
                if (upNextVisible && !anyPickerOpen) {
                    UpNextOverlay(
                        upNext = state.upNext,
                        fallbackImageUrl = state.backdropUrl,
                        primaryFocusRequester = upNextFocus,
                        onPlayNext = { vm.playNextEpisode() },
                        onWatchCredits = { vm.watchCredits() },
                        onBackToDetails = {
                            vm.saveProgressNow()
                            exit()
                        },
                    )
                }
            }
        }

        state.queueNotice?.let { notice ->
            Text(notice, style = MaterialTheme.typography.bodyMedium, color = VelvetColors.TextPrimary,
                modifier = Modifier.align(Alignment.TopStart).padding(start = 48.dp, top = 24.dp)
                    .background(VelvetColors.Surface, RoundedCornerShape(12.dp)).padding(16.dp))
        }

        // Failover notice — a dead source is being swapped out under the user. Purely
        // informational: nothing focusable, nothing blocking, auto-hides when the new
        // stream is ready (the VM clears the flag on STATE_READY).
        AnimatedVisibility(
            visible = state.switchingSource,
            enter = fadeIn(tween(160)),
            exit = fadeOut(tween(160)),
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(start = 48.dp, top = 24.dp),
        ) {
            SwitchingSourceNotice(state.checkingSources)
        }

        // Skip Intro pill — shown only while the controls are down (the controls have
        // their own affordances); the root key handler makes OK skip while it's up,
        // so it is informational chrome, not a focus target.
        AnimatedVisibility(
            visible = state.skipIntroVisible && !controlsVisible &&
                !upNextVisible && !anyPickerOpen && state.phase == PlayerPhase.PLAYING,
            enter = fadeIn(tween(160)),
            exit = fadeOut(tween(160)),
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 48.dp, bottom = 44.dp),
        ) {
            SkipIntroPill()
        }

        when (panel) {
            PlayerPanel.STREAMS -> StreamPickerSheet(
                streams = state.streams,
                currentUrl = state.currentStreamUrl,
                episodeVerdicts = state.episodeVerdicts,
                onOpenPlaybackOptions = if (state.isShow && state.blockedGroups.isNotEmpty())
                    ({ openPanel(PlayerPanel.OPTIONS) }) else null,
                onPick = { option ->
                    vm.switchStream(option)
                    closePanel()
                },
            )
            PlayerPanel.OPTIONS -> PlaybackOptionsSheet(
                state = state,
                initialFocus = optionFocus,
                onFocus = { optionFocus = it },
                onAudio = { panel = PlayerPanel.AUDIO },
                onSubtitles = { panel = PlayerPanel.SUBTITLES },
                onBlockCurrent = vm::blockCurrentRelease,
                onResetBlocks = { state.blockedGroups.forEach { vm.unblockReleaseGroup(it.key) } },
                onBack = ::closePanel,
            )
            PlayerPanel.SUBTITLES -> TrackPickerSheet(
                title = "Subtitles",
                options = state.subtitleOptions,
                onPick = { option ->
                    vm.selectSubtitleTrack(option.index)
                    panel = PlayerPanel.OPTIONS
                },
            )
            PlayerPanel.AUDIO -> TrackPickerSheet(
                title = "Audio",
                options = state.audioOptions,
                onPick = { option ->
                    vm.selectAudioTrack(option.index)
                    panel = PlayerPanel.OPTIONS
                },
            )
            null -> Unit
        }
    }
}

private enum class PlayerPanel { STREAMS, OPTIONS, AUDIO, SUBTITLES }
private enum class PlayerControl { PLAY, STREAMS, OPTIONS }

private val DPAD_KEYS = setOf(
    Key.DirectionUp, Key.DirectionDown, Key.DirectionLeft, Key.DirectionRight,
    Key.DirectionCenter, Key.Enter, Key.NumPadEnter, Key.Spacebar,
)

// =========================================================================================
// Loading / error overlays
// =========================================================================================

@Composable
private fun LoadingOverlay(state: PlayerUiState) {
    Box(modifier = Modifier.fillMaxSize()) {
        BackdropImage(state.backdropUrl)
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(VelvetColors.Scrim)
        )
        Column(
            modifier = Modifier.align(Alignment.Center),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (state.showTitle.isNotBlank()) {
                Text(
                    text = state.showTitle,
                    style = MaterialTheme.typography.headlineMedium,
                    color = VelvetColors.TextPrimary,
                    textAlign = TextAlign.Center,
                )
                state.episodeLabel?.let {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = it,
                        style = MaterialTheme.typography.titleMedium,
                        color = VelvetColors.TextSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
                Spacer(Modifier.height(28.dp))
            }
            VelvetSpinner(modifier = Modifier.size(46.dp))
            Spacer(Modifier.height(18.dp))
            Text(
                text = if (state.checkingSources) "Checking sources…" else "Finding the best stream…",
                style = MaterialTheme.typography.titleMedium,
                color = VelvetColors.TextSecondary,
            )
        }
    }
}

@Composable
private fun ErrorOverlay(
    state: PlayerUiState,
    retryFocus: FocusRequester,
    onRetry: () -> Unit,
    onChooseStream: () -> Unit,
    streamActionLabel: String,
    onBack: () -> Unit,
    onNext: (() -> Unit)? = null,
) {
    Box(modifier = Modifier.fillMaxSize()) {
        BackdropImage(state.backdropUrl)
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(VelvetColors.Scrim)
        )
        Column(
            modifier = Modifier
                .align(Alignment.Center)
                .padding(horizontal = 96.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = "Playback problem",
                style = MaterialTheme.typography.headlineMedium,
                color = VelvetColors.TextPrimary,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                text = state.errorMessage ?: "Something went wrong.",
                style = MaterialTheme.typography.bodyMedium,
                color = VelvetColors.TextSecondary,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(26.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                // Shared Velvet styling — without it the theme's white colorScheme.border
                // renders UNFOCUSED outlined buttons with a focus-ring-colored border.
                Button(
                    onClick = onRetry,
                    colors = velvetButtonColors(),
                    modifier = Modifier.focusRequester(retryFocus),
                ) {
                    Text("Retry", style = MaterialTheme.typography.labelLarge)
                }
                if (state.canChooseStream) {
                    OutlinedButton(onClick = onChooseStream, border = velvetOutlinedButtonBorder()) {
                        Text(streamActionLabel, style = MaterialTheme.typography.labelLarge)
                    }
                }
                if (onNext != null) OutlinedButton(onClick = onNext, border = velvetOutlinedButtonBorder()) {
                    Text("Next", style = MaterialTheme.typography.labelLarge)
                }
                OutlinedButton(onClick = onBack, border = velvetOutlinedButtonBorder()) {
                    Text("Back", style = MaterialTheme.typography.labelLarge)
                }
            }
        }
    }
}

/** "Skip Intro · OK" — non-focusable pill; the root key handler performs the skip. */
@Composable
private fun SkipIntroPill() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(22.dp))
            .background(VelvetColors.Surface.copy(alpha = 0.94f))
            .padding(horizontal = 18.dp, vertical = 11.dp),
    ) {
        Text(
            text = "Skip Intro",
            style = MaterialTheme.typography.titleSmall,
            color = VelvetColors.TextPrimary,
        )
        Spacer(Modifier.width(10.dp))
        Text(
            text = "OK",
            style = MaterialTheme.typography.labelSmall,
            color = VelvetColors.Background,
            modifier = Modifier
                .clip(RoundedCornerShape(6.dp))
                .background(VelvetColors.TextSecondary)
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

/** Small dark pill: spinner + "Trying another source…". Overscan-safe, non-focusable. */
@Composable
private fun SwitchingSourceNotice(checkingSources: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(VelvetColors.Surface.copy(alpha = 0.92f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        VelvetSpinner(modifier = Modifier.size(18.dp), color = VelvetColors.TextSecondary)
        Spacer(Modifier.width(10.dp))
        Text(
            text = if (checkingSources) "Checking sources…" else "Trying another source…",
            style = MaterialTheme.typography.labelLarge,
            color = VelvetColors.TextSecondary,
        )
    }
}

@Composable
private fun BackdropImage(url: String?) {
    if (url == null) return
    AsyncImage(
        model = ImageRequest.Builder(LocalContext.current).data(url).crossfade(220).build(),
        contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = Modifier
            .fillMaxSize()
            .alpha(0.65f),
    )
}

/** Lightweight indeterminate spinner — tv-material has no progress indicator. */
@Composable
internal fun VelvetSpinner(
    modifier: Modifier = Modifier,
    color: Color = VelvetColors.Accent,
) {
    val transition = rememberInfiniteTransition(label = "spinner")
    val angle by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(durationMillis = 900, easing = LinearEasing)),
        label = "spinnerAngle",
    )
    Canvas(modifier = modifier) {
        drawArc(
            color = color,
            startAngle = angle,
            sweepAngle = 270f,
            useCenter = false,
            style = Stroke(width = 4.dp.toPx(), cap = StrokeCap.Round),
        )
    }
}
