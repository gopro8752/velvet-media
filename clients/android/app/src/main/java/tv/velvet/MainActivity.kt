package tv.velvet

import android.content.Intent
import android.os.Bundle
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.flow.first
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import tv.velvet.data.launcher.LauncherHomeRequest
import tv.velvet.data.launcher.LauncherNavigation
import tv.velvet.data.launcher.LauncherRequest
import tv.velvet.data.launcher.LauncherSportsSelection
import tv.velvet.data.launcher.launcherSportsFilter
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget
import tv.velvet.ui.details.DetailsScreen
import tv.velvet.ui.home.HomeScreen
import tv.velvet.ui.navigation.GlassNavigationDock
import tv.velvet.ui.navigation.dockBackdropSource
import tv.velvet.ui.navigation.rememberDockBackdrop
import tv.velvet.ui.navigation.NavigationPage
import tv.velvet.ui.navigation.TvDestinations
import tv.velvet.ui.sports.SportsScreen
import tv.velvet.ui.sports.SportsPlayerScreen
import tv.velvet.ui.live.LiveScreen
import tv.velvet.ui.live.LivePlayerScreen
import tv.velvet.ui.player.HandoffReceiver
import tv.velvet.ui.player.PlayerScreen
import tv.velvet.ui.profile.ProfilePickerScreen
import tv.velvet.ui.profile.ProfilesViewModel
import tv.velvet.ui.search.SearchScreen
import tv.velvet.ui.settings.SettingsScreen
import tv.velvet.ui.theme.VelvetColors
import tv.velvet.ui.theme.VelvetTheme

/** Central route builders — every navigation in the app goes through these. */
object Routes {
    const val HOME = "home"
    const val SEARCH = "search"
    const val SETTINGS = "settings"
    const val SPORTS = "sports"
    const val SPORTS_PLAYER = "sports-player/{eventId}?title={title}"
    fun sportsPlayer(id: String, title: String) = "sports-player/${Uri.encode(id)}?title=${Uri.encode(title)}"
    const val LIVE = "live"
    const val LIVE_PLAYER_PATTERN = "live-player/{channelId}"
    fun livePlayer(channelId: String) = "live-player/${Uri.encode(channelId)}"

    fun details(type: MediaType, id: Int) = "details/${type.key}/$id"
    const val DETAILS_PATTERN = "details/{type}/{id}"

    /** season/episode = -1 means "movie" / "resolve next unwatched". resumeMs -1 = ask/resume default. */
    fun player(target: PlayTarget) =
        "player/${target.type.key}/${target.mediaId}?season=${target.season ?: -1}&episode=${target.episode ?: -1}&queue=${target.queueSessionId.orEmpty()}&cursor=${target.queueIndex ?: -1}&handoff=${target.handoffId.orEmpty()}"
    const val PLAYER_PATTERN = "player/{type}/{id}?season={season}&episode={episode}&queue={queue}&cursor={cursor}&handoff={handoff}"
}

class MainActivity : ComponentActivity() {

    /** Sync pulls on launch/foreground and ticks only while the app is visible. */
    override fun onStart() {
        super.onStart()
        (application as VelvetApp).container.syncEngine.onAppForegrounded()
    }

    override fun onStop() {
        (application as VelvetApp).container.syncEngine.onAppBackgrounded()
        super.onStop()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContent {
            VelvetTheme {
                ProfileGate(onExit = ::exitToLauncher)
            }
        }
    }

