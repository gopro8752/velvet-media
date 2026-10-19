package tv.velour.ui.wallpaper

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import androidx.compose.runtime.mutableLongStateOf
import tv.velour.core.WallpaperMode
import tv.velour.ui.theme.VelourMotion
import kotlin.math.PI
import kotlin.math.hypot
import kotlin.random.Random

internal const val TWO_PI = (2.0 * PI).toFloat()

internal fun lerpF(a: Float, b: Float, t: Float): Float = a + (b - a) * t

internal fun alpha255(a: Float): Int = (a * 255f + 0.5f).toInt().coerceIn(0, 255)

// Temporal-dither phase stepping: inverse-plastic-number (R2) additive recurrence.
// Successive frames get maximally-spread tile offsets, so the rounding error a given
// pixel sees changes every frame — that is what dissolves sub-LSB tonal motion into
// smooth motion. (A static tile only shifts the threshold; it adds no temporal change.)
private const val DITHER_TILE = 64f
private const val R2X = 0.7548776662f
private const val R2Y = 0.5698402910f

/**
 * Shared engine state: master clock, lean easing, the pre-baked corner-vignette alpha
 * bitmap, a static dither tile, the single preallocated Matrix shared by every
 * setLocalMatrix call, and the four mode renderers.
 *
 * The gradient field is drawn DIRECTLY on the hardware-accelerated canvas at full
 * resolution. An earlier build rasterized it into a quarter-res RGB_565 offscreen
 * bitmap and upscaled — but RGB_565 only has ~32 brightness levels per channel in the
 * near-black range, and the 4x bilinear upscale spread each quantization contour across
 * four screen pixels, so the slow breathing glow's banding crawled in visible steps
 * (read as "1fps / slideshow"). Full-res 8-bit gradients on the GPU have ~8x finer
 * tone steps with no upscale spreading, and the GPU renders low-frequency radial/linear
 * gradients essentially for free. A ~1-LSB dither tile breaks any residual 8-bit bands.
 *
 * Zero allocation inside the frame loop: shaders, paints and arrays are (re)allocated
 * only on size or accent changes, both of which happen outside the loop.
 */
internal class WallpaperRenderer {

    /** Bumped once per master-clock frame; read in the draw phase to schedule redraws. */
    val frameTick = mutableLongStateOf(0L)

    var mode: WallpaperMode = WallpaperMode.TUNGSTEN
    var reduceMotion: Boolean = false

    // ---- master clock -------------------------------------------------------------
    private var lastNanos = 0L
    private var timeSec = 0f   // always advances while RESUMED: alpha breath, flicker, twinkle, crossfade
    private var driftSec = 0f  // positional time: Lissajous/sine drift, dust — FROZEN by reduceMotion
    private var driftDt = 0f

    fun resetClock() {
        lastNanos = 0L
    }

    fun tick(nanos: Long) {
        if (lastNanos != 0L) {
            var dt = (nanos - lastNanos) / 1_000_000_000f
            if (dt < 0f) dt = 0f
            if (dt > 0.1f) dt = 0.1f // resume after a stall becomes one small step, not a jump
            timeSec += dt
            driftDt = if (reduceMotion) 0f else dt
            driftSec += driftDt
        } else {
            driftDt = 0f
        }
        lastNanos = nanos
        frameTick.longValue = nanos
        ditherFrame++ // steps once per presented frame, independent of dt or reduceMotion
    }

    // ---- room lean: ease toward leanX, clamped ±18% width, 600ms Lean easing -------
    private var leanCurrent = 0f
    private var leanFrom = 0f
    private var leanTarget = 0f
    private var leanStartT = -1f

    private fun easedLean(rawNormX: Float): Float {
        if (reduceMotion) return leanCurrent // reduce motion freezes the room lean in place
        val target = (rawNormX - 0.5f).coerceIn(-0.18f, 0.18f)
        if (target != leanTarget) {
            leanFrom = leanCurrent
            leanTarget = target
            leanStartT = timeSec
        }
        if (leanStartT < 0f) return leanCurrent
        val p = ((timeSec - leanStartT) * 1000f / VelourMotion.LeanMs).coerceIn(0f, 1f)
        leanCurrent = lerpF(leanFrom, leanTarget, VelourMotion.Lean.transform(p))
        return leanCurrent
    }

    // ---- full-res direct render + vignette + dither ---------------------------------
    private var w = 0f
    private var h = 0f
    private var dps = 1f // px per design-dp (960x540dp canvas) → previews are true miniatures
    private var vignette: Bitmap? = null
    private val dst = RectF()
    private val vignettePaint = Paint(Paint.FILTER_BITMAP_FLAG).apply { color = 0xFF000000.toInt() }
    // ~1-LSB triangular noise tile, repeated across the screen and drawn last. It is
    // RE-PHASED every frame (ditherMatrix + R2 offset) so the per-pixel rounding error
    // changes each frame — this is what turns sub-LSB tonal motion (the slow breathing
    // glow) into perceptually smooth motion instead of coarse 1-LSB steps.
    private var ditherShader: BitmapShader? = null
    private val ditherPaint = Paint()
    private val ditherMatrix = Matrix() // dedicated; never the shared `matrix`
    private var ditherFrame = 0L

    /** THE single preallocated Matrix — every shader is animated through this one instance. */
    private val matrix = Matrix()

    private val tungsten = TungstenMode(matrix)
    private val sodium = SodiumMode(matrix)
    private val celluloid = CelluloidMode()
    private val deepField = DeepFieldMode(matrix)

