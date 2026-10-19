package tv.velour.ui.components

import android.graphics.Matrix
import android.graphics.Shader
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.debugInspectorInfo
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import tv.velour.ui.theme.VelourMotion
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/*
 * The five-layer focus treatment (DESIGN.md "Elevation / glow recipe" + "Motion / FOCUS ENTER"):
 *
 *  1. Scale       — 1.0 -> focusedScale, 260ms Spotlight in / 200ms out, via graphicsLayer.
 *  2. Shadow      — two stacked translucent rounded-rects behind the card (no shadow APIs).
 *  3. Under-glow  — one cached RadialGradient (accent -> transparent), extent 1.6x card size;
 *                   ignites 0->100% in 220ms, breathes 18%<->26% on a 4000ms sine while focused,
 *                   decays IN PLACE over 350ms on focus loss (the "ember trail").
 *  4. Rim light   — 1dp hairline: rest #FFFFFF@8% crossfading to a vertical-gradient stroke
 *                   (35% top -> 0% bottom) over 200ms.
 *  5. Specular sweep — one cached LinearGradient band (45% of card width, rotated 30°),
 *                   translated across the card via setLocalMatrix, clipped to the rounded rect;
 *                   fires exactly once per focus gain, 600ms ease-out, +80ms after focus.
 *
 *  Plus house dimming: unfocused content 78% alpha (row neighbors 90%) + 3-keyframe
 *  desaturation via ColorMatrixColorFilter (card-sized saveLayer, never full-screen).
 *
 *  All animated values are read ONLY inside graphicsLayer{} / draw lambdas; the Animatables
 *  are driven from the `focused` flag (the caller wires onFocusChanged), so 60fps motion never
 *  recomposes or relayouts.
 */

private val SweepEaseOut = CubicBezierEasing(0f, 0f, 0.2f, 1f)

/** DESIGN.md FOCUS ENTER: "rim animates 8% -> top-gradient 35% in 200ms" — its own clock. */
private const val RimEnterMs = 200

/** Saturation keyframes for house dimming, precomputed once — stepped, zero alloc in draw. */
private val SatFilters: Array<ColorFilter> = arrayOf(
    saturationFilter(0.95f),
    saturationFilter(0.90f),
    saturationFilter(0.85f),
)

private fun saturationFilter(sat: Float): ColorFilter =
    ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(sat) })

