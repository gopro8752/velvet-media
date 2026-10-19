@file:OptIn(ExperimentalFoundationApi::class)

package tv.velvet.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider

/**
 * D-pad focus scrolling control. On TV, Compose's platform-default BringIntoViewSpec
 * pivots the focused child to 30% of the viewport — which scrolls vertical columns
 * even when the focused hero buttons are already fully visible, beheading the hero
 * artwork. We pin our own pivots instead:
 *  - vertical columns: 48% — heroes stay intact at the top, focused rows sit
 *    mid-screen Netflix-style while browsing down
 *  - horizontal rails: 30% — focused cards ride at the left third
 * CompositionLocals cascade, so every horizontal rail inside a [VerticalPivotLocal]
 * column must wrap its LazyRow in [HorizontalPivotLocal].
 */
private class PivotBringIntoViewSpec(private val parentFraction: Float) : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float =
        offset - containerSize * parentFraction
}

private val VerticalPivot: BringIntoViewSpec = PivotBringIntoViewSpec(0.48f)
private val HorizontalPivot: BringIntoViewSpec = PivotBringIntoViewSpec(0.30f)

@Composable
fun VerticalPivotLocal(content: @Composable () -> Unit) =
    CompositionLocalProvider(LocalBringIntoViewSpec provides VerticalPivot, content = content)

@Composable
fun HorizontalPivotLocal(content: @Composable () -> Unit) =
    CompositionLocalProvider(LocalBringIntoViewSpec provides HorizontalPivot, content = content)
