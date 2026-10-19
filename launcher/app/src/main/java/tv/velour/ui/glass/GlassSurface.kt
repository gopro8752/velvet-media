package tv.velour.ui.glass

import android.graphics.Matrix
import android.graphics.Shader
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.isActive
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * A softened copy of the scene artwork, prepared once off the UI thread when the
 * artwork changes. It is center-cropped exactly like a fullscreen ContentScale.Crop
 * image. The glass samples its own coordinates, so the horizon stays aligned.
 *
 * This deliberately has no screen capture or CPU blur in the draw loop. Tegra TVs
 * can draw the resulting small texture with the same path as newer Android TVs.
 */
@Immutable
data class GlassBackdrop(val image: ImageBitmap, val viewportSize: IntSize)

/** Home also disables this while Settings or ambient mode covers its controls. */
val LocalGlassMotionActive = staticCompositionLocalOf { true }

/**
 * A moving, light-catching edge shared by glass chips and artwork tiles. The rim
 * owns its own display-list layer, so each frame redraws only four cached strokes,
 * never the underlying artwork/text. Paints, shaders, geometry and the shader
 * matrix are cached; the draw callback allocates no paths, gradients or bitmaps.
 *
 * Idle light barely breathes while faint highlights take 80 seconds to orbit.
 * Focus brings up a pearl rim and gently accelerates that same light. The motion
 * stops on lifecycle pause, when hidden, and under Reduce Motion.
 */
@Composable
fun LivingGlassRim(
    modifier: Modifier = Modifier,
    radius: Dp = 14.dp,
    focused: Boolean = false,
    reduceMotion: Boolean = false,
    accent: Color = Color(0xFFC9C0F8),
    seed: Int = 0,
) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val active = LocalGlassMotionActive.current
    val focus = remember { Animatable(if (focused) 1f else 0f) }
    var phase by remember(seed) { mutableFloatStateOf((seed and 0x7fffffff) % 997 / 997f) }
    LaunchedEffect(focused, reduceMotion, active) {
        if (reduceMotion || !active) focus.snapTo(if (focused) 1f else 0f)
        else focus.animateTo(if (focused) 1f else 0f,
            tween(if (focused) 280 else 340, easing = CubicBezierEasing(.2f, .85f, .25f, 1f)))
    }
    LaunchedEffect(lifecycle, active, reduceMotion) {
        if (!active || reduceMotion) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            var lastFrame = 0L
            val tick: (Long) -> Unit = { frame ->
                if (lastFrame != 0L) {
                    // Clamp a resumed/dropped frame rather than jumping the light.
                    val seconds = ((frame - lastFrame) / 1_000_000_000f).coerceIn(0f, .05f)
                    phase = (phase + seconds * (.0125f + .1675f * focus.value)) % 1f
                }
                lastFrame = frame
            }
            while (isActive) withFrameNanos(tick)
        }
    }
    Box(modifier.graphicsLayer().drawWithCache {
        val inset = 1.2.dp.toPx()
        val corner = (radius.toPx() - inset).coerceAtLeast(0f)
        val path = android.graphics.Path().apply {
            addRoundRect(inset, inset, (size.width - inset).coerceAtLeast(inset),
                (size.height - inset).coerceAtLeast(inset), corner, corner, android.graphics.Path.Direction.CW)
        }
        val pearl = Color(0xFFFFFAF2)
        val reflection = lerp(accent, Color.White, .55f)
        val base = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            style = android.graphics.Paint.Style.STROKE
            shader = android.graphics.LinearGradient(0f, 0f, size.width, size.height,
                intArrayOf(pearl.toArgb(), Color.White.copy(alpha = .18f).toArgb(), reflection.toArgb()),
                floatArrayOf(0f, .46f, 1f), Shader.TileMode.CLAMP)
        }
        val orbit = android.graphics.SweepGradient(size.width * .5f, size.height * .5f,
            intArrayOf(Color.Transparent.toArgb(), Color.Transparent.toArgb(), pearl.toArgb(),
                Color.Transparent.toArgb(), Color.Transparent.toArgb(), reflection.copy(alpha = .72f).toArgb(),
                Color.Transparent.toArgb(), Color.Transparent.toArgb()),
            floatArrayOf(0f, .04f, .13f, .23f, .48f, .61f, .73f, 1f))
        val glint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            style = android.graphics.Paint.Style.STROKE
            shader = orbit
        }
        val bloom = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            style = android.graphics.Paint.Style.STROKE
            shader = orbit
        }
        val undercut = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            style = android.graphics.Paint.Style.STROKE
            color = android.graphics.Color.BLACK
            strokeWidth = 3.dp.toPx()
        }
        val matrix = Matrix()
        val thin = .85.dp.toPx()
        val extra = .75.dp.toPx()
        val softWidth = 3.8.dp.toPx()
        onDrawBehind {
            val light = focus.value
            val position = phase
            val breath = if (reduceMotion || !active) .5f else
                .5f + .5f * sin(position * (4f * PI.toFloat()))
            matrix.setRotate(position * 360f, size.width * .5f, size.height * .5f)
            orbit.setLocalMatrix(matrix)
            undercut.alpha = (30f + light * 28f).toInt()
            base.strokeWidth = thin + extra * light
            // Keep idle edges steady and faint; preserve the full focused effect.
            base.alpha = (79f + breath * 6f + light * (88f + breath * 24f)).toInt().coerceAtMost(255)
            glint.strokeWidth = thin + extra * light
            glint.alpha = (24f + breath * 8f + light * (191f + breath * 27f)).toInt().coerceAtMost(255)
            bloom.strokeWidth = softWidth + light * extra
            bloom.alpha = (2f + breath * 2f + light * (32f + breath * 6f)).toInt()
            val canvas = drawContext.canvas.nativeCanvas
            canvas.drawPath(path, undercut)
            canvas.drawPath(path, bloom)
            canvas.drawPath(path, base)
            canvas.drawPath(path, glint)
        }
    })
}

