package tv.velvet.ui.sports

import android.os.SystemClock
import android.view.MotionEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.*
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.*
import tv.velvet.VelvetApp
import tv.velvet.data.sports.*
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.theme.VelvetColors

/** The website receives only pointer/keyboard gestures, never an app credential or JavaScript bridge. */
@Composable
fun SportsPlayerScreen(eventId: String, title: String, onBack: () -> Unit) {
    val app = LocalContext.current.applicationContext as VelvetApp
    LaunchedEffect(eventId) {
        // The user selected an event. Prepare only Gecko and our bundled helper
        // while its source list loads; no provider page or hidden stream opens.
        SportsBrowserRuntime.prepare(app).accept({}, {})
    }
    val vm: SportsStreamsViewModel = viewModel(factory = viewModelFactory { initializer { SportsStreamsViewModel(app.container.sportsRepository, eventId) } })
    val state by vm.state.collectAsStateWithLifecycle()
    var selected by remember { mutableStateOf<SportsStream?>(null) }
    var showSources by remember { mutableStateOf(false) }
    var pointerMode by remember { mutableStateOf(false) }
    var pointerVisible by remember { mutableStateOf(false) }
    var pointerActivity by remember { mutableIntStateOf(0) }
    var fullscreen by remember { mutableStateOf(false) }
    var suspended by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var starting by remember { mutableStateOf(true) }
    var manualFallback by remember { mutableStateOf(false) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableIntStateOf(0) }
    var pointerX by remember { mutableFloatStateOf(.5f) }
    var pointerY by remember { mutableFloatStateOf(.5f) }
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    var browserView by remember { mutableStateOf<SportsBrowserView?>(null) }
    val controlsFocus = remember { FocusRequester() }
    val pointerFocus = remember { FocusRequester() }
    val sourceFocus = remember { FocusRequester() }
    val resumeFocus = remember { FocusRequester() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var observedState by remember { mutableStateOf("buffering") }
    var observedAt by remember { mutableLongStateOf(0L) }
    val telemetry = remember { tv.velvet.data.telemetry.PlaybackTelemetry(app, app.container.settingsRepository) }
    DisposableEffect(eventId) {
        telemetry.start("live_sports", eventId, title) {
            val status = if (suspended) "paused" else if (loadError != null) "error"
                else if (observedState == "playing" && SystemClock.elapsedRealtime() - observedAt > 2_000) "buffering"
                else observedState
            tv.velvet.data.telemetry.PlaybackTelemetry.Sample(status)
        }
        onDispose { telemetry.end() }
    }
    fun hideCustom() { browserView?.exitPlayerFullscreen() }
    fun controls() { hideCustom(); fullscreen = false; pointerMode = false; runCatching { controlsFocus.requestFocus() } }
    fun back() { if (showSources) showSources = false else if (pointerMode || fullscreen) controls() else onBack() }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) { suspended = true; telemetry.observe(true); browserView?.close(); pointerMode = false; fullscreen = false }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); browserView?.close() }
    }
    LaunchedEffect(state.streams) {
        if (selected == null || state.streams.none { it.key == selected?.key && it.embedUrl == selected?.embedUrl }) selected = state.streams.firstOrNull()
    }
    LaunchedEffect(selected?.key, reloadKey) { if (selected != null && observedAt > 0) telemetry.sourceSwitch(); observedState = "buffering"; telemetry.observe(true); loading = true; starting = true; loadError = null; manualFallback = false; pointerX = .5f; pointerY = .5f }
    LaunchedEffect(suspended) { if (suspended) { withFrameNanos { }; runCatching { resumeFocus.requestFocus() } } }
    LaunchedEffect(loadError) {
        if (loadError != null) { controls(); withFrameNanos { }; runCatching { sourceFocus.requestFocus() } }
    }
    LaunchedEffect(pointerMode, fullscreen, selected?.key) { withFrameNanos { }; runCatching { if (pointerMode) pointerFocus.requestFocus() else controlsFocus.requestFocus() } }
    LaunchedEffect(pointerMode, pointerActivity) {
        pointerVisible = pointerMode
        if (pointerMode) { kotlinx.coroutines.delay(3_000); pointerVisible = false }
    }
    BackHandler { back() }
    CompositionLocalProvider(LocalContentColor provides VelvetColors.TextPrimary) {
    Column(Modifier.fillMaxSize().background(Color.Black).onPreviewKeyEvent { event ->
        if (event.type != KeyEventType.KeyDown || showSources) return@onPreviewKeyEvent false
        if (event.nativeKeyEvent.keyCode == android.view.KeyEvent.KEYCODE_MENU) { controls(); return@onPreviewKeyEvent true }
        if (!pointerMode) return@onPreviewKeyEvent false
        pointerActivity++
        val step = if (event.nativeKeyEvent.repeatCount > 5) .04f else .012f
        when (event.key) {
            Key.DirectionLeft -> pointerX = (pointerX - step).coerceIn(.005f, .995f)
            Key.DirectionRight -> pointerX = (pointerX + step).coerceIn(.005f, .995f)
            Key.DirectionUp -> pointerY = (pointerY - step).coerceIn(.005f, .995f)
            Key.DirectionDown -> pointerY = (pointerY + step).coerceIn(.005f, .995f)
            Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                if (event.nativeKeyEvent.repeatCount == 0) {
                    val receiver = browserView
                    val time = SystemClock.uptimeMillis()
                    listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP).forEach { action ->
                        val touch = MotionEvent.obtain(time, time, action, pointerX * viewport.width, pointerY * viewport.height, 0)
                        receiver?.dispatchTouchEvent(touch); touch.recycle()
                    }
                }
            }
            else -> return@onPreviewKeyEvent false
        }
        true
    }.focusRequester(pointerFocus).focusable()) {
        if (!fullscreen) Row(Modifier.fillMaxWidth().background(VelvetColors.Background).padding(horizontal = 32.dp, vertical = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Button(onClick = onBack, colors = velvetButtonColors()) { Text("Back") }
            Text(title, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleLarge)
            Button(onClick = { showSources = true }, enabled = state.streams.isNotEmpty(), colors = velvetButtonColors(), modifier = Modifier.focusRequester(sourceFocus)) { Text("Streams") }
            Button(onClick = { if (selected == null) vm.refresh() else { hideCustom(); suspended = false; reloadKey++ } }, colors = velvetButtonColors()) { Text("Reload") }
        }
        Box(Modifier.weight(1f).fillMaxWidth().onSizeChanged { viewport = it }) {
            when {
                suspended -> Column(Modifier.align(Alignment.Center), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Playback stopped while Velvet was in the background.")
                    Button(onClick = { suspended = false; reloadKey++ }, modifier = Modifier.focusRequester(resumeFocus), colors = velvetButtonColors()) { Text("Resume event") }
                }
                state.loading -> Text("Finding streams…", modifier = Modifier.align(Alignment.Center))
                selected == null -> Text(state.message ?: "No streams are posted for this event yet. Try again closer to the start.",
                    modifier = Modifier.align(Alignment.Center).padding(48.dp))
                else -> key(selected!!.key, selected!!.embedUrl, reloadKey) {
                    val embed = selected!!.embedUrl
                    AndroidView(factory = { context ->
                        SportsBrowserView(context, embed,
                            onLoading = { loading = it },
                            onError = { message, manual -> starting = false; loadError = message; manualFallback = manual; telemetry.error() },
                            onStarted = { starting = false },
                            onPlaybackObservation = { status -> observedState = status; observedAt = SystemClock.elapsedRealtime(); telemetry.observe() },
                            onFullscreen = { fullscreen = it; pointerMode = it },
                        ).also { browserView = it }
                    }, onRelease = { view ->
                        if (browserView === view) browserView = null
                        view.close()
                    }, modifier = Modifier.fillMaxSize())
                }
            }
            if (starting && selected != null && !suspended && loadError == null) Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
                Text("Starting stream…", style = MaterialTheme.typography.titleLarge)
            }
            loadError?.let { Text(it, modifier = Modifier.align(Alignment.TopCenter).background(Color.Black.copy(alpha = .9f)).padding(20.dp)) }
            if (pointerMode && pointerVisible && !suspended) {
                Canvas(Modifier.fillMaxSize()) {
                    val point = Offset(pointerX * size.width, pointerY * size.height)
                    drawCircle(Color.Black, 12.dp.toPx(), point, style = Stroke(4.dp.toPx()))
                    drawCircle(Color.White, 10.dp.toPx(), point, style = Stroke(2.dp.toPx()))
                    drawCircle(Color.White, 2.dp.toPx(), point)
                }
                Text("D-pad moves pointer · OK selects · Back returns to controls", style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.align(Alignment.TopEnd).background(Color.Black.copy(alpha = .75f)).padding(10.dp))
            }
        }
        if (!fullscreen) Row(Modifier.fillMaxWidth().background(VelvetColors.Background).padding(horizontal = 32.dp, vertical = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Button(onClick = { pointerMode = !pointerMode }, enabled = selected != null && !suspended && !starting && (loadError == null || manualFallback),
                modifier = Modifier.focusRequester(controlsFocus), colors = velvetButtonColors()) { Text(if (pointerMode) "Pointer active" else "Player controls") }
            Button(onClick = { fullscreen = true; pointerMode = true }, enabled = selected != null && !suspended && !starting && (loadError == null || manualFallback), colors = velvetButtonColors()) { Text("Fullscreen") }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(selected?.label ?: "StreamFree", maxLines = 1, overflow = TextOverflow.Ellipsis, color = VelvetColors.TextSecondary)
                Text("If a source stalls, try another stream or Reload.", color = VelvetColors.TextTertiary,
                    style = MaterialTheme.typography.labelSmall, maxLines = 2)
            }
        }
    }
    if (showSources) Dialog(onDismissRequest = { showSources = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val first = remember { FocusRequester() }
        LaunchedEffect(Unit) { withFrameNanos { }; runCatching { first.requestFocus() } }
        Column(Modifier.width(680.dp).heightIn(max = 450.dp).background(VelvetColors.Background).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Choose a stream", style = MaterialTheme.typography.headlineSmall)
            Text("Quality and language are supplied by StreamFree.", color = VelvetColors.TextSecondary)
            LazyColumn(Modifier.weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(4.dp)) {
                items(state.streams, key = { it.key }) { stream ->
                    Button(onClick = { hideCustom(); selected = stream; reloadKey++; suspended = false; pointerMode = false; fullscreen = false; showSources = false },
                        colors = velvetButtonColors(), modifier = Modifier.fillMaxWidth().then(if (stream == state.streams.first()) Modifier.focusRequester(first) else Modifier)) {
                        Text((if (selected?.key == stream.key) "✓ " else "") + stream.label)
                    }
                }
            }
            Button(onClick = { showSources = false }, colors = velvetButtonColors()) { Text("Cancel") }
        }
    }
    }
}
