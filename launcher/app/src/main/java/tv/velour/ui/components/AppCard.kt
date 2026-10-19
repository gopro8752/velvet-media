package tv.velour.ui.components

import android.os.SystemClock
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.findRootCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import tv.velour.core.AppEntry
import tv.velour.ui.theme.VelourColors
import tv.velour.ui.theme.VelourMotion
import tv.velour.ui.theme.VelourType
import kotlin.math.PI
import kotlin.math.cos

private const val LONG_PRESS_MS = 400L

/** 8000ms alternating sine for the Ken Burns dwell drift. */
private val SineEasing = Easing { x -> ((1f - cos(PI.toFloat() * x)) / 2f) }

/**
 * D-pad press handling at the KEY-EVENT layer (velvet MediaCards.kt pattern) —
 * combinedClickable onLongClick is unreliable on TV. A held DPAD_CENTER/ENTER repeats
 * its key-down; we fire [onLongPress] the moment the hold crosses 400ms (so the menu
 * opens while the button is still down) and swallow the eventual key-up. Remotes that
 * do not auto-repeat fall back to the key-up duration check. A stray key-up with no
 * recorded key-down (marquee wake, focus handoff) is ignored.
 */
private fun Modifier.cardPressKeys(
    pressState: LongArray, // [0] = downAt (0 = idle), [1] = longPressFired
    onClick: () -> Unit,
    onLongPress: () -> Unit,
): Modifier = onPreviewKeyEvent { event ->
    when (event.key) {
        Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> when (event.type) {
            KeyEventType.KeyDown -> {
                val now = SystemClock.uptimeMillis()
                if (event.nativeKeyEvent.repeatCount == 0) {
                    // Only a FRESH key-down starts a press. Auto-repeat downs whose
                    // original down we never saw (marquee wake, focus handoff) must not
                    // seed downAt, or the swallowed wake key-up leaves a stale press
                    // that turns the next quick OK tap into a phantom long-press.
                    if (pressState[0] == 0L) {
                        pressState[0] = now
                        pressState[1] = 0L
                    }
                } else if (pressState[0] != 0L && pressState[1] == 0L &&
                    (now - pressState[0] >= LONG_PRESS_MS || event.nativeKeyEvent.isLongPress)
                ) {
                    // The isLongPress flag covers input stacks whose repeats carry
                    // unreliable timing (HDMI-CEC bridges, synthetic input) — the
                    // system stamps it on the repeat that crosses ITS long-press
                    // timeout, which on a real remote lands just after our 400ms.
                    pressState[1] = 1L
                    onLongPress()
                }
                true
            }
            KeyEventType.KeyUp -> {
                val downAt = pressState[0]
                val fired = pressState[1]
                pressState[0] = 0L
                pressState[1] = 0L
                if (downAt == 0L) {
                    false
                } else {
                    if (fired == 0L) {
                        if (SystemClock.uptimeMillis() - downAt >= LONG_PRESS_MS) onLongPress()
                        else onClick()
                    }
                    true
                }
            }
            else -> false
        }
        else -> false
    }
}