/**
 * Neutral optical glass: softened scene, smoked body, a white light-catching upper
 * lip and a quiet violet lower reflection. The panel itself never accepts focus.
 */
@Composable
fun GlassPanel(
    modifier: Modifier = Modifier,
    radius: Dp = 28.dp,
    tint: Color = Color(0xFF11151F),
    opacity: Float = .42f,
    focused: Boolean = false,
    backdrop: GlassBackdrop? = null,
    reduceMotion: Boolean = false,
    livingRim: Boolean = false,
    rimAccent: Color = Color(0xFFC9C0F8),
    rimSeed: Int = 0,
    content: @Composable BoxScope.() -> Unit,
) {
    var origin by remember { mutableStateOf(Offset.Zero) }
    val shape = remember(radius) { RoundedCornerShape(radius) }
    Box(
        modifier
            .onGloballyPositioned { coordinates ->
                if (backdrop != null) origin = coordinates.positionInRoot()
            }
            .shadow(
                elevation = 16.dp,
                shape = shape,
                clip = false,
                ambientColor = Color.Black.copy(alpha = .28f),
                spotColor = Color.Black.copy(alpha = .30f),
            )
            .clip(shape)
            .drawWithCache {
                val corner = CornerRadius(radius.toPx())
                val halfPixel = .5.dp.toPx()
                val edgeSize = Size(
                    (size.width - halfPixel * 2f).coerceAtLeast(0f),
                    (size.height - halfPixel * 2f).coerceAtLeast(0f),
                )
                val body = Brush.verticalGradient(
                    0f to Color(0xFFE8E8F2).copy(alpha = .13f),
                    .38f to tint.copy(alpha = opacity.coerceIn(0f, 1f)),
                    1f to tint.copy(alpha = (opacity + .12f).coerceIn(0f, 1f)),
                )
                val sheen = Brush.linearGradient(
                    0f to Color.White.copy(alpha = .09f),
                    .3f to Color.White.copy(alpha = .015f),
                    .68f to Color.Transparent,
                    1f to Color(0xFFD2CBFF).copy(alpha = .055f),
                    start = Offset.Zero,
                    end = Offset(size.width, size.height),
                )
                val rim = Brush.linearGradient(
                    0f to Color(0xFFFFF9EF).copy(alpha = if (focused) .85f else .48f),
                    .2f to Color.White.copy(alpha = .23f),
                    .47f to Color.White.copy(alpha = .06f),
                    .73f to Color(0xFFD5CCFF).copy(alpha = .13f),
                    1f to Color(0xFFE3DCFF).copy(alpha = .34f),
                    start = Offset(size.width * .14f, 0f),
                    end = Offset(size.width * .84f, size.height),
                )
                val innerRim = Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = .17f),
                    .5f to Color.Transparent,
                    1f to Color.White.copy(alpha = .07f),
                )
                val texture = backdrop?.takeIf {
                    it.viewportSize.width > 0 && it.viewportSize.height > 0
                }
                val imageScale = texture?.let {
                    max(
                        it.viewportSize.width.toFloat() / it.image.width,
                        it.viewportSize.height.toFloat() / it.image.height,
                    )
                } ?: 1f
                val imageSize = texture?.let {
                    IntSize(
                        (it.image.width * imageScale).roundToInt(),
                        (it.image.height * imageScale).roundToInt(),
                    )
                } ?: IntSize.Zero
                val imageOffset = texture?.let {
                    IntOffset(
                        ((it.viewportSize.width - imageSize.width) * .5f - origin.x).roundToInt(),
                        ((it.viewportSize.height - imageSize.height) * .5f - origin.y).roundToInt(),
                    )
                } ?: IntOffset.Zero
                val rimStroke = Stroke(1.dp.toPx())
                val innerStroke = Stroke(.7.dp.toPx())
                val inset = 1.6.dp.toPx()
                val innerSize = Size(
                    (size.width - inset * 2).coerceAtLeast(0f),
                    (size.height - inset * 2).coerceAtLeast(0f),
                )
                val innerCorner = CornerRadius((radius.toPx() - inset).coerceAtLeast(0f))
                onDrawWithContent {
                    if (texture != null) {
                        drawImage(
                            image = texture.image,
                            dstOffset = imageOffset,
                            dstSize = imageSize,
                            alpha = .92f,
                            filterQuality = FilterQuality.Low,
                        )
                    }
                    drawRoundRect(body, cornerRadius = corner)
                    drawRoundRect(sheen, cornerRadius = corner)
                    drawContent()
                    if (!livingRim) {
                        drawRoundRect(
                            brush = rim,
                            topLeft = Offset(halfPixel, halfPixel),
                            size = edgeSize,
                            cornerRadius = corner,
                            style = rimStroke,
                        )
                    }
                    if (innerSize.width > 0f && innerSize.height > 0f) {
                        drawRoundRect(
                            brush = innerRim,
                            topLeft = Offset(inset, inset),
                            size = innerSize,
                            cornerRadius = innerCorner,
                            style = innerStroke,
                        )
                    }
                }
            },
    ) {
        content()
        if (livingRim) LivingGlassRim(Modifier.matchParentSize(), radius, focused, reduceMotion, rimAccent, rimSeed)
    }
}

/** Fixed geometry keeps remote focus predictable while its light moves softly. */
@Composable
fun GlassDock(
    modifier: Modifier = Modifier,
    backdrop: GlassBackdrop? = null,
    reduceMotion: Boolean = false,
    scene: SceneBackdropState? = null,
    content: @Composable RowScope.() -> Unit,
) {
    Box(modifier) {
        if (scene != null) {
            // The live scene sits underneath the optical body and never samples
            // the dock itself. Its one small crop includes actual cards and text.
            SceneBackdrop(scene, Modifier.matchParentSize().clip(RoundedCornerShape(36.dp)))
        }
        GlassPanel(
            radius = 36.dp,
            opacity = .40f,
            backdrop = if (scene == null) backdrop else null,
            reduceMotion = reduceMotion,
        ) {
            Row(
                modifier = Modifier.padding(6.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
                content = content,
            )
        }
    }
}
