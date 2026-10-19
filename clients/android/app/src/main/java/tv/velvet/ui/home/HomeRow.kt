package tv.velvet.ui.home

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.PlayTarget
import tv.velvet.data.model.RowStyle
import tv.velvet.ui.components.CardDefaults
import tv.velvet.ui.components.ContinueWatchingCard
import tv.velvet.ui.components.HorizontalPivotLocal
import tv.velvet.ui.components.LandscapeCard
import tv.velvet.ui.components.PosterCard
import tv.velvet.ui.components.Top10Card
import tv.velvet.ui.theme.VelvetColors

/**
 * One titled home row. Loading shows shimmer placeholders; Loaded renders the
 * style-appropriate cards from ui/components/MediaCards.kt. Failed renders nothing
 * (the caller also collapses failed/empty rows entirely, header included).
 */
@Composable
fun HomeRow(
    title: String,
    style: RowStyle,
    state: RowUiState,
    onItemClick: (MediaItem) -> Unit,
    onItemLongClick: ((MediaItem) -> Unit)? = null,
    onItemFocused: ((MediaItem) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth().padding(top = 22.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.headlineSmall,
            color = VelvetColors.TextPrimary,
            modifier = Modifier.padding(start = 48.dp, bottom = 10.dp),
        )
        when (state) {
            is RowUiState.Loaded ->
                MediaItemsRow(style, state.items, onItemClick, onItemLongClick, onItemFocused)
            RowUiState.Loading -> RowPlaceholder(style)
            RowUiState.Failed -> Unit
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun MediaItemsRow(
    style: RowStyle,
    items: List<MediaItem>,
    onItemClick: (MediaItem) -> Unit,
    onItemLongClick: ((MediaItem) -> Unit)?,
    onItemFocused: ((MediaItem) -> Unit)?,
) {
    // Attached to the FIRST card (index 0 always composes first in a LazyRow), so the
    // restorer's fallback target is guaranteed to exist whenever the row has items.
    val firstItemRequester = remember { FocusRequester() }
    HorizontalPivotLocal { LazyRow(
        contentPadding = PaddingValues(horizontal = 48.dp),
        horizontalArrangement = Arrangement.spacedBy(if (style == RowStyle.TOP10) 20.dp else 14.dp),
        // Re-entering the row (d-pad up/down or back-navigation) restores focus to the
        // previously focused card instead of snapping to the first visible one. If the
        // remembered card is gone (row data changed/reordered while away), fall back to
        // the first card instead of failing restoration and breaking focus search.
        modifier = Modifier.focusRestorer { firstItemRequester },
    ) {
        itemsIndexed(
            items = items,
            key = { index, item -> "${item.type.key}:${item.id}:$index" },
        ) { index, item ->
            var focusModifier: Modifier = Modifier
            if (index == 0) {
                focusModifier = focusModifier.focusRequester(firstItemRequester)
            }
            if (onItemFocused != null) {
                focusModifier = focusModifier
                    .onFocusChanged { if (it.hasFocus) onItemFocused(item) }
            }
            val longClick: (() -> Unit)? = onItemLongClick?.let { handler -> { handler(item) } }
            when (style) {
                RowStyle.POSTER -> PosterCard(
                    item = item,
                    onClick = { onItemClick(item) },
                    onLongClick = longClick,
                    modifier = focusModifier,
                )
                RowStyle.LANDSCAPE -> LandscapeCard(
                    item = item,
                    onClick = { onItemClick(item) },
                    onLongClick = longClick,
                    modifier = focusModifier,
                )
                RowStyle.TOP10 -> Top10Card(
                    item = item,
                    rank = item.rankInRow ?: (index + 1),
                    onClick = { onItemClick(item) },
                    onLongClick = longClick,
                    modifier = focusModifier,
                )
            }
        }
    } }
}

/** Continue Watching rail — click resumes playback, long-press opens the actions sheet. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun ContinueWatchingRow(
    entries: List<ContinueWatchingUi>,
    onResume: (PlayTarget) -> Unit,
    onLongClick: (ContinueWatchingUi) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth().padding(top = 22.dp)) {
        Text(
            text = "Continue Watching",
            style = MaterialTheme.typography.headlineSmall,
            color = VelvetColors.TextPrimary,
            modifier = Modifier.padding(start = 48.dp, bottom = 10.dp),
        )
        // Continue Watching reorders after every playback session — exactly the case
        // where focusRestorer's remembered target goes stale. Fall back to the first
        // card (index 0 always composes first, so the requester is always attached).
        val firstItemRequester = remember { FocusRequester() }
        HorizontalPivotLocal { LazyRow(
            contentPadding = PaddingValues(horizontal = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier.focusRestorer { firstItemRequester },
        ) {
            itemsIndexed(
                items = entries,
                key = { _, entry -> "${entry.item.type.key}:${entry.item.id}" },
            ) { index, entry ->
                ContinueWatchingCard(
                    item = entry.item,
                    progressFraction = entry.progressFraction,
                    progressLabel = entry.label,
                    onClick = { onResume(entry.target) },
                    onLongClick = { onLongClick(entry) },
                    modifier = if (index == 0) {
                        Modifier.focusRequester(firstItemRequester)
                    } else {
                        Modifier
                    },
                )
            }
        } }
    }
}

/** Shimmering placeholder cards (animated alpha on CardPlaceholder) while a row loads. */
@Composable
private fun RowPlaceholder(style: RowStyle) {
    val transition = rememberInfiniteTransition(label = "rowShimmer")
    val shimmerAlpha by transition.animateFloat(
        initialValue = 0.45f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 750, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "shimmerAlpha",
    )
    val landscape = style == RowStyle.LANDSCAPE
    val top10 = style == RowStyle.TOP10
    val cardWidth = if (landscape) CardDefaults.LandscapeWidth else CardDefaults.PosterWidth
    val cardHeight = if (landscape) CardDefaults.LandscapeHeight else CardDefaults.PosterHeight
    // Mirror Top10Card geometry (rank gutter + 20dp spacing) so the loaded row lands
    // exactly where the placeholder was — no layout jump on the flagship row.
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 48.dp),
        horizontalArrangement = Arrangement.spacedBy(if (top10) 20.dp else 14.dp),
    ) {
        repeat(if (landscape) 5 else 7) {
            Column {
                Row(verticalAlignment = Alignment.Bottom) {
                    if (top10) {
                        Box(
                            Modifier
                                .padding(end = 2.dp)
                                .size(62.dp, 84.dp)
                                .graphicsLayer { alpha = shimmerAlpha * 0.5f }
                                .background(
                                    VelvetColors.CardPlaceholder,
                                    RoundedCornerShape(CardDefaults.CornerRadius),
                                )
                        )
                    }
                    Box(
                        Modifier
                            .size(cardWidth, cardHeight)
                            .graphicsLayer { alpha = shimmerAlpha }
                            .background(
                                VelvetColors.CardPlaceholder,
                                RoundedCornerShape(CardDefaults.CornerRadius),
                            )
                    )
                }
                Column(modifier = if (top10) Modifier.padding(start = 64.dp) else Modifier) {
                    Spacer(Modifier.height(8.dp))
                    Box(
                        Modifier
                            .size(cardWidth * 0.7f, 10.dp)
                            .graphicsLayer { alpha = shimmerAlpha * 0.8f }
                            .background(VelvetColors.CardPlaceholder, RoundedCornerShape(4.dp))
                    )
                    Spacer(Modifier.height(5.dp))
                    Box(
                        Modifier
                            .size(cardWidth * 0.4f, 9.dp)
                            .graphicsLayer { alpha = shimmerAlpha * 0.8f }
                            .background(VelvetColors.CardPlaceholder, RoundedCornerShape(4.dp))
                    )
                }
            }
        }
    }
}
