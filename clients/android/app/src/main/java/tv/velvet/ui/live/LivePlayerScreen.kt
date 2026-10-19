package tv.velvet.ui.live

import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
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
import androidx.tv.material3.Text
import kotlinx.coroutines.delay
import tv.velvet.VelvetApp
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.theme.VelvetColors

@OptIn(UnstableApi::class)
@Composable
fun LivePlayerScreen(channelId: String, onExit: () -> Unit) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: LivePlayerViewModel = viewModel(factory = viewModelFactory { initializer {
        LivePlayerViewModel(app, app.container.liveRepository, app.container.settingsRepository, channelId)
    } })
    val state by vm.state.collectAsStateWithLifecycle()
    var controls by remember { mutableStateOf(true) }
    var interaction by remember { mutableLongStateOf(0L) }
    var rootFocused by remember { mutableStateOf(false) }
    val rootFocus = remember { FocusRequester() }
    val channelsFocus = remember { FocusRequester() }
    val retryFocus = remember { FocusRequester() }
    val lifecycleOwner = LocalLifecycleOwner.current
    val exit = { vm.close(); onExit() }
    DisposableEffect(vm, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> vm.onHostStop()
                Lifecycle.Event.ON_RESUME -> vm.onHostResume()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        vm.onHostResume()
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer); vm.onHostStop() }
    }
    LaunchedEffect(state.phase) { if (state.phase != LivePhase.PLAYING) controls = true }
    LaunchedEffect(controls, interaction, state.phase, state.buffering) {
        if (controls && state.phase == LivePhase.PLAYING && !state.buffering) { delay(5_000); controls = false }
    }
    LaunchedEffect(controls, state.phase) {
        withFrameNanos { }
        runCatching {
            when {
                state.phase == LivePhase.ERROR -> retryFocus.requestFocus()
                controls -> channelsFocus.requestFocus()
                else -> rootFocus.requestFocus()
            }
        }
    }
    BackHandler { exit() }
    Box(Modifier.fillMaxSize().background(Color.Black)
        .onPreviewKeyEvent { event ->
            if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
            interaction++
            when (event.nativeKeyEvent.keyCode) {
                android.view.KeyEvent.KEYCODE_CHANNEL_UP -> { vm.changeChannel(1); controls = true; return@onPreviewKeyEvent true }
                android.view.KeyEvent.KEYCODE_CHANNEL_DOWN -> { vm.changeChannel(-1); controls = true; return@onPreviewKeyEvent true }
            }
            if (event.key == Key.Back) return@onPreviewKeyEvent false
            if (event.key in listOf(Key.MediaPlayPause, Key.MediaPause, Key.MediaPlay, Key.MediaFastForward, Key.MediaRewind)) {
                controls = true // this source is live-only; no fictitious pause or seek
                return@onPreviewKeyEvent true
            }
            val dpad = event.key in listOf(Key.DirectionUp, Key.DirectionDown, Key.DirectionLeft,
                Key.DirectionRight, Key.DirectionCenter, Key.Enter, Key.NumPadEnter)
            if (dpad && (!controls || rootFocused)) {
                controls = true
                runCatching { if (state.phase == LivePhase.ERROR) retryFocus.requestFocus() else channelsFocus.requestFocus() }
                true
            } else false
        }.focusRequester(rootFocus).onFocusChanged { rootFocused = it.isFocused }.focusable()) {
        AndroidView(factory = { context -> PlayerView(context).apply {
            useController = false
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            keepScreenOn = true
            isFocusable = false
            isFocusableInTouchMode = false
            player = vm.player
        } }, update = { it.player = vm.player }, onRelease = { it.player = null }, modifier = Modifier.fillMaxSize())

        if (state.phase != LivePhase.PLAYING || state.buffering) {
            Column(Modifier.align(Alignment.Center).padding(48.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(when {
                    state.phase == LivePhase.ERROR -> state.error ?: "This channel couldn't play."
                    state.phase == LivePhase.SUSPENDED -> "Live TV is paused while Velvet is in the background."
                    state.reconnecting -> "Reconnecting to ${state.channel?.name ?: "the channel"}…"
                    state.phase == LivePhase.PLAYING -> "Buffering…"
                    else -> "Starting ${state.channel?.name ?: "Live TV"}…"
                }, style = MaterialTheme.typography.titleLarge, color = VelvetColors.TextPrimary)
                if (state.phase == LivePhase.ERROR) Button(onClick = vm::retry, colors = velvetButtonColors(),
                    modifier = Modifier.focusRequester(retryFocus)) { Text("Retry") }
            }
        }
        if (controls) Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.85f)).padding(horizontal = 48.dp, vertical = 24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("● LIVE", color = VelvetColors.Accent, style = MaterialTheme.typography.labelLarge)
                Text(state.channel?.name ?: "Live TV", color = VelvetColors.TextPrimary,
                    style = MaterialTheme.typography.headlineSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f))
                state.channel?.number?.let { Text(it, color = VelvetColors.TextSecondary) }
            }
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Button(onClick = { vm.changeChannel(-1) }, enabled = state.canChangeChannel, colors = velvetButtonColors()) { Text("Previous") }
                Button(onClick = exit, colors = velvetButtonColors(), modifier = Modifier.focusRequester(channelsFocus)) { Text("Channels") }
                Button(onClick = { vm.changeChannel(1) }, enabled = state.canChangeChannel, colors = velvetButtonColors()) { Text("Next") }
                if (state.captionsAvailable) Button(onClick = vm::toggleCaptions, colors = velvetButtonColors()) {
                    Text(if (state.captionsEnabled) "Captions on" else "Captions off")
                }
                Spacer(Modifier.weight(1f))
                Button(onClick = exit, colors = velvetButtonColors()) { Text("Close") }
            }
        }
    }
}
