package tv.velvet.ui.home

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.outlined.Info
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.type
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.Border
import androidx.tv.material3.Button
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import tv.velvet.VelvetApp
import tv.velvet.data.categories.Category
import tv.velvet.data.categories.ownsHalloweenCategory
import tv.velvet.data.categories.CategoryItem
import tv.velvet.data.local.ProfileEntity
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget
import tv.velvet.data.model.RowStyle
import tv.velvet.ui.components.MediaAction
import tv.velvet.ui.components.MediaActionsSheet
import tv.velvet.ui.components.VerticalPivotLocal
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.profile.ProfileAvatar
import tv.velvet.ui.navigation.LocalDockContentInset
import tv.velvet.ui.theme.VelvetColors
import tv.velvet.ui.theme.VelvetFonts

/**
 * Home — immersive hero billboard over a full-screen LazyColumn of rows:
 * Continue Watching, My List, then the user-ordered TMDB rows, each loading
 * independently (shimmer while loading, silent collapse when failed/empty).
 */
@Composable
fun HomeScreen(
    onItemClick: (MediaItem) -> Unit,
    onPlay: (PlayTarget) -> Unit,
    onProfile: () -> Unit,
    launcherRequest: tv.velvet.data.launcher.LauncherRequest? = null,
    onLauncherRequestHandled: () -> Unit = {},
) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: HomeViewModel = viewModel(
        factory = viewModelFactory { initializer { HomeViewModel(app.container) } }
    )

    val categoryProfileId by vm.categoryProfileId.collectAsStateWithLifecycle()
    val halloweenSnapshot by vm.halloween.collectAsStateWithLifecycle()
    val showHalloween = ownsHalloweenCategory(categoryProfileId)
    // A retained StateFlow emission cannot flash Me's rail on another profile.
    val halloween = halloweenSnapshot.takeIf { showHalloween }
    val generatedCategories by vm.generatedCategories.collectAsStateWithLifecycle()
    val queuePreparing by vm.queuePreparing.collectAsStateWithLifecycle()
    val queueError by vm.queueError.collectAsStateWithLifecycle()
    val categoryBusy by vm.categoryBusy.collectAsStateWithLifecycle()
    val categoryError by vm.categoryError.collectAsStateWithLifecycle()
    val halloweenFailed by vm.halloweenFailed.collectAsStateWithLifecycle()
    var categoryDialog by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(launcherRequest?.id) {
        val request = launcherRequest ?: return@LaunchedEffect
        when (request.destination) {
            "create" -> categoryDialog = true
            "category" -> request.categoryId?.let { vm.playCategoryById(it, request.shuffle, onPlay) }
        }
        onLauncherRequestHandled()
    }
    var categoryActions by remember(categoryProfileId) { mutableStateOf<Pair<Category, CategoryItem>?>(null) }
    var categoryToDelete by remember(categoryProfileId) { mutableStateOf<Category?>(null) }
    var categoryDeleting by remember(categoryProfileId) { mutableStateOf(false) }
    var categoryDeleteError by remember(categoryProfileId) { mutableStateOf<String?>(null) }
    var restoreCreateFocus by remember(categoryProfileId) { mutableStateOf(false) }
    val createCategoryFocus = remember { FocusRequester() }
    LaunchedEffect(restoreCreateFocus, categoryToDelete) {
        if (restoreCreateFocus && categoryToDelete == null) {
            withFrameNanos { }
            createCategoryFocus.requestFocus()
            restoreCreateFocus = false
        }
    }
    val hero by vm.hero.collectAsStateWithLifecycle()
    val heroInMyList by vm.heroInMyList.collectAsStateWithLifecycle()
    val continueWatching by vm.continueWatching.collectAsStateWithLifecycle()
    val myList by vm.myList.collectAsStateWithLifecycle()
    val tmdbRows by vm.tmdbRows.collectAsStateWithLifecycle()
    val rowStates by vm.rowStates.collectAsStateWithLifecycle()
    val homeUnavailable by vm.homeUnavailable.collectAsStateWithLifecycle()
    val actionsFor by vm.actionsFor.collectAsStateWithLifecycle()
    val activeProfile by vm.activeProfile.collectAsStateWithLifecycle()

    // Cross-device resume: pull watch state the moment Home becomes visible (he may have
    // walked up to a TV that never left this screen), and keep the pull cadence tight
    // while it stays visible. Leaving Home hands the cadence back to the 60s default.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> vm.onHomeResumed()
                Lifecycle.Event.ON_PAUSE -> vm.onHomePaused()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            vm.onHomePaused()
        }
    }

    val listState = rememberLazyListState()
    val heroFadePx = with(LocalDensity.current) { 160.dp.toPx() }
    val scrolledPastHero by remember(listState, heroFadePx) {
        derivedStateOf {
            listState.firstVisibleItemIndex > 0 ||
                listState.firstVisibleItemScrollOffset > heroFadePx
        }
    }

    // Land d-pad focus on ▶ Play once per HomeViewModel lifetime — never again on
    // back-navigation or late hero loads, which would yank focus out of a row
    // mid-browse and auto-scroll the list back to the top.
    val playFocusRequester = remember { FocusRequester() }
    val heroVisible = hero != null
    LaunchedEffect(heroVisible) {
        if (heroVisible && !vm.initialFocusPlaced) {
            if (runCatching { playFocusRequester.requestFocus() }.isSuccess) {
                vm.initialFocusPlaced = true
            }
        }
    }

    Box(Modifier.fillMaxSize().background(VelvetColors.Background).onPreviewKeyEvent { event ->
        // Some remotes route mic/search through the app; others reserve it for the system.
        if (event.type == KeyEventType.KeyUp && event.nativeKeyEvent.keyCode in setOf(
                android.view.KeyEvent.KEYCODE_VOICE_ASSIST, android.view.KeyEvent.KEYCODE_SEARCH)) {
            categoryDialog = true
            true
        } else false
    }) {
        HeroBackdrop(
            backdropUrl = hero?.backdropUrl ?: hero?.posterUrl,
            visible = !scrolledPastHero,
        )
        if (homeUnavailable && (!showHalloween || halloweenFailed) && halloween == null && generatedCategories.isEmpty()) {
            HomeUnavailableState(
                onRetry = { vm.retryFailedRows(); vm.refreshHalloween() },
                modifier = Modifier.align(Alignment.Center),
            )
        } else VerticalPivotLocal { LazyColumn(
            state = listState,
            contentPadding = PaddingValues(bottom = 27.dp + LocalDockContentInset.current),
            modifier = Modifier.fillMaxSize().focusRestorer(),
        ) {
            item(key = "hero") {
                HeroBillboard(
                    hero = hero,
                    inMyList = heroInMyList,
                    playFocusRequester = playFocusRequester,
                    createCategoryFocus = createCategoryFocus,
                    onPlay = { hero?.let { vm.play(it, onPlay) } },
                    onDetails = { hero?.let(onItemClick) },
                    onToggleMyList = vm::toggleHeroMyList,
                )
            }
            if (continueWatching.isNotEmpty()) {
                item(key = "continue_watching") {
                    ContinueWatchingRow(
                        entries = continueWatching,
                        onResume = onPlay,
                        onLongClick = { entry ->
                            vm.openActions(entry.item, ActionsSource.CONTINUE_WATCHING, entry)
                        },
                    )
                }
            }
            if (myList.isNotEmpty()) {
                item(key = "my_list") {
                    HomeRow(
                        title = "My List",
                        style = RowStyle.POSTER,
                        state = RowUiState.Loaded(myList),
                        onItemClick = onItemClick,
                        onItemLongClick = { vm.openActions(it, ActionsSource.MY_LIST) },
                    )
                }
            }
            halloween?.takeIf { it.items.isNotEmpty() }?.let { category ->
                item(key = "halloween_episodes") {
                    CategoryRow(category, onPlay = { onPlay(it.playTarget()) },
                        onPlayAll = { shuffle -> vm.playCategory(category, shuffle, onPlay) },
                        onLongClick = { categoryActions = category to it })
                }
            }
            if (showHalloween && halloween == null && !halloweenFailed) {
                item(key = "halloween_loading") {
                    HomeRow(title = "Monstober & Nick Halloween", style = RowStyle.LANDSCAPE,
                        state = RowUiState.Loading, onItemClick = {})
                }
            }
            if (showHalloween && halloween == null && halloweenFailed) {
                item(key = "halloween_retry") {
                    Button(onClick = vm::refreshHalloween, colors = velvetButtonColors(),
                        modifier = Modifier.padding(start = 48.dp, top = 22.dp)) {
                        Text("Retry Monstober & Nick Halloween")
                    }
                }
            }
            generatedCategories.forEach { category ->
                item(key = "generated_${category.id}") {
                    CategoryRow(category, onPlay = { onPlay(it.playTarget()) },
                        onPlayAll = { shuffle -> vm.playCategory(category, shuffle, onPlay) },
                        onLongClick = { categoryActions = category to it },
                        onDelete = { categoryDeleteError = null; categoryToDelete = category })
                }
            }
            tmdbRows.forEachIndexed { index, spec ->
                val state = rowStates[spec.id] ?: RowUiState.Loading
                val visible = state is RowUiState.Loading ||
                    (state is RowUiState.Loaded && state.items.isNotEmpty())
                if (visible) {
                    item(key = "row_${spec.id}") {
                        HomeRow(
                            title = spec.title,
                            style = spec.style,
                            state = state,
                            onItemClick = onItemClick,
                            onItemLongClick = { vm.openActions(it, ActionsSource.ROW) },
                            // The hero follows focus through the FIRST row only.
                            onItemFocused = if (index == 0) vm::onHeroCandidateFocused else null,
                        )
                    }
                }
            }
        } }
        HomeTopBar(
            showBackground = scrolledPastHero,
            // DOWN from the top-bar icons must always land somewhere — focus search
            // alone can strand focus there after back-navigation from Details. While
            // the hero (and its Play button) is composed at the top of the list, route
            // DOWN to it explicitly; once scrolled past (hero may be disposed), leave
            // the default search, which finds the visible rows below the bar.
            heroPlayFocusRequester = playFocusRequester
                .takeIf { heroVisible && !scrolledPastHero },
            activeProfile = activeProfile,
            onProfile = onProfile,
            onCreateCategory = { vm.categoryError.value = null; categoryDialog = true },
            createCategoryFocus = createCategoryFocus,
            modifier = Modifier.align(Alignment.TopCenter),
        )
        if (queuePreparing || queueError != null) {
            QueuePreparationDialog(queuePreparing, queueError, vm::dismissQueuePreparation)
        }
        if (categoryDialog) CreateCategoryDialog(categoryBusy, categoryError,
            onCreate = { prompt -> vm.createCategory(prompt) { categoryDialog = false } },
            onDismiss = { categoryDialog = false })
        categoryActions?.let { (category, item) ->
            MediaActionsSheet(title = item.title,
                subtitle = item.episodeTitle,
                actions = buildList {
                    add(MediaAction(Icons.Filled.PlayArrow, "Play") { onPlay(item.playTarget()) })
                    add(MediaAction(Icons.Outlined.Info, "Go to details") { onItemClick(item.mediaItem()) })
                    if (category.id != halloween?.id) add(MediaAction(Icons.Filled.Delete, "Delete category") {
                        categoryDeleteError = null
                        categoryToDelete = category
                    })
                }, onDismiss = { categoryActions = null })
        }
        categoryToDelete?.let { category ->
            DeleteCategoryDialog(title = category.title, deleting = categoryDeleting, error = categoryDeleteError,
                onDismiss = { categoryToDelete = null },
                onDelete = {
                    if (!categoryDeleting) {
                        categoryDeleting = true
                        categoryDeleteError = null
                        vm.removeCategory(category.id,
                            onRemoved = {
                                categoryDeleting = false
                                categoryToDelete = null
                                // The deleted rail no longer has a focus target. Restore to
                                // the permanent creation button, never a detached card.
                                restoreCreateFocus = true
                            },
                            onError = { categoryDeleting = false; categoryDeleteError = it })
                    }
                })
        }
        // Long-press context menu. Renders in its own window, so the LazyColumn keeps
        // its scroll/focus state and the long-pressed card regains focus on dismiss.
        actionsFor?.let { subject ->
            MediaActionsSheet(
                title = subject.item.title,
                // Continue Watching long-presses carry their progress line
                // ("S4 E5 · 41m left") into the sheet header.
                subtitle = subject.cwEntry?.label,
                actions = homeMediaActions(subject, vm, onItemClick, onPlay),
                onDismiss = vm::dismissActions,
            )
        }


    }
}

