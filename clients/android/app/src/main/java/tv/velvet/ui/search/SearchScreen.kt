package tv.velvet.ui.search

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Info
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import tv.velvet.VelvetApp
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.PlayTarget
import tv.velvet.ui.components.MediaAction
import tv.velvet.ui.components.MediaActionsSheet
import tv.velvet.ui.components.PosterCard
import tv.velvet.ui.navigation.LocalDockContentInset
import tv.velvet.ui.theme.VelvetColors

private const val GRID_COLUMNS = 5

@Composable
fun SearchScreen(
    onItemClick: (MediaItem) -> Unit,
    onBack: () -> Unit,
    onPlay: ((PlayTarget) -> Unit)? = null,
) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: SearchViewModel = viewModel(
        factory = viewModelFactory { initializer { SearchViewModel(app.container) } }
    )
    val state by vm.state.collectAsStateWithLifecycle()
    val actionsFor by vm.actionsFor.collectAsStateWithLifecycle()
    val focusManager = LocalFocusManager.current

    // Auto-focus + keyboard only on FIRST entry (survives the trip to Details and
    // back via the backstack entry's saved state) — returning from a result must not
    // steal focus from the grid or pop the keyboard over it.
    var initialFocusDone by rememberSaveable { mutableStateOf(false) }

    BackHandler { onBack() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(VelvetColors.Background),
    ) {
        SearchField(
            query = state.query,
            onQueryChange = vm::onQueryChange,
            autoFocus = !initialFocusDone,
            onAutoFocused = { initialFocusDone = true },
            onSubmit = {
                if (state.results.isNotEmpty()) focusManager.moveFocus(FocusDirection.Down)
            },
            onDpadDown = { focusManager.moveFocus(FocusDirection.Down) },
            modifier = Modifier.padding(start = 48.dp, end = 48.dp, top = 24.dp),
        )

        val trimmed = state.query.trim()
        when {
            trimmed.length < 2 -> SearchPrompt(modifier = Modifier.fillMaxSize())

            state.results.isEmpty() && state.searching -> SearchStatus(
                text = "Searching…",
                modifier = Modifier.fillMaxSize(),
            )

            state.results.isEmpty() && state.resultsFor.isNotEmpty() -> SearchStatus(
                text = "No results for “${state.resultsFor}”",
                subText = "Check the spelling or try a different title.",
                modifier = Modifier.fillMaxSize(),
            )

            state.results.isEmpty() -> SearchPrompt(modifier = Modifier.fillMaxSize())

            else -> SearchResultsGrid(
                results = state.results,
                onItemClick = onItemClick,
                onItemLongClick = vm::openActions,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }

    // Long-press context menu for a result. Lives in its own window — the grid keeps
    // its scroll/focus state and the long-pressed card regains focus on dismiss.
    actionsFor?.let { subject ->
        val item = subject.item
        MediaActionsSheet(
            title = item.title,
            subtitle = null,
            actions = listOf(
                MediaAction(icon = Icons.Outlined.Info, label = "Go to details") {
                    onItemClick(item)
                },
                MediaAction(icon = Icons.Filled.PlayArrow, label = "Play") {
                    // Plain target: shows resolve to the next unwatched episode
                    // downstream. Until the caller wires onPlay, fall back to Details.
                    val target = PlayTarget(mediaId = item.id, type = item.type)
                    onPlay?.invoke(target) ?: onItemClick(item)
                },
                MediaAction(
                    icon = if (subject.inMyList) Icons.Filled.Remove else Icons.Filled.Add,
                    label = if (subject.inMyList) "Remove from My List" else "Add to My List",
                ) { vm.toggleMyList(item) },
            ),
            onDismiss = vm::dismissActions,
        )
    }
}

/**
 * Velvet-styled search input: SurfaceElevated pill, search icon, hint, white cursor.
 * Auto-focuses on FIRST open only ([autoFocus]) so the Shield remote keyboard pops
 * immediately — but never again when returning from a result's Details.
 */
@Composable
private fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    autoFocus: Boolean,
    onAutoFocused: () -> Unit,
    onSubmit: () -> Unit,
    onDpadDown: () -> Boolean,
    modifier: Modifier = Modifier,
) {
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(12.dp)

    LaunchedEffect(Unit) {
        if (autoFocus) {
            runCatching { focusRequester.requestFocus() }
            keyboard?.show()
            onAutoFocused()
        }
    }

    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = MaterialTheme.typography.titleMedium.copy(color = VelvetColors.TextPrimary),
        cursorBrush = SolidColor(VelvetColors.FocusRing),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = {
            keyboard?.hide()
            onSubmit()
        }),
        modifier = modifier
            .fillMaxWidth()
            .focusRequester(focusRequester)
            .onFocusChanged { focused = it.isFocused }
            // A remote has no Tab key: DPAD DOWN must escape the field to the results
            // grid (the IME, when open, consumes dpad before this and that's fine).
            .onPreviewKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown && event.key == Key.DirectionDown) {
                    keyboard?.hide()
                    onDpadDown()
                } else false
            },
        decorationBox = { innerTextField ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(shape)
                    .background(VelvetColors.SurfaceElevated)
                    .border(
                        width = 2.dp,
                        color = if (focused) VelvetColors.FocusRing else Color.Transparent,
                        shape = shape,
                    )
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.Search,
                    contentDescription = null,
                    tint = if (focused) VelvetColors.TextPrimary else VelvetColors.TextTertiary,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(12.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) {
                        Text(
                            text = "Search movies & shows",
                            style = MaterialTheme.typography.titleMedium,
                            color = VelvetColors.TextTertiary,
                        )
                    }
                    innerTextField()
                }
            }
        },
    )
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun SearchResultsGrid(
    results: List<MediaItem>,
    onItemClick: (MediaItem) -> Unit,
    onItemLongClick: (MediaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(GRID_COLUMNS),
        contentPadding = PaddingValues(start = 48.dp, end = 48.dp, top = 20.dp, bottom = 27.dp + LocalDockContentInset.current),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
        // Focus returns to the previously focused result when re-entering the grid.
        modifier = modifier.focusRestorer(),
    ) {
        items(results, key = { "${it.type.key}-${it.id}" }) { item ->
            // PosterCard has a fixed width; center it inside the (wider) grid cell.
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                PosterCard(
                    item = item,
                    onClick = { onItemClick(item) },
                    onLongClick = { onItemLongClick(item) },
                )
            }
        }
    }
}

/** Idle empty state: invites the user to type. */
@Composable
private fun SearchPrompt(modifier: Modifier = Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                imageVector = Icons.Default.Search,
                contentDescription = null,
                tint = VelvetColors.SurfaceHighlight,
                modifier = Modifier.size(56.dp),
            )
            Spacer(Modifier.height(14.dp))
            Text(
                text = "Search movies & shows",
                style = MaterialTheme.typography.titleLarge,
                color = VelvetColors.TextSecondary,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                text = "Type at least 2 characters to search",
                style = MaterialTheme.typography.bodySmall,
                color = VelvetColors.TextTertiary,
            )
        }
    }
}

/** Centered status text — used for "Searching…" and "No results". */
@Composable
private fun SearchStatus(
    text: String,
    modifier: Modifier = Modifier,
    subText: String? = null,
) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = text,
                style = MaterialTheme.typography.titleLarge,
                color = VelvetColors.TextSecondary,
            )
            if (subText != null) {
                Spacer(Modifier.height(6.dp))
                Text(
                    text = subText,
                    style = MaterialTheme.typography.bodySmall,
                    color = VelvetColors.TextTertiary,
                )
            }
        }
    }
}
