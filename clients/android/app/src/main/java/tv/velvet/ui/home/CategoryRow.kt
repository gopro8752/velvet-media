package tv.velvet.ui.home

import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import kotlinx.coroutines.launch
import tv.velvet.data.categories.Category
import tv.velvet.data.categories.CategoryItem
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.components.CardDefaults
import tv.velvet.ui.components.HorizontalPivotLocal
import tv.velvet.ui.components.LandscapeCard
import tv.velvet.ui.theme.VelvetColors

/** Episodes keep their own identities: two Halloween episodes of a show are two cards. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun CategoryRow(category: Category, onPlay: (CategoryItem) -> Unit, onPlayAll: (Boolean) -> Unit,
    onLongClick: ((CategoryItem) -> Unit)? = null, onDelete: (() -> Unit)? = null) {
    val playAllFocus = remember(category.id) { FocusRequester() }
    val shuffleFocus = remember(category.id) { FocusRequester() }
    val deleteFocus = remember(category.id) { FocusRequester() }
    val cardFocus = remember(category.id) { mutableMapOf<String, FocusRequester>() }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    var lastCardKey by rememberSaveable(category.id) { mutableStateOf<String?>(null) }
    var focusedCardKey by remember(category.id) { mutableStateOf<String?>(null) }
    var headerHasFocus by remember(category.id) { mutableStateOf(false) }

    fun requester(key: String) = cardFocus.getOrPut(key) { FocusRequester() }

    fun returnToCards() {
        if (category.items.isEmpty()) return
        val index = category.items.indexOfFirst { it.key == lastCardKey }.takeIf { it >= 0 }
            ?: listState.firstVisibleItemIndex.coerceIn(category.items.indices)
        val key = category.items[index].key
        val target = requester(key)
        // The previously focused card normally remains composed while its header is
        // focused. Preserve its scroll position instead of jumping to card zero.
        if (listState.layoutInfo.visibleItemsInfo.any { it.key == key }) {
            runCatching { target.requestFocus() }
            if (focusedCardKey == key) return
        }
        scope.launch {
            // A restored/scrolled lazy rail can dispose that card. Recompose its
            // actual index before requesting focus; never target a detached node.
            if (listState.layoutInfo.visibleItemsInfo.none { it.key == key }) listState.scrollToItem(index)
            repeat(3) {
                withFrameNanos { }
                // If the user pressed Up meanwhile, do not steal focus back.
                if (!headerHasFocus) return@launch
                runCatching { target.requestFocus() }
                if (focusedCardKey == key) return@launch
            }
        }
    }

    val headerDown = Modifier.onPreviewKeyEvent { event ->
        if (event.key == Key.DirectionDown) {
            if (event.type == KeyEventType.KeyDown) returnToCards()
            true
        } else false
    }

    Column(Modifier.fillMaxWidth().padding(top = 22.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 48.dp, end = 48.dp, bottom = 10.dp)
            .onFocusChanged { headerHasFocus = it.hasFocus }.focusRestorer().focusGroup(),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(category.title, style = MaterialTheme.typography.headlineSmall,
                color = VelvetColors.TextPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f))
            Button(onClick = { onPlayAll(false) }, colors = velvetButtonColors(),
                modifier = Modifier.focusRequester(playAllFocus).focusProperties {
                    left = FocusRequester.Cancel
                    right = shuffleFocus
                    // Up intentionally uses normal spatial search into the previous row.
                }.then(headerDown)) { Text("Play all") }
            Button(onClick = { onPlayAll(true) }, colors = velvetButtonColors(),
                modifier = Modifier.focusRequester(shuffleFocus).focusProperties {
                    left = playAllFocus
                    right = if (onDelete != null) deleteFocus else FocusRequester.Cancel
                }.then(headerDown)) { Text("Shuffle") }
            onDelete?.let { delete ->
                Button(onClick = delete, colors = velvetButtonColors(),
                    modifier = Modifier.focusRequester(deleteFocus).focusProperties {
                        left = shuffleFocus
                        right = FocusRequester.Cancel
                    }.then(headerDown)) { Text("Delete") }
            }
        }
        HorizontalPivotLocal {
            LazyRow(state = listState, contentPadding = PaddingValues(horizontal = 48.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier.focusRestorer {
                    // Card zero may be far offscreen. The fallback must be attached
                    // to a currently visible child when re-entering a scrolled rail.
                    val visible = listState.layoutInfo.visibleItemsInfo.map { it.key }
                    val key = lastCardKey?.takeIf { it in visible }
                        ?: visible.firstOrNull() as? String
                        ?: category.items.firstOrNull()?.key
                    key?.let(::requester) ?: playAllFocus
                }) {
                itemsIndexed(category.items, key = { _, item -> item.key }) { _, item ->
                    Column {
                        LandscapeCard(item.mediaItem(), onClick = { onPlay(item) },
                            onLongClick = onLongClick?.let { { it(item) } },
                            modifier = Modifier.focusRequester(requester(item.key))
                                .focusProperties { up = playAllFocus }
                                .onFocusChanged {
                                    if (it.hasFocus) {
                                        lastCardKey = item.key
                                        focusedCardKey = item.key
                                    } else if (focusedCardKey == item.key) focusedCardKey = null
                                })
                        if (item.episode != null) Text(
                            "S${item.season} E${item.episode} · ${item.episodeTitle.orEmpty()}",
                            style = MaterialTheme.typography.labelSmall, color = VelvetColors.TextSecondary,
                            maxLines = 2, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.width(CardDefaults.LandscapeWidth))
                    }
                }
            }
        }
    }
}
