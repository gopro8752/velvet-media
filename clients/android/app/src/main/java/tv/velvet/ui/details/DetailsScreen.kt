package tv.velvet.ui.details

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlaylistRemove
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RemoveDone
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.Button
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import tv.velvet.VelvetApp
import tv.velvet.data.model.Episode
import tv.velvet.data.model.MediaDetails
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.MediaType
import tv.velvet.data.model.PlayTarget
import tv.velvet.data.model.Season
import tv.velvet.ui.components.MediaAction
import tv.velvet.ui.components.MediaActionsSheet
import tv.velvet.ui.theme.VelvetColors
import tv.velvet.ui.navigation.LocalDockContentInset
import java.util.Locale

/**
 * Which long-press actions sheet is open, if any — one at a time, owned by
 * [DetailsScreen]. SimilarActions carries the My List membership resolved by the
 * VM *before* the sheet opens, so the toggle row renders the right label/icon.
 */
private sealed interface DetailsSheet {
    data class EpisodeActions(val episode: Episode) : DetailsSheet
    data class SeasonActions(val season: Season) : DetailsSheet
    data class SimilarActions(val item: MediaItem, val inList: Boolean) : DetailsSheet
}

/**
 * Details screen — full-bleed backdrop hero with scrims, logo-or-title, meta line,
 * Play/Resume + My List (+ Start Over) buttons; shows get season chips + episode
 * list; everyone gets a cast row and a "More Like This" poster row.
 * Long-pressing (holding d-pad center on) an episode row, season chip, or More
 * Like This card opens a [MediaActionsSheet] overlay with contextual actions.
 */
@Composable
fun DetailsScreen(
    type: MediaType,
    id: Int,
    onPlay: (PlayTarget) -> Unit,
    onItemClick: (MediaItem) -> Unit,
    onBack: () -> Unit,
) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: DetailsViewModel = viewModel(
        key = "details_${type.key}_$id",
        factory = viewModelFactory { initializer { DetailsViewModel(app.container, type, id) } },
    )
    val state by vm.state.collectAsStateWithLifecycle()
    var sheet by remember { mutableStateOf<DetailsSheet?>(null) }

    Box(Modifier.fillMaxSize().background(VelvetColors.Background)) {
        val error = state.error
        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                VelvetSpinner()
            }
            error != null -> DetailsError(message = error, onRetry = vm::load, onBack = onBack)
            state.details != null -> DetailsContent(
                state = state,
                requestInitialFocus = !vm.initialFocusPlaced,
                onInitialFocusPlaced = { vm.initialFocusPlaced = true },
                onPlay = onPlay,
                onItemClick = onItemClick,
                onToggleMyList = vm::toggleMyList,
                onStartOver = { vm.startOver(onPlay) },
                onSelectSeason = vm::selectSeason,
                onEpisodeLongClick = { episode -> sheet = DetailsSheet.EpisodeActions(episode) },
                onSeasonLongClick = { season -> sheet = DetailsSheet.SeasonActions(season) },
                onSimilarLongClick = { item ->
                    // Resolve My List membership first so the sheet's toggle row is correct.
                    vm.resolveInMyList(item) { inList ->
                        sheet = DetailsSheet.SimilarActions(item, inList)
                    }
                },
            )
        }

        // ── long-press actions sheet (drawn over everything, one at a time) ──
        val details = state.details
        val activeSheet = sheet
        if (details != null && activeSheet != null) {
            when (activeSheet) {
                is DetailsSheet.EpisodeActions -> EpisodeActionsSheet(
                    state = state,
                    showTitle = details.item.title,
                    showId = details.item.id,
                    episode = activeSheet.episode,
                    vm = vm,
                    onPlay = onPlay,
                    onDismiss = { sheet = null },
                )
                is DetailsSheet.SeasonActions -> {
                    val season = activeSheet.season
                    MediaActionsSheet(
                        title = details.item.title,
                        subtitle = season.name.ifBlank { "Season ${season.number}" },
                        actions = listOf(
                            MediaAction(Icons.Default.DoneAll, "Mark season watched") {
                                sheet = null
                                vm.markSeasonWatched(season.number)
                            },
                            MediaAction(Icons.Default.Delete, "Clear season history", destructive = true) {
                                sheet = null
                                vm.clearSeasonHistory(season.number)
                            },
                        ),
                        onDismiss = { sheet = null },
                    )
                }
                is DetailsSheet.SimilarActions -> {
                    val item = activeSheet.item
                    MediaActionsSheet(
                        title = item.title,
                        subtitle = item.year,
                        actions = listOf(
                            MediaAction(Icons.Default.Info, "Go to details") {
                                sheet = null
                                onItemClick(item)
                            },
                            MediaAction(Icons.Default.PlayArrow, "Play") {
                                sheet = null
                                // No season/episode: the player resolves next unwatched / S1 E1.
                                onPlay(PlayTarget(item.id, item.type))
                            },
                            if (activeSheet.inList) {
                                MediaAction(Icons.Default.PlaylistRemove, "Remove from My List") {
                                    sheet = null
                                    vm.toggleMyListFor(item, currentlyInList = true)
                                }
                            } else {
                                MediaAction(Icons.AutoMirrored.Filled.PlaylistAdd, "Add to My List") {
                                    sheet = null
                                    vm.toggleMyListFor(item, currentlyInList = false)
                                }
                            },
                        ),
                        onDismiss = { sheet = null },
                    )
                }
            }
        }
    }
}

