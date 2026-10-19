package tv.velour.ui.wallpaper

import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import java.util.TimeZone
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

/*
 * The four wallpaper modes. Each renders its low-frequency gradient field into the
 * quarter-res RGB_565 bitmap (drawField) and its crisp elements at full res on top
 * (drawOverlay). All shaders are built in onSize / setAccent — never per frame —
 * and animated only via setLocalMatrix with the renderer's single shared Matrix,
 * or via Paint.alpha for breathing/flicker (paint alpha modulates the shader).
 *
 * Field-space positions/radii are proportional to field size, full-res ones to drawn
 * size (dps = px per 960x540 design-dp), so the engine is resolution-independent.
 */

// ---------------------------------------------------------------------------------
// 1. TUNGSTEN — "Porsche interior at night."
// ---------------------------------------------------------------------------------
internal class TungstenMode(private val matrix: Matrix) {
    private val basePaint = Paint(Paint.DITHER_FLAG)
    private val warmPaint = Paint(Paint.DITHER_FLAG)
    private val coolPaint = Paint(Paint.DITHER_FLAG)
    private val hairPaint = Paint()
    private var warmShader: RadialGradient? = null
    private var coolShader: RadialGradient? = null
    private var fw = 0f
    private var fh = 0f
    private var w = 0f
    private var h = 0f
    private var hairH = 1f
    private var lastUtcMinute = -1L
    private var warmAlpha = 0.33f

    fun onSize(fw: Float, fh: Float, w: Float, h: Float, dps: Float) {
        this.fw = fw; this.fh = fh; this.w = w; this.h = h
        // Base vertical #050507 → #0B0A09.
        basePaint.shader = LinearGradient(
            0f, 0f, 0f, fh, 0xFF050507.toInt(), 0xFF0B0A09.toInt(), Shader.TileMode.CLAMP
        )
        // Warm amber lamp burning just out of frame: radius 1.4x width, built at origin,
        // positioned every frame via setLocalMatrix.
        warmShader = RadialGradient(0f, 0f, 1.4f * fw, 0xFF3A2410.toInt(), 0x003A2410, Shader.TileMode.CLAMP)
        warmPaint.shader = warmShader
        // Cool counter-radial #0E1620 @25%, radius 1.1x width.
        coolShader = RadialGradient(0f, 0f, 1.1f * fw, 0xFF0E1620.toInt(), 0x000E1620, Shader.TileMode.CLAMP)
        coolPaint.shader = coolShader
        coolPaint.alpha = alpha255(0.25f)
        // Dashboard horizon: 1dp full-res hairline, horizontal #FFFFFF 0% → 4% → 0%.
        hairPaint.shader = LinearGradient(
            0f, 0f, w, 0f,
            intArrayOf(0x00FFFFFF, 0x0AFFFFFF, 0x00FFFFFF),
            floatArrayOf(0f, 0.5f, 1f),
            Shader.TileMode.CLAMP,
        )
        hairH = max(1f, 1f * dps)
        lastUtcMinute = -1L // force warmth recompute at next frame
    }

    /** Time-aware warmth: 28% at 12:00 → 38% at 22:00, held overnight; once per minute. */
    private fun refreshWarmth() {
        val nowMs = System.currentTimeMillis()
        val utcMin = nowMs / 60000L
        if (utcMin == lastUtcMinute) return
        lastUtcMinute = utcMin
        val local = nowMs + TimeZone.getDefault().getOffset(nowMs)
        val hr = ((local / 60000L) % 1440L).toInt() / 60f
        warmAlpha = when {
            hr >= 22f -> 0.38f
            hr >= 12f -> lerpF(0.28f, 0.38f, (hr - 12f) / 10f)
            hr < 7f -> 0.38f // held overnight
            // Spec fixes the 12:00/22:00 anchors and the overnight hold; ease back
            // through the morning so noon never snaps.
            else -> lerpF(0.38f, 0.28f, (hr - 7f) / 5f)
        }
    }