    private var accent = 0xFFF2A93B.toInt()
    // CONTRACT-NOTE: the palette spec says each accent "has a precomputed deep variant
    // used where accent light falls on dark surfaces", but neither DESIGN.md's four mode
    // recipes nor the focus system names a concrete consumption site — the four modes
    // use pure accent. accentDeep is plumbed and stored so a future site (e.g. the outer
    // stops of Deep Field's standby glow or Sodium's signal horizon) can adopt it without
    // touching any contract signature.
    @Suppress("unused")
    private var accentDeep = 0xFF3A2810.toInt()

    fun setAccent(accentArgb: Int, accentDeepArgb: Int) {
        accent = accentArgb
        accentDeep = accentDeepArgb
        if (w > 0f) { // already sized → rebuild the two accent-reactive shaders now
            sodium.setAccent(accent)
            deepField.setAccent(accent)
        }
    }

    fun setStarTarget(count: Int) = deepField.setTargetCount(count)

    fun configureSize(widthPx: Float, heightPx: Float) {
        if (widthPx == w && heightPx == h) return
        if (widthPx < 1f || heightPx < 1f) return
        w = widthPx
        h = heightPx
        dps = h / 540f
        // Each mode's "field" space is now the FULL drawn size: shaders, radii and
        // Lissajous amplitudes scale up with it and stay coordinate-consistent with the
        // full-res overlays. The vignette stays a small smooth alpha bitmap (single
        // channel, static, upscaled) — no colour banding to worry about there.
        vignette = bakeVignette((widthPx / 4f).toInt().coerceIn(1, 480), (heightPx / 4f).toInt().coerceIn(1, 270))
        dst.set(0f, 0f, w, h)
        if (ditherShader == null) {
            ditherShader = buildDither().also { ditherPaint.shader = it }
        }
        tungsten.onSize(w, h, w, h, dps)
        sodium.onSize(w, h, w, h, dps, accent)
        celluloid.onSize(w, h, w, h, dps)
        deepField.onSize(w, h, w, h, dps, accent)
    }

    /** A 64x64 BIPOLAR noise tile: each pixel randomly LIGHTENS (white) or DARKENS (black)
     *  with triangular-PDF alpha 0..4 (mean 2). Bipolar + brightness-neutral so it bridges
     *  a sub-LSB tonal step in BOTH directions (a white-only tile could only push values up),
     *  which is what makes the slow breath read as continuous rather than stepped. Re-phased
     *  every frame in render() (temporal dithering). Peak 4 — the darkening half keeps it from
     *  sparkling on near-#04050A while giving more bridging range than the old white-only 0..3. */
    private fun buildDither(): BitmapShader {
        val n = 64
        val bmp = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888)
        val rnd = Random(0x0D17)
        val px = IntArray(n * n)
        for (i in px.indices) {
            val a = rnd.nextInt(0, 3) + rnd.nextInt(0, 3) // TPDF 0..4, mean 2
            val rgb = if (rnd.nextBoolean()) 0x00FFFFFF else 0x00000000 // lighten or darken
            px[i] = (a shl 24) or rgb
        }
        bmp.setPixels(px, 0, n, 0, 0, n, n)
        return BitmapShader(bmp, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
    }

    /** Corner vignette #000000 0% (center) → 40% (corners), pre-baked into an alpha bitmap. */
    private fun bakeVignette(fw: Int, fh: Int): Bitmap {
        val bmp = Bitmap.createBitmap(fw, fh, Bitmap.Config.ALPHA_8)
        val c = Canvas(bmp)
        val p = Paint(Paint.DITHER_FLAG)
        val cx = fw / 2f
        val cy = fh / 2f
        p.shader = RadialGradient(cx, cy, hypot(cx, cy), 0x00000000, 0x66000000, Shader.TileMode.CLAMP)
        c.drawRect(0f, 0f, fw.toFloat(), fh.toFloat(), p)
        return bmp
    }

    // ---- per-frame render: gradient field (GPU, full res) → overlays → vignette → dither
    fun render(canvas: Canvas, rawLeanX: Float) {
        // Snapshot read: subscribes this draw pass to the master clock.
        if (frameTick.longValue == Long.MIN_VALUE) return
        val v = vignette ?: return
        val lean = easedLean(rawLeanX)
        val t = timeSec
        val d = driftSec
        canvas.save()
        canvas.clipRect(0f, 0f, w, h)
        when (mode) {
            WallpaperMode.NOCTURNE, WallpaperMode.HORIZON -> Unit // Static images bypass this renderer.
            WallpaperMode.TUNGSTEN -> {
                tungsten.drawField(canvas, d, lean)
                tungsten.drawOverlay(canvas)
            }
            WallpaperMode.SODIUM_COAST -> {
                sodium.drawField(canvas, d, lean)
                sodium.drawOverlay(canvas, t)
            }
            WallpaperMode.CELLULOID -> {
                celluloid.drawField(canvas, t) // no lean — the projector does not move
                celluloid.drawOverlay(canvas, driftDt)
            }
            WallpaperMode.DEEP_FIELD -> {
                deepField.drawField(canvas, t, d, lean)
                deepField.drawOverlay(canvas, t)
            }
        }
        canvas.drawBitmap(v, null, dst, vignettePaint)
        // Temporal dither: re-phase the tile each frame so the rounding error moves,
        // bridging sub-LSB tonal motion. REPEAT tiling makes any offset wrap for free.
        ditherShader?.let { sh ->
            val n = (ditherFrame % 1024L) // bound float growth over long idle
            ditherMatrix.setTranslate((n * R2X % 1f) * DITHER_TILE, (n * R2Y % 1f) * DITHER_TILE)
            sh.setLocalMatrix(ditherMatrix)
            canvas.drawRect(0f, 0f, w, h, ditherPaint)
        }
        canvas.restore()
    }
}
