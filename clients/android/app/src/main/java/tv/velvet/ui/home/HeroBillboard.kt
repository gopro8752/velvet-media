package tv.velvet.ui.home

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Info
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Button
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import tv.velvet.data.model.MediaItem
import tv.velvet.ui.components.velvetOutlinedButtonBorder
import tv.velvet.ui.theme.VelvetColors
import java.util.Locale

/**
 * Full-bleed hero backdrop behind the Home LazyColumn. Crossfades (220ms) when the
 * featured item changes; left + bottom gradient scrims keep text and rows legible.
 * [visible] fades the whole thing out once the list scrolls past the hero.
 */
@Composable
fun HeroBackdrop(
    backdropUrl: String?,
    visible: Boolean,
    modifier: Modifier = Modifier,
) {
    val bg = VelvetColors.Background
    val backdropAlpha = animateFloatAsState(
        targetValue = if (visible) 1f else 0f,
        animationSpec = tween(300),
        label = "backdropAlpha",
    )
    Box(
        modifier = modifier
            .fillMaxWidth()
            .fillMaxHeight(0.72f)
            // Read each animation frame in the layer phase, so fading the hero
            // never recomposes the home screen or its scrolling card rows.
            .graphicsLayer { alpha = backdropAlpha.value },
    ) {
        Crossfade(
            targetState = backdropUrl,
            animationSpec = tween(220),
            label = "heroBackdrop",
        ) { url ->
            if (url != null) {
                AsyncImage(
                    model = ImageRequest.Builder(LocalContext.current)
                        .data(url)
                        .crossfade(220)
                        .build(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Box(Modifier.fillMaxSize().background(bg))
            }
        }
        // Horizontal scrim: ~65% opaque background on the left fading to clear.
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.horizontalGradient(
                        0f to bg.copy(alpha = 0.93f),
                        0.32f to bg.copy(alpha = 0.55f),
                        0.65f to bg.copy(alpha = 0f),
                    )
                )
        )
        // Vertical scrims: a whisper at the top (top-bar legibility), solid at the
        // bottom so the first rows sit on the hero for the premium overlap look.
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0f to bg.copy(alpha = 0.5f),
                        0.18f to bg.copy(alpha = 0f),
                        0.55f to bg.copy(alpha = 0f),
                        0.9f to bg.copy(alpha = 0.95f),
                        1f to bg,
                    )
                )
        )
    }
}

/**
 * Hero content block — logo (or display-typeface title), meta line, 2-line overview,
 * Play / Details / My List buttons. Text crossfades on item change (300ms); the
 * buttons live outside the crossfade so d-pad focus never gets dropped mid-rotation.
 */
@Composable
fun HeroBillboard(
    hero: MediaItem?,
    inMyList: Boolean,
    playFocusRequester: FocusRequester,
    createCategoryFocus: FocusRequester,
    onPlay: () -> Unit,
    onDetails: () -> Unit,
    onToggleMyList: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .align(Alignment.TopStart)
                .fillMaxWidth(0.58f)
                // Size to the artwork and controls, with a stable top margin.
                // List-end dock clearance must never compress the hero.
                .padding(start = 48.dp, top = 40.dp, bottom = 18.dp),
        ) {
            Crossfade(
                targetState = hero,
                animationSpec = tween(300),
                label = "heroContent",
            ) { item ->
                if (item == null) {
                    Spacer(Modifier.height(168.dp))
                } else {
                    Column {
                        Box(
                            modifier = Modifier
                                .height(92.dp)
                                .fillMaxWidth(),
                            contentAlignment = Alignment.BottomStart,
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
                                    modifier = Modifier
                                        .fillMaxWidth(0.8f)
                                        .height(88.dp),
                                )
                            } else {
                                Text(
                                    text = item.title,
                                    style = MaterialTheme.typography.displaySmall,
                                    color = VelvetColors.TextPrimary,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        Spacer(Modifier.height(10.dp))
                        HeroMetaLine(item)
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = item.overview.orEmpty(),
                            style = MaterialTheme.typography.bodyMedium,
                            color = VelvetColors.TextSecondary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.heightIn(min = 40.dp),
                        )
                    }
                }
            }
            if (hero != null) {
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = onPlay,
                        colors = ButtonDefaults.colors(
                            containerColor = VelvetColors.TextPrimary,
                            contentColor = VelvetColors.Background,
                            focusedContainerColor = VelvetColors.FocusRing,
                            focusedContentColor = VelvetColors.Background,
                            pressedContainerColor = VelvetColors.TextPrimary,
                            pressedContentColor = VelvetColors.Background,
                        ),
                        modifier = Modifier.focusRequester(playFocusRequester).focusProperties { up = createCategoryFocus },
                    ) {
                        Icon(
                            imageVector = Icons.Filled.PlayArrow,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Play")
                    }
                    OutlinedButton(onClick = onDetails, border = velvetOutlinedButtonBorder(),
                        modifier = Modifier.focusProperties { up = createCategoryFocus }) {
                        Icon(
                            imageVector = Icons.Outlined.Info,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("Details")
                    }
                    OutlinedButton(onClick = onToggleMyList, border = velvetOutlinedButtonBorder(),
                        modifier = Modifier.focusProperties { up = createCategoryFocus }) {
                        Icon(
                            imageVector = if (inMyList) Icons.Filled.Check else Icons.Filled.Add,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(if (inMyList) "In My List" else "My List")
                    }
                }
            }
        }
    }
}

/** "★ 8.1 · 2024 · 2h 18m · Sci-Fi" — gold star rating, the rest in secondary. */
@Composable
private fun HeroMetaLine(item: MediaItem) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        val rating = item.rating?.takeIf { it > 0 }
        if (rating != null) {
            Text(
                text = "★ " + String.format(Locale.US, "%.1f", rating),
                style = MaterialTheme.typography.titleSmall,
                color = VelvetColors.Gold,
            )
        }
        val parts = buildList {
            item.year?.takeIf { it.isNotBlank() }?.let { add(it) }
            item.runtimeMinutes?.takeIf { it > 0 }?.let { add(formatRuntime(it)) }
            item.genres.take(2).forEach { add(it) }
        }
        if (parts.isNotEmpty()) {
            Text(
                text = (if (rating != null) "  ·  " else "") + parts.joinToString("  ·  "),
                style = MaterialTheme.typography.titleSmall,
                color = VelvetColors.TextSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private fun formatRuntime(minutes: Int): String {
    val h = minutes / 60
    val m = minutes % 60
    return when {
        h > 0 && m > 0 -> "${h}h ${m}m"
        h > 0 -> "${h}h"
        else -> "${m}m"
    }
}