/**
 * Builds the action set for a long-pressed Home card. The My List label uses the
 * membership resolved by [HomeViewModel.openActions] before the sheet opened.
 */
private fun homeMediaActions(
    subject: ActionsFor,
    vm: HomeViewModel,
    onItemClick: (MediaItem) -> Unit,
    onPlay: (PlayTarget) -> Unit,
): List<MediaAction> {
    val item = subject.item
    val isShow = item.type == MediaType.SHOW
    val myListToggle = MediaAction(
        icon = if (subject.inMyList) Icons.Filled.Remove else Icons.Filled.Add,
        label = if (subject.inMyList) "Remove from My List" else "Add to My List",
    ) { vm.toggleMyList(item) }
    val goToDetails = MediaAction(icon = Icons.Outlined.Info, label = "Go to details") {
        onItemClick(item)
    }
    // Plain target: shows resolve to the next unwatched episode downstream.
    val play = MediaAction(icon = Icons.Filled.PlayArrow, label = "Play") {
        onPlay(PlayTarget(mediaId = item.id, type = item.type))
    }
    val cwEntry = subject.cwEntry
    return when {
        subject.source == ActionsSource.CONTINUE_WATCHING && cwEntry != null -> buildList {
            add(MediaAction(icon = Icons.Filled.PlayArrow, label = "Resume") {
                onPlay(cwEntry.target)
            })
            add(
                MediaAction(
                    icon = Icons.Filled.Replay,
                    label = if (isShow) "Start episode over" else "Start over",
                ) { vm.startOver(cwEntry, onPlay) }
            )
            add(goToDetails.copy(label = if (isShow) "Go to show" else "Go to movie"))
            add(
                MediaAction(
                    icon = Icons.Filled.Close,
                    label = "Remove from Continue Watching",
                    destructive = true,
                ) { vm.removeFromContinueWatching(item) }
            )
            if (isShow) {
                add(
                    MediaAction(
                        icon = Icons.Filled.Delete,
                        label = "Clear watch progress",
                        destructive = true,
                    ) { vm.clearAllProgress(item) }
                )
            }
            add(myListToggle)
        }
        subject.source == ActionsSource.MY_LIST -> listOf(
            goToDetails,
            play,
            MediaAction(
                icon = Icons.Filled.Delete,
                label = "Remove from My List",
                destructive = true,
            ) { vm.removeFromMyList(item) },
        )
        else -> listOf(goToDetails, play, myListToggle)
    }
}

