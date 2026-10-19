package tv.velvet.ui.player

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.components.velvetOutlinedButtonBorder
import tv.velvet.ui.theme.VelvetColors

/**
 * Bottom-right Up Next card. Two flavors:
 *  - [UpNextUi.Countdown]: still + "Up Next · S2 E5" + ticking ring; Play now / Watch credits.
 *  - [UpNextUi.EndChoice]: shown at ENDED when autoplay was cancelled or disabled;
 *    Play next / Back to details, no countdown.
 */
@Composable
fun UpNextOverlay(
    upNext: UpNextUi,
    fallbackImageUrl: String?,
    primaryFocusRequester: FocusRequester,
    onPlayNext: () -> Unit,
    onWatchCredits: () -> Unit,
    onBackToDetails: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val next: NextEpisodeUi
    val countdown: UpNextUi.Countdown?
    when (upNext) {
        is UpNextUi.Countdown -> {
            next = upNext.next
            countdown = upNext
        }
        is UpNextUi.EndChoice -> {
            next = upNext.next
            countdown = null
        }
        UpNextUi.Hidden -> return
    }

    Box(modifier = modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 48.dp, bottom = 40.dp)
                .width(300.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(VelvetColors.SurfaceElevated),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
            ) {
                AsyncImage(
                    model = ImageRequest.Builder(LocalContext.current)
                        .data(next.stillUrl ?: fallbackImageUrl)
                        .crossfade(220)
                        .build(),
                    contentDescription = next.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                val scrimColor = VelvetColors.SurfaceElevated.copy(alpha = 0.9f)
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        // Fraction-based start (not raw pixels) so the still→card blend
                        // covers the same bottom half at every display density.
                        .drawBehind {
                            drawRect(
                                Brush.verticalGradient(
                                    0f to Color.Transparent,
                                    1f to scrimColor,
                                    startY = size.height * 0.5f,
                                )
                            )
                        }
                )
            }
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = if (next.isMovie) "Up Next · Movie" else "Up Next · S${next.season} E${next.episode}",
                        style = MaterialTheme.typography.labelLarge,
                        color = VelvetColors.Accent,
                        modifier = Modifier.weight(1f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (countdown != null) {
                        CountdownRing(
                            secondsLeft = countdown.secondsLeft,
                            totalSeconds = countdown.totalSeconds,
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                if (!next.isMovie && next.showTitle != null) Text(next.showTitle,
                    style = MaterialTheme.typography.labelLarge, color = VelvetColors.TextSecondary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    text = next.title.ifBlank { "Episode ${next.episode}" },
                    style = MaterialTheme.typography.titleMedium,
                    color = VelvetColors.TextPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    // Explicit Velvet styling: the theme's white colorScheme.border would
                    // otherwise make the UNFOCUSED outlined button look focused — fatal
                    // on a time-critical countdown card.
                    Button(
                        onClick = onPlayNext,
                        colors = velvetButtonColors(),
                        modifier = Modifier.focusRequester(primaryFocusRequester),
                    ) {
                        Text(
                            text = if (countdown != null) "Play now" else "Play next",
                            style = MaterialTheme.typography.labelLarge,
                        )
                    }
                    if (countdown != null) {
                        OutlinedButton(onClick = onWatchCredits, border = velvetOutlinedButtonBorder()) {
                            Text("Watch credits", style = MaterialTheme.typography.labelLarge)
                        }
                    } else {
                        OutlinedButton(onClick = onBackToDetails, border = velvetOutlinedButtonBorder()) {
                            Text("Back to details", style = MaterialTheme.typography.labelLarge)
                        }
                    }
                }
            }
        }
    }
}

/** Small ring that drains as the countdown ticks, seconds number in the middle. */
@Composable
private fun CountdownRing(
    secondsLeft: Int,
    totalSeconds: Int,
    modifier: Modifier = Modifier,
) {
    val fraction = if (totalSeconds > 0) {
        (secondsLeft.toFloat() / totalSeconds.toFloat()).coerceIn(0f, 1f)
    } else 0f
    Box(modifier = modifier.size(30.dp), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val stroke = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round)
            val inset = 3.dp.toPx()
            val arcSize = androidx.compose.ui.geometry.Size(
                size.width - inset * 2, size.height - inset * 2
            )
            drawArc(
                color = Color.White.copy(alpha = 0.18f),
                startAngle = -90f,
                sweepAngle = 360f,
                useCenter = false,
                style = stroke,
                topLeft = Offset(inset, inset),
                size = arcSize,
            )
            drawArc(
                color = VelvetColors.Accent,
                startAngle = -90f,
                sweepAngle = 360f * fraction,
                useCenter = false,
                style = stroke,
                topLeft = Offset(inset, inset),
                size = arcSize,
            )
        }
        Text(
            text = secondsLeft.toString(),
            style = MaterialTheme.typography.labelSmall,
            color = VelvetColors.TextPrimary,
        )
    }
}
