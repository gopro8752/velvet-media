@file:OptIn(ExperimentalComposeUiApi::class)

package tv.velour.ui.home

import android.os.SystemClock
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import tv.velour.core.AppEntry
import tv.velour.ui.components.AppCard
import tv.velour.ui.components.FavoritesKeylineLocal
import tv.velour.ui.theme.VelourMotion

/*
 * ZONE B: FAVORITES (DESIGN.md, y 230–360dp). No label. 192x108dp cards, radius 10dp,
 * 18dp gaps, left keyline x=48dp with the focused card pinned to it (KeylineBringIntoViewSpec),
 * right-edge peek as the scroll affordance. Max 12 favorites, focused scale 1.12
 * (1.16 while MOVE-lifted). Reorder swaps slide on the 0.78/380 spring via animateItem.
 *
 * The LazyRow carries 32dp of internal vertical headroom (GLOW_PAD) so the radial
 * under-glow is not clipped by the scroll container; HomeScreen compensates in the
 * spine's top padding so cards still rest at y=230.
 */

val FAVORITES_GLOW_PAD = 32.dp
val FAVORITE_CARD_WIDTH = 192.dp
val FAVORITE_CARD_HEIGHT = 108.dp
private val FAVORITE_LABEL_SPACE = 32.dp // 12dp gap + 20dp label slot inside AppCard

/** Row item height: glow pad + card + label slot + glow pad. */
val FAVORITES_ROW_HEIGHT = FAVORITES_GLOW_PAD + FAVORITE_CARD_HEIGHT + FAVORITE_LABEL_SPACE + FAVORITES_GLOW_PAD

/** Sentinel for [FavoritesRow.introAtMs]: cold-start choreography already played. */
const val INTRO_DONE = Long.MIN_VALUE

/** Art passthrough wiring AppCard to the repository caches via HomeViewModel. */
class CardArtLoader(
    val banner: suspend (String) -> ImageBitmap?,
    val whisper: suspend (String) -> Color?,
)

@Composable
fun FavoritesRow(
    favorites: List<AppEntry>,
    accent: Color,
    reduceMotion: Boolean,
    focusedIndex: Int?,            // focused favorite index, for neighbor dimming
    cardFocusActive: Boolean,      // any card focused anywhere AND no menu up -> house dimming on
    movingPackage: String?,        // non-null while MOVE mode is active
    introAtMs: Long,               // cold-start origin (uptimeMillis) or INTRO_DONE
    rowFocus: FocusRequester,
    firstCardFocus: FocusRequester,
    gearFocus: FocusRequester,
    art: CardArtLoader,
    worldDim: () -> Float,         // long-press world dim x marquee chrome (draw-phase read)
    menuPackage: String?,          // pressed card holds 100% while the menu is up
    pressedPackage: String?,       // sticky long-press target: keeps the restore requester attached
    listState: LazyListState,      // hoisted so MOVE mode can keep the lifted card pinned
    onCardFocused: (index: Int, centerXNorm: Float) -> Unit,
    onLaunch: (AppEntry, Rect) -> Unit,
    onLongPress: (AppEntry, Rect) -> Unit,
    pressedCardFocus: FocusRequester, // re-attached to the long-pressed card for restore-on-dismiss
    modifier: Modifier = Modifier,
) {
    val cardHeightPx = with(LocalDensity.current) { FAVORITE_CARD_HEIGHT.toPx() }
    FavoritesKeylineLocal {
        LazyRow(
            state = listState,
            contentPadding = PaddingValues(horizontal = 48.dp, vertical = FAVORITES_GLOW_PAD),
            horizontalArrangement = Arrangement.spacedBy(18.dp),
            modifier = modifier
                .fillMaxWidth()
                .height(FAVORITES_ROW_HEIGHT)
                .focusGroup()
                .focusRequester(rowFocus)
                .focusRestorer { firstCardFocus },
        ) {
            itemsIndexed(
                items = favorites,
                key = { _, entry -> entry.packageName },
            ) { index, entry ->
                FavoriteCard(
                    entry = entry,
                    index = index,
                    accent = accent,
                    reduceMotion = reduceMotion,
                    focusedIndex = focusedIndex,
                    cardFocusActive = cardFocusActive,
                    moving = entry.packageName == movingPackage,
                    introAtMs = introAtMs,
                    firstCardFocus = if (index == 0) firstCardFocus else null,
                    gearFocus = gearFocus,
                    art = art,
                    worldDim = worldDim,
                    menuExempt = entry.packageName == menuPackage,
                    cardHeightPx = cardHeightPx,
                    onCardFocused = onCardFocused,
                    onLaunch = onLaunch,
                    onLongPress = onLongPress,
                    pressedCardFocus = pressedCardFocus.takeIf { entry.packageName == pressedPackage },
                    modifier = Modifier.animateItem(
                        fadeInSpec = null,
                        fadeOutSpec = null,
                        // Reorder swaps: 0.78 damping / 380 stiffness spring slides (DESIGN.md MOVE MODE).
                        placementSpec = spring(
                            dampingRatio = 0.78f,
                            stiffness = 380f,
                            visibilityThreshold = IntOffset.VisibilityThreshold,
                        ),
                    ),
                )
            }
        }
    }
}

