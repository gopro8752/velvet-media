@file:OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)

package tv.velour.ui.home

import android.os.SystemClock
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.key.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect
import tv.velour.R
import tv.velour.core.AppAction
import tv.velour.core.AppEntry
import tv.velour.core.WallpaperMode
import tv.velour.ui.wallpaper.WallpaperLayer
import tv.velour.ui.theme.VelourColors
import tv.velour.data.velvet.*
import tv.velour.ui.components.AppActionsMenu
import tv.velour.ui.glass.*
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private enum class HomePage { Home, Apps }

/** A quiet TV home. Settings lives in the header; Back returns to the top of the page. */
@Composable
fun HomeScreen(onOpenSettings: () -> Unit, viewModel: HomeViewModel, active: Boolean = true) {
    val ui by viewModel.uiState.collectAsStateWithLifecycle()
    val velvet by viewModel.velvet.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    val artwork = rememberHomeArtwork()
    val reduced = ui.settings.reduceMotion
    val idleTimeout by rememberUpdatedState(ui.settings.idleTimeoutSec)
    var page by remember { mutableStateOf(HomePage.Home) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    val homeFirstFocus = remember { FocusRequester() }
    val appsFirstFocus = remember { FocusRequester() }
    val todayFocus = remember { FocusRequester() }
    val settingsFocus = remember { FocusRequester() }
    var lastContent by remember { mutableStateOf<FocusRequester?>(null) }
    var lastHeader by remember { mutableStateOf<FocusRequester?>(null) }
    var inHeader by remember { mutableStateOf(false) }
    var inToday by remember { mutableStateOf(false) }
    var menuEntry by remember { mutableStateOf<AppEntry?>(null) }
    var moveEntry by remember { mutableStateOf<AppEntry?>(null) }
    var moveOrder by remember { mutableStateOf<List<String>>(emptyList()) }
    var ambient by remember { mutableStateOf(false) }
    var resumed by remember { mutableStateOf(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    var swallowWake by remember { mutableStateOf(false) }
    var lastInteraction by remember { mutableLongStateOf(SystemClock.uptimeMillis()) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val homeScroll = rememberLazyListState()
    val appsScroll = rememberLazyListState()
    val favoriteScroll = rememberLazyListState()
    val scroll = if (page == HomePage.Home) homeScroll else appsScroll
    val firstContentFocus = if (page == HomePage.Home) homeFirstFocus else appsFirstFocus
    val chrome = remember { Animatable(1f) }
    val appearance = remember { Animatable(0f) }
    var softened by remember { mutableStateOf<ImageBitmap?>(null) }
    val staticWallpaper = ui.settings.wallpaperMode in setOf(WallpaperMode.NOCTURNE, WallpaperMode.HORIZON)
    val wallpaperResource = if (ui.settings.wallpaperMode == WallpaperMode.HORIZON)
        R.drawable.velour_horizon else R.drawable.velour_nocturne
    val wallpaper = if (staticWallpaper) rememberArtwork(artwork, null, 2048, wallpaperResource) else null
    val todayGames = velvet.games.filter { it.matchesTeams(ui.settings.sportsTeams) && it.isToday(now) }
    val todayVisible = ui.settings.sportsTeams.isNotEmpty() && (velvet.sportsUnavailable || todayGames.isNotEmpty())

    suspend fun focusFirstContent(animate: Boolean = false) {
        if (animate && !reduced) scroll.animateScrollToItem(0) else scroll.scrollToItem(0)
        if (page == HomePage.Home) favoriteScroll.scrollToItem(0)
        withFrameNanos { }
        if (!runCatching { firstContentFocus.requestFocus() }.isSuccess) settingsFocus.requestFocus()
    }

    fun restoreContent() {
        val restored = lastContent?.let { runCatching { it.requestFocus() }.isSuccess } ?: false
        if (!restored) scope.launch { focusFirstContent() }
    }
    fun open(action: VelvetAction) {
        if (!viewModel.openVelvet(action)) Toast.makeText(context,
            "Open or update Velvet to use this feature.", Toast.LENGTH_LONG).show()
    }
    fun focusContent(requester: FocusRequester) { lastContent = requester; inHeader = false; inToday = false }
    fun focusHeader(requester: FocusRequester) { lastHeader = requester; inHeader = true; inToday = false }
    fun selectPage(next: HomePage) {
        if (page != next) { page = next; lastContent = null; inHeader = false; inToday = false }
    }
    fun back() {
        when {
            ambient -> ambient = false
            menuEntry != null -> { menuEntry = null; scope.launch { withFrameNanos { }; restoreContent() } }
            moveEntry != null -> { moveEntry = null; scope.launch { withFrameNanos { }; restoreContent() } }
            page == HomePage.Apps -> selectPage(HomePage.Home)
            inHeader -> restoreContent()
            else -> scope.launch { focusFirstContent(animate = true) }
        }
    }

    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ ->
            resumed = lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if (!resumed) ambient = false
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(wallpaper, active, resumed) {
        if (!active || !resumed) return@LaunchedEffect
        softened = wallpaper?.let { artwork.softened(it) }
    }
    LaunchedEffect(ambient, reduced) { chrome.animateTo(if (ambient) 0f else 1f, tween(if (reduced) 0 else if (ambient) 850 else 180)) }
    LaunchedEffect(Unit) { appearance.animateTo(1f, tween(if (reduced) 0 else 650)) }
    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            ambient = false
            lastInteraction = SystemClock.uptimeMillis()
            viewModel.onHomeResumed()
            launch { viewModel.velvetChanges.collect { viewModel.refreshVelvet() } }
            launch { while (true) { viewModel.refreshVelvet(); delay(30_000) } }
            launch { while (true) { now = System.currentTimeMillis(); delay(15_000) } }
            while (true) {
                delay(1_000)
                val timeout = idleTimeout
                if (timeout > 0 && menuEntry == null && moveEntry == null &&
                    SystemClock.uptimeMillis() - lastInteraction > timeout * 1000L) ambient = true
            }
        }
    }
    var previousPage by remember { mutableStateOf(page) }
    var firstEntry by remember { mutableStateOf(true) }
    LaunchedEffect(active, page) {
        if (active) {
            withFrameNanos { }
            if (firstEntry || previousPage != page) {
                focusFirstContent()
            } else if (inHeader) {
                if (!runCatching { (lastHeader ?: settingsFocus).requestFocus() }.isSuccess) settingsFocus.requestFocus()
            } else restoreContent()
            previousPage = page
            firstEntry = false
        }
    }
    LaunchedEffect(active, resumed, page, todayGames.map { it.id }, todayVisible) {
        if (!active || !resumed || !inToday) return@LaunchedEffect
        // A schedule refresh or local midnight can remove the focused game.
        withFrameNanos { }
        val restored = lastHeader?.let { runCatching { it.requestFocus() }.isSuccess } ?: false
        if (!restored) {
            val groupRestored = page == HomePage.Home && todayVisible && runCatching { todayFocus.requestFocus() }.isSuccess
            if (!groupRestored) settingsFocus.requestFocus()
        }
    }
    BackHandler(active) { back() }
    val backdrop = if (staticWallpaper) softened?.let { GlassBackdrop(it, size) } else null
    val canUseContent = active && menuEntry == null && moveEntry == null

    BoxWithConstraints(Modifier.fillMaxSize().background(Color(0xFF090D16)).onSizeChanged { size = it }
        .onPreviewKeyEvent { event ->
            if (!active) return@onPreviewKeyEvent false
            if (event.type == KeyEventType.KeyDown) lastInteraction = SystemClock.uptimeMillis()
            when {
                ambient && event.type == KeyEventType.KeyDown -> { ambient = false; swallowWake = true; true }
                swallowWake -> { if (event.type == KeyEventType.KeyUp) swallowWake = false; true }
                event.key == Key.Back -> {
                    if (event.type == KeyEventType.KeyDown && event.nativeKeyEvent.repeatCount == 0) back()
                    true
                }
                inHeader && event.key == Key.DirectionDown -> {
                    if (event.type == KeyEventType.KeyDown && event.nativeKeyEvent.repeatCount == 0) restoreContent()
                    true
                }
                else -> false
            }
        }) {
        // Use the spare Home space without squeezing content on shorter displays.
        val contentDrop = if (page == HomePage.Home)
            (maxHeight - 464.dp).coerceIn(0.dp, 64.dp) else 0.dp
        CompositionLocalProvider(
            LocalHomeAccent provides lerp(VelourColors.accent(ui.settings.accent), Pearl, .5f),
            LocalGlassMotionActive provides (active && resumed && !ambient),
        ) {
        Box(Modifier.fillMaxSize()) {
        // Preserve the chosen wallpaper for browsing; standby covers it in pure black.
        if (!staticWallpaper) {
            WallpaperLayer(ui.settings.wallpaperMode, VelourColors.accent(ui.settings.accent),
                VelourColors.accentDeep(ui.settings.accent), { .5f }, ui.weather, reduced,
                Modifier.fillMaxSize(), active = active && resumed && !ambient)
        } else if (wallpaper != null) Image(wallpaper, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
            0f to Color(0xFF080B12).copy(alpha = .12f), .45f to Color.Transparent,
            1f to Color(0xFF080B12).copy(alpha = .28f))))

        Box(Modifier.fillMaxSize().graphicsLayer { alpha = chrome.value * appearance.value }
            .focusProperties { canFocus = canUseContent; enter = { if (canUseContent) FocusRequester.Default else FocusRequester.Cancel } }.focusGroup()) {
            HomeViewport(vertical = true, reduced = reduced) {
            LazyColumn(state = scroll, contentPadding = PaddingValues(top = 10.dp, bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp), modifier = Modifier.fillMaxSize().padding(top = 94.dp + contentDrop)) {
                if (page == HomePage.Home) {
                    item("apps") {
                        AppShelf("Apps", ui.favorites, viewModel, reduced,
                            onFocus = ::focusContent, onMenu = { menuEntry = it },
                            onAllApps = { selectPage(HomePage.Apps) }, initialFocus = homeFirstFocus,
                            upFocus = if (todayVisible) todayFocus else settingsFocus, listState = favoriteScroll)
                    }
                    if (velvet.continueWatching.isNotEmpty()) item("continue") {
                        TitleShelf("Continue watching", null, velvet.continueWatching,
                            artwork, reduced, onFocused = { _, focus -> focusContent(focus) },
                            onOpen = { open(VelvetAction.Resume(it)) }, progress = true)
                    }
                    if (!velvet.connected || velvet.profile == null) item("connect") {
                        ConnectionCard(velvet, reduced, ::focusContent) { open(if (velvet.connected) VelvetAction.Profiles else VelvetAction.Home) }
                    }
                } else {
                    item("app-heading") {
                        Row(Modifier.padding(horizontal = 48.dp), verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                            HomeAction("Home", GlassIcon.Back, { selectPage(HomePage.Home) }, reduced,
                                modifier = Modifier.focusProperties { up = settingsFocus }, focusTracker = ::focusContent)
                            HomeText("APPS", 10, color = PearlMuted, tracking = 1.6f)
                        }
                    }
                    if (ui.library.isEmpty()) item("empty-apps") {
                        HomeAction("Launcher settings", GlassIcon.Settings, onOpenSettings, reduced,
                            Modifier.padding(horizontal = 48.dp).focusRequester(appsFirstFocus), onFocused = { focusContent(appsFirstFocus) })
                    }
                    ui.library.chunked(5).forEachIndexed { row, entries -> item("app-row-$row") {
                        Row(Modifier.padding(horizontal = 48.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                            entries.forEachIndexed { col, app ->
                                LauncherAppCard(app, viewModel, reduced, 156.dp,
                                    initialFocus = if (row == 0 && col == 0) appsFirstFocus else null,
                                    onFocused = ::focusContent, onMenu = { menuEntry = app })
                            }
                        }
                    } }
                }
            }

            }

            // Today follows the shelves down; clock and utility controls stay anchored.
            Row(Modifier.fillMaxWidth().padding(horizontal = 48.dp, vertical = 21.dp).height(48.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f).padding(end = 28.dp).offset(y = contentDrop)) {
                    if (page == HomePage.Home && todayVisible) TodayGames(velvet.games, ui.settings.sportsTeams, artwork, reduced,
                        onFocus = { focusHeader(it); inToday = true }, onOpen = { open(VelvetAction.SportsGame(it)) },
                        modifier = Modifier.fillMaxWidth(), backdrop = backdrop, now = now,
                        unavailable = velvet.sportsUnavailable, onBrowse = { open(VelvetAction.LiveSports) },
                        use24Hour = ui.settings.use24Hour, firstFocus = todayFocus, headerFocus = settingsFocus)
                }
                ui.weather?.let { weather ->
                    HomeText("${(weather.tempC * 9 / 5 + 32).toInt()}°", 16, color = PearlMuted)
                    Spacer(Modifier.width(18.dp))
                }
                HomeText(SimpleDateFormat(if (ui.settings.use24Hour) "HH:mm" else "h:mm", Locale.getDefault()).format(Date(now)), 22)
                Spacer(Modifier.width(18.dp))
                Box(Modifier.focusRequester(settingsFocus).focusProperties {
                    left = if (page == HomePage.Home && todayVisible) todayFocus else FocusRequester.Default
                }) {
                    HeaderButton(GlassIcon.Settings, "Launcher settings", reduced, backdrop,
                        onFocus = ::focusHeader, onClick = onOpenSettings)
                }
                Spacer(Modifier.width(10.dp))
                ProfileButton(velvet.profile?.name ?: "You", reduced, backdrop,
                    onFocus = ::focusHeader, onClick = { open(VelvetAction.Profiles) })
            }

            }
        }

        }
        // A real black plane, not a dimmed wallpaper. It also hides retained Home
        // content while its focus and scroll state remain ready for the wake key.
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = 1f - chrome.value }.background(Color.Black))
        if (ambient && active && resumed) {
            AmbientClock(now, ui.settings.use24Hour, reduced, Modifier.align(Alignment.Center))
        }
        menuEntry?.let { app ->
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .58f)), contentAlignment = Alignment.Center) {
                AppActionsMenu(app, app.packageName in ui.favoritePackages, true, Pearl,
                    onAction = { action ->
                        menuEntry = null
                        if (action == AppAction.Move) {
                            moveEntry = app; moveOrder = ui.favorites.map { it.packageName }
                        } else {
                            viewModel.onAppAction(app, action)
                            scope.launch { delay(100); restoreContent() }
                        }
                    }, onDismiss = { menuEntry = null; scope.launch { withFrameNanos { }; restoreContent() } })
            }
        }
        moveEntry?.let { entry ->
            ArrangePanel(entry, moveOrder, ui.library, reduced,
                onMove = { delta ->
                    val from = moveOrder.indexOf(entry.packageName)
                    val to = (from + delta).coerceIn(0, moveOrder.lastIndex)
                    if (from >= 0 && from != to) moveOrder = moveOrder.toMutableList().apply { add(to, removeAt(from)) }
                }, onDone = {
                    viewModel.commitMove(moveOrder); moveEntry = null
                    scope.launch { withFrameNanos { }; restoreContent() }
                })
        }
    }
}