/**
 * Full-screen friendly failure state: every TMDB row failed and there is no local
 * data to fall back on. Keeps the top bar reachable and focuses Retry by default.
 */
@Composable
private fun HomeUnavailableState(
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val retryFocusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { retryFocusRequester.requestFocus() } }
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Can't reach TMDB right now",
            style = MaterialTheme.typography.headlineMedium,
            color = VelvetColors.TextPrimary,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Check your connection, then try again.",
            style = MaterialTheme.typography.bodyMedium,
            color = VelvetColors.TextSecondary,
        )
        Spacer(Modifier.height(22.dp))
        Button(
            onClick = onRetry,
            colors = velvetButtonColors(),
            modifier = Modifier.focusRequester(retryFocusRequester),
        ) {
            Icon(
                imageVector = Icons.Filled.Refresh,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text("Retry", style = MaterialTheme.typography.labelLarge)
        }
    }
}

/**
 * Overlaid top bar — everything top-RIGHT (wordmark, then Search + Settings) so the
 * wordmark never clashes with hero title art baked into backdrops; bg fades in on
 * scroll. When [heroPlayFocusRequester] is non-null, DOWN from either icon jumps
 * straight to the hero Play button instead of relying on default focus search.
 */
@Composable
private fun HomeTopBar(
    showBackground: Boolean,
    heroPlayFocusRequester: FocusRequester?,
    activeProfile: ProfileEntity?,
    onProfile: () -> Unit,
    onCreateCategory: () -> Unit,
    createCategoryFocus: FocusRequester,
    modifier: Modifier = Modifier,
) {
    val bgAlpha by animateFloatAsState(
        targetValue = if (showBackground) 1f else 0f,
        animationSpec = tween(220),
        label = "topBarBg",
    )
    val barColor = VelvetColors.Background
    val iconEscapeModifier = if (heroPlayFocusRequester != null) {
        Modifier.focusProperties { down = heroPlayFocusRequester }
    } else {
        Modifier
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .drawBehind { drawRect(barColor.copy(alpha = 0.93f * bgAlpha)) }
            .padding(horizontal = 48.dp)
            // 24dp top = DESIGN.md overscan-safe minimum for text.
            .padding(top = 24.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Spacer(Modifier.weight(1f))
        Text(
            text = "VELVET",
            style = MaterialTheme.typography.titleLarge.copy(
                fontFamily = VelvetFonts.Display,
                letterSpacing = 6.sp,
            ),
            color = VelvetColors.TextPrimary,
        )
        Spacer(Modifier.width(18.dp))
        TopBarIconButton(
            icon = Icons.Filled.Add,
            contentDescription = "Create category",
            onClick = onCreateCategory,
            modifier = iconEscapeModifier.focusRequester(createCategoryFocus),
        )
        if (activeProfile != null) {
            Spacer(Modifier.width(14.dp))
            TopBarProfileButton(
                profile = activeProfile,
                onClick = onProfile,
                modifier = iconEscapeModifier,
            )
        }
    }
}

/** Small colored profile avatar in the top bar; selecting re-opens the picker. */
@Composable
private fun TopBarProfileButton(
    profile: ProfileEntity,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(9.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = VelvetColors.Background.copy(alpha = 0f),
            focusedContainerColor = VelvetColors.Background.copy(alpha = 0f),
            pressedContainerColor = VelvetColors.Background.copy(alpha = 0f),
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = RoundedCornerShape(9.dp),
            ),
        ),
        glow = ClickableSurfaceDefaults.glow(
            focusedGlow = Glow(
                elevationColor = VelvetColors.FocusRing.copy(alpha = 0.3f),
                elevation = 12.dp,
            ),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.1f),
        modifier = modifier.size(36.dp),
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            ProfileAvatar(profile = profile, size = 32.dp)
        }
    }
}