    fun drawField(c: Canvas, d: Float, lean: Float) {
        refreshWarmth()
        c.drawRect(0f, 0f, fw, fh, basePaint)
        // Both centers drift on Lissajous paths (periods 90s / 127s, amplitude 6%).
        // Warm radial is the lean layer.
        var cx = 1.10f * fw + 0.06f * fw * sin(TWO_PI * d / 50f) + lean * fw
        var cy = 1.15f * fh + 0.06f * fh * sin(TWO_PI * d / 70f + 0.8f)
        matrix.setTranslate(cx, cy)
        warmShader?.setLocalMatrix(matrix)
        warmPaint.alpha = alpha255(warmAlpha)
        c.drawRect(0f, 0f, fw, fh, warmPaint)
        cx = -0.10f * fw + 0.06f * fw * sin(TWO_PI * d / 70f + 2.4f)
        cy = -0.15f * fh + 0.06f * fh * sin(TWO_PI * d / 50f + 1.3f)
        matrix.setTranslate(cx, cy)
        coolShader?.setLocalMatrix(matrix)
        c.drawRect(0f, 0f, fw, fh, coolPaint)
    }

    fun drawOverlay(c: Canvas) {
        val y = 0.62f * h
        c.drawRect(0f, y - hairH * 0.5f, w, y + hairH * 0.5f, hairPaint)
    }
}

// ---------------------------------------------------------------------------------
// 2. SODIUM COAST — Blade Runner fog city.
// ---------------------------------------------------------------------------------
internal class SodiumMode(private val matrix: Matrix) {
    private val amberPaint = Paint(Paint.DITHER_FLAG)
    private val cyanPaint = Paint(Paint.DITHER_FLAG)
    private val magentaPaint = Paint(Paint.DITHER_FLAG)
    private val horizonPaint = Paint(Paint.DITHER_FLAG)
    private var amberShader: RadialGradient? = null
    private var cyanShader: RadialGradient? = null
    private var magentaShader: RadialGradient? = null
    private var fw = 0f
    private var fh = 0f
    private var w = 0f
    private var bandTop = 0f
    private var bandBottom = 0f

    fun onSize(fw: Float, fh: Float, w: Float, h: Float, dps: Float, accent: Int) {
        this.fw = fw; this.fh = fh; this.w = w
        amberShader = RadialGradient(0f, 0f, 1.2f * fw, 0xFF5A3110.toInt(), 0x005A3110, Shader.TileMode.CLAMP)
        amberPaint.shader = amberShader
        amberPaint.alpha = alpha255(0.30f)
        cyanShader = RadialGradient(0f, 0f, 1.0f * fw, 0xFF0E3A3E.toInt(), 0x000E3A3E, Shader.TileMode.CLAMP)
        cyanPaint.shader = cyanShader
        cyanPaint.alpha = alpha255(0.22f)
        magentaShader = RadialGradient(0f, 0f, 1.5f * fw, 0xFF2A1230.toInt(), 0x002A1230, Shader.TileMode.CLAMP)
        magentaPaint.shader = magentaShader
        magentaPaint.alpha = alpha255(0.18f)
        // Signal horizon: 90dp-tall full-res band centered at 70% height.
        val bandH = 90f * dps
        bandTop = 0.70f * h - bandH * 0.5f
        bandBottom = bandTop + bandH
        setAccent(accent)
    }

    /**
     * Accent-reactive: rebuild the horizon gradient (accent 0% → peak → 0%).
     * CONTRACT-NOTE: DESIGN.md's "horizontal LinearGradient band" is read as a
     * horizontal BAND whose accent fades across its vertical extent (transparent top
     * edge → peak at the horizon line → transparent bottom edge) — a physically
     * sensible glowing horizon. If "horizontal" was meant as the gradient AXIS,
     * switch the gradient to (0,y)→(w,y) with the same 0/peak/0 stops.
     */
    fun setAccent(accent: Int) {
        if (bandBottom <= bandTop) return
        val clear = accent and 0x00FFFFFF
        horizonPaint.shader = LinearGradient(
            0f, bandTop, 0f, bandBottom,
            intArrayOf(clear, accent or 0xFF000000.toInt(), clear),
            floatArrayOf(0f, 0.5f, 1f),
            Shader.TileMode.CLAMP,
        )
    }

