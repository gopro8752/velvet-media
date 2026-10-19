package tv.velvet.ui.components

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.BorderStroke
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import tv.velvet.data.model.MediaItem
import tv.velvet.ui.theme.VelvetColors
import tv.velvet.ui.theme.VelvetFonts
import java.util.Locale

/**
 * Velvet card system. Every card shows TITLE + META *below the artwork, always* —
 * no hovering required to know what something is. Focus = scale + white ring + glow,
 * and the text below brightens.
 *
 * Sizes assume a 960x540dp TV canvas (1080p @ xhdpi). Rows use 48dp side padding.
 */

/**
 * D-pad long-press for a focusable card, handled at the key-event layer so it is
 * race-free. tv-material's Surface fires onClick on the key-UP even when the hold
 * already long-pressed — so onClick/onLongClick alone always lets the release "click"
 * the card (resuming playback) the instant the actions menu opens. Instead we watch
 * the raw key stream on the card's ancestor: when Android flags a long-press we invoke
 * [onLongClick] and swallow that event plus its matching key-UP, so the Surface's click
 * never completes. No interception at all when [onLongClick] is null (normal tap-only).
 */
private const val LONG_PRESS_MS = 400L

@Composable
internal fun Modifier.longPressKeyGuard(onLongClick: (() -> Unit)?): Modifier {
    if (onLongClick == null) return this
    // [0] = first key-down time of the current press (0 = idle), [1] = key-down count.
    val press = remember { longArrayOf(0L, 0L) }
    return onPreviewKeyEvent { event ->
        when (event.key) {
            Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> when (event.type) {
                KeyEventType.KeyDown -> {
                    if (press[0] == 0L) press[0] = System.currentTimeMillis()
                    press[1] = press[1] + 1
                    false // let the Surface show its pressed state while held
                }
                KeyEventType.KeyUp -> {
                    val downAt = press[0]
                    val downCount = press[1]
                    press[0] = 0L
                    press[1] = 0L
                    // A held d-pad center repeats its key-down (downCount >= 2) and/or
                    // lasts >= LONG_PRESS_MS; a deliberate tap is one quick down + up.
                    val longPress = downAt != 0L &&
                        (downCount >= 2 || System.currentTimeMillis() - downAt >= LONG_PRESS_MS)
                    if (longPress) {
                        onLongClick()
                        true // swallow the release so the Surface never turns it into a click
                    } else {
                        false // a normal tap — let the Surface fire onClick
                    }
                }
                else -> false
            }
            else -> false
        }
    }
}

object CardDefaults {
    val PosterWidth = 142.dp
    val PosterHeight = 213.dp
    val LandscapeWidth = 228.dp
    val LandscapeHeight = 128.dp
    val CornerRadius = 10.dp
    const val FOCUS_SCALE = 1.08f
}

@Composable
private fun cardSurfaceColors() = ClickableSurfaceDefaults.colors(
    containerColor = VelvetColors.CardPlaceholder,
    focusedContainerColor = VelvetColors.CardPlaceholder,
    pressedContainerColor = VelvetColors.CardPlaceholder,
)

@Composable
private fun cardBorder() = ClickableSurfaceDefaults.border(
    focusedBorder = Border(
        border = BorderStroke(2.5.dp, VelvetColors.FocusRing),
        shape = RoundedCornerShape(CardDefaults.CornerRadius),
    ),
)

@Composable
private fun cardGlow() = ClickableSurfaceDefaults.glow(
    focusedGlow = Glow(elevationColor = VelvetColors.FocusRing.copy(alpha = 0.35f), elevation = 16.dp),
)

@Composable
private fun cardScale() = ClickableSurfaceDefaults.scale(focusedScale = CardDefaults.FOCUS_SCALE)

@Composable
fun CardArtwork(url: String?, contentDescription: String?, modifier: Modifier = Modifier) {
    AsyncImage(
        model = ImageRequest.Builder(LocalContext.current).data(url).crossfade(220).build(),
        contentDescription = contentDescription,
        contentScale = ContentScale.Crop,
        modifier = modifier.fillMaxSize(),
    )
}

/** Title + meta line under a card. [width] must match the card width so text aligns. */
@Composable
fun CardCaption(item: MediaItem, width: androidx.compose.ui.unit.Dp, focused: Boolean) {
    Column(modifier = Modifier.width(width).padding(top = 7.dp)) {
        Text(
            text = item.title,
            style = MaterialTheme.typography.titleSmall,
            color = if (focused) VelvetColors.TextPrimary else VelvetColors.TextSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            item.year?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.labelSmall,
                    color = VelvetColors.TextTertiary,
                )
            }
            item.rating?.takeIf { it > 0 }?.let { rating ->
                if (item.year != null) {
                    Text(
                        text = "  ·  ",
                        style = MaterialTheme.typography.labelSmall,
                        color = VelvetColors.TextTertiary,
                    )
                }
                Text(
                    text = "★ " + String.format(Locale.US, "%.1f", rating),
                    style = MaterialTheme.typography.labelSmall,
                    color = VelvetColors.Gold.copy(alpha = if (focused) 1f else 0.75f),
                )
            }
        }
    }
}

