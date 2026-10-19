package tv.velvet.ui.details

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import tv.velvet.data.model.CastMember
import tv.velvet.data.model.Episode
import tv.velvet.data.model.MediaItem
import tv.velvet.data.model.Season
import tv.velvet.ui.components.HorizontalPivotLocal
import tv.velvet.ui.components.longPressKeyGuard
import tv.velvet.ui.components.PosterCard
import tv.velvet.ui.theme.VelvetColors
import androidx.compose.ui.graphics.Color

// ── seasons ──────────────────────────────────────────────────────────────────

@Composable
fun SeasonChipsRow(
    seasons: List<Season>,
    selectedSeason: Int?,
    onSelect: (Int) -> Unit,
    onLongPress: ((Season) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    HorizontalPivotLocal { LazyRow(
        modifier = modifier.fillMaxWidth().focusRestorer(),
        contentPadding = PaddingValues(horizontal = 48.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items(seasons, key = { "season_${it.number}" }) { season ->
            SeasonChip(
                label = season.name.ifBlank { "Season ${season.number}" },
                selected = season.number == selectedSeason,
                onClick = { onSelect(season.number) },
                onLongClick = onLongPress?.let { cb -> { cb(season) } },
            )
        }
    } }
}

@Composable
private fun SeasonChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val shape = RoundedCornerShape(50)
    Surface(
        onClick = onClick,
        modifier = Modifier.longPressKeyGuard(onLongClick),
        interactionSource = interactionSource,
        shape = ClickableSurfaceDefaults.shape(shape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) VelvetColors.Accent else VelvetColors.SurfaceElevated,
            focusedContainerColor = if (selected) VelvetColors.Accent else VelvetColors.SurfaceHighlight,
            pressedContainerColor = if (selected) VelvetColors.Accent else VelvetColors.SurfaceHighlight,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = shape,
            ),
        ),
        glow = ClickableSurfaceDefaults.glow(
            focusedGlow = Glow(elevationColor = Color.White.copy(alpha = 0.25f), elevation = 10.dp),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.05f),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            color = when {
                selected -> VelvetColors.Background
                focused -> VelvetColors.TextPrimary
                else -> VelvetColors.TextSecondary
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

// ── episodes ─────────────────────────────────────────────────────────────────

private val EpisodeStillWidth = 168.dp
private val EpisodeRowShape = RoundedCornerShape(12.dp)
private val EpisodeStillShape = RoundedCornerShape(8.dp)

@Composable
fun EpisodeRow(
    episode: Episode,
    watched: Boolean,
    progressFraction: Float?,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(EpisodeRowShape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = VelvetColors.Background.copy(alpha = 0f),
            focusedContainerColor = VelvetColors.SurfaceElevated,
            pressedContainerColor = VelvetColors.SurfaceElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = EpisodeRowShape,
            ),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        modifier = modifier.longPressKeyGuard(onLongClick).fillMaxWidth().padding(horizontal = 40.dp),
    ) {
        Row(
            modifier = Modifier.padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // 16:9 still with optional green partial-progress underline.
            Box(
                modifier = Modifier
                    .width(EpisodeStillWidth)
                    .aspectRatio(16f / 9f)
                    .clip(EpisodeStillShape)
                    .background(VelvetColors.CardPlaceholder),
            ) {
                AsyncImage(
                    model = ImageRequest.Builder(LocalContext.current)
                        .data(episode.stillUrl)
                        .crossfade(220)
                        .build(),
                    contentDescription = episode.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                if (progressFraction != null && progressFraction > 0f && progressFraction < 1f) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .fillMaxWidth()
                            .height(3.dp)
                            .background(Color.White.copy(alpha = 0.25f)),
                    )
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .fillMaxWidth(progressFraction)
                            .height(3.dp)
                            .background(VelvetColors.Match),
                    )
                }
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = "E${episode.number} · ${episode.title}",
                    style = MaterialTheme.typography.titleMedium,
                    color = VelvetColors.TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val metaParts = listOfNotNull(
                    episode.runtimeMinutes?.takeIf { it > 0 }?.let { formatRuntime(it) },
                    episode.airDate?.takeIf { it.isNotBlank() }?.let { formatAirDate(it) },
                )
                if (metaParts.isNotEmpty()) {
                    Spacer(Modifier.height(2.dp))
                    Text(
                        text = metaParts.joinToString("  ·  "),
                        style = MaterialTheme.typography.labelSmall,
                        color = VelvetColors.TextTertiary,
                    )
                }
                episode.overview?.takeIf { it.isNotBlank() }?.let { overview ->
                    Spacer(Modifier.height(5.dp))
                    Text(
                        text = overview,
                        style = MaterialTheme.typography.bodySmall,
                        color = VelvetColors.TextSecondary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (watched) {
                Spacer(Modifier.width(14.dp))
                Icon(
                    imageVector = Icons.Default.CheckCircle,
                    contentDescription = "Watched",
                    tint = VelvetColors.Match,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

/** Shimmering placeholder row shown while a season's episodes load. */
@Composable
fun EpisodeRowPlaceholder(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "episodeShimmer")
    val alpha by transition.animateFloat(
        initialValue = 0.45f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(durationMillis = 700), RepeatMode.Reverse),
        label = "episodeShimmerAlpha",
    )
    val tone = VelvetColors.CardPlaceholder.copy(alpha = alpha)
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = 48.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .width(EpisodeStillWidth)
                .aspectRatio(16f / 9f)
                .clip(EpisodeStillShape)
                .background(tone),
        )
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Box(
                Modifier.fillMaxWidth(0.45f).height(14.dp)
                    .clip(RoundedCornerShape(4.dp)).background(tone)
            )
            Spacer(Modifier.height(8.dp))
            Box(
                Modifier.fillMaxWidth(0.28f).height(10.dp)
                    .clip(RoundedCornerShape(4.dp)).background(tone)
            )
            Spacer(Modifier.height(8.dp))
            Box(
                Modifier.fillMaxWidth(0.85f).height(10.dp)
                    .clip(RoundedCornerShape(4.dp)).background(tone)
            )
        }
    }
}

// ── cast ─────────────────────────────────────────────────────────────────────

@Composable
fun CastRow(cast: List<CastMember>, modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            text = "Cast",
            style = MaterialTheme.typography.headlineSmall,
            color = VelvetColors.TextPrimary,
            modifier = Modifier.padding(start = 48.dp, bottom = 12.dp),
        )
        HorizontalPivotLocal { LazyRow(
            modifier = Modifier.focusRestorer(),
            contentPadding = PaddingValues(horizontal = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            itemsIndexed(cast.take(15), key = { index, _ -> "cast_$index" }) { _, member ->
                CastCell(member)
            }
        } }
    }
}

/**
 * Focusable cast cell. On a d-pad-only device a row with no focusable children can
 * never scroll (members past the first screenful would be unreachable) and would be a
 * dead zone in vertical traversal. Click is a no-op for now (person page, someday).
 */
@Composable
private fun CastCell(member: CastMember, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(10.dp)
    Surface(
        onClick = {},
        shape = ClickableSurfaceDefaults.shape(shape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = VelvetColors.Background.copy(alpha = 0f),
            focusedContainerColor = VelvetColors.SurfaceElevated,
            pressedContainerColor = VelvetColors.SurfaceElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = shape,
            ),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.05f),
        modifier = modifier.width(88.dp),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 6.dp, vertical = 8.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(CircleShape)
                    .background(VelvetColors.SurfaceElevated),
            ) {
                AsyncImage(
                    model = ImageRequest.Builder(LocalContext.current)
                        .data(member.profileUrl)
                        .crossfade(220)
                        .build(),
                    contentDescription = member.name,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            Spacer(Modifier.height(6.dp))
            Text(
                text = member.name,
                style = MaterialTheme.typography.labelMedium,
                color = VelvetColors.TextSecondary,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// ── more like this ───────────────────────────────────────────────────────────

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SimilarRow(
    similar: List<MediaItem>,
    onItemClick: (MediaItem) -> Unit,
    onItemLongClick: ((MediaItem) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            text = "More Like This",
            style = MaterialTheme.typography.headlineSmall,
            color = VelvetColors.TextPrimary,
            modifier = Modifier.padding(start = 48.dp, bottom = 12.dp),
        )
        HorizontalPivotLocal { LazyRow(
            modifier = Modifier.focusRestorer(),
            contentPadding = PaddingValues(horizontal = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            items(similar, key = { "similar_${it.type.key}_${it.id}" }) { item ->
                val fullCardBounds = remember { BringIntoViewRequester() }
                var focused by remember { mutableStateOf(false) }
                LaunchedEffect(focused) {
                    if (focused) {
                        // PosterCard's focusable Surface covers only the art.
                        // Request the enclosing column after layout so its title,
                        // year and rating also fit inside the vertical viewport.
                        withFrameNanos { }
                        fullCardBounds.bringIntoView()
                    }
                }
                PosterCard(
                    item = item,
                    onClick = { onItemClick(item) },
                    onLongClick = onItemLongClick?.let { cb -> { cb(item) } },
                    modifier = Modifier
                        .bringIntoViewRequester(fullCardBounds)
                        .onFocusChanged { focused = it.hasFocus }
                        .focusGroup(),
                )
            }
        } }
    }
}
