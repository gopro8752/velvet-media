package tv.velvet.ui.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.CompositingStrategy
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlin.math.ceil

/** The page is a shared display list; it never includes the dock or its own reflection. */
class DockBackdropState(val page: GraphicsLayer) {
    var pageOrigin by mutableStateOf(Offset.Zero)
}

@Composable
fun rememberDockBackdrop(): DockBackdropState {
    val page = rememberGraphicsLayer()
    return remember(page) { DockBackdropState(page) }
}

fun Modifier.dockBackdropSource(state: DockBackdropState): Modifier = this
    .onGloballyPositioned { state.pageOrigin = it.positionInRoot() }
    .drawWithContent {
        state.page.record { this@drawWithContent.drawContent() }
        drawLayer(state.page)
    }

/**
 * A small, entirely GPU-rendered backdrop for Android 11 as well as newer TVs.
 *
 * RenderNode references remain live: when the page's scroll layers move, HWUI draws
 * that same frame into a small crop, then two five-tap blur passes.
 * Only the dock-sized crop is rasterized offscreen. The rest of the page remains a
 * display list, and the blur taps reuse its small texture instead of replaying it.
 * There is no pixel readback, bitmap allocation, CPU blur, timer, or frame-driven
 * composition. Disposing the dock releases all its layers through rememberGraphicsLayer.
 */
@Composable
fun DockBackdrop(state: DockBackdropState, modifier: Modifier = Modifier) {
    val crop = rememberGraphicsLayer()
    val horizontal = rememberGraphicsLayer()
    val vertical = rememberGraphicsLayer()
    val horizontalTaps = List(BlurWeights.size) { rememberGraphicsLayer() }
    val verticalTaps = List(BlurWeights.size) { rememberGraphicsLayer() }
    var origin by remember { mutableStateOf(Offset.Zero) }

    Box(modifier
        .onGloballyPositioned { origin = it.positionInRoot() }
        .drawWithCache {
            val tapDistance = 4.dp.toPx()
            // Adjacent blur taps must sample adjacent texture texels. A higher
            // resolution crop with widely spaced taps creates repeated text edges.
            val sampleScale = 1f / tapDistance.coerceAtLeast(1f)
            // Both ends need two taps of real content beyond the visible glass edge.
            val padding = tapDistance * 2 + 1 / sampleScale
            val cropSize = IntSize(
                ceil((size.width + padding * 2) * sampleScale).toInt().coerceAtLeast(1),
                ceil((size.height + padding * 2) * sampleScale).toInt().coerceAtLeast(1),
            )
            val pageOffset = origin - state.pageOrigin
            crop.compositingStrategy = CompositingStrategy.Offscreen
            crop.clip = true
            crop.record(this, layoutDirection, cropSize) {
                scale(sampleScale, sampleScale, Offset.Zero) {
                    translate(padding - pageOffset.x, padding - pageOffset.y) {
                        drawLayer(state.page)
                    }
                }
            }
            recordBlurPass(this, layoutDirection, crop, horizontal, horizontalTaps, cropSize, tapDistance * sampleScale, horizontal = true)
            recordBlurPass(this, layoutDirection, horizontal, vertical, verticalTaps, cropSize, tapDistance * sampleScale, horizontal = false)

            onDrawBehind {
                if (!state.page.isReleased) {
                    clipRect {
                        translate(-padding, -padding) {
                            scale(1 / sampleScale, 1 / sampleScale, Offset.Zero) {
                                drawLayer(vertical)
                            }
                        }
                    }
                }
            }
        })
}

private val BlurWeights = floatArrayOf(1f, 4f, 6f, 4f, 1f)

/** Binomial convolution using tiny cached textures, supported by HWUI on API 26+. */
private fun recordBlurPass(
    density: Density,
    layoutDirection: LayoutDirection,
    source: GraphicsLayer,
    output: GraphicsLayer,
    taps: List<GraphicsLayer>,
    size: IntSize,
    distance: Float,
    horizontal: Boolean,
) {
    var accumulatedWeight = 0f
    taps.forEachIndexed { index, tap ->
        accumulatedWeight += BlurWeights[index]
        // Successive source-over weights form a normalized weighted average. Each
        // tap contains one opaque texture, so ModulateAlpha needs no extra buffer.
        tap.alpha = BlurWeights[index] / accumulatedWeight
        tap.compositingStrategy = CompositingStrategy.ModulateAlpha
        tap.record(density, layoutDirection, size) { drawLayer(source) }
    }
    output.compositingStrategy = CompositingStrategy.Offscreen
    output.clip = true
    output.record(density, layoutDirection, size) {
        taps.forEachIndexed { index, tap ->
            val offset = (index - 2) * distance
            translate(if (horizontal) offset else 0f, if (horizontal) 0f else offset) {
                drawLayer(tap)
            }
        }
    }
}
