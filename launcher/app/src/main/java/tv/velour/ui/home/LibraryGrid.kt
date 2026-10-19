package tv.velour.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import tv.velour.core.AppEntry
import tv.velour.ui.components.AppCard
import tv.velour.ui.components.elementAlpha
import tv.velour.ui.theme.VelourColors
import tv.velour.ui.theme.VelourType

/*
 * ZONE C: LIBRARY (DESIGN.md, below the fold). "LIBRARY · {count}" eyebrow peeking at
 * y≈400dp as the scroll hint, then 6 columns of 128x72dp banner tiles, radius 8dp,
 * 14dp gaps, alphabetical, hidden apps excluded (the ViewModel already filtered),
 * focused scale 1.10, playbill fallback at tile size. Composed as chunked rows inside
 * HomeScreen's spine LazyColumn so the single vertical scroll owns the whole journey.
 */

private val TILE_WIDTH = 128.dp
private val TILE_HEIGHT = 72.dp
private const val COLUMNS = 6

/** Library grid cell address: row to column. */
typealias LibraryCell = Pair<Int, Int>

fun LazyListScope.libraryGrid(
    library: List<AppEntry>,
    accent: Color,
    reduceMotion: Boolean,
    focusedCell: LibraryCell?,
    cardFocusActive: Boolean,
    art: CardArtLoader,
    worldDim: () -> Float,
    menuPackage: String?,
    pressedPackage: String?,
    onCardFocused: (row: Int, col: Int, centerXNorm: Float) -> Unit,
    onLaunch: (AppEntry, Rect) -> Unit,
    onLongPress: (AppEntry, Rect) -> Unit,
    pressedCardFocus: FocusRequester,
) {
    item(key = "library_eyebrow") {
        androidx.tv.material3.Text(
            text = "LIBRARY · ${library.size}",
            style = VelourType.eyebrow,
            color = VelourColors.InkTertiary,
            modifier = Modifier
                .padding(start = 48.dp, bottom = 16.dp)
                .elementAlpha(worldDim),
        )
    }
    val rows = library.chunked(COLUMNS)
    rows.forEachIndexed { rowIndex, rowEntries ->
        item(key = "library_row_$rowIndex") {
            Row(
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 48.dp, end = 48.dp, bottom = 14.dp),
            ) {
                rowEntries.forEachIndexed { colIndex, entry ->
                    LibraryTile(
                        entry = entry,
                        row = rowIndex,
                        col = colIndex,
                        accent = accent,
                        reduceMotion = reduceMotion,
                        focusedCell = focusedCell,
                        cardFocusActive = cardFocusActive,
                        art = art,
                        worldDim = worldDim,
                        menuExempt = entry.packageName == menuPackage,
                        onCardFocused = onCardFocused,
                        onLaunch = onLaunch,
                        onLongPress = onLongPress,
                        pressedCardFocus = pressedCardFocus.takeIf { entry.packageName == pressedPackage },
                    )
                }
            }
        }
    }
}

@Composable
private fun LibraryTile(
    entry: AppEntry,
    row: Int,
    col: Int,
    accent: Color,
    reduceMotion: Boolean,
    focusedCell: LibraryCell?,
    cardFocusActive: Boolean,
    art: CardArtLoader,
    worldDim: () -> Float,
    menuExempt: Boolean,
    onCardFocused: (Int, Int, Float) -> Unit,
    onLaunch: (AppEntry, Rect) -> Unit,
    onLongPress: (AppEntry, Rect) -> Unit,
    pressedCardFocus: FocusRequester?,
) {
    var bannerResolved by remember(entry.packageName) { mutableStateOf(false) }
    var banner by remember(entry.packageName) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(art, entry.packageName) {
        banner = art.banner(entry.packageName)
        bannerResolved = true
    }
    // Whisper (icon render + Palette) runs only after the banner lookup has DEFINITIVELY
    // resolved to null — never speculatively for tiles that will get banners.
    var whisper by remember(entry.packageName) { mutableStateOf<Color?>(null) }
    LaunchedEffect(art, entry.packageName, bannerResolved && banner == null) {
        whisper = if (bannerResolved && banner == null) art.whisper(entry.packageName) else null
    }
    var coords by remember { mutableStateOf<LayoutCoordinates?>(null) }

    val isFocusedTile = focusedCell?.first == row && focusedCell?.second == col
    // Graduated darkness: immediate same-row neighbors only (DESIGN.md FOCUS ENTER).
    val isNeighbor = focusedCell != null && focusedCell.first == row &&
        kotlin.math.abs(focusedCell.second - col) == 1

    AppCard(
        entry = entry,
        banner = banner,
        whisper = whisper,
        width = TILE_WIDTH,
        height = TILE_HEIGHT,
        radius = 8.dp,
        accent = accent,
        focusedScale = 1.10f,
        dimmed = cardFocusActive && !isFocusedTile && !isNeighbor,
        neighborDim = cardFocusActive && isNeighbor && !isFocusedTile,
        reduceMotion = reduceMotion,
        smallType = true,
        onLaunch = { bounds -> onLaunch(entry, bounds) },
        onLongPress = {
            coords?.let { c ->
                val b = c.boundsInRoot()
                onLongPress(entry, Rect(b.left, b.top, b.right, b.bottom))
            }
        },
        onFocused = { norm -> onCardFocused(row, col, norm) },
        // The long-pressed tile holds its full focus treatment while the menu owns input.
        heldFocused = pressedCardFocus != null,
        modifier = Modifier
            .onGloballyPositioned { coords = it }
            .then(
                if (pressedCardFocus != null) {
                    Modifier.focusRequester(pressedCardFocus)
                } else Modifier
            )
            .graphicsLayer {
                alpha = if (menuExempt) 1f else worldDim()
            },
    )
}