/**
 * Episode long-press sheet. Watched/in-progress flags are read from [state] at
 * composition time, so the toggle row's label is current even if the watched set
 * changed since the long-press.
 */
@Composable
private fun EpisodeActionsSheet(
    state: DetailsUiState,
    showTitle: String,
    showId: Int,
    episode: Episode,
    vm: DetailsViewModel,
    onPlay: (PlayTarget) -> Unit,
    onDismiss: () -> Unit,
) {
    val watched = (episode.season to episode.number) in state.watchedEpisodes
    val isInProgress = state.progress
        ?.let { it.season == episode.season && it.episode == episode.number } == true
    val actions = buildList {
        add(MediaAction(Icons.Default.PlayArrow, "Play this episode") {
            onDismiss()
            onPlay(PlayTarget(showId, MediaType.SHOW, episode.season, episode.number))
        })
        if (watched) {
            add(MediaAction(Icons.Default.RemoveDone, "Mark unwatched") {
                onDismiss()
                vm.unmarkEpisodeWatched(episode)
            })
        } else {
            add(MediaAction(Icons.Default.Check, "Mark watched") {
                onDismiss()
                vm.markEpisodeWatched(episode)
            })
        }
        add(MediaAction(Icons.Default.DoneAll, "Mark all up to here watched") {
            onDismiss()
            vm.markWatchedUpTo(episode)
        })
        // Only the episode that owns the saved resume position can clear it.
        if (isInProgress) {
            add(MediaAction(Icons.Default.Delete, "Clear episode progress", destructive = true) {
                onDismiss()
                vm.clearEpisodeProgress()
            })
        }
    }
    MediaActionsSheet(
        title = showTitle,
        subtitle = "S${episode.season} E${episode.number} — ${episode.title}",
        actions = actions,
        onDismiss = onDismiss,
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DetailsContent(
    state: DetailsUiState,
    requestInitialFocus: Boolean,
    onInitialFocusPlaced: () -> Unit,
    onPlay: (PlayTarget) -> Unit,
    onItemClick: (MediaItem) -> Unit,
    onToggleMyList: () -> Unit,
    onStartOver: () -> Unit,
    onSelectSeason: (Int) -> Unit,
    onEpisodeLongClick: (Episode) -> Unit,
    onSeasonLongClick: (Season) -> Unit,
    onSimilarLongClick: (MediaItem) -> Unit,
) {
    val details = state.details ?: return
    val playFocusRequester = remember { FocusRequester() }
    val listState = rememberLazyListState()
    val heroFocused = remember(details.item.id) { mutableStateOf(false) }
    val heroHeightPx = remember(details.item.id) { mutableStateOf(0) }
    val density = LocalDensity.current
    val dockInset = LocalDockContentInset.current
    val focusScroll = remember(density, dockInset, heroFocused, heroHeightPx) {
        val topInsetPx = with(density) { 18.dp.toPx() }
        val bottomInsetPx = with(density) { (dockInset + 18.dp).toPx() }
        object : BringIntoViewSpec {
            override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
                val bottom = (containerSize - bottomInsetPx).coerceAtLeast(topInsetPx)
                // Reveal the whole compact hero, not just a control's bounds.
                // A very long expanded synopsis still needs ordinary scrolling
                // so the text and actions remain reachable above the dock.
                if (heroFocused.value && heroHeightPx.value <= bottom) return 0f
                // Keep visible controls still. A fixed pivot scrolls the initial
                // Play button upward even when it fits, cutting off the title.
                return when {
                    offset < topInsetPx || size > bottom - topInsetPx -> offset - topInsetPx
                    offset + size > bottom -> offset + size - bottom
                    else -> 0f
                }
            }
        }
    }

    LaunchedEffect(heroFocused.value, heroHeightPx.value) {
        val availableHeight = listState.layoutInfo.viewportSize.height -
            with(density) { (dockInset + 18.dp).toPx() }
        if (heroFocused.value && heroHeightPx.value in 1..availableHeight.toInt() &&
            (listState.firstVisibleItemIndex != 0 || listState.firstVisibleItemScrollOffset != 0)
        ) {
            listState.animateScrollToItem(0)
        }
    }

    // Initial focus lands on the Play button ONCE per backstack entry (VM flag) —
    // re-entering composition after the Player must not reset the episode position.
    LaunchedEffect(details.item.id) {
        if (requestInitialFocus) {
            if (runCatching { playFocusRequester.requestFocus() }.isSuccess) {
                onInitialFocusPlaced()
            }
        }
    }

    CompositionLocalProvider(LocalBringIntoViewSpec provides focusScroll) { LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize().focusRestorer(),
        contentPadding = PaddingValues(bottom = 27.dp + LocalDockContentInset.current),
    ) {
        item(key = "hero") {
            HeroSection(
                state = state,
                playFocusRequester = playFocusRequester,
                onPlayClick = { state.playTarget?.let(onPlay) },
                onToggleMyList = onToggleMyList,
                onStartOver = onStartOver,
                onHeroFocusChanged = { heroFocused.value = it },
                onHeroHeightChanged = { heroHeightPx.value = it },
            )
        }

        if (details.item.type == MediaType.SHOW && details.seasons.any { it.number >= 1 }) {
            item(key = "seasons") {
                SeasonChipsRow(
                    seasons = details.seasons.filter { it.number >= 1 },
                    selectedSeason = state.selectedSeason,
                    onSelect = onSelectSeason,
                    onLongPress = onSeasonLongClick,
                    modifier = Modifier.padding(top = 14.dp),
                )
            }
            if (state.episodesLoading) {
                items(count = 4, key = { "ep_placeholder_$it" }) { index ->
                    EpisodeRowPlaceholder(
                        modifier = Modifier.padding(top = if (index == 0) 12.dp else 4.dp),
                    )
                }
            } else if (state.episodes.isEmpty() && state.selectedSeason != null) {
                item(key = "ep_empty") {
                    Text(
                        text = "No episodes found for this season.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = VelvetColors.TextTertiary,
                        modifier = Modifier.padding(start = 48.dp, top = 18.dp),
                    )
                }
            } else {
                items(state.episodes, key = { "ep_${it.season}_${it.number}" }) { episode ->
                    val watched = (episode.season to episode.number) in state.watchedEpisodes
                    val progressFraction = state.progress
                        ?.takeIf {
                            it.season == episode.season && it.episode == episode.number &&
                                it.durationMs > 0 && it.positionMs > 0
                        }
                        ?.let { (it.positionMs.toFloat() / it.durationMs.toFloat()).coerceIn(0f, 1f) }
                    EpisodeRow(
                        episode = episode,
                        watched = watched,
                        progressFraction = progressFraction,
                        onClick = {
                            onPlay(PlayTarget(details.item.id, MediaType.SHOW, episode.season, episode.number))
                        },
                        onLongClick = { onEpisodeLongClick(episode) },
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }

        if (details.cast.isNotEmpty()) {
            item(key = "cast") {
                CastRow(cast = details.cast, modifier = Modifier.padding(top = 28.dp))
            }
        }
        if (details.similar.isNotEmpty()) {
            item(key = "similar") {
                SimilarRow(
                    similar = details.similar,
                    onItemClick = onItemClick,
                    onItemLongClick = onSimilarLongClick,
                    modifier = Modifier.padding(top = 28.dp),
                )
            }
        }
    } }
}

// ── hero ─────────────────────────────────────────────────────────────────────

@Composable
private fun HeroSection(
    state: DetailsUiState,
    playFocusRequester: FocusRequester,
    onPlayClick: () -> Unit,
    onToggleMyList: () -> Unit,
    onStartOver: () -> Unit,
    onHeroFocusChanged: (Boolean) -> Unit,
    onHeroHeightChanged: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val details = state.details ?: return
    val item = details.item
    Box(modifier = modifier.fillMaxWidth()) {
        AsyncImage(
            model = ImageRequest.Builder(LocalContext.current)
                .data(item.backdropUrl ?: item.posterUrl)
                .crossfade(220)
                .build(),
            contentDescription = item.title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.matchParentSize(),
        )
        // Horizontal scrim: left ~65% fades from near-opaque background → transparent.
        Box(
            Modifier.matchParentSize().background(
                Brush.horizontalGradient(
                    0.00f to VelvetColors.Background.copy(alpha = 0.92f),
                    0.40f to VelvetColors.Background.copy(alpha = 0.55f),
                    0.65f to VelvetColors.Background.copy(alpha = 0f),
                )
            )
        )
        // Vertical scrim: blends the hero seamlessly into the page below.
        Box(
            Modifier.matchParentSize().background(
                Brush.verticalGradient(
                    0.00f to VelvetColors.Background.copy(alpha = 0f),
                    0.55f to VelvetColors.Background.copy(alpha = 0.25f),
                    1.00f to VelvetColors.Background,
                )
            )
        )
        Column(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .onSizeChanged { onHeroHeightChanged(it.height) }
                .onFocusChanged { onHeroFocusChanged(it.hasFocus) }
                .focusGroup()
                // Let the foreground determine the hero's height. A fraction
                // of the dock-padded viewport can be shorter than this stack.
                .padding(start = 48.dp, top = 40.dp, end = 48.dp, bottom = 18.dp),
        ) {
            if (item.logoUrl != null) {
                AsyncImage(
                    model = ImageRequest.Builder(LocalContext.current)
                        .data(item.logoUrl)
                        .crossfade(220)
                        .build(),
                    contentDescription = item.title,
                    contentScale = ContentScale.Fit,
                    alignment = Alignment.BottomStart,
                    modifier = Modifier.fillMaxWidth(0.5f).height(76.dp),
                )
            } else {
                Text(
                    text = item.title,
                    style = MaterialTheme.typography.displayMedium,
                    color = VelvetColors.TextPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.widthIn(max = 560.dp),
                )
            }
            details.tagline?.takeIf { it.isNotBlank() }?.let { tagline ->
                Spacer(Modifier.height(8.dp))
                Text(
                    text = tagline,
                    style = MaterialTheme.typography.bodyMedium,
                    fontStyle = FontStyle.Italic,
                    color = VelvetColors.TextSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(10.dp))
            MetaLine(details)
            item.overview?.takeIf { it.isNotBlank() }?.let { overview ->
                Spacer(Modifier.height(10.dp))
                ExpandableOverview(
                    mediaId = item.id,
                    overview = overview,
                    modifier = Modifier.fillMaxWidth(0.58f)
                        .focusProperties { down = playFocusRequester },
                )
            }
            Spacer(Modifier.height(16.dp))
            ActionButtons(
                state = state,
                playFocusRequester = playFocusRequester,
                onPlayClick = onPlayClick,
                onToggleMyList = onToggleMyList,
                onStartOver = onStartOver,
            )
        }
    }
}

/** Same compact synopsis at rest; the remote can reveal and collapse the full text. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ExpandableOverview(mediaId: Int, overview: String, modifier: Modifier = Modifier) {
    var expanded by rememberSaveable(mediaId) { mutableStateOf(false) }
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val bringIntoView = remember { BringIntoViewRequester() }
    var measuredHeight by remember { mutableStateOf(0) }
    val shape = RoundedCornerShape(4.dp)

    LaunchedEffect(expanded, focused, measuredHeight) {
        if (expanded && focused && measuredHeight > 0) {
            // Expanding preserves focus, so focus-driven scrolling alone will
            // not reveal the new bounds. Wait for layout before requesting them.
            withFrameNanos { }
            bringIntoView.bringIntoView()
        }
    }

    Text(
        text = overview,
        style = MaterialTheme.typography.bodyMedium,
        color = VelvetColors.TextSecondary,
        maxLines = if (expanded) Int.MAX_VALUE else 5,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .onSizeChanged { measuredHeight = it.height }
            .bringIntoViewRequester(bringIntoView)
            .then(if (focused) Modifier.background(VelvetColors.SurfaceHighlight.copy(alpha = 0.65f), shape)
                else Modifier)
            .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                role = Role.Button,
                onClickLabel = if (expanded) "Collapse description" else "Expand description",
            ) { expanded = !expanded },
    )
}

@Composable
private fun MetaLine(details: MediaDetails) {
    val item = details.item
    val runtimeLabel = when (item.type) {
        MediaType.MOVIE -> item.runtimeMinutes?.takeIf { it > 0 }?.let { formatRuntime(it) }
        MediaType.SHOW -> seasonCountLabel(details)
    }
    val entries = mutableListOf<@Composable () -> Unit>()
    details.certification?.takeIf { it.isNotBlank() }?.let { cert ->
        entries += { CertificationChip(cert) }
    }
    item.year?.let { year -> entries += { MetaText(year) } }
    runtimeLabel?.let { label -> entries += { MetaText(label) } }
    item.rating?.takeIf { it > 0 }?.let { rating ->
        entries += {
            Text(
                text = "★ " + String.format(Locale.US, "%.1f", rating),
                style = MaterialTheme.typography.labelLarge,
                color = VelvetColors.Gold,
            )
        }
    }
    if (item.genres.isNotEmpty()) {
        entries += { MetaText(item.genres.take(3).joinToString(", ")) }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        entries.forEachIndexed { index, entry ->
            if (index > 0) {
                Text(
                    text = "  ·  ",
                    style = MaterialTheme.typography.labelLarge,
                    color = VelvetColors.TextTertiary,
                )
            }
            entry()
        }
    }
}

@Composable
private fun MetaText(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelLarge,
        color = VelvetColors.TextSecondary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun CertificationChip(certification: String) {
    Box(
        modifier = Modifier
            .border(1.dp, VelvetColors.TextTertiary, RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(
            text = certification,
            style = MaterialTheme.typography.labelSmall,
            color = VelvetColors.TextSecondary,
        )
    }
}

private fun seasonCountLabel(details: MediaDetails): String? {
    val count = details.seasons.count { it.number >= 1 }.takeIf { it > 0 }
        ?: details.seasons.size.takeIf { it > 0 }
        ?: return null
    return if (count == 1) "1 Season" else "$count Seasons"
}

// ── buttons ──────────────────────────────────────────────────────────────────

@Composable
private fun ActionButtons(
    state: DetailsUiState,
    playFocusRequester: FocusRequester,
    onPlayClick: () -> Unit,
    onToggleMyList: () -> Unit,
    onStartOver: () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Button(
            onClick = onPlayClick,
            colors = detailsButtonColors(),
            modifier = Modifier.focusRequester(playFocusRequester),
        ) {
            Icon(
                imageVector = Icons.Default.PlayArrow,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(text = state.playLabel, style = MaterialTheme.typography.labelLarge)
        }
        Button(onClick = onToggleMyList, colors = detailsButtonColors()) {
            Icon(
                imageVector = if (state.inMyList) Icons.Default.Check else Icons.Default.Add,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = if (state.inMyList) "In List" else "My List",
                style = MaterialTheme.typography.labelLarge,
            )
        }
        if (state.showStartOver) {
            Button(onClick = onStartOver, colors = detailsButtonColors()) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(text = "Start Over", style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

@Composable
private fun detailsButtonColors() = ButtonDefaults.colors(
    containerColor = VelvetColors.SurfaceHighlight,
    contentColor = VelvetColors.TextPrimary,
    focusedContainerColor = VelvetColors.TextPrimary,
    focusedContentColor = VelvetColors.Background,
    pressedContainerColor = VelvetColors.TextPrimary,
    pressedContentColor = VelvetColors.Background,
)

// ── loading / error states ───────────────────────────────────────────────────

@Composable
private fun VelvetSpinner(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "detailsSpinner")
    val angle by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(durationMillis = 900, easing = LinearEasing)),
        label = "detailsSpinnerAngle",
    )
    Canvas(modifier.size(44.dp)) {
        drawArc(
            color = VelvetColors.Accent,
            startAngle = angle,
            sweepAngle = 270f,
            useCenter = false,
            style = Stroke(width = 4.dp.toPx(), cap = StrokeCap.Round),
        )
    }
}

@Composable
private fun DetailsError(message: String, onRetry: () -> Unit, onBack: () -> Unit) {
    val retryFocusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { retryFocusRequester.requestFocus() } }
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 48.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "Something went wrong",
            style = MaterialTheme.typography.headlineMedium,
            color = VelvetColors.TextPrimary,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = VelvetColors.TextSecondary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(20.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = onRetry,
                colors = detailsButtonColors(),
                modifier = Modifier.focusRequester(retryFocusRequester),
            ) {
                Text(text = "Try Again", style = MaterialTheme.typography.labelLarge)
            }
            Button(onClick = onBack, colors = detailsButtonColors()) {
                Text(text = "Go Back", style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}