    fun drawField(c: Canvas, d: Float, lean: Float) {
        c.drawColor(0xFF06080C.toInt())
        // Three wide radials drifting through each other on incommensurate sine periods
        // (61s / 89s / 143s — the mix never repeats). Sodium amber is the lean layer.
        var cx = 0.15f * fw + 0.06f * fw * sin(TWO_PI * d / 34f) + lean * fw
        var cy = 0.95f * fh + 0.06f * fh * cos(TWO_PI * d / 34f)
        matrix.setTranslate(cx, cy)
        amberShader?.setLocalMatrix(matrix)
        c.drawRect(0f, 0f, fw, fh, amberPaint)
        cx = 0.88f * fw + 0.06f * fw * sin(TWO_PI * d / 50f + 2.1f)
        cy = 0.08f * fh + 0.06f * fh * cos(TWO_PI * d / 50f + 2.1f)
        matrix.setTranslate(cx, cy)
        cyanShader?.setLocalMatrix(matrix)
        c.drawRect(0f, 0f, fw, fh, cyanPaint)
        cx = 0.50f * fw + 0.06f * fw * sin(TWO_PI * d / 80f + 4.2f)
        cy = 0.50f * fh + 0.06f * fh * cos(TWO_PI * d / 80f + 4.2f)
        matrix.setTranslate(cx, cy)
        magentaShader?.setLocalMatrix(matrix)
        c.drawRect(0f, 0f, fw, fh, magentaPaint)
    }

    fun drawOverlay(c: Canvas, t: Float) {
        // Peak alpha breathes 3% ↔ 9% on a 12s sine.
        horizonPaint.alpha = alpha255(0.06f + 0.03f * sin(TWO_PI * t / 12f))
        c.drawRect(0f, bandTop, w, bandBottom, horizonPaint)
    }
}

