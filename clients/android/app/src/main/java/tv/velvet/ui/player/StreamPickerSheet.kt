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
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import tv.velvet.data.model.StreamOption
import tv.velvet.data.streams.EpisodeTitleVerdict
import tv.velvet.ui.theme.VelvetColors
import java.util.Locale

/**
 * Right-anchored stream picker: release tags (folded quality chip), size, and an
 * amber "EP N?" warning on any stream whose filename carries a different episode's
 * title. Selecting an option switches streams while preserving the playback position.
 */
@Composable
fun StreamPickerSheet(
    streams: List<StreamOption>,
    currentUrl: String?,
    onPick: (StreamOption) -> Unit,
    modifier: Modifier = Modifier,
    episodeVerdicts: Map<String, EpisodeTitleVerdict> = emptyMap(),
    onOpenPlaybackOptions: (() -> Unit)? = null,
) {
    val selectedIndex = streams.indexOfFirst { it.url == currentUrl }.coerceAtLeast(0)
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = selectedIndex.coerceAtMost((streams.size - 1).coerceAtLeast(0))
    )
    val selectedFocus = remember { FocusRequester() }
    val emptyOptionsFocus = remember { FocusRequester() }
    LaunchedEffect(streams.map { it.url }) {
        if (streams.isNotEmpty()) {
            listState.scrollToItem(selectedIndex)
            withFrameNanos { }
            runCatching { selectedFocus.requestFocus() }
        } else if (onOpenPlaybackOptions != null) {
            withFrameNanos { }
            runCatching { emptyOptionsFocus.requestFocus() }
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(VelvetColors.Scrim)
    ) {
        Column(
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .width(430.dp)
                .fillMaxHeight()
                .background(VelvetColors.Surface)
                .padding(horizontal = 24.dp, vertical = 24.dp),
        ) {
            Text("Streams", style = MaterialTheme.typography.headlineSmall, color = VelvetColors.TextPrimary)
            Text(
                text = if (streams.size == 1) "1 stream available" else "${streams.size} streams available",
                style = MaterialTheme.typography.labelMedium,
                color = VelvetColors.TextTertiary,
            )
            Spacer(Modifier.height(16.dp))
            if (streams.isEmpty()) {
                Text("No streams available.", style = MaterialTheme.typography.bodyMedium,
                    color = VelvetColors.TextSecondary)
                if (onOpenPlaybackOptions != null) {
                    Spacer(Modifier.height(16.dp))
                    PlaybackOptionRow(
                        title = "Playback options", subtitle = "Manage playback for this show",
                        onClick = onOpenPlaybackOptions,
                        modifier = Modifier.fillMaxWidth().focusRequester(emptyOptionsFocus),
                    )
                }
            } else {
                LazyColumn(
                    state = listState,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    itemsIndexed(streams, key = { index, s -> "${index}_${s.url}" }) { index, stream ->
                        StreamRow(
                            stream = stream,
                            fallbackLabel = "Stream",
                            isCurrent = stream.url == currentUrl,
                            verdict = episodeVerdicts[stream.url],
                            onClick = { onPick(stream) },
                            modifier = if (index == selectedIndex) Modifier.focusRequester(selectedFocus)
                                else Modifier,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun StreamRow(
    stream: StreamOption,
    fallbackLabel: String,
    isCurrent: Boolean,
    verdict: EpisodeTitleVerdict?,
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
            // The old standalone quality badge is folded into the first resolution chip
            // (StreamTagChipRow). Unknown tags use a neutral stream number; source
            // and release-group names are intentionally absent from these clean rows.
            Column(modifier = Modifier.weight(1f)) {
                StreamTagChipRow(
                    title = stream.title,
                    quality = stream.quality,
                    fallbackLabel = fallbackLabel,
                )
                val mismatch = verdict as? EpisodeTitleVerdict.Mismatch
                val size = formatStreamSize(stream.sizeBytes)
                if (mismatch != null || size != null) {
                    Spacer(Modifier.height(4.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (mismatch != null) {
                            MismatchBadge(text = "EP ${mismatch.actualEpisode}?")
                            if (size != null) Spacer(Modifier.width(8.dp))
                        }
                        if (size != null) {
                            Text(
                                text = size,
                                style = MaterialTheme.typography.labelSmall,
                                color = VelvetColors.TextTertiary,
                                maxLines = 1,
                            )
                        }
                    }
                }
            }
            if (isCurrent) {
                Spacer(Modifier.width(10.dp))
                Icon(
                    imageVector = Icons.Default.Check,
                    contentDescription = "Currently playing",
                    tint = VelvetColors.Match,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

/**
 * Amber warning chip for a stream whose filename carries a DIFFERENT episode's title
 * (off-by-one release numbering). Muted amber (Gold), not red — it's a warning, not an
 * error: these streams sink to the bottom of the list and are never auto-picked, but a
 * wrong-titled file that actually plays still beats an error screen.
 */
@Composable
private fun MismatchBadge(text: String, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(
                color = VelvetColors.Gold.copy(alpha = 0.20f),
                shape = RoundedCornerShape(6.dp),
            )
            .padding(horizontal = 8.dp, vertical = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall,
            color = VelvetColors.Gold,
            maxLines = 1,
        )
    }
}

internal fun formatStreamSize(bytes: Long?): String? {
    if (bytes == null || bytes <= 0) return null
    val gb = bytes / 1_073_741_824.0
    return if (gb >= 1.0) {
        String.format(Locale.US, "%.1f GB", gb)
    } else {
        String.format(Locale.US, "%.0f MB", bytes / 1_048_576.0)
    }
}