fun Modifier.velourFocus(
    focused: Boolean,
    accent: Color,
    radius: Dp,
    focusedScale: Float = 1.12f,
    glowBoost: Float = 1f,        // reorder lift passes >1 (glow doubles + 1500ms pulse)
    dimmed: Boolean = false,      // house dimming (78% + desaturate)
    neighborDim: Boolean = false, // 90%
    reduceMotion: Boolean = false,
    // CONTRACT-NOTE: two defaulted params beyond the contract signature — the booth row
    // needs an accent rim (DESIGN.md BOOTH ROW) and the accent swatches a 250ms glow
    // bloom (DESIGN.md ACCENT). Defaults preserve contract behavior for every other caller.
    rimColor: Color = Color.White,
    glowIgniteMs: Int = VelourMotion.GlowIgniteMs,
): Modifier = composed(
    inspectorInfo = debugInspectorInfo {
        name = "velourFocus"
        properties["focused"] = focused
    }
) {
    val lifecycleOwner = LocalLifecycleOwner.current

    // -- animation state ------------------------------------------------------------------
    // Focus transform progress (scale, shadow): 0..1, 260ms Spotlight in.
    val focusProgress = remember { Animatable(0f) }
    // Rim crossfade progress: 0..1 — its own 200ms clock (DESIGN.md FOCUS ENTER).
    val rimProgress = remember { Animatable(0f) }
    // Glow ignite/ember: 0..1, multiplied by the breath value.
    val glowIgnite = remember { Animatable(0f) }
    // Breath phase written per-frame while focused; read only in draw.
    var breathValue by remember { mutableFloatStateOf(0.22f) }
    // Specular sweep progress: 0..1; <=0 or >=1 means "not drawing".
    val sweep = remember { Animatable(0f) }
    // House dimming alpha (1.0 / 0.90 / 0.78), 200ms linear.
    val dimAlpha = remember { Animatable(1f) }

    val pulsing = glowBoost > 1f
    val breathPeriodMs = if (pulsing) 1500f else 4000f

    // MOVE mode hands in a different focusedScale (1.16) and glowBoost (2x) while the
    // card is lifted; ease both so the lift settles in and the glow "exhales" over
    // 250ms on commit instead of snapping.
    val scaleTarget = remember { Animatable(focusedScale) }
    androidx.compose.runtime.LaunchedEffect(focusedScale) {
        scaleTarget.animateTo(focusedScale, tween(250, easing = VelourMotion.Spotlight))
    }
    val boost = remember { Animatable(glowBoost) }
    androidx.compose.runtime.LaunchedEffect(glowBoost) {
        boost.animateTo(glowBoost, tween(250, easing = LinearEasing))
    }

    androidx.compose.runtime.LaunchedEffect(focused, reduceMotion, pulsing) {
        if (focused) {
            // Layer 1+2: transform in, 260ms Spotlight.
            launch {
                if (reduceMotion) {
                    focusProgress.animateTo(1f, tween(VelourMotion.FocusEnterMs, easing = LinearEasing))
                } else {
                    focusProgress.animateTo(
                        1f,
                        tween(VelourMotion.FocusEnterMs, easing = VelourMotion.Spotlight),
                    )
                }
            }
            // Layer 4: rim crossfade 8% -> 35%-top gradient in 200ms (DESIGN.md FOCUS ENTER).
            launch {
                rimProgress.animateTo(
                    1f,
                    tween(
                        RimEnterMs,
                        easing = if (reduceMotion) LinearEasing else VelourMotion.Spotlight,
                    ),
                )
            }
            // Layer 5: one-shot specular sweep, +80ms after focus, 600ms ease-out. Never loops.
            launch {
                sweep.snapTo(0f)
                if (!reduceMotion) {
                    delay(VelourMotion.SweepDelayMs.toLong())
                    sweep.animateTo(1f, tween(VelourMotion.SweepMs, easing = SweepEaseOut))
                }
            }
            // Layer 3: glow ignites 0->100% in 220ms, then breathes on a sine.
            // Breath is retained under reduce-motion (DESIGN.md REDUCE MOTION keeps glow breath),
            // but pauses whenever the launcher is not RESUMED ("All InfiniteTransitions pause
            // when not RESUMED") — no per-frame work while a launched app owns the screen.
            launch {
                glowIgnite.animateTo(1f, tween(glowIgniteMs, easing = LinearEasing))
                lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                    val t0 = System.nanoTime()
                    val tick: (Long) -> Unit = { now -> // hoisted: no per-frame lambda alloc
                        val tMs = (now - t0) / 1_000_000f
                        breathValue =
                            0.22f + 0.04f * sin(2f * PI.toFloat() * tMs / breathPeriodMs)
                    }
                    while (isActive) withFrameNanos(tick)
                }
            }
        } else {
            launch {
                focusProgress.animateTo(
                    0f,
                    tween(VelourMotion.FocusExitMs, easing = VelourMotion.Spotlight),
                )
            }
            launch {
                rimProgress.animateTo(0f, tween(VelourMotion.FocusExitMs, easing = VelourMotion.Spotlight))
            }
            // Ember trail: the glow cools in place over 350ms while the next card ignites.
            launch { glowIgnite.animateTo(0f, tween(VelourMotion.EmberDecayMs, easing = LinearEasing)) }
            launch { sweep.snapTo(0f) }
        }
    }

    androidx.compose.runtime.LaunchedEffect(focused, dimmed, neighborDim) {
        val target = when {
            focused -> 1f
            dimmed -> 0.78f
            neighborDim -> 0.90f
            else -> 1f
        }
        dimAlpha.animateTo(target, tween(VelourMotion.DimMs, easing = LinearEasing))
    }

    // Card-sized saveLayer paint for the desaturation pass; filter swapped per keyframe band.
    val satPaint = remember { Paint() }

    this
        // Layers 2 + 3 sit OUTSIDE the scale layer so the ember decays in place
        // (the cooling pool of light does not follow the shrinking card).
        .drawWithCache {
            val w = size.width
            val h = size.height
            val r = radius.toPx()
            // Under-glow: one cached android RadialGradient, accent at full alpha in the
            // center -> transparent; paint alpha modulates it per frame. Extent 1.6x card.
            val glowRadius = 0.8f * maxOf(w, h * 1.78f)
            val glowCx = w / 2f
            val glowCy = h * 0.66f // light pools beneath the card
            val glowPaint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                shader = android.graphics.RadialGradient(
                    glowCx, glowCy, glowRadius,
                    accent.toArgb(), 0x00FFFFFF and accent.toArgb(),
                    Shader.TileMode.CLAMP,
                )
            }
            val shadowR = r + 2.dp.toPx()
            onDrawBehind {
                val fp = focusProgress.value
                // Shadow: #000@30% offset y+6dp inflated 2dp, #000@15% y+14dp inflated 6dp.
                // This layer is unscaled (so the ember can decay in place), so the shadow
                // rects track the visually scaled card bounds themselves.
                if (fp > 0.01f) {
                    val s = 1f + (scaleTarget.value - 1f) * fp
                    val growX = w * (s - 1f) / 2f
                    val growY = h * (s - 1f) / 2f
                    val i1 = 2.dp.toPx()
                    val i2 = 6.dp.toPx()
                    drawRoundRect(
                        color = Color.Black,
                        topLeft = Offset(-growX - i2, -growY + 14.dp.toPx() - i2),
                        size = Size(w * s + 2 * i2, h * s + 2 * i2),
                        cornerRadius = CornerRadius(shadowR, shadowR),
                        alpha = 0.15f * fp,
                    )
                    drawRoundRect(
                        color = Color.Black,
                        topLeft = Offset(-growX - i1, -growY + 6.dp.toPx() - i1),
                        size = Size(w * s + 2 * i1, h * s + 2 * i1),
                        cornerRadius = CornerRadius(shadowR, shadowR),
                        alpha = 0.30f * fp,
                    )
                }
                // Under-glow / ember.
                val glow = glowIgnite.value * breathValue * boost.value
                if (glow > 0.002f) {
                    glowPaint.alpha = (glow.coerceIn(0f, 1f) * 255f).toInt()
                    drawContext.canvas.nativeCanvas.drawCircle(glowCx, glowCy, glowRadius, glowPaint)
                }
            }
        }
        // Layer 1: scale + house-dim alpha. transformOrigin = center (default).
        .graphicsLayer {
            val fp = focusProgress.value
            val s = 1f + (scaleTarget.value - 1f) * fp
            scaleX = s
            scaleY = s
            alpha = dimAlpha.value
        }
        // Desaturation + layers 4 + 5 (drawn over the content, inside the scale layer).
        .drawWithCache {
            val w = size.width
            val h = size.height
            val r = radius.toPx()
            val cardRect = RoundRect(0f, 0f, w, h, CornerRadius(r, r))
            val clip = Path().apply { addRoundRect(cardRect) }
            val layerRect = Rect(0f, 0f, w, h) // cached: no allocation inside draw

            // Rim: rest hairline + focused vertical-gradient stroke (cached ShaderBrush).
            val rimBrush = androidx.compose.ui.graphics.Brush.verticalGradient(
                0f to rimColor.copy(alpha = 0.35f),
                1f to rimColor.copy(alpha = 0f),
            )
            val hairline = Stroke(width = 1.dp.toPx())

            // Specular sweep: cached gradient band rotated 30°, moved via setLocalMatrix.
            val bandW = 0.45f * w
            val rad = (30.0 * PI / 180.0)
            val dirX = cos(rad).toFloat()
            val dirY = sin(rad).toFloat()
            val sweepShader = android.graphics.LinearGradient(
                0f, 0f, bandW * dirX, bandW * dirY,
                intArrayOf(0x00FFFFFF, 0x1FFFFFFF, 0x00FFFFFF), // transparent -> white@12% -> transparent
                floatArrayOf(0f, 0.5f, 1f),
                Shader.TileMode.CLAMP,
            )
            val sweepPaint = android.graphics.Paint().apply { shader = sweepShader }
            val sweepMatrix = Matrix()
            val travel = w + 2f * bandW // from -bandW to cardWidth + bandWidth

            onDrawWithContent {
                // House-dim desaturation: 3 stepped keyframes keyed off the dim alpha so the
                // 200ms dim transition walks 0.95 / 0.90 / 0.85 with zero allocation.
                // CONTRACT-NOTE: DESIGN.md's "immediate row neighbors only to 90%" is read as
                // graduated alpha AND saturation — neighbors land on the 0.90 keyframe.
                val da = dimAlpha.value
                val filter: ColorFilter? = if ((dimmed || neighborDim) && da < 0.995f) {
                    when {
                        da > 0.927f -> SatFilters[0]
                        da > 0.853f -> SatFilters[1]
                        else -> SatFilters[2]
                    }
                } else null
                if (filter != null) {
                    satPaint.colorFilter = filter
                    drawContext.canvas.saveLayer(layerRect, satPaint)
                    this@onDrawWithContent.drawContent()
                    drawContext.canvas.restore()
                } else {
                    this@onDrawWithContent.drawContent()
                }

                // Layer 4: rim hairline crossfade 8% rest -> 35%-top gradient, on the
                // dedicated 200ms rim clock (not the 260ms transform progress).
                val rp = rimProgress.value
                if (rp < 1f) {
                    drawRoundRect(
                        color = Color.White,
                        cornerRadius = CornerRadius(r, r),
                        style = hairline,
                        alpha = 0.08f * (1f - rp),
                    )
                }
                if (rp > 0f) {
                    drawRoundRect(
                        brush = rimBrush,
                        cornerRadius = CornerRadius(r, r),
                        style = hairline,
                        alpha = rp,
                    )
                }

                // Layer 5: specular sweep, clipped to the rounded rect.
                val sp = sweep.value
                if (sp > 0f && sp < 1f) {
                    val d = -bandW + travel * sp
                    sweepMatrix.setTranslate(d * dirX, d * dirY)
                    sweepShader.setLocalMatrix(sweepMatrix)
                    clipPath(clip) {
                        drawContext.canvas.nativeCanvas.drawRect(0f, 0f, w, h, sweepPaint)
                    }
                }
            }
        }
}

/**
 * World-dim helper for the long-press menu and marquee chrome fades: per-element
 * graphicsLayer alpha (never a full-screen layer). [alpha] is read inside the layer
 * block only — driving it per frame never recomposes.
 */
fun Modifier.elementAlpha(alpha: () -> Float): Modifier =
    graphicsLayer { this.alpha = alpha() }
