@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
package tv.velour.ui.home

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp

/** Keep focus inside the content viewport without the TV default's automatic pivot jumps. */
@Composable
internal fun HomeViewport(vertical: Boolean, reduced: Boolean, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val start = with(density) { (if (vertical) 8.dp else 42.dp).toPx() }
    val end = with(density) { (if (vertical) 16.dp else 42.dp).toPx() }
    val spec = remember(start, end, reduced) {
        object : BringIntoViewSpec {
            // Compose 1.7.6's UpdatableAnimationState restarts from the remaining
            // distance every frame. A tween keeps repeating its ease-in and creeps;
            // a critically damped spring preserves velocity without overshooting.
            override val scrollAnimationSpec = if (reduced) snap<Float>() else spring(
                dampingRatio = Spring.DampingRatioNoBouncy,
                stiffness = Spring.StiffnessMedium,
            )
            override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
                val usableEnd = (containerSize - end).coerceAtLeast(start + 1f)
                return when {
                    size > usableEnd - start -> offset - start
                    offset < start -> offset - start
                    offset + size > usableEnd -> offset + size - usableEnd
                    else -> 0f
                }
            }
        }
    }
    CompositionLocalProvider(LocalBringIntoViewSpec provides spec, content = content)
}
