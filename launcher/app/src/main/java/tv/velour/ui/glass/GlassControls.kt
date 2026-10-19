package tv.velour.ui.glass

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text

private val GlassEase = CubicBezierEasing(.20f, .85f, .25f, 1f)

/**
 * A D-pad, keyboard, pointer and accessibility-clickable dock control. Focus and
 * selection are independent: the selected destination retains a quiet violet
 * wash; remote focus carries a bright pearl lens and a clear warm-white rim.
 * A FocusRequester/focusProperties may be supplied on [modifier]. Foundation's
 * clickable provides one activation on key release, consumes a held center/enter
 * key correctly, and removes the focus target when disabled. Direction repeats
 * remain available to the parent focus system.
 */
@Composable
fun GlassIconButton(
    icon: GlassIcon,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    enabled: Boolean = true,
    showLabel: Boolean = true,
    reduceMotion: Boolean = false,
    onFocusChanged: (Boolean) -> Unit = {},
) {
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val focus = remember { Animatable(0f) }
    val press = remember { Animatable(0f) }
    LaunchedEffect(focused, reduceMotion) {
        if (reduceMotion) focus.snapTo(if (focused) 1f else 0f)
        else focus.animateTo(if (focused) 1f else 0f, tween(if (focused) 220 else 180, easing = GlassEase))
    }
    LaunchedEffect(pressed, reduceMotion) {
        if (reduceMotion) press.snapTo(if (pressed) 1f else 0f)
        else press.animateTo(if (pressed) 1f else 0f, tween(100, easing = GlassEase))
    }
    val ink = when {
        !enabled -> Color(0xFF9295A0)
        focused -> Color(0xFFFFFDF8)
        selected -> Color(0xFFDFD8FF)
        else -> Color(0xFFE1E2E8)
    }
    Column(
        modifier = modifier
            .sizeIn(minWidth = if (showLabel) 74.dp else 48.dp, minHeight = if (showLabel) 60.dp else 48.dp)
            .graphicsLayer {
                // State is consumed in the layer/draw phase: no per-frame layout.
                val amount = if (reduceMotion) 0f else focus.value * .035f - press.value * .025f
                scaleX = 1f + amount
                scaleY = 1f + amount
                alpha = if (enabled) 1f else .5f
            }
            .drawWithCache {
                val radius = CornerRadius(27.dp.toPx())
                val halfLine = .7.dp.toPx()
                val stroke = Stroke(1.35.dp.toPx())
                val lens = Brush.linearGradient(
                    0f to Color(0xFFF8F5FF).copy(alpha = .24f),
                    .48f to Color(0xFFE9E4FF).copy(alpha = .10f),
                    1f to Color(0xFFB9ABD8).copy(alpha = .23f),
                    start = Offset.Zero,
                    end = Offset(size.width, size.height),
                )
                val rim = Brush.verticalGradient(
                    0f to Color(0xFFFFF9EF),
                    .48f to Color(0xFFF0EBFF).copy(alpha = .62f),
                    1f to Color(0xFFE3DAFF).copy(alpha = .86f),
                )
                onDrawBehind {
                    if (selected) {
                        drawRoundRect(Color(0xFFB7A5E0), cornerRadius = radius, alpha = .17f)
                    }
                    val light = focus.value
                    if (light > .001f) {
                        drawRoundRect(lens, cornerRadius = radius, alpha = light)
                        drawRoundRect(
                            brush = rim,
                            topLeft = Offset(halfLine, halfLine),
                            size = Size(size.width - halfLine * 2, size.height - halfLine * 2),
                            cornerRadius = radius,
                            style = stroke,
                            alpha = light * .90f,
                        )
                    }
                    if (pressed) drawRoundRect(Color.White, cornerRadius = radius, alpha = .07f * press.value)
                }
            }
            .onFocusChanged {
                focused = it.isFocused
                onFocusChanged(it.isFocused)
            }
            .semantics(mergeDescendants = true) {
                contentDescription = label
                this.selected = selected
            }
            .clickable(
                enabled = enabled,
                role = Role.Button,
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically),
    ) {
        GlassGlyph(icon, Modifier.size(23.dp), ink)
        if (showLabel) {
            Text(
                text = label,
                color = ink,
                fontSize = 11.sp,
                fontWeight = if (focused || selected) FontWeight.SemiBold else FontWeight.Medium,
                letterSpacing = .1.sp,
                maxLines = 1,
            )
        }
    }
}
