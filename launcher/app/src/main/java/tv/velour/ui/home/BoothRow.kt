package tv.velour.ui.home

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import tv.velour.ui.components.velourFocus
import tv.velour.ui.theme.VelourColors
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/*
 * BOOTH ROW (DESIGN.md): two 40dp circular ghost buttons — Settings gear and
 * Wallpaper-mode cycler — 20dp icons at 1.5dp stroke InkSecondary, 12dp gap.
 * Invisible (alpha 0) until UP from Favorites carries focus into the hero zone,
 * then fades in over 200ms; DOWN/BACK fades out over 150ms. Focused button scales
 * 1.10 with the accent rim + standard under-glow (velourFocus). HomeScreen
 * right-aligns the row ending at x=912dp, centered y=160dp.
 */
@Composable
fun BoothRow(
    accent: Color,
    reduceMotion: Boolean,
    chromeAlpha: () -> Float,            // marquee / menu world-dim factor
    favoritesFocus: FocusRequester,      // DOWN returns to the favorites row
    gearFocus: FocusRequester,           // UP from favorites lands here
    onOpenSettings: () -> Unit,
    onCycleWallpaper: () -> Unit,
    onFocusWithin: (Boolean) -> Unit,    // HomeScreen zone bookkeeping
    modifier: Modifier = Modifier,
) {
    var focusWithin by remember { mutableStateOf(false) }
    val visibility = remember { Animatable(0f) }
    LaunchedEffect(focusWithin) {
        onFocusWithin(focusWithin)
        if (focusWithin) {
            visibility.animateTo(1f, tween(200, easing = LinearEasing))
        } else {
            visibility.animateTo(0f, tween(150, easing = LinearEasing))
        }
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .onFocusChanged { focusWithin = it.hasFocus }
            .graphicsLayer { alpha = visibility.value * chromeAlpha() },
    ) {
        BoothButton(
            accent = accent,
            reduceMotion = reduceMotion,
            favoritesFocus = favoritesFocus,
            onClick = onOpenSettings,
            icon = BoothIcon.GEAR,
            // The gear is the landing pad for UP from Favorites.
            modifier = Modifier.focusRequester(gearFocus),
        )
        Spacer(Modifier.width(12.dp))
        BoothButton(
            accent = accent,
            reduceMotion = reduceMotion,
            favoritesFocus = favoritesFocus,
            onClick = onCycleWallpaper,
            icon = BoothIcon.WALLPAPER,
        )
    }
}

private enum class BoothIcon { GEAR, WALLPAPER }

@Composable
private fun BoothButton(
    accent: Color,
    reduceMotion: Boolean,
    favoritesFocus: FocusRequester,
    onClick: () -> Unit,
    icon: BoothIcon,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(40.dp)
            .onFocusChanged { focused = it.isFocused }
            .focusProperties { down = favoritesFocus }
            .velourFocus(
                focused = focused,
                accent = accent,
                radius = 20.dp, // 40dp circle
                focusedScale = 1.10f,
                reduceMotion = reduceMotion,
                rimColor = accent, // DESIGN.md BOOTH ROW: accent rim, not the white card rim
            )
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            ),
    ) {
        Box(
            Modifier
                .size(20.dp)
                .drawWithCache {
                    val stroke = Stroke(
                        width = 1.5.dp.toPx(),
                        cap = StrokeCap.Round,
                        join = StrokeJoin.Round,
                    )
                    val paths = when (icon) {
                        BoothIcon.GEAR -> gearPaths(size.width)
                        BoothIcon.WALLPAPER -> wallpaperPaths(size.width)
                    }
                    onDrawBehind {
                        for (p in paths) drawPath(p, VelourColors.InkSecondary, style = stroke)
                    }
                }
        )
    }
}

/** Line-art gear: body circle + hub + 8 radial teeth. */
private fun gearPaths(s: Float): List<Path> {
    val c = s / 2f
    val body = s * 0.30f
    val hub = s * 0.12f
    val teethIn = s * 0.34f
    val teethOut = s * 0.46f
    val circle = Path().apply { addOval(Rect(c - body, c - body, c + body, c + body)) }
    val center = Path().apply { addOval(Rect(c - hub, c - hub, c + hub, c + hub)) }
    val teeth = Path().apply {
        for (i in 0 until 8) {
            val a = (2.0 * PI * i / 8.0 + PI / 8.0).toFloat()
            moveTo(c + teethIn * cos(a), c + teethIn * sin(a))
            lineTo(c + teethOut * cos(a), c + teethOut * sin(a))
        }
    }
    return listOf(circle, center, teeth)
}

/** Line-art picture: rounded frame, sun dot, mountain ridge. */
private fun wallpaperPaths(s: Float): List<Path> {
    val frame = Path().apply {
        addRoundRect(
            androidx.compose.ui.geometry.RoundRect(
                left = s * 0.08f, top = s * 0.16f, right = s * 0.92f, bottom = s * 0.84f,
                radiusX = s * 0.10f, radiusY = s * 0.10f,
            )
        )
    }
    val sun = Path().apply {
        val r = s * 0.07f
        addOval(Rect(s * 0.30f - r, s * 0.34f - r, s * 0.30f + r, s * 0.34f + r))
    }
    val ridge = Path().apply {
        moveTo(s * 0.14f, s * 0.74f)
        lineTo(s * 0.40f, s * 0.46f)
        lineTo(s * 0.58f, s * 0.64f)
        lineTo(s * 0.72f, s * 0.52f)
        lineTo(s * 0.88f, s * 0.70f)
    }
    return listOf(frame, sun, ridge)
}
