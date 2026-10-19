package tv.velour.ui.glass

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

enum class GlassIcon {
    Home, Search, Apps, LiveTV, Sports, Settings, Plus, Play, Velvet,
    Back, Info, ArrowRight, Clock, Moon, Heart, Check,
}

/** Small, consistent hand-drawn glyphs; no icon font, bitmap, or extra dependency. */
@Composable
fun GlassGlyph(
    icon: GlassIcon,
    modifier: Modifier = Modifier.size(24.dp),
    tint: Color = Color.White,
) {
    val geometry = remember(icon) { glyphPaths(icon) }
    val stroke = remember { Stroke(width = 1.65f, cap = StrokeCap.Round, join = StrokeJoin.Round) }
    Canvas(modifier) {
        val factor = minOf(size.width, size.height) / 24f
        scale(factor, factor, pivot = androidx.compose.ui.geometry.Offset.Zero) {
            for (index in geometry.indices) {
                val segment = geometry[index]
                drawPath(segment.path, color = tint, style = if (segment.filled) Fill else stroke)
            }
        }
    }
}

private data class GlyphPath(val path: Path, val filled: Boolean = false)

private fun glyphPaths(icon: GlassIcon): List<GlyphPath> = buildList {
    fun outline(block: Path.() -> Unit) = add(GlyphPath(Path().apply(block)))
    fun fill(block: Path.() -> Unit) = add(GlyphPath(Path().apply(block), true))
    fun Path.roundRect(left: Float, top: Float, right: Float, bottom: Float, radius: Float) {
        addRoundRect(RoundRect(left, top, right, bottom, CornerRadius(radius)))
    }
    when (icon) {
        GlassIcon.Home -> {
            outline {
                moveTo(2.1f, 10.6f); lineTo(12f, 2.5f); lineTo(21.9f, 10.6f)
                moveTo(5f, 9.2f); lineTo(5f, 20.5f); lineTo(19f, 20.5f); lineTo(19f, 9.2f)
            }
            fill { moveTo(10f, 10.7f); lineTo(15.4f, 14.1f); lineTo(10f, 17.5f); close() }
        }
        GlassIcon.Search -> outline {
            addOval(Rect(3f, 2.7f, 16.9f, 16.6f))
            moveTo(14.9f, 14.5f); lineTo(21f, 20.6f)
        }
        GlassIcon.Apps -> outline {
            roundRect(3f, 3f, 10f, 10f, 1.8f)
            roundRect(14f, 3f, 21f, 10f, 1.8f)
            roundRect(3f, 14f, 10f, 21f, 1.8f)
            roundRect(14f, 14f, 21f, 21f, 1.8f)
        }
        GlassIcon.LiveTV -> outline {
            roundRect(2f, 3.7f, 22f, 17.7f, 2.1f)
            moveTo(8.1f, 21f); lineTo(15.9f, 21f)
            moveTo(12f, 17.7f); lineTo(12f, 21f)
        }
        GlassIcon.Sports -> outline {
            roundRect(1.6f, 4f, 22.4f, 20f, 1.5f)
            moveTo(12f, 4f); lineTo(12f, 20f)
            addOval(Rect(8.4f, 8.4f, 15.6f, 15.6f))
            moveTo(1.6f, 8f); lineTo(5.4f, 8f); lineTo(5.4f, 16f); lineTo(1.6f, 16f)
            moveTo(22.4f, 8f); lineTo(18.6f, 8f); lineTo(18.6f, 16f); lineTo(22.4f, 16f)
        }
        GlassIcon.Settings -> {
            outline {
                // Eight shallow teeth keep the silhouette recognizable at TV distance.
                for (index in 0 until 32) {
                    val angle = index * (PI * 2 / 32) - PI / 2
                    val radius = if (index % 4 == 0 || index % 4 == 3) 9.5f else 7.7f
                    val x = 12f + cos(angle).toFloat() * radius
                    val y = 12f + sin(angle).toFloat() * radius
                    if (index == 0) moveTo(x, y) else lineTo(x, y)
                }
                close()
                addOval(Rect(8.6f, 8.6f, 15.4f, 15.4f))
            }
        }
        GlassIcon.Plus -> outline {
            moveTo(12f, 4.5f); lineTo(12f, 19.5f)
            moveTo(4.5f, 12f); lineTo(19.5f, 12f)
        }
        GlassIcon.Play -> fill {
            moveTo(7f, 3.4f); cubicTo(6.4f, 3.1f, 5.9f, 3.4f, 5.9f, 4.1f)
            lineTo(5.9f, 19.9f); cubicTo(5.9f, 20.6f, 6.4f, 20.9f, 7f, 20.6f)
            lineTo(20f, 12.7f); cubicTo(20.6f, 12.4f, 20.6f, 11.6f, 20f, 11.3f)
            close()
        }
        GlassIcon.Velvet -> fill {
            moveTo(2.4f, 3.2f); lineTo(7.4f, 3.2f); lineTo(12f, 15.4f)
            lineTo(16.6f, 3.2f); lineTo(21.6f, 3.2f); lineTo(14.4f, 21f)
            lineTo(9.6f, 21f); close()
        }
        GlassIcon.Back -> outline {
            moveTo(14.9f, 4.2f); lineTo(7.1f, 12f); lineTo(14.9f, 19.8f)
        }
        GlassIcon.Info -> {
            outline {
                addOval(Rect(2.7f, 2.7f, 21.3f, 21.3f))
                moveTo(11f, 10.6f); lineTo(12.4f, 10.6f); lineTo(12.4f, 16.8f)
                moveTo(10.5f, 16.8f); lineTo(14.2f, 16.8f)
            }
            fill { addOval(Rect(11.15f, 6.1f, 13.25f, 8.2f)) }
        }
        GlassIcon.ArrowRight -> outline {
            moveTo(3.5f, 12f); lineTo(20.5f, 12f)
            moveTo(13f, 4.5f); lineTo(20.5f, 12f); lineTo(13f, 19.5f)
        }
        GlassIcon.Clock -> outline {
            addOval(Rect(2.5f, 2.5f, 21.5f, 21.5f))
            moveTo(12f, 6.4f); lineTo(12f, 12f); lineTo(16.2f, 14.5f)
        }
        GlassIcon.Moon -> outline {
            moveTo(10.8f, 2.5f)
            cubicTo(9f, 3.5f, 7.9f, 6.4f, 7.9f, 9.1f)
            cubicTo(7.9f, 13.9f, 11.8f, 17.4f, 16.3f, 17.4f)
            cubicTo(18.2f, 17.4f, 20f, 16.8f, 21.4f, 15.8f)
            cubicTo(20f, 19.6f, 16.4f, 21.7f, 12.6f, 21.7f)
            cubicTo(7f, 21.7f, 2.8f, 17.5f, 2.8f, 12f)
            cubicTo(2.8f, 7.3f, 6.2f, 3.1f, 10.8f, 2.5f)
            close()
        }
        GlassIcon.Heart -> outline {
            moveTo(12f, 20.3f)
            cubicTo(9.5f, 18.2f, 2.5f, 13.9f, 2.5f, 8.3f)
            cubicTo(2.5f, 2.4f, 9f, 2f, 12f, 6.3f)
            cubicTo(15f, 2f, 21.5f, 2.4f, 21.5f, 8.3f)
            cubicTo(21.5f, 13.9f, 14.5f, 18.2f, 12f, 20.3f)
            close()
        }
        GlassIcon.Check -> outline {
            moveTo(4f, 12.4f); lineTo(9.5f, 18f); lineTo(20.5f, 6f)
        }
    }
}