// ---------------------------------------------------------------------------------
// 3. CELLULOID — the projector beam; strict grayscale. No lean.
// ---------------------------------------------------------------------------------
internal class CelluloidMode {
    private val basePaint = Paint(Paint.DITHER_FLAG)
    private val beamPaint = Paint(Paint.DITHER_FLAG)
    private val dustPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt() }
    private var fw = 0f
    private var fh = 0f
    private var w = 0f
    private var h = 0f
    private var beamLeft = 0f
    private var beamTop = 0f
    private var beamRight = 0f
    private var beamBottom = 0f

    // The beam's bounding rect at FULL res, expressed in the beam's own rotated frame
    // (-24° about the projector corner (w, 0)). Dust is seeded, advanced and wrapped
    // inside this rect (DESIGN.md: motes drift "within beam bounds, wrapping at edges"),
    // then rotated back to screen space at draw time.
    private var dustLeft = 0f
    private var dustTop = 0f
    private var dustRight = 0f
    private var dustBottom = 0f
    private val beamCos = cos(BEAM_ANGLE_RAD)
    private val beamSin = sin(BEAM_ANGLE_RAD)

    // 24 dust motes in preallocated FloatArrays, mutated in place; never reallocated.
    // Positions and velocities live in beam space.
    private val dustPos = FloatArray(48)
    private val dustVel = FloatArray(48)
    private val dustR = FloatArray(24)
    private val dustA = IntArray(24)

    fun onSize(fw: Float, fh: Float, w: Float, h: Float, dps: Float) {
        this.fw = fw; this.fh = fh; this.w = w; this.h = h
        basePaint.shader = LinearGradient(
            0f, 0f, 0f, fh, 0xFF050505.toInt(), 0xFF0A0A0A.toInt(), Shader.TileMode.CLAMP
        )
        // Beam: fades from the top-right corner across 70% of the screen diagonal;
        // drawn as one rotated-canvas rect (-24°) in the quarter-res field.
        val beamLen = 0.7f * hypot(fw, fh)
        beamPaint.shader = LinearGradient(
            fw, 0f, fw - beamLen, 0f, 0xFFFFFFFF.toInt(), 0x00FFFFFF, Shader.TileMode.CLAMP
        )
        beamLeft = fw - beamLen
        beamTop = -0.15f * fh
        beamRight = fw + 0.2f * fw
        beamBottom = 0.8f * fh
        // The same wedge mirrored at full res — the dust's home.
        dustLeft = w - 0.7f * hypot(w, h)
        dustTop = -0.15f * h
        dustRight = w + 0.2f * w
        dustBottom = 0.8f * h
        // Dust: 2–6dp/s diagonally down-left, r 1–2dp, alpha 3–6%. Fixed seed.
        // Seeded inside the beam rect; screen-space velocity is rotated into beam
        // space once so per-frame advance/wrap stays in the beam's frame.
        val rnd = Random(0x5EED)
        for (i in 0 until 24) {
            dustPos[i * 2] = dustLeft + rnd.nextFloat() * (dustRight - dustLeft)
            dustPos[i * 2 + 1] = dustTop + rnd.nextFloat() * (dustBottom - dustTop)
            val speed = (2f + rnd.nextFloat() * 4f) * dps
            val ang = 0.6f + rnd.nextFloat() * 0.45f // radians below horizontal
            val vx = -speed * cos(ang) // screen space: down-left
            val vy = speed * sin(ang)
            dustVel[i * 2] = vx * beamCos + vy * beamSin
            dustVel[i * 2 + 1] = -vx * beamSin + vy * beamCos
            dustR[i] = (1f + rnd.nextFloat()) * dps
            dustA[i] = alpha255(0.03f + rnd.nextFloat() * 0.03f)
        }
    }

    fun drawField(c: Canvas, t: Float) {
        c.drawRect(0f, 0f, fw, fh, basePaint)
        // Flicker you feel rather than see: ±1% around 7%, value noise sampled at 8Hz.
        beamPaint.alpha = alpha255(0.07f + 0.01f * flutter(t))
        c.save()
        c.rotate(-24f, fw, 0f)
        c.drawRect(beamLeft, beamTop, beamRight, beamBottom, beamPaint)
        c.restore()
    }

    fun drawOverlay(c: Canvas, driftDt: Float) {
        // driftDt is 0 under reduceMotion → motes freeze in place.
        val spanU = dustRight - dustLeft
        val spanV = dustBottom - dustTop
        for (i in 0 until 24) {
            var u = dustPos[i * 2] + dustVel[i * 2] * driftDt
            var v = dustPos[i * 2 + 1] + dustVel[i * 2 + 1] * driftDt
            if (u < dustLeft) u += spanU
            if (u > dustRight) u -= spanU
            if (v < dustTop) v += spanV
            if (v > dustBottom) v -= spanV
            dustPos[i * 2] = u
            dustPos[i * 2 + 1] = v
            // Beam space -> screen: rotate -24° about the projector corner (w, 0).
            val du = u - w
            dustPaint.alpha = dustA[i]
            c.drawCircle(
                w + du * beamCos - v * beamSin,
                du * beamSin + v * beamCos,
                dustR[i],
                dustPaint,
            )
        }
    }

    /** Value noise in -1..1, sampled at 8Hz, smoothstep-lerped between samples. */
    private fun flutter(t: Float): Float {
        val s = t * 8f
        val i = s.toInt()
        val f = s - i
        val u = f * f * (3f - 2f * f)
        return lerpF(hash01(i), hash01(i + 1), u) * 2f - 1f
    }

    private fun hash01(n: Int): Float {
        var x = n * 0x27D4EB2D
        x = x xor (x ushr 15)
        x *= 0x2C1B3C6D
        x = x xor (x ushr 12)
        x *= 0x297A2D39
        x = x xor (x ushr 15)
        return (x and 0xFFFFFF) / 16777215f
    }

    private companion object {
        val BEAM_ANGLE_RAD = (-24.0 * PI / 180.0).toFloat()
    }
}

