package tv.velour.ui.home

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import tv.velour.core.WeatherSnapshot
import tv.velour.ui.components.WeatherGlyph
import tv.velour.ui.components.elementAlpha
import tv.velour.ui.theme.VelourColors
import tv.velour.ui.theme.VelourMotion
import tv.velour.ui.theme.VelourType
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/*
 * ZONE A: HERO (DESIGN.md, y 27–200dp, left-aligned at x=48dp, never focusable).
 * Greeting eyebrow (word-by-word entrance) / 84sp flip clock with accent halation /
 * date·weather line with the thin-line glyph. The right two-thirds stays empty —
 * the wallpaper breathes there. HomeScreen positions this block, drives the 0.5x
 * parallax, the 240ms big<->mini clock crossfade, and the marquee Lissajous drift.
 */
@Composable
fun HeroZone(
    greeting: String,
    use24Hour: Boolean,
    weather: WeatherSnapshot?,
    accent: Color,
    reduceMotion: Boolean,
    chromeAlpha: () -> Float,    // marquee + menu dim (eyebrow + date line)
    clockAlpha: () -> Float,     // big-clock crossfade + menu dim (clock survives marquee)
    clockDriftX: () -> Float,    // marquee Lissajous, px
    clockDriftY: () -> Float,
    modifier: Modifier = Modifier,
) {
    // One minute-aligned ticker drives clock digits and the date line. Zero work between ticks.
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            nowMs = System.currentTimeMillis()
            delay(60_000L - System.currentTimeMillis() % 60_000L + 20L)
        }
    }

    Column(modifier) {
        GreetingEyebrow(
            greeting = greeting,
            accent = accent,
            reduceMotion = reduceMotion,
            modifier = Modifier.elementAlpha(chromeAlpha),
        )
        Spacer(Modifier.height(8.dp))
        FlipClock(
            timeStr = formatClock(nowMs, use24Hour),
            accent = accent,
            reduceMotion = reduceMotion,
            modifier = Modifier.graphicsLayer {
                alpha = clockAlpha()
                translationX = clockDriftX()
                translationY = clockDriftY()
            },
        )
        Spacer(Modifier.height(12.dp))
        DateWeatherLine(
            nowMs = nowMs,
            weather = weather,
            accent = accent,
            modifier = Modifier.elementAlpha(chromeAlpha),
        )
    }
}

/** Greeting copy typesets word-by-word: 120ms stagger, each word 240ms fade + 4dp rise. */
@Composable
private fun GreetingEyebrow(
    greeting: String,
    accent: Color,
    reduceMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    val words = remember(greeting) { greeting.split(' ').filter { it.isNotEmpty() } }
    Row(modifier) {
        words.forEachIndexed { index, word ->
            val rise = remember(greeting) { Animatable(0f) }
            LaunchedEffect(greeting) {
                delay(120L * index)
                rise.animateTo(1f, tween(240, easing = VelourMotion.Decelerate))
            }
            androidx.tv.material3.Text(
                text = word,
                style = VelourType.eyebrow,
                color = accent.copy(alpha = 0.70f),
                modifier = Modifier.graphicsLayer {
                    alpha = rise.value
                    if (!reduceMotion) translationY = 4.dp.toPx() * (1f - rise.value)
                },
            )
            if (index != words.lastIndex) Spacer(Modifier.width(8.dp))
        }
    }
}

/**
 * 84sp Outfit 200 flip clock. Only changed digits animate: the old digit translates
 * +8dp down fading out while the new one drops in from −8dp, 300ms Spotlight,
 * staggered 40ms per changed digit. tnum keeps the slots fixed so nothing reflows.
 */
@Composable
private fun FlipClock(
    timeStr: String,
    accent: Color,
    reduceMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    // Previous string tracked across compositions to know which slots flipped.
    val history = remember { mutableStateOf(timeStr to timeStr) } // (prev, current)
    if (history.value.second != timeStr) {
        history.value = history.value.second to timeStr
    }
    val (prevStr, curStr) = history.value

    val style = VelourType.clockHero.copy(
        color = VelourColors.InkPrimary,
        shadow = Shadow(color = accent.copy(alpha = 0.25f), offset = Offset.Zero, blurRadius = 24f),
    )

    Row(modifier) {
        val aligned = prevStr.length == curStr.length
        var changedOrder = 0
        curStr.forEachIndexed { i, ch ->
            val prevCh = if (aligned) prevStr[i] else ch
            val changed = (!aligned && prevStr != curStr) || prevCh != ch
            val staggerIndex = if (changed) changedOrder++ else 0
            DigitSlot(
                current = ch,
                previous = if (changed && aligned) prevCh else ch,
                changed = changed,
                staggerIndex = staggerIndex,
                trigger = curStr,
                style = style,
                reduceMotion = reduceMotion,
            )
        }
    }
}

