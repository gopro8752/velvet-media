package tv.velour.ui.wallpaper

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import tv.velour.R
import tv.velour.core.WallpaperMode
import tv.velour.core.WeatherSnapshot

/**
 * The Velour ambient wallpaper engine.
 *
 * Shared engine: every mode draws its low-frequency gradient field directly on the
 * hardware-accelerated canvas at full resolution (the GPU renders radial/linear
 * gradients essentially for free, with none of the RGB_565 band-crawling the old
 * quarter-res offscreen field produced). Particles, hairlines and star points draw on
 * top; a pre-baked corner-vignette alpha bitmap and a ~1-LSB dither are composited last.
 *
 * All shaders are allocated once at size/accent time and animated exclusively via
 * `setLocalMatrix` with a single preallocated Matrix, driven by one master
 * `withFrameNanos` clock that pauses when the lifecycle is not RESUMED and freezes
 * positional drift when reduce-motion is on (alpha breath/flicker/twinkle continue).
 *
 * Used full-screen behind home/settings AND at 192x108dp inside the settings live
 * previews (same code path). Fills the bounds it is given — resolution-independent:
 * every dimension is derived proportionally from the drawn size (960x540dp design
 * canvas), so the preview is a true miniature.
 */
@Composable
fun WallpaperLayer(
    mode: WallpaperMode,
    accent: Color,
    accentDeep: Color,
    leanX: () -> Float,          // normalized 0..1; READ ONLY INSIDE THE DRAW PHASE
    weather: WeatherSnapshot?,   // for Deep Field star density; nullable
    reduceMotion: Boolean,
    modifier: Modifier = Modifier,
    // CONTRACT-NOTE: defaulted param beyond the contract signature — false stops the
    // master frame loop entirely (last frame stays on the bitmap). Home passes
    // `screen == Home` so the occluded launcher wallpaper does not keep re-rendering
    // its 480x270 field at 60fps beneath Settings; an alpha-0 ancestor layer only
    // skips the GPU composite, not the per-frame displaylist re-record.
    active: Boolean = true,
) {
    // Static images never instantiate the animated renderer or its frame clock,
    // either full-screen or in the Settings previews.
    if (mode == WallpaperMode.NOCTURNE || mode == WallpaperMode.HORIZON) {
        Image(
            painter = painterResource(
                if (mode == WallpaperMode.NOCTURNE) R.drawable.velour_nocturne else R.drawable.velour_horizon,
            ),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = modifier,
        )
        return
    }

    val renderer = remember { WallpaperRenderer() }

    // Cheap composition-time configuration; all animated state stays in the draw phase.
    renderer.mode = mode
    renderer.reduceMotion = reduceMotion
    LaunchedEffect(renderer, accent, accentDeep) { renderer.setAccent(accent.toArgb(), accentDeep.toArgb()) }
    val starCount = starCountFor(weather)
    LaunchedEffect(renderer, starCount) { renderer.setStarTarget(starCount) }

    // One master frame clock. repeatOnLifecycle pauses it whenever the host is not
    // RESUMED; `active = false` (occluded behind another screen) stops it outright.
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner, renderer, active) {
        if (!active) return@LaunchedEffect
        val tick: (Long) -> Unit = { renderer.tick(it) } // hoisted: no per-frame lambda alloc
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            renderer.resetClock() // swallow the paused gap instead of jumping
            while (true) withFrameNanos(tick)
        }
    }

    Box(
        modifier.drawWithCache {
            // Re-runs only on size change: (re)allocates the field bitmap, vignette and
            // all shaders for the new size. Never runs inside the frame loop.
            renderer.configureSize(size.width, size.height)
            onDrawBehind {
                // leanX() and the frame-clock state are read HERE, inside the draw
                // phase only — frame ticks invalidate draw, never composition.
                renderer.render(drawContext.canvas.nativeCanvas, leanX())
            }
        }
    )
}

/** Deep Field weather-aware star density: clear night 120, overcast 40, otherwise 80. */
private fun starCountFor(weather: WeatherSnapshot?): Int = when {
    weather == null -> 80
    weather.conditionCode == 0 && weather.isNight -> 120
    weather.conditionCode == 3 -> 40
    else -> 80
}