// ---------------------------------------------------------------------------------
// 4. DEEP FIELD — after-hours listening room.
// ---------------------------------------------------------------------------------
internal class DeepFieldMode(private val matrix: Matrix) {
    // Several soft accent pools spread around the screen, each breathing and drifting on
    // its OWN incommensurate rhythm, so the field ebbs and flows without any single glow
    // visibly looping. Anchors/radii are fractions of field size; breath uses t (keeps
    // breathing under reduce motion), drift uses d (frozen under reduce motion).
    private class Glow(
        val ax: Float, val ay: Float, val rad: Float,
        val base: Float, val amp: Float, val breath: Float, val phase: Float,
        val driftAmp: Float, val driftPx: Float, val driftPy: Float,
        val lean: Boolean = false,
    ) {
        var shader: RadialGradient? = null
        val paint = Paint(Paint.DITHER_FLAG)
    }
    private val glows = arrayOf(
        // primary standby-LED glow behind the hero text — the lean (focus-reactive) layer
        Glow(0.28f, 0.26f, 0.92f, 0.10f, 0.050f, 7f,  0.0f, 0.045f, 40f, 53f, lean = true),
        Glow(0.82f, 0.70f, 0.60f, 0.05f, 0.035f, 9.5f, 1.7f, 0.050f, 61f, 47f),
        Glow(0.68f, 0.14f, 0.66f, 0.045f, 0.030f, 13f, 3.1f, 0.045f, 71f, 83f),
        Glow(0.10f, 0.64f, 0.54f, 0.040f, 0.030f, 17f, 4.6f, 0.050f, 53f, 67f),
    )
    private val starPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        strokeCap = Paint.Cap.ROUND
    }
    private var fw = 0f
    private var fh = 0f

    // Fixed-seed sky, normalized once at construction — your sky is always your sky.
    private val normX = FloatArray(120)
    private val normY = FloatArray(120)
    private val starBand = IntArray(120)
    private val px = FloatArray(240) // interleaved full-res positions

    // Per-star alphas 4–10% baked into a precomputed array; batched as one drawPoints
    // call per quantized alpha level (Android draws one alpha per batch).
    private val bandAlpha = floatArrayOf(0.04f, 0.06f, 0.08f, 0.10f)
    private val buckets = Array(4) { FloatArray(240) }
    private val bucketN = IntArray(4)

    // Exactly 5 twinklers on offset sines, periods 7–13s; all within the first 40
    // stars so they survive every weather tier.
    private val twinkleIdx = intArrayOf(3, 11, 17, 23, 31)
    private val twinklePeriod = floatArrayOf(7f, 8.5f, 10f, 11.5f, 13f)
    private val twinklePhase = floatArrayOf(0f, 1.3f, 2.7f, 4.1f, 5.4f)

    // Weather-aware count with 1200ms crossfade.
    private var currentCount = 80
    private var targetCount = 80
    private var fading = false
    private var fadeFrom = 80
    private var fadeStartT = 0f

    init {
        val rnd = Random(0xA57E0)
        for (i in 0 until 120) {
            normX[i] = rnd.nextFloat()
            normY[i] = rnd.nextFloat()
            starBand[i] = rnd.nextInt(4)
        }
    }

    fun onSize(fw: Float, fh: Float, w: Float, h: Float, dps: Float, accent: Int) {
        this.fw = fw
        this.fh = fh
        starPaint.strokeWidth = max(1.5f, 1.1f * dps)
        for (i in 0 until 120) {
            px[i * 2] = normX[i] * w
            px[i * 2 + 1] = normY[i] * h
        }
        setAccent(accent)
        if (fading) { // a resize mid-fade just snaps to the target
            fading = false
            currentCount = targetCount
        }
        rebuildBuckets(currentCount)
    }

    /** Accent-reactive: every ambient pool is the current accent (low alpha = colored light). */
    fun setAccent(accent: Int) {
        if (fw <= 0f) return
        val core = accent or 0xFF000000.toInt()
        val clear = accent and 0x00FFFFFF
        for (g in glows) {
            g.shader = RadialGradient(0f, 0f, g.rad * fw, core, clear, Shader.TileMode.CLAMP)
            g.paint.shader = g.shader
        }
    }

    fun setTargetCount(count: Int) {
        targetCount = count
        if (fw <= 0f) currentCount = count // before first layout: no crossfade, just snap
    }

    fun drawField(c: Canvas, t: Float, d: Float, lean: Float) {
        c.drawColor(0xFF04050A.toInt())
        // Several accent pools, each ebbing/flowing and drifting on incommensurate
        // rhythms (breath 7/9.5/13/17s, drift 40-83s) so nothing reads as a single loop.
        for (g in glows) {
            val lx = if (g.lean) lean * fw else 0f
            matrix.setTranslate(
                g.ax * fw + g.driftAmp * fw * sin(TWO_PI * d / g.driftPx) + lx,
                g.ay * fh + g.driftAmp * fh * sin(TWO_PI * d / g.driftPy),
            )
            g.shader?.setLocalMatrix(matrix)
            g.paint.alpha = alpha255(g.base + g.amp * sin(TWO_PI * t / g.breath + g.phase))
            c.drawRect(0f, 0f, fw, fh, g.paint)
        }
    }

    fun drawOverlay(c: Canvas, t: Float) {
        // Kick off a pending recount crossfade (set by the 30-min weather poll).
        if (!fading && targetCount != currentCount) {
            fading = true
            fadeFrom = currentCount
            fadeStartT = t
            rebuildBuckets(min(currentCount, targetCount))
        }
        // Stable stars: one batched drawPoints per alpha level.
        for (b in 0 until 4) {
            val n = bucketN[b]
            if (n > 0) {
                starPaint.alpha = alpha255(bandAlpha[b])
                c.drawPoints(buckets[b], 0, n * 2, starPaint)
            }
        }
        // Transitioning stars fade in/out over 1200ms.
        if (fading) {
            val p = ((t - fadeStartT) / 1.2f).coerceIn(0f, 1f)
            val lo = min(fadeFrom, targetCount)
            val hi = max(fadeFrom, targetCount)
            val mul = if (targetCount > fadeFrom) p else 1f - p
            if (mul > 0f) {
                for (i in lo until hi) {
                    starPaint.alpha = alpha255(bandAlpha[starBand[i]] * mul)
                    c.drawPoint(px[i * 2], px[i * 2 + 1], starPaint)
                }
            }
            if (p >= 1f) {
                fading = false
                currentCount = targetCount
                rebuildBuckets(currentCount)
            }
        }
        // The five twinklers.
        for (k in 0 until 5) {
            val i = twinkleIdx[k]
            starPaint.alpha = alpha255(0.07f + 0.03f * sin(TWO_PI * t / twinklePeriod[k] + twinklePhase[k]))
            c.drawPoint(px[i * 2], px[i * 2 + 1], starPaint)
        }
    }

    /** Refill the preallocated bucket arrays in place — only on recount/resize. */
    private fun rebuildBuckets(count: Int) {
        bucketN[0] = 0; bucketN[1] = 0; bucketN[2] = 0; bucketN[3] = 0
        for (i in 0 until count) {
            if (isTwinkler(i)) continue
            val b = starBand[i]
            val n = bucketN[b]
            buckets[b][n * 2] = px[i * 2]
            buckets[b][n * 2 + 1] = px[i * 2 + 1]
            bucketN[b] = n + 1
        }
    }

    private fun isTwinkler(i: Int) = i == 3 || i == 11 || i == 17 || i == 23 || i == 31
}
