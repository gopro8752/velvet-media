package tv.velour.ui.components

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * 20dp thin-line weather glyph (1.5dp stroke, round caps) per WMO code group
 * (DESIGN.md hero date line). Groups follow the WeatherRepository mapping:
 * 0 Clear; 1–2 Partly cloudy; 3 Overcast; 45/48 Fog; 51–57 Drizzle;
 * 61–67/80–82 Rain; 71–77/85–86 Snow; 95–99 Thunderstorm.
 * Clear at night renders a crescent moon. Everything is cached Path work —
 * nothing animates, nothing allocates after the cache builds.
 */
@Composable
fun WeatherGlyph(conditionCode: Int, isNight: Boolean, tint: Color, modifier: Modifier = Modifier) {
    Spacer(
        modifier
            .size(20.dp)
            .drawWithCache {
                val stroke = Stroke(
                    width = 1.5.dp.toPx(),
                    cap = StrokeCap.Round,
                    join = StrokeJoin.Round,
                )
                val w = size.width
                val h = size.height
                val group = wmoGroup(conditionCode, isNight)
                val paths = buildGlyph(group, w, h)
                onDrawBehind {
                    for (p in paths.strokes) drawPath(p, tint, style = stroke)
                    for (dot in paths.dots) drawCircle(tint, radius = 0.75.dp.toPx(), center = dot)
                }
            }
    )
}

private enum class GlyphGroup { SUN, MOON, PARTLY, CLOUD, FOG, DRIZZLE, RAIN, SNOW, THUNDER }

private fun wmoGroup(code: Int, isNight: Boolean): GlyphGroup = when (code) {
    0 -> if (isNight) GlyphGroup.MOON else GlyphGroup.SUN
    1, 2 -> GlyphGroup.PARTLY
    3 -> GlyphGroup.CLOUD
    45, 48 -> GlyphGroup.FOG
    in 51..57 -> GlyphGroup.DRIZZLE
    in 61..67, in 80..82 -> GlyphGroup.RAIN
    in 71..77, 85, 86 -> GlyphGroup.SNOW
    in 95..99 -> GlyphGroup.THUNDER
    else -> GlyphGroup.CLOUD
}

private class GlyphPaths(val strokes: List<Path>, val dots: List<Offset>)

private fun buildGlyph(group: GlyphGroup, w: Float, h: Float): GlyphPaths {
    val strokes = mutableListOf<Path>()
    val dots = mutableListOf<Offset>()

    fun sun(cx: Float, cy: Float, r: Float, rayInner: Float, rayOuter: Float, rays: Int = 8) {
        strokes += Path().apply {
            addOval(androidx.compose.ui.geometry.Rect(cx - r, cy - r, cx + r, cy + r))
        }
        val rayPath = Path()
        for (i in 0 until rays) {
            val a = (2.0 * PI * i / rays).toFloat()
            rayPath.moveTo(cx + rayInner * cos(a), cy + rayInner * sin(a))
            rayPath.lineTo(cx + rayOuter * cos(a), cy + rayOuter * sin(a))
        }
        strokes += rayPath
    }

    /** Classic line-art cloud: flat base + two lobes, drawn as one open path. */
    fun cloud(left: Float, right: Float, baseY: Float, lift: Float) {
        val width = right - left
        strokes += Path().apply {
            moveTo(left + width * 0.10f, baseY)
            // big left lobe
            cubicTo(
                left - width * 0.08f, baseY,
                left - width * 0.02f, baseY - lift * 1.05f,
                left + width * 0.30f, baseY - lift * 0.95f,
            )
            // top-right lobe
            cubicTo(
                left + width * 0.45f, baseY - lift * 1.55f,
                left + width * 0.85f, baseY - lift * 1.35f,
                left + width * 0.85f, baseY - lift * 0.55f,
            )
            // right shoulder back to base
            cubicTo(
                right + width * 0.08f, baseY - lift * 0.45f,
                right + width * 0.04f, baseY,
                left + width * 0.78f, baseY,
            )
            close()
        }
    }

    when (group) {
        GlyphGroup.SUN -> sun(w / 2f, h / 2f, w * 0.22f, w * 0.34f, w * 0.46f)

        GlyphGroup.MOON -> strokes += Path().apply {
            // Crescent: outer arc then inner arc carved back.
            val r = w * 0.36f
            val cx = w * 0.52f
            val cy = h * 0.50f
            addArc(
                androidx.compose.ui.geometry.Rect(cx - r, cy - r, cx + r, cy + r),
                startAngleDegrees = -50f,
                sweepAngleDegrees = 280f,
            )
            val r2 = r * 0.78f
            val cx2 = cx + r * 0.42f
            val cy2 = cy - r * 0.38f
            arcTo(
                androidx.compose.ui.geometry.Rect(cx2 - r2, cy2 - r2, cx2 + r2, cy2 + r2),
                startAngleDegrees = 130f,
                sweepAngleDegrees = -160f,
                forceMoveTo = false,
            )
        }

        GlyphGroup.PARTLY -> {
            sun(w * 0.32f, h * 0.34f, w * 0.15f, w * 0.23f, w * 0.31f, rays = 6)
            cloud(w * 0.30f, w * 0.92f, h * 0.82f, h * 0.30f)
        }

        GlyphGroup.CLOUD -> cloud(w * 0.10f, w * 0.90f, h * 0.72f, h * 0.34f)

        GlyphGroup.FOG -> {
            cloud(w * 0.15f, w * 0.85f, h * 0.48f, h * 0.26f)
            val lines = Path()
            lines.moveTo(w * 0.12f, h * 0.66f); lines.lineTo(w * 0.88f, h * 0.66f)
            lines.moveTo(w * 0.20f, h * 0.84f); lines.lineTo(w * 0.80f, h * 0.84f)
            strokes += lines
        }

        GlyphGroup.DRIZZLE -> {
            cloud(w * 0.10f, w * 0.90f, h * 0.58f, h * 0.28f)
            dots += Offset(w * 0.35f, h * 0.80f)
            dots += Offset(w * 0.60f, h * 0.90f)
        }

        GlyphGroup.RAIN -> {
            cloud(w * 0.10f, w * 0.90f, h * 0.58f, h * 0.28f)
            val drops = Path()
            drops.moveTo(w * 0.38f, h * 0.74f); drops.lineTo(w * 0.30f, h * 0.94f)
            drops.moveTo(w * 0.62f, h * 0.74f); drops.lineTo(w * 0.54f, h * 0.94f)
            strokes += drops
        }

        GlyphGroup.SNOW -> {
            cloud(w * 0.10f, w * 0.90f, h * 0.58f, h * 0.28f)
            val flakes = Path()
            for ((fx, fy) in listOf(w * 0.36f to h * 0.84f, w * 0.62f to h * 0.86f)) {
                val s = w * 0.06f
                flakes.moveTo(fx - s, fy); flakes.lineTo(fx + s, fy)
                flakes.moveTo(fx, fy - s); flakes.lineTo(fx, fy + s)
            }
            strokes += flakes
        }

        GlyphGroup.THUNDER -> {
            cloud(w * 0.10f, w * 0.90f, h * 0.55f, h * 0.26f)
            strokes += Path().apply {
                moveTo(w * 0.54f, h * 0.62f)
                lineTo(w * 0.40f, h * 0.80f)
                lineTo(w * 0.52f, h * 0.80f)
                lineTo(w * 0.42f, h * 0.97f)
            }
        }
    }
    return GlyphPaths(strokes, dots)
}