    private fun exitToLauncher() {
        // Follow the system HOME role so any chosen launcher works. Normal
        // background lifecycle releases playback/presence while retaining the viewer.
        startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

/**
 * The profile selection gate that fronts the whole app (spec §"Active profile").
 *
 * Picker shows when `!profileChosenThisLaunch && (activeProfileId == null ||
 * liveProfileCount >= 2)`. Exactly one profile, already chosen → straight to Home
 * (auto-selected). The Home top-bar avatar re-opens the picker on demand by flipping
 * [profileChosenThisLaunch] back to false. `profileChosenThisLaunch` is intentionally
 * NOT a rememberSaveable: a process death is a fresh launch, so the picker re-evaluates.
 */
@Composable
private fun ProfileGate(onExit: () -> Unit) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: ProfilesViewModel = viewModel(
        factory = viewModelFactory { initializer { ProfilesViewModel(app.container) } }
    )
    val state by vm.state.collectAsStateWithLifecycle()
    val launcherRequest by LauncherNavigation.request.collectAsStateWithLifecycle()

    var profileChosenThisLaunch by remember { mutableStateOf(false) }
    // On-demand re-open from the Home avatar — works even with a single profile, where
    // the launch-gating formula alone would keep the picker suppressed.
    var forcePicker by remember { mutableStateOf(false) }

    LaunchedEffect(launcherRequest?.id, state.loading, state.activeProfileId) {
        val request = launcherRequest ?: return@LaunchedEffect
        if (state.loading) return@LaunchedEffect
        if (request.profileId != null && request.profileId != state.activeProfileId) {
            LauncherNavigation.consume(request.id)
        } else if (request.destination == "profiles") {
            forcePicker = true
            LauncherNavigation.consume(request.id)
        } else if (request.profileId != null) {
            // The signed launcher already presents the active viewer. A requested
            // resume should not detour into the same profile picker on cold launch.
            profileChosenThisLaunch = true
        }
    }

    // Hold a blank canvas until profiles exist. Covers both the first combine emission
    // (loading) AND the brief window where AppContainer's async bootstrap hasn't yet
    // created the "default" profile — showing an empty picker there would flash. Per
    // spec, zero profiles never shows the picker; the bootstrap creates one and proceeds.
    if (state.loading || state.profiles.isEmpty()) {
        androidx.compose.foundation.layout.Box(
            Modifier.fillMaxSize().background(VelvetColors.Background)
        )
        return
    }

    val showPicker = forcePicker || (
        !profileChosenThisLaunch &&
            !(launcherRequest?.profileId != null && launcherRequest?.profileId == state.activeProfileId && launcherRequest?.destination != "profiles") &&
            (state.activeProfileId == null || state.profiles.size >= 2)
        )

    if (showPicker) {
        ProfilePickerScreen(
            onProfileChosen = { id ->
                vm.selectProfile(id)
                profileChosenThisLaunch = true
                forcePicker = false
            },
            // Cancellable only when a profile is already active (something is behind the
            // picker to return to): the cold-start gate with no active profile can't BACK.
            onBack = if (state.activeProfileId != null) {
                {
                    profileChosenThisLaunch = true
                    forcePicker = false
                }
            } else null,
        )
    } else {
        VelvetNavHost(
            onOpenProfilePicker = { forcePicker = true },
            onExit = onExit,
            launcherRequest = launcherRequest?.takeIf { it.profileId == null || it.profileId == state.activeProfileId },
        )
    }
}

@Composable
private fun VelvetNavHost(onOpenProfilePicker: () -> Unit, onExit: () -> Unit, launcherRequest: LauncherRequest? = null) {
    val navController = rememberNavController()
    var homeLauncherRequest by remember { mutableStateOf<LauncherHomeRequest?>(null) }
    var sportsLauncherSelection by remember { mutableStateOf<LauncherSportsSelection?>(null) }
    val app = LocalContext.current.applicationContext as VelvetApp

    LaunchedEffect(launcherRequest?.id) {
        val request = launcherRequest ?: return@LaunchedEffect
        if (request.destination == "profiles") return@LaunchedEffect
        val game = if (request.destination == "game") try {
            app.container.launcherSportsRepository.resolve(requireNotNull(request.gameId))
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
          catch (_: Exception) { null }
        else null
        val destination = when (request.destination) {
            "search" -> Routes.SEARCH
            "live" -> Routes.LIVE
            "sports" -> Routes.SPORTS
            "game" -> game?.eventId?.let { Routes.sportsPlayer(it, game.title) } ?: Routes.SPORTS
            "details" -> Routes.details(MediaType.fromKey(requireNotNull(request.type)), requireNotNull(request.mediaId))
            "resume" -> Routes.player(PlayTarget(requireNotNull(request.mediaId), MediaType.fromKey(requireNotNull(request.type)), request.season, request.episode))
            else -> Routes.HOME
        }
        // An explicit launcher selection replaces the active screen/player, so a
        // previously playing surface cannot remain alive below a new destination.
        navController.navigate(destination) {
            popUpTo(Routes.HOME) { inclusive = destination == Routes.HOME }
            launchSingleTop = true
        }
        sportsLauncherSelection = if (request.destination == "game" && destination == Routes.SPORTS) {
            navController.currentBackStackEntry?.id?.let { entryId ->
                LauncherSportsSelection(entryId, request.id, game?.homeTeam?.shortName.orEmpty(),
                    launcherSportsFilter(game?.league ?: request.gameId.orEmpty().substringBefore(':')),
                    game?.title, when {
                        game == null -> "The selected game could not be refreshed. Browse available events below."
                        game.stale -> "Schedule information is being refreshed. Choose an available event below."
                        game?.status == "final" -> "This game has finished. Related events are shown below."
                        game?.status in setOf("postponed", "canceled") -> "This game is ${game?.status}. Related events are shown below."
                        else -> "Choose an available event below. Refresh if this matchup is not listed yet."
                    })
            }
        } else null
        homeLauncherRequest = request.takeIf { it.destination in setOf("create", "category") }?.let { pending ->
            navController.currentBackStackEntry?.id?.let { LauncherHomeRequest(it, pending) }
        }
        LauncherNavigation.consume(request.id)
    }

    HandoffReceiver { target ->
        // A replaced player must be destroyed, not left playing underneath the new route.
        val current = navController.currentDestination
        navController.navigate(Routes.player(target)) {
            if (current?.route in setOf(Routes.PLAYER_PATTERN, Routes.LIVE_PLAYER_PATTERN, Routes.SPORTS_PLAYER)) {
                popUpTo(requireNotNull(current).id) { inclusive = true }
            }
        }
    }

    val entry by navController.currentBackStackEntryAsState()
    val route = entry?.destination?.route ?: Routes.HOME
    val isPlayer = route in setOf(Routes.PLAYER_PATTERN, Routes.LIVE_PLAYER_PATTERN, Routes.SPORTS_PLAYER)
    val showDock = !isPlayer && route != Routes.DETAILS_PATTERN
    val dockBackdrop = rememberDockBackdrop()
    val dockRequests = remember { TvDestinations.associate { it.route to FocusRequester() } }
    // Details can appear several times in a back stack. A requester belongs to a
    // concrete page entry, never its route pattern or the page underneath it.
    val pageRequests = remember { mutableMapOf<String, FocusRequester>() }
    val laidOutPages = remember { mutableStateMapOf<String, Boolean>() }
    fun pageRequest(id: String) = pageRequests.getOrPut(id) { FocusRequester() }
    var lastTabRoute by rememberSaveable { mutableStateOf(Routes.HOME) }
    val selectedDockRoute = route.takeIf { candidate -> TvDestinations.any { it.route == candidate } } ?: lastTabRoute
    var dockHasFocus by remember { mutableStateOf(false) }
    var dockReadyPageId by remember { mutableStateOf<String?>(null) }
    var dockOpen by remember { mutableStateOf(false) }
    var dockLaidOut by remember { mutableStateOf(false) }
    var returningFromPlayer by remember { mutableStateOf(false) }
    var pendingPageRestore by remember { mutableStateOf<String?>(null) }
    var pendingDockFocus by remember { mutableStateOf<String?>(null) }
    val dockVisibility = remember { MutableTransitionState(false) }
    val dockReady = entry != null && dockReadyPageId == entry?.id
    // Open intent covers the short interval before AnimatedVisibility mounts
    // focus targets. Actual focus alone cannot make a hidden dock appear.
    val dockInteractive = showDock && dockReady && dockOpen
    SideEffect { dockVisibility.targetState = dockInteractive }
    // Keep the live page display list through the final exit frame. Removing
    // capture as soon as the route changes would leave fading glass stale/blank.
    val captureDockBackdrop = dockInteractive || dockVisibility.currentState ||
        dockVisibility.targetState || !dockVisibility.isIdle
    val keyboard = LocalSoftwareKeyboardController.current
    val imeVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0

    LaunchedEffect(selectedDockRoute) { lastTabRoute = selectedDockRoute }
    LaunchedEffect(entry?.id, showDock, pendingPageRestore) {
        val currentEntry = entry
        if (pendingDockFocus != currentEntry?.id) {
            pendingDockFocus = null
            if (!dockReady) dockOpen = false
        }
        if (!showDock || currentEntry == null) {
            dockReadyPageId = null
            dockHasFocus = false
            dockOpen = false
            pendingDockFocus = null
        }
        if (isPlayer || currentEntry == null) {
            if (isPlayer) returningFromPlayer = true
            return@LaunchedEffect
        }
        val restoreContent = returningFromPlayer || pendingPageRestore == currentEntry.id
        // Details has no dock, but returning from playback or another details
        // page still restores its saved content focus after the page is ready.
        if (!showDock && !restoreContent) return@LaunchedEffect
        // NavHost holds incoming pages at STARTED during its crossfade. Waiting
        // for RESUMED plus layout restores the page first. The glass only rises
        // later if the viewer explicitly asks to control it.
        if (!dockReady || restoreContent) {
            currentEntry.lifecycle.currentStateFlow.first { it.isAtLeast(Lifecycle.State.RESUMED) }
            snapshotFlow { laidOutPages[currentEntry.id] == true }.first { it }
            withFrameNanos { }
            if (navController.currentBackStackEntry?.id != currentEntry.id) return@LaunchedEffect
            if (restoreContent) {
                val focus = pageRequest(currentEntry.id)
                runCatching { if (!focus.restoreFocusedChild()) focus.requestFocus() }
                // Back may arrive during the incoming page's crossfade. Finish
                // restoring that page before honoring its queued dock request.
                if (dockOpen && pendingDockFocus == currentEntry.id) {
                    runCatching { focus.saveFocusedChild() }
                }
                returningFromPlayer = false
                pendingPageRestore = null
            }
            dockReadyPageId = currentEntry.id.takeIf { showDock }
        }
    }

    fun openDetails(type: MediaType, id: Int) {
        // Keep the actual search/result entry in the back stack, including its
        // query and grid scroll state, and remember the card that opened details.
        entry?.id?.let { pageId -> runCatching { pageRequest(pageId).saveFocusedChild() } }
        navController.navigate(Routes.details(type, id))
    }

    fun closeDetails(pageId: String) {
        // Ignore a second Back from a destination that is already transitioning
        // away; it must not also pop the search/results page underneath it.
        if (navController.currentBackStackEntry?.id != pageId) return
        val previousPage = navController.previousBackStackEntry?.id
        if (navController.popBackStack()) pendingPageRestore = previousPage
    }

    fun restorePageFocus() {
        pendingDockFocus = null
        dockOpen = false
        val focus = entry?.id?.let(::pageRequest) ?: return
        runCatching {
            if (!focus.restoreFocusedChild()) focus.requestFocus()
        }
    }

    fun focusDock() {
        if (!showDock) return
        val pageId = entry?.id ?: return
        runCatching { pageRequest(pageId).saveFocusedChild() }
        dockOpen = true
        pendingDockFocus = pageId
    }

    LaunchedEffect(pendingDockFocus, dockInteractive, dockLaidOut, entry?.id) {
        val requestedPage = pendingDockFocus ?: return@LaunchedEffect
        if (!dockInteractive || !dockLaidOut || requestedPage != entry?.id) return@LaunchedEffect
        // A hidden dock has no attached FocusRequester until its first layout.
        // Recheck after the frame: a second Back or route change cancels opening.
        withFrameNanos { }
        if (!dockOpen || pendingDockFocus != requestedPage ||
            navController.currentBackStackEntry?.id != requestedPage) return@LaunchedEffect
        runCatching { dockRequests.getValue(selectedDockRoute).requestFocus() }
        withFrameNanos { }
        if (dockOpen && pendingDockFocus == requestedPage &&
            navController.currentBackStackEntry?.id == requestedPage) {
            pendingDockFocus = null
            // Do not leave a visible dock without control if a destination's
            // own focus request won the race or the dock could not take focus.
            if (!dockHasFocus) restorePageFocus()
        }
    }

    fun navigateTab(destination: String) {
        if (destination == route) {
            restorePageFocus()
        } else {
            dockOpen = false
            pendingDockFocus = null
            navController.navigate(destination) {
                popUpTo(Routes.HOME) { saveState = true }
                launchSingleTop = true
                // Home is a destination, not a saved detail stack: selecting its
                // icon while browsing a title must actually return to Home.
                restoreState = destination != Routes.HOME
            }
            // Activating a tab hands control to that page. Preserve its saved
            // child when available, and never show the dock over page browsing.
            pendingPageRestore = navController.currentBackStackEntry?.id
        }
    }
    fun toggleDockFocus() {
        // Usually the IME consumes Back first; preserve that priority on remotes
        // whose keyboard delegates it to the Activity instead.
        if (imeVisible) keyboard?.hide()
        else if (dockOpen || dockHasFocus || pendingDockFocus != null) restorePageFocus()
        else focusDock()
    }

    // Main browsing pages show/focus or hide/unfocus the dock. Details pops its entry;
    // dialogs and players retain their existing Back behavior.
    BackHandler(enabled = showDock) {
        toggleDockFocus()
    }
    Box(Modifier.fillMaxSize().background(VelvetColors.Background).onPreviewKeyEvent { event ->
        if (showDock && event.type == KeyEventType.KeyDown &&
            event.nativeKeyEvent.keyCode == android.view.KeyEvent.KEYCODE_MENU) {
            toggleDockFocus()
            true
        } else false
    }) {
    NavHost(
        navController = navController,
        startDestination = Routes.HOME,
        modifier = Modifier.fillMaxSize().then(if (captureDockBackdrop) Modifier.dockBackdropSource(dockBackdrop) else Modifier),
    ) {
        composable(Routes.HOME) { pageEntry ->
            NavigationPage(pageRequest(pageEntry.id), onLaidOut = { laidOutPages[pageEntry.id] = true }, onBack = ::toggleDockFocus) {
                HomeScreen(
                    onItemClick = { item -> openDetails(item.type, item.id) },
                    onPlay = { target -> navController.navigate(Routes.player(target)) },
                    onProfile = onOpenProfilePicker,
                    launcherRequest = homeLauncherRequest?.forEntry(pageEntry.id),
                    onLauncherRequestHandled = {
                        if (homeLauncherRequest?.entryId == pageEntry.id) homeLauncherRequest = null
                    },
                )
            }
        }
        composable(
            Routes.DETAILS_PATTERN,
            arguments = listOf(
                navArgument("type") { type = NavType.StringType },
                navArgument("id") { type = NavType.IntType },
            ),
        ) { entry ->
            NavigationPage(pageRequest(entry.id), onLaidOut = { laidOutPages[entry.id] = true },
                onBack = { closeDetails(entry.id) }, dockVisible = false) {
            DetailsScreen(
                type = MediaType.fromKey(entry.arguments!!.getString("type")!!),
                id = entry.arguments!!.getInt("id"),
                onPlay = { target -> navController.navigate(Routes.player(target)) },
                onItemClick = { item -> openDetails(item.type, item.id) },
                onBack = { closeDetails(entry.id) },
            )
            }
        }
        composable(
            Routes.PLAYER_PATTERN,
            arguments = listOf(
                navArgument("type") { type = NavType.StringType },
                navArgument("id") { type = NavType.IntType },
                navArgument("season") { type = NavType.IntType; defaultValue = -1 },
                navArgument("episode") { type = NavType.IntType; defaultValue = -1 },
                navArgument("queue") { type = NavType.StringType; defaultValue = "" },
                navArgument("cursor") { type = NavType.IntType; defaultValue = -1 },
                navArgument("handoff") { type = NavType.StringType; defaultValue = "" },
            ),
        ) { entry ->
            val season = entry.arguments!!.getInt("season").takeIf { it >= 0 }
            val episode = entry.arguments!!.getInt("episode").takeIf { it >= 0 }
            PlayerScreen(
                target = PlayTarget(
                    mediaId = entry.arguments!!.getInt("id"),
                    type = MediaType.fromKey(entry.arguments!!.getString("type")!!),
                    season = season,
                    episode = episode,
                    queueSessionId = entry.arguments!!.getString("queue")?.takeIf { it.isNotBlank() },
                    queueIndex = entry.arguments!!.getInt("cursor").takeIf { it >= 0 },
                    handoffId = entry.arguments!!.getString("handoff")?.takeIf { it.isNotBlank() },
                ),
                onQueueNext = { target ->
                    // An advance that finishes during Back must never reopen the player.
                    if (navController.currentBackStackEntry?.id == entry.id) {
                        navController.navigate(Routes.player(target)) {
                            popUpTo(entry.destination.id) { inclusive = true }
                        }
                    }
                },
                onExit = { navController.popBackStack() },
            )
        }
        composable(Routes.SPORTS) { pageEntry ->
            NavigationPage(pageRequest(pageEntry.id), onLaidOut = { laidOutPages[pageEntry.id] = true }, onBack = ::toggleDockFocus) {
                SportsScreen(onBack = ::toggleDockFocus,
                    launcherSelection = sportsLauncherSelection?.takeIf { it.entryId == pageEntry.id },
                    onEvent = { id, title -> navController.navigate(Routes.sportsPlayer(id, title)) },
                    onSettings = { navigateTab(Routes.SETTINGS) })
            }
        }
        composable(Routes.SPORTS_PLAYER, arguments = listOf(navArgument("eventId") { type = NavType.StringType },
            navArgument("title") { type = NavType.StringType; defaultValue = "Live Sports" })) { entry ->
            SportsPlayerScreen(entry.arguments!!.getString("eventId").orEmpty(), entry.arguments!!.getString("title").orEmpty(),
                onBack = { if (navController.currentBackStackEntry?.id == entry.id) navController.popBackStack() })
        }
        composable(Routes.LIVE) { pageEntry ->
            NavigationPage(pageRequest(pageEntry.id), onLaidOut = { laidOutPages[pageEntry.id] = true }, onBack = ::toggleDockFocus) {
                LiveScreen(onBack = ::toggleDockFocus,
                    onPlay = { navController.navigate(Routes.livePlayer(it)) },
                    onSettings = { navigateTab(Routes.SETTINGS) })
            }
        }
        composable(Routes.LIVE_PLAYER_PATTERN, arguments = listOf(navArgument("channelId") { type = NavType.StringType })) { entry ->
            LivePlayerScreen(channelId = entry.arguments!!.getString("channelId").orEmpty(),
                onExit = { if (navController.currentBackStackEntry?.id == entry.id) navController.popBackStack() })
        }
        composable(Routes.SEARCH) { pageEntry ->
            NavigationPage(pageRequest(pageEntry.id), onLaidOut = { laidOutPages[pageEntry.id] = true }, onBack = ::toggleDockFocus) {
                SearchScreen(
                    onItemClick = { item -> openDetails(item.type, item.id) },
                    onBack = ::toggleDockFocus,
                    onPlay = { target -> navController.navigate(Routes.player(target)) },
                )
            }
        }
        composable(Routes.SETTINGS) { pageEntry ->
            NavigationPage(pageRequest(pageEntry.id), onLaidOut = { laidOutPages[pageEntry.id] = true }, onBack = ::toggleDockFocus) {
                SettingsScreen(onBack = ::toggleDockFocus)
            }
        }
    }
    // Remain composed while hiding so the existing glass entrance has a matching
    // fade/slide exit. Input stops immediately when control returns to the page.
    AnimatedVisibility(
        visibleState = dockVisibility,
        enter = fadeIn(tween(320)) + slideInVertically(tween(420, easing = FastOutSlowInEasing)) { it / 2 },
        exit = fadeOut(tween(320)) + slideOutVertically(tween(420, easing = FastOutSlowInEasing)) { it / 2 },
        modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp),
    ) {
        DisposableEffect(Unit) {
            onDispose { dockLaidOut = false }
        }
        GlassNavigationDock(
            backdrop = dockBackdrop,
            selectedRoute = selectedDockRoute,
            requests = dockRequests,
            onReturnToContent = ::restorePageFocus,
            onNavigate = ::navigateTab,
            onExit = onExit,
            onFocusChanged = { focused ->
                val previouslyFocused = dockHasFocus
                dockHasFocus = focused && dockInteractive
                // Ignore the initial unfocused callback while opening; the
                // pending request owns that interval until the dock is laid out.
                if (!focused && previouslyFocused && pendingDockFocus == null) dockOpen = false
            },
            enabled = dockInteractive,
            modifier = Modifier.onGloballyPositioned { dockLaidOut = true },
        )
    }
    }
}
