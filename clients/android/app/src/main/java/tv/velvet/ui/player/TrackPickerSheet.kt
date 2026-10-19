package tv.velvet.ui.player

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import tv.velvet.ui.theme.VelvetColors

/**
 * Right-anchored track picker (subtitles / audio) — same visual pattern as
 * [StreamPickerSheet]. Focus lands on the currently-selected entry when it opens;
 * selecting applies immediately (the caller closes the sheet). Back is handled by
 * the screen-level BackHandler, mirroring the stream picker.
 */
@Composable
fun TrackPickerSheet(
    title: String,
    options: List<TrackOptionUi>,
    onPick: (TrackOptionUi) -> Unit,
    modifier: Modifier = Modifier,
) {
    val selectedIndex = options.indexOfFirst { it.selected }.coerceAtLeast(0)
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = selectedIndex.coerceAtMost((options.size - 1).coerceAtLeast(0))
    )
    val selectedFocus = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        runCatching { selectedFocus.requestFocus() }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(VelvetColors.Scrim)
    ) {
        Column(
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .width(340.dp)
                .fillMaxHeight()
                .background(VelvetColors.Surface)
                .padding(horizontal = 24.dp, vertical = 24.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.headlineSmall,
                color = VelvetColors.TextPrimary,
            )
            val trackCount = options.count { it.index >= 0 }
            Text(
                text = if (trackCount == 1) "1 track" else "$trackCount tracks",
                style = MaterialTheme.typography.labelMedium,
                color = VelvetColors.TextTertiary,
            )
            Spacer(Modifier.height(16.dp))
            if (options.isEmpty()) {
                Text(
                    text = "No tracks available.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = VelvetColors.TextSecondary,
                )
            } else {
                LazyColumn(
                    state = listState,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    itemsIndexed(options, key = { _, option -> option.index }) { index, option ->
                        TrackRow(
                            option = option,
                            onClick = { onPick(option) },
                            modifier = if (index == selectedIndex) {
                                Modifier.focusRequester(selectedFocus)
                            } else {
                                Modifier
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TrackRow(
    option: TrackOptionUi,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(10.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = VelvetColors.SurfaceElevated,
            focusedContainerColor = VelvetColors.SurfaceHighlight,
            pressedContainerColor = VelvetColors.SurfaceHighlight,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = RoundedCornerShape(10.dp),
            ),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        modifier = modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Text(
                text = option.label,
                style = MaterialTheme.typography.titleSmall,
                // Accent marks the active track (selected-state, per the design bible).
                color = if (option.selected) VelvetColors.Accent else VelvetColors.TextPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (option.selected) {
                Spacer(Modifier.width(10.dp))
                Icon(
                    imageVector = Icons.Default.Check,
                    contentDescription = "Selected",
                    tint = VelvetColors.Accent,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}
