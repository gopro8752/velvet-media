package tv.velvet.ui.player

import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.focusable
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.ui.platform.LocalContext
import java.util.Date
import androidx.tv.material3.Icon
import androidx.tv.material3.IconButton
import androidx.tv.material3.IconButtonDefaults
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import kotlinx.coroutines.delay
import tv.velvet.ui.theme.VelvetColors
import java.util.Locale

/**
 * Custom playback controls overlaid on the video. Bottom-anchored: title block,
 * scrub bar (focusable, ±10s with hold acceleration), then the buttons row.
 */
@Composable
fun PlayerControls(
    state: PlayerUiState,
    playPauseFocusRequester: FocusRequester,
    onPlayPause: () -> Unit,
    onSeekTo: (Long) -> Unit,
    onPreviousEpisode: () -> Unit,
    onNextEpisode: () -> Unit,
    onReplayWithSubtitles: () -> Unit,
    onOpenPlaybackOptions: () -> Unit,
    streamsFocusRequester: FocusRequester,
    optionsFocusRequester: FocusRequester,
    onOpenStreamPicker: () -> Unit,
    onInteraction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .drawBehind {
                drawRect(
                    Brush.verticalGradient(
                        0f to Color.Transparent,
                        0.55f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.88f),
                    )
                )
            }
    ) {
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(horizontal = 48.dp)
                // 27dp = DESIGN.md overscan-safe bottom padding for text.
                .padding(bottom = 27.dp),
        ) {
            // Title block — show name + "S2 E4 — Episode Title", or just the movie title.
            if (state.episodeLabel != null) {
                Text(
                    text = state.showTitle,
                    style = MaterialTheme.typography.labelLarge,
                    color = VelvetColors.TextSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = state.episodeLabel,
                    style = MaterialTheme.typography.headlineSmall,
                    color = VelvetColors.TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            } else {
                Text(
                    text = state.showTitle,
                    style = MaterialTheme.typography.headlineSmall,
                    color = VelvetColors.TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Spacer(Modifier.height(14.dp))

            ScrubBar(
                positionMs = state.positionMs,
                durationMs = state.durationMs,
                bufferedMs = state.bufferedMs,
                onSeekTo = onSeekTo,
                onPlayPause = onPlayPause,
                onInteraction = onInteraction,
            )

            Spacer(Modifier.height(12.dp))

            Box(modifier = Modifier.fillMaxWidth()) {
                // Transport stays centered and symmetric; utility actions sit to either side.
                ControlIconButton(
                    icon = { focused ->
                        Icon(Icons.Default.Replay, "What did they say? (replay with subtitles)",
                            tint = if (focused) VelvetColors.Background else if (state.replayActive)
                                VelvetColors.Accent else VelvetColors.TextPrimary)
                    },
                    onClick = onReplayWithSubtitles,
                    modifier = Modifier.align(Alignment.CenterStart),
                )
                Row(
                    modifier = Modifier.align(Alignment.Center),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (state.isShow || state.inCategory) {
                        ControlIconButton(
                            icon = { focused ->
                                Icon(Icons.Default.SkipPrevious,
                                    if (state.inCategory) "Previous item" else "Previous episode",
                                    tint = if (focused) VelvetColors.Background else if (state.hasPrevious)
                                        VelvetColors.TextPrimary else VelvetColors.TextTertiary)
                            },
                            onClick = onPreviousEpisode,
                            enabled = state.hasPrevious,
                        )
                    }
                    ControlIconButton(
                        icon = { focused ->
                            Icon(if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                if (state.isPlaying) "Pause" else "Play",
                                tint = if (focused) VelvetColors.Background else VelvetColors.TextPrimary)
                        },
                        onClick = onPlayPause,
                        size = 56.dp,
                        modifier = Modifier.focusRequester(playPauseFocusRequester),
                    )
                    if (state.isShow || state.inCategory) {
                        ControlIconButton(
                            icon = { focused ->
                                Icon(Icons.Default.SkipNext,
                                    if (state.inCategory) "Next item" else "Next episode",
                                    tint = if (focused) VelvetColors.Background else if (state.hasNext)
                                        VelvetColors.TextPrimary else VelvetColors.TextTertiary)
                            },
                            onClick = onNextEpisode,
                            enabled = state.hasNext,
                        )
                    }
                }
                Row(
                    modifier = Modifier.align(Alignment.CenterEnd),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ControlIconButton(
                        icon = { focused ->
                            Icon(Icons.Default.VideoLibrary, "Streams",
                                tint = if (focused) VelvetColors.Background else VelvetColors.TextPrimary)
                        },
                        onClick = onOpenStreamPicker,
                        modifier = Modifier.focusRequester(streamsFocusRequester),
                    )
                    ControlIconButton(
                        icon = { focused ->
                            Icon(Icons.Default.Tune, "Playback options",
                                tint = if (focused) VelvetColors.Background else VelvetColors.TextPrimary)
                        },
                        onClick = onOpenPlaybackOptions,
                        modifier = Modifier.focusRequester(optionsFocusRequester),
                    )
                }
            }
        }
    }
}

@Composable
private fun ControlIconButton(
    icon: @Composable (focused: Boolean) -> Unit,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    size: androidx.compose.ui.unit.Dp = 44.dp,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    IconButton(
        onClick = onClick,
        enabled = enabled,
        interactionSource = interactionSource,
        colors = IconButtonDefaults.colors(
            containerColor = VelvetColors.TextPrimary.copy(alpha = 0.12f),
            contentColor = VelvetColors.TextPrimary,
            focusedContainerColor = VelvetColors.FocusRing,
            focusedContentColor = VelvetColors.Background,
            disabledContainerColor = VelvetColors.TextPrimary.copy(alpha = 0.05f),
            disabledContentColor = VelvetColors.TextTertiary,
        ),
        modifier = modifier.size(size),
    ) {
        icon(focused)
    }
}

/**
 * Focusable scrub bar. Left/right seek ±10s; holding accelerates (30s, then 60s steps).
 * Center toggles play/pause. The pending scrub target commits on key-up (with an idle
 * fallback) so a long hold performs one seek, not dozens.
 */
@Composable
private fun ScrubBar(
    positionMs: Long,
    durationMs: Long,
    bufferedMs: Long,
    onSeekTo: (Long) -> Unit,
    onPlayPause: () -> Unit,
    onInteraction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    var scrubTarget by remember { mutableStateOf<Long?>(null) }
    var commitSignal by remember { mutableIntStateOf(0) }

    // Idle fallback: if key-up was missed, commit 600ms after the last step.
    LaunchedEffect(scrubTarget, commitSignal) {
        val pending = scrubTarget ?: return@LaunchedEffect
        delay(600)
        onSeekTo(pending)
        scrubTarget = null
    }

    val shownPosition = scrubTarget ?: positionMs
    val safeDuration = if (durationMs > 0) durationMs else 0L
    val playedFraction =
        if (safeDuration > 0) (shownPosition.toFloat() / safeDuration).coerceIn(0f, 1f) else 0f
    val bufferedFraction =
        if (safeDuration > 0) (bufferedMs.toFloat() / safeDuration).coerceIn(0f, 1f) else 0f

    Column(modifier = modifier.fillMaxWidth()) {
        Row(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = formatPlayerTime(shownPosition),
                style = MaterialTheme.typography.labelMedium,
                color = if (scrubTarget != null) VelvetColors.Accent else VelvetColors.TextSecondary,
            )
            Spacer(Modifier.weight(1f))
            // "Ends 11:42 PM" — the wall clock when playback finishes from here.
            // Uses the device's 12/24h preference; recomputed as the position ticks.
            val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }
            val endsAt = if (safeDuration > 0) {
                " · Ends " + timeFormat.format(
                    Date(System.currentTimeMillis() + (safeDuration - shownPosition))
                )
            } else ""
            Text(
                text = formatPlayerTime(safeDuration) + endsAt,
                style = MaterialTheme.typography.labelMedium,
                color = VelvetColors.TextSecondary,
            )
        }
        Spacer(Modifier.height(6.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(20.dp)
                .onKeyEvent { event ->
                    val isLeft = event.key == Key.DirectionLeft
                    val isRight = event.key == Key.DirectionRight
                    val isCenter = event.key == Key.DirectionCenter ||
                        event.key == Key.Enter || event.key == Key.NumPadEnter
                    when {
                        event.type == KeyEventType.KeyDown && (isLeft || isRight) -> {
                            onInteraction()
                            val repeat = event.nativeKeyEvent.repeatCount
                            val step = when {
                                repeat >= 20 -> 60_000L
                                repeat >= 8 -> 30_000L
                                else -> 10_000L
                            }
                            val base = scrubTarget ?: positionMs
                            val delta = if (isRight) step else -step
                            val upper = if (safeDuration > 0) safeDuration - 1_000L else Long.MAX_VALUE
                            scrubTarget = (base + delta).coerceIn(0L, upper.coerceAtLeast(0L))
                            true
                        }
                        event.type == KeyEventType.KeyUp && (isLeft || isRight) -> {
                            scrubTarget?.let {
                                onSeekTo(it)
                                scrubTarget = null
                            }
                            commitSignal++
                            true
                        }
                        event.type == KeyEventType.KeyDown && isCenter -> {
                            onInteraction()
                            onPlayPause()
                            true
                        }
                        else -> false
                    }
                }
                .focusable(interactionSource = interactionSource)
                .drawBehind {
                    val trackHeight = (if (focused) 6.dp else 4.dp).toPx()
                    val centerY = size.height / 2f
                    val top = centerY - trackHeight / 2f
                    val radius = CornerRadius(trackHeight / 2f)
                    // track
                    drawRoundRect(
                        color = VelvetColors.TextPrimary.copy(alpha = 0.22f),
                        topLeft = Offset(0f, top),
                        size = Size(size.width, trackHeight),
                        cornerRadius = radius,
                    )
                    // buffered
                    if (bufferedFraction > 0f) {
                        drawRoundRect(
                            color = VelvetColors.TextPrimary.copy(alpha = 0.30f),
                            topLeft = Offset(0f, top),
                            size = Size(size.width * bufferedFraction, trackHeight),
                            cornerRadius = radius,
                        )
                    }
                    // played
                    if (playedFraction > 0f) {
                        drawRoundRect(
                            color = if (focused) VelvetColors.FocusRing
                            else VelvetColors.TextPrimary.copy(alpha = 0.7f),
                            topLeft = Offset(0f, top),
                            size = Size(size.width * playedFraction, trackHeight),
                            cornerRadius = radius,
                        )
                    }
                    // thumb
                    if (focused) {
                        val cx = size.width * playedFraction
                        drawCircle(
                            color = VelvetColors.FocusRing.copy(alpha = 0.35f),
                            radius = 10.dp.toPx(),
                            center = Offset(cx, centerY),
                        )
                        drawCircle(
                            color = VelvetColors.FocusRing,
                            radius = 6.dp.toPx(),
                            center = Offset(cx, centerY),
                        )
                    }
                }
        )
    }
}

internal fun formatPlayerTime(ms: Long): String {
    if (ms <= 0) return "0:00"
    val totalSecs = ms / 1000
    val h = totalSecs / 3600
    val m = (totalSecs % 3600) / 60
    val s = totalSecs % 60
    return if (h > 0) {
        String.format(Locale.US, "%d:%02d:%02d", h, m, s)
    } else {
        String.format(Locale.US, "%d:%02d", m, s)
    }
}