@Composable
private fun FavoriteCard(
    entry: AppEntry,
    index: Int,
    accent: Color,
    reduceMotion: Boolean,
    focusedIndex: Int?,
    cardFocusActive: Boolean,
    moving: Boolean,
    introAtMs: Long,
    firstCardFocus: FocusRequester?,
    gearFocus: FocusRequester,
    art: CardArtLoader,
    worldDim: () -> Float,
    menuExempt: Boolean,
    cardHeightPx: Float,
    onCardFocused: (Int, Float) -> Unit,
    onLaunch: (AppEntry, Rect) -> Unit,
    onLongPress: (AppEntry, Rect) -> Unit,
    pressedCardFocus: FocusRequester?,
    modifier: Modifier = Modifier,
) {
    var bannerResolved by remember(entry.packageName) { mutableStateOf(false) }
    var banner by remember(entry.packageName) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(art, entry.packageName) {
        banner = art.banner(entry.packageName)
        bannerResolved = true
    }
    // Whisper (icon render + Palette) runs only after the banner lookup has DEFINITIVELY
    // resolved to null — never speculatively for cards that will get banners.
    var whisper by remember(entry.packageName) { mutableStateOf<Color?>(null) }
    LaunchedEffect(art, entry.packageName, bannerResolved && banner == null) {
        whisper = if (bannerResolved && banner == null) art.whisper(entry.packageName) else null
    }

    // Cold-start choreography: favorites stagger in 40ms apart (each 300ms Decelerate)
    // starting at +400ms. Cards composed after the intro window snap straight in.
    val intro = remember { Animatable(if (introAtMs == INTRO_DONE) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (intro.value < 1f) {
            val wait = introAtMs + 400L + 40L * index - SystemClock.uptimeMillis()
            if (wait > 0) delay(wait)
            intro.animateTo(1f, tween(300, easing = VelourMotion.Decelerate))
        }
    }

    var coords by remember { mutableStateOf<LayoutCoordinates?>(null) }
    val isFocusedCard = focusedIndex == index
    val isNeighbor = focusedIndex != null && kotlin.math.abs(focusedIndex - index) == 1

    AppCard(
        entry = entry,
        banner = banner,
        whisper = whisper,
        width = FAVORITE_CARD_WIDTH,
        height = FAVORITE_CARD_HEIGHT,
        radius = 10.dp,
        accent = accent,
        focusedScale = if (moving) 1.16f else 1.12f,
        dimmed = cardFocusActive && !isFocusedCard && !isNeighbor,
        neighborDim = cardFocusActive && isNeighbor && !isFocusedCard,
        reduceMotion = reduceMotion,
        smallType = false,
        onLaunch = { bounds -> onLaunch(entry, bounds) },
        onLongPress = {
            coords?.let { c ->
                val b = c.boundsInRoot()
                onLongPress(entry, Rect(b.left, b.top, b.right, b.top + cardHeightPx))
            }
        },
        onFocused = { norm -> onCardFocused(index, norm) },
        // The long-pressed card holds its full focus treatment (scale, rim, glow) while
        // the menu owns input; the requester is attached exactly while this is true.
        heldFocused = pressedCardFocus != null,
        modifier = modifier
            .onGloballyPositioned { coords = it }
            .focusProperties { up = gearFocus }
            .then(if (firstCardFocus != null) Modifier.focusRequester(firstCardFocus) else Modifier)
            .then(if (pressedCardFocus != null) Modifier.focusRequester(pressedCardFocus) else Modifier)
            .graphicsLayer {
                alpha = intro.value * (if (menuExempt) 1f else worldDim())
            },
    )
}