/** Standard 2:3 poster card with caption. */
@Composable
fun PosterCard(item: MediaItem, onClick: () -> Unit, onLongClick: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    Column(modifier = modifier.longPressKeyGuard(onLongClick)) {
        Surface(
            onClick = onClick,
            interactionSource = interactionSource,
            shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(CardDefaults.CornerRadius)),
            colors = cardSurfaceColors(),
            border = cardBorder(),
            glow = cardGlow(),
            scale = cardScale(),
            modifier = Modifier.size(CardDefaults.PosterWidth, CardDefaults.PosterHeight),
        ) {
            CardArtwork(item.posterUrl, item.title)
        }
        CardCaption(item, CardDefaults.PosterWidth, focused)
    }
}

/** 16:9 backdrop card with caption — for trending rows and episode-like content. */
@Composable
fun LandscapeCard(item: MediaItem, onClick: () -> Unit, onLongClick: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    Column(modifier = modifier.longPressKeyGuard(onLongClick)) {
        Surface(
            onClick = onClick,
            interactionSource = interactionSource,
            shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(CardDefaults.CornerRadius)),
            colors = cardSurfaceColors(),
            border = cardBorder(),
            glow = cardGlow(),
            scale = cardScale(),
            modifier = Modifier.size(CardDefaults.LandscapeWidth, CardDefaults.LandscapeHeight),
        ) {
            Box {
                CardArtwork(item.backdropUrl ?: item.posterUrl, item.title)
                // soft bottom scrim keeps any baked-in art text readable
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .drawWithContent {
                            drawContent()
                            drawRect(
                                Brush.verticalGradient(
                                    0f to Color.Transparent,
                                    1f to Color.Black.copy(alpha = 0.25f),
                                    startY = size.height * 0.6f,
                                )
                            )
                        }
                )
            }
        }
        CardCaption(item, CardDefaults.LandscapeWidth, focused)
    }
}

/** Top 10 card — huge accent-violet rank numeral beside a poster (DESIGN.md: accent
 *  is for rank numerals). Dimmed-but-legible at rest, full accent when focused. */
@Composable
fun Top10Card(item: MediaItem, rank: Int, onClick: () -> Unit, onLongClick: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    Column(modifier = modifier.longPressKeyGuard(onLongClick)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = rank.toString(),
                fontFamily = VelvetFonts.Display,
                fontWeight = FontWeight.Bold,
                fontSize = if (rank < 10) 110.sp else 84.sp,
                color = if (focused) VelvetColors.Accent
                else VelvetColors.Accent.copy(alpha = 0.45f),
                modifier = Modifier.padding(end = 2.dp),
            )
            Surface(
                onClick = onClick,
                interactionSource = interactionSource,
                shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(CardDefaults.CornerRadius)),
                colors = cardSurfaceColors(),
                border = cardBorder(),
                glow = cardGlow(),
                scale = cardScale(),
                modifier = Modifier.size(CardDefaults.PosterWidth, CardDefaults.PosterHeight),
            ) {
                CardArtwork(item.posterUrl, item.title)
            }
        }
        Column(modifier = Modifier.padding(start = if (rank < 10) 64.dp else 52.dp)) {
            CardCaption(item, CardDefaults.PosterWidth, focused)
        }
    }
}

/** Continue Watching card — backdrop, progress bar, full caption (title + year +
 *  rating, per rule 1) plus the "S2 E4 · 23m left" resume label. */
@Composable
fun ContinueWatchingCard(
    item: MediaItem,
    progressFraction: Float,
    progressLabel: String,        // e.g. "S2 E4 · 23m left" or "48m left"
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    Column(modifier = modifier.longPressKeyGuard(onLongClick)) {
        Surface(
            onClick = onClick,
            interactionSource = interactionSource,
            shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(CardDefaults.CornerRadius)),
            colors = cardSurfaceColors(),
            border = cardBorder(),
            glow = cardGlow(),
            scale = cardScale(),
            modifier = Modifier.size(CardDefaults.LandscapeWidth, CardDefaults.LandscapeHeight),
        ) {
            Box {
                CardArtwork(item.backdropUrl ?: item.posterUrl, item.title)
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .drawWithContent {
                            drawContent()
                            drawRect(
                                Brush.verticalGradient(
                                    0f to Color.Transparent,
                                    1f to Color.Black.copy(alpha = 0.55f),
                                    startY = size.height * 0.45f,
                                )
                            )
                            // progress track + fill, pinned to the bottom edge
                            val trackH = 3.5.dp.toPx()
                            drawRect(
                                color = Color.White.copy(alpha = 0.25f),
                                topLeft = Offset(0f, size.height - trackH),
                                size = androidx.compose.ui.geometry.Size(size.width, trackH),
                            )
                            drawRect(
                                color = VelvetColors.Match,
                                topLeft = Offset(0f, size.height - trackH),
                                size = androidx.compose.ui.geometry.Size(
                                    size.width * progressFraction.coerceIn(0f, 1f), trackH
                                ),
                            )
                        }
                )
            }
        }
        Column {
            CardCaption(item, CardDefaults.LandscapeWidth, focused)
            Text(
                text = progressLabel,
                style = MaterialTheme.typography.labelSmall,
                color = VelvetColors.TextTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.width(CardDefaults.LandscapeWidth),
            )
        }
    }
}