@Composable
private fun TopBarIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    Box(modifier = modifier.size(36.dp), contentAlignment = Alignment.Center) {
    Surface(
        onClick = onClick,
        interactionSource = interactionSource,
        shape = ClickableSurfaceDefaults.shape(CircleShape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = VelvetColors.Surface.copy(alpha = 0.55f),
            focusedContainerColor = VelvetColors.SurfaceHighlight,
            pressedContainerColor = VelvetColors.SurfaceHighlight,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = CircleShape,
            ),
        ),
        glow = ClickableSurfaceDefaults.glow(
            focusedGlow = Glow(
                elevationColor = VelvetColors.FocusRing.copy(alpha = 0.3f),
                elevation = 12.dp,
            ),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.1f),
        modifier = Modifier.fillMaxSize(),
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = contentDescription,
                tint = if (focused) VelvetColors.TextPrimary else VelvetColors.TextSecondary,
                modifier = Modifier.size(20.dp),
            )
        }
    }
    if (focused) {
        Text(
            contentDescription,
            style = MaterialTheme.typography.labelSmall,
            color = VelvetColors.TextPrimary,
            modifier = Modifier.align(Alignment.BottomCenter).offset(y = 24.dp).wrapContentWidth(unbounded = true),
        )
    }
    }
}
