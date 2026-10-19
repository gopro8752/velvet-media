@file:OptIn(ExperimentalFoundationApi::class)

package tv.velour.ui.components

import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import tv.velour.ui.theme.VelourMotion

/*
 * D-pad scroll control, adapted from velvet's BringIntoView.kt pivot pattern.
 *
 * Velour's spine has two scroll personalities (DESIGN.md):
 *  - Favorites row: KEYLINE scrolling — the focused card pins to x=48dp,
 *    320ms Decelerate (RowScrollMs).
 *  - Vertical spine: Favorites <-> Library transitions at 420ms Decelerate (SpineMs),
 *    with library rows riding at a ~42% pivot so favorites returns to its rest
 *    position (y=230 of 540) when focus walks back up.
 *
 * CompositionLocals cascade, so the horizontal keyline local must wrap the LazyRow
 * INSIDE the vertical local's column.
 */

/** Pins the focused child's leading edge to a fixed keyline offset from the container start. */
private class KeylineBringIntoViewSpec(
    private val keylinePx: Float,
    private val spec: AnimationSpec<Float>,
) : BringIntoViewSpec {
    override val scrollAnimationSpec: AnimationSpec<Float> get() = spec
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float =
        offset - keylinePx
}

/** Classic fractional pivot (velvet's PivotBringIntoViewSpec) with a custom animation spec. */
private class PivotBringIntoViewSpec(
    private val parentFraction: Float,
    private val spec: AnimationSpec<Float>,
) : BringIntoViewSpec {
    override val scrollAnimationSpec: AnimationSpec<Float> get() = spec
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float =
        offset - containerSize * parentFraction
}

/** Favorites keyline: focused card pins to x=48dp, 320ms Decelerate. */
@Composable
fun FavoritesKeylineLocal(content: @Composable () -> Unit) {
    val keylinePx = with(LocalDensity.current) { 48.dp.toPx() }
    val spec = remember(keylinePx) {
        KeylineBringIntoViewSpec(
            keylinePx = keylinePx,
            spec = tween(VelourMotion.RowScrollMs, easing = VelourMotion.Decelerate),
        )
    }
    CompositionLocalProvider(LocalBringIntoViewSpec provides spec, content = content)
}

/** Vertical spine: 420ms Decelerate, library rows pivot at 42% of the viewport. */
@Composable
fun SpinePivotLocal(content: @Composable () -> Unit) {
    val spec = remember {
        PivotBringIntoViewSpec(
            parentFraction = 230f / 540f,
            spec = tween(VelourMotion.SpineMs, easing = VelourMotion.Decelerate),
        )
    }
    CompositionLocalProvider(LocalBringIntoViewSpec provides spec, content = content)
}
