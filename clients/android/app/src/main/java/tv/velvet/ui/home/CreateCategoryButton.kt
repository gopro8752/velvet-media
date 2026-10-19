package tv.velvet.ui.home

import android.animation.ValueAnimator
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SweepGradient
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import tv.velvet.ui.theme.VelvetColors

/** A quiet moving outline invites discovery; the white ring always means D-pad focus. */
@Composable
fun CreateCategoryButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var motionEnabled by remember(lifecycle) {
        mutableStateOf(
            lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) &&
                ValueAnimator.areAnimatorsEnabled()
        )
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME ->
                    motionEnabled = ValueAnimator.areAnimatorsEnabled()
                Lifecycle.Event.ON_STOP -> motionEnabled = false
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    // Read the animated value only while drawing: the text and layout do not
    // recompose every frame. Disabled system animations get a static highlight.
    val outlineAngle: State<Float> = if (motionEnabled) {
        rememberInfiniteTransition(label = "categoryOutline").animateFloat(
            initialValue = 0f,
            targetValue = 360f,
            animationSpec = infiniteRepeatable(
                animation = tween(5400, easing = LinearEasing),
                repeatMode = RepeatMode.Restart,
            ),
            label = "categoryOutlineAngle",
        )
    } else {
        remember { mutableStateOf(25f) }
    }
    val shape = RoundedCornerShape(50)

    Surface(
        onClick = onClick,
        interactionSource = interactionSource,
        shape = ClickableSurfaceDefaults.shape(shape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = VelvetColors.Surface.copy(alpha = 0.94f),
            contentColor = VelvetColors.TextPrimary,
            focusedContainerColor = VelvetColors.SurfaceHighlight,
            focusedContentColor = VelvetColors.FocusRing,
            pressedContainerColor = VelvetColors.AccentDeep,
            pressedContentColor = VelvetColors.FocusRing,
        ),
        border = ClickableSurfaceDefaults.border(
            border = Border(BorderStroke(1.dp, VelvetColors.Accent.copy(alpha = 0.40f)), shape = shape),
            focusedBorder = Border(BorderStroke(2.dp, VelvetColors.FocusRing), shape = shape),
            pressedBorder = Border(BorderStroke(2.dp, VelvetColors.FocusRing), shape = shape),
        ),
        glow = ClickableSurfaceDefaults.glow(
            focusedGlow = Glow(VelvetColors.Accent.copy(alpha = 0.40f), elevation = 12.dp),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.035f),
        // Keep the caller's focusRequester/focusProperties on the actual TV
        // Surface, with no extra focus target between it and the remote.
        modifier = modifier
            .height(40.dp)
            .widthIn(min = 176.dp)
            .semantics { role = Role.Button }
            .drawWithCache {
                val inset = if (focused) 3.dp.toPx() else 1.4.dp.toPx()
                val bounds = RectF(inset, inset, size.width - inset, size.height - inset)
                val gradient = SweepGradient(
                    size.width / 2f,
                    size.height / 2f,
                    intArrayOf(
                        VelvetColors.Accent.copy(alpha = 0f).toArgb(),
                        VelvetColors.Accent.copy(alpha = 0.08f).toArgb(),
                        VelvetColors.Accent.copy(alpha = 0.80f).toArgb(),
                        Color(0xFFE0D9FF).copy(alpha = 0.95f).toArgb(),
                        VelvetColors.Accent.copy(alpha = 0.12f).toArgb(),
                        VelvetColors.Accent.copy(alpha = 0f).toArgb(),
                    ),
                    floatArrayOf(0f, 0.10f, 0.23f, 0.31f, 0.44f, 1f),
                )
                val rotation = Matrix()
                val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE
                    strokeWidth = 1.3.dp.toPx()
                    shader = gradient
                }
                onDrawWithContent {
                    drawContent()
                    rotation.setRotate(outlineAngle.value, size.width / 2f, size.height / 2f)
                    gradient.setLocalMatrix(rotation)
                    drawIntoCanvas { canvas ->
                        canvas.nativeCanvas.drawRoundRect(bounds, bounds.height() / 2f, bounds.height() / 2f, paint)
                    }
                }
            },
    ) {
        Row(
            modifier = Modifier.fillMaxHeight().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        ) {
            Icon(
                imageVector = Icons.Default.AutoAwesome,
                contentDescription = null,
                tint = if (focused) VelvetColors.FocusRing else VelvetColors.Accent,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = "Create category",
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
            )
        }
    }
}
