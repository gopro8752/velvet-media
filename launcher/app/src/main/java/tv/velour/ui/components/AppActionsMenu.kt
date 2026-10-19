@file:OptIn(ExperimentalComposeUiApi::class)

package tv.velour.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import tv.velour.core.AppAction
import tv.velour.core.AppEntry
import tv.velour.ui.theme.VelourColors
import tv.velour.ui.theme.VelourMotion
import tv.velour.ui.theme.VelourType

private data class MenuRow(val label: String, val action: AppAction, val danger: Boolean = false)

/**
 * Long-press overlay panel (DESIGN.md LONG-PRESS MENU): 240dp wide, SurfaceRaised,
 * radius 12dp, rest rim hairline. Rows are 44dp, Inter 18sp/500, 16dp side insets,
 * staggering in 30ms apart (each 150ms Spotlight with a 16dp slide from the card's
 * edge). Focused row = accent text + 2dp accent bar on the panel's leading edge —
 * no glow; glow is reserved for cards and the clock. BACK dismisses; the world
 * relight is the caller's job. HomeScreen positions this next to the pressed card.
 */
@Composable
fun AppActionsMenu(
    entry: AppEntry,
    isFavorite: Boolean,
    anchorRight: Boolean,        // panel side
    accent: Color,
    onAction: (AppAction) -> Unit,
    onDismiss: () -> Unit,
) {
    BackHandler { onDismiss() }

    val rows = remember(isFavorite) {
        buildList {
            add(MenuRow(if (isFavorite) "Unfavourite" else "Favourite", AppAction.ToggleFavorite))
            // CONTRACT-NOTE: DESIGN.md lists a fixed five-row set, but Move reorders the
            // favorites shelf — it is meaningless for a library-only app, so the row is
            // shown only for favorites rather than rendered as a dead row.
            if (isFavorite) add(MenuRow("Move", AppAction.Move))
            add(MenuRow("Hide", AppAction.Hide))
            add(MenuRow("App info", AppAction.AppInfo))
            add(MenuRow("Uninstall", AppAction.Uninstall, danger = true))
        }
    }

    val firstRowFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { firstRowFocus.requestFocus() } }

    // Slide direction: out from the pressed card's edge.
    val slideSign = if (anchorRight) 1f else -1f

    Column(
        modifier = Modifier
            .width(240.dp)
            // The menu is modal: focus cannot escape while it is up.
            .focusProperties { exit = { FocusRequester.Cancel } }
            .clip(RoundedCornerShape(12.dp))
            .background(VelourColors.SurfaceRaised)
            .drawBehind {
                // Rest rim hairline on the panel itself.
                drawRoundRect(
                    color = Color.White,
                    cornerRadius = CornerRadius(12.dp.toPx(), 12.dp.toPx()),
                    style = Stroke(1.dp.toPx()),
                    alpha = 0.08f,
                )
            }
            .padding(vertical = 6.dp),
    ) {
        rows.forEachIndexed { index, row ->
            MenuRowItem(
                row = row,
                accent = accent,
                anchorRight = anchorRight,
                staggerDelayMs = index * 30L,
                slideSign = slideSign,
                onSelect = { onAction(row.action) },
                modifier = if (index == 0) Modifier.focusRequester(firstRowFocus) else Modifier,
            )
        }
    }
}

@Composable
private fun MenuRowItem(
    row: MenuRow,
    accent: Color,
    anchorRight: Boolean,
    staggerDelayMs: Long,
    slideSign: Float,
    onSelect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    // Entrance: 30ms stagger, 150ms Spotlight, 16dp slide.
    val entrance = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        delay(staggerDelayMs)
        entrance.animateTo(1f, tween(VelourMotion.MenuRowMs, easing = VelourMotion.Spotlight))
    }
    // Focus bar/text accenting, read only in draw.
    val focusT by animateFloatAsState(
        targetValue = if (focused) 1f else 0f,
        animationSpec = tween(VelourMotion.MenuRowMs, easing = VelourMotion.Spotlight),
        label = "menuRowFocus",
    )
    // The long-press that opened this menu may still be held: require a fresh
    // key-down on THIS row before a key-up counts as a click.
    var sawDown by remember { mutableStateOf(false) }

    val textColor = when {
        row.danger -> VelourColors.Danger
        focused -> accent
        else -> VelourColors.InkPrimary
    }
    val barColor = if (row.danger) VelourColors.Danger else accent

    Box(
        contentAlignment = if (anchorRight) Alignment.CenterStart else Alignment.CenterEnd,
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp)
            .graphicsLayer {
                alpha = entrance.value
                translationX = slideSign * 16.dp.toPx() * (1f - entrance.value)
            }
            .onFocusChanged {
                focused = it.isFocused
                if (!it.isFocused) sawDown = false
            }
            .onPreviewKeyEvent { event ->
                when (event.key) {
                    Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> when (event.type) {
                        KeyEventType.KeyDown -> {
                            // Only a FRESH key-down arms the row. The long-press that
                            // opened this menu auto-repeats its key-down while still
                            // held (normal Shield-remote behavior); counting a repeat
                            // would let the eventual release execute this row.
                            if (event.nativeKeyEvent.repeatCount == 0) sawDown = true
                            true // repeats are still consumed — they must not leak out
                        }
                        KeyEventType.KeyUp -> {
                            if (sawDown) {
                                sawDown = false
                                if (!event.nativeKeyEvent.isCanceled) onSelect()
                            }
                            true
                        }
                        else -> false
                    }
                    else -> false
                }
            }
            .drawBehind {
                // 2dp accent bar on the panel's leading edge while focused.
                if (focusT > 0f) {
                    val barW = 2.dp.toPx()
                    val x = if (anchorRight) 0f else size.width - barW
                    drawRect(
                        color = barColor,
                        topLeft = Offset(x, 0f),
                        size = Size(barW, size.height),
                        alpha = focusT,
                    )
                }
            }
            .focusable(),
    ) {
        androidx.tv.material3.Text(
            text = row.label,
            style = VelourType.menuRow,
            color = textColor,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
    }
}