@Composable
private fun DigitSlot(
    current: Char,
    previous: Char,
    changed: Boolean,
    staggerIndex: Int,
    trigger: String,
    style: androidx.compose.ui.text.TextStyle,
    reduceMotion: Boolean,
) {
    val flip = remember { Animatable(1f) }
    LaunchedEffect(trigger) {
        if (changed) {
            flip.snapTo(0f)
            delay(40L * staggerIndex)
            flip.animateTo(1f, tween(VelourMotion.ClockFlipMs, easing = VelourMotion.Spotlight))
        } else if (flip.value != 1f) {
            flip.snapTo(1f)
        }
    }
    Box {
        if (changed) {
            // Old digit: translates +8dp down, fading out.
            androidx.tv.material3.Text(
                text = previous.toString(),
                style = style,
                modifier = Modifier.graphicsLayer {
                    val p = flip.value
                    alpha = 1f - p
                    if (!reduceMotion) translationY = 8.dp.toPx() * p
                },
            )
        }
        // New digit: drops in from −8dp.
        androidx.tv.material3.Text(
            text = current.toString(),
            style = style,
            modifier = Modifier.graphicsLayer {
                val p = flip.value
                alpha = p
                if (!reduceMotion) translationY = -8.dp.toPx() * (1f - p)
            },
        )
    }
}

/** "Wednesday, June 10 · 21° Clear" — degrades silently to date-only without weather. */
@Composable
private fun DateWeatherLine(
    nowMs: Long,
    weather: WeatherSnapshot?,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    val dateStr = remember(nowMs / 86_400_000L, nowMs) {
        SimpleDateFormat("EEEE, MMMM d", Locale.getDefault()).format(Date(nowMs))
    }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        androidx.tv.material3.Text(
            text = dateStr,
            style = VelourType.dateLine,
            color = VelourColors.InkSecondary,
        )
        if (weather != null) {
            androidx.tv.material3.Text(
                text = "  ·  ",
                style = VelourType.dateLine,
                color = VelourColors.InkSecondary,
            )
            WeatherGlyph(
                conditionCode = weather.conditionCode,
                isNight = weather.isNight,
                tint = accent.copy(alpha = 0.60f),
            )
            Spacer(Modifier.width(8.dp))
            androidx.tv.material3.Text(
                text = "${weather.tempC.roundToInt()}° ${weather.conditionLabel}",
                style = VelourType.dateLine,
                color = VelourColors.InkSecondary,
            )
        }
    }
}

/**
 * Mini-clock that docks top-right while browsing the Library (Outfit 300 24sp tnum,
 * 16px halation). Crossfaded with the big clock by HomeScreen over 240ms.
 */
@Composable
fun MiniClock(
    use24Hour: Boolean,
    accent: Color,
    alpha: () -> Float,
    modifier: Modifier = Modifier,
) {
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            nowMs = System.currentTimeMillis()
            delay(60_000L - System.currentTimeMillis() % 60_000L + 20L)
        }
    }
    androidx.tv.material3.Text(
        text = formatClock(nowMs, use24Hour),
        style = VelourType.clockMini.copy(
            color = VelourColors.InkPrimary,
            shadow = Shadow(color = accent.copy(alpha = 0.25f), offset = Offset.Zero, blurRadius = 16f),
        ),
        modifier = modifier.elementAlpha(alpha),
    )
}

private fun formatClock(nowMs: Long, use24Hour: Boolean): String {
    val cal = Calendar.getInstance().apply { timeInMillis = nowMs }
    val h = cal.get(Calendar.HOUR_OF_DAY)
    val m = cal.get(Calendar.MINUTE)
    return if (use24Hour) {
        String.format(Locale.US, "%02d:%02d", h, m)
    } else {
        String.format(Locale.US, "%d:%02d", ((h + 11) % 12) + 1, m)
    }
}