@Composable
fun AppCard(
    entry: AppEntry,
    banner: ImageBitmap?,        // null → playbill rendering
    whisper: Color?,             // playbill dominant-color whisper
    width: Dp, height: Dp, radius: Dp,
    accent: Color,
    focusedScale: Float,
    dimmed: Boolean, neighborDim: Boolean, reduceMotion: Boolean,
    smallType: Boolean,          // library tile type sizes
    onLaunch: (boundsInRoot: Rect) -> Unit,   // androidx.compose.ui.geometry.Rect
    onLongPress: () -> Unit,
    onFocused: (centerXNorm: Float) -> Unit,  // feeds FocusLight + house dimming bookkeeping
    modifier: Modifier = Modifier,
    // CONTRACT-NOTE: defaulted param beyond the contract signature — while the long-press
    // menu owns input the pressed card must HOLD its full focus treatment (DESIGN.md
    // LONG-PRESS: "pressed card holds 100% + glow"), even though real focus sits on the
    // panel's first row. The latch keeps scale, rim and breathing glow lit without
    // re-firing the one-shot specular sweep.
    heldFocused: Boolean = false,
) {
    var focused by remember { mutableStateOf(false) }
    var coords by remember { mutableStateOf<LayoutCoordinates?>(null) }
    val pressState = remember { longArrayOf(0L, 0L) }
    val effectiveFocused = focused || heldFocused
    val lifecycleOwner = LocalLifecycleOwner.current

    // CONTRACT-NOTE: the contract gives AppCard no glowBoost parameter; MOVE mode's
    // doubled, 1500ms-pulsing glow rides in on its distinctive 1.16 lift scale.
    val glowBoost = if (focusedScale > 1.14f) 2f else 1f

    // Ken Burns dwell: after 2s steady focus, art drifts 1.0 -> 1.04 on an 8000ms
    // alternating sine. Frozen under reduce-motion. Only the focused card runs this.
    // The infinite drift pauses whenever the launcher is not RESUMED (DESIGN.md
    // REDUCE MOTION: "All InfiniteTransitions pause when not RESUMED").
    val kenBurns = remember { Animatable(1f) }
    LaunchedEffect(effectiveFocused, reduceMotion, banner == null) {
        if (effectiveFocused && !reduceMotion && banner != null) {
            kenBurns.snapTo(1f)
            delay(2000)
            lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                kenBurns.animateTo(
                    targetValue = 1.04f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(8000, easing = SineEasing),
                        repeatMode = RepeatMode.Reverse,
                    ),
                )
            }
        } else {
            kenBurns.snapTo(1f)
        }
    }

    // Focused-only label below favorites cards: 150ms fade after a 100ms settle delay.
    val labelAlpha = remember { Animatable(0f) }
    if (!smallType) {
        LaunchedEffect(effectiveFocused) {
            if (effectiveFocused) {
                delay(100)
                labelAlpha.animateTo(1f, tween(150, easing = LinearEasing))
            } else {
                labelAlpha.animateTo(0f, tween(VelourMotion.MenuRowMs, easing = LinearEasing))
            }
        }
    }

    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = modifier) {
        Box(
            modifier = Modifier
                .size(width, height)
                .onGloballyPositioned { coords = it }
                .onFocusChanged { state ->
                    focused = state.isFocused
                    if (!state.isFocused) {
                        pressState[0] = 0L
                        pressState[1] = 0L
                    } else {
                        coords?.let { c ->
                            val rootW = c.findRootCoordinates().size.width
                            if (rootW > 0) {
                                val b = c.boundsInRoot()
                                onFocused(((b.left + b.right) / 2f / rootW).coerceIn(0f, 1f))
                            }
                        }
                    }
                }
                .cardPressKeys(
                    pressState = pressState,
                    onClick = { coords?.let { onLaunch(it.boundsInRoot()) } },
                    onLongPress = onLongPress,
                )
                .velourFocus(
                    focused = effectiveFocused,
                    accent = accent,
                    radius = radius,
                    focusedScale = focusedScale,
                    glowBoost = glowBoost,
                    dimmed = dimmed,
                    neighborDim = neighborDim,
                    reduceMotion = reduceMotion,
                )
                .focusable(),
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(radius))
            ) {
                if (banner != null) {
                    Image(
                        bitmap = banner,
                        contentDescription = entry.label,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxSize()
                            .graphicsLayer {
                                val k = kenBurns.value
                                scaleX = k
                                scaleY = k
                            },
                    )
                } else {
                    PlaybillFace(
                        entry = entry,
                        whisper = whisper,
                        accent = accent,
                        smallType = smallType,
                    )
                }
            }
        }
        // Label slot keeps a fixed height so focus motion never relayouts the row.
        if (!smallType) {
            Spacer(Modifier.height(12.dp))
            Box(Modifier.width(width).height(20.dp), contentAlignment = Alignment.TopCenter) {
                androidx.tv.material3.Text(
                    text = entry.label,
                    style = VelourType.cardTitle,
                    color = VelourColors.InkPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.graphicsLayer { alpha = labelAlpha.value },
                )
            }
        }
    }
}

/**
 * PLAYBILL CARD for bannerless apps (DESIGN.md Zone B): Surface fill, name bottom-left
 * at 12dp insets (2-line max), a 16x2dp accent tick 6dp above the name, and a
 * dominant-color radial whisper (color@10% -> transparent) centered top-right.
 * The 1dp hairline frame is the velourFocus rest rim.
 */
@Composable
private fun PlaybillFace(
    entry: AppEntry,
    whisper: Color?,
    accent: Color,
    smallType: Boolean,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(VelourColors.Surface)
            .drawWithCache {
                val brush = whisper?.let {
                    Brush.radialGradient(
                        colors = listOf(it.copy(alpha = 0.10f), it.copy(alpha = 0f)),
                        center = Offset(size.width, 0f),
                        radius = size.width * 0.9f,
                    )
                }
                onDrawBehind {
                    if (brush != null) drawRect(brush)
                }
            }
    ) {
        Column(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(12.dp),
        ) {
            Box(
                Modifier
                    .size(width = 16.dp, height = 2.dp)
                    .background(accent)
            )
            Spacer(Modifier.height(6.dp))
            androidx.tv.material3.Text(
                text = entry.label,
                style = if (smallType) VelourType.playbillNameSmall else VelourType.playbillName,
                color = VelourColors.InkPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
