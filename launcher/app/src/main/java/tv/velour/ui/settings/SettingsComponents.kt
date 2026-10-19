package tv.velour.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tv.velour.ui.theme.VelourColors
import tv.velour.ui.theme.VelourMotion
import tv.velour.ui.theme.VelourType

internal val LocalSettingsReduceMotion = staticCompositionLocalOf { false }
internal val SettingsPearl = Color(0xFFF5F2FC)
internal val SettingsSecondary = Color(0xFFB8B6C8)

/** A quiet glass lens with fixed geometry, so remote focus never shifts its neighbors. */
@Composable
internal fun Modifier.settingsFocusLens(focused: Boolean, selected: Boolean = false): Modifier {
    val reduceMotion = LocalSettingsReduceMotion.current
    val light by animateFloatAsState(
        targetValue = if (focused) 1f else 0f,
        animationSpec = tween(if (reduceMotion) 0 else 180, easing = VelourMotion.Spotlight),
        label = "settingsLens",
    )
    return drawWithCache {
        val corner = CornerRadius(14.dp.toPx())
        val lens = Brush.linearGradient(
            listOf(Color(0xFFF6F2FF).copy(alpha = .24f), Color(0xFFCFBEEA).copy(alpha = .10f)),
            start = Offset.Zero,
            end = Offset(size.width, size.height),
        )
        val rim = Brush.verticalGradient(listOf(Color.White.copy(alpha = .85f), Color(0xFFD5C7EE).copy(alpha = .45f)))
        val inset = .65.dp.toPx()
        val stroke = Stroke(1.2.dp.toPx())
        onDrawBehind {
            if (selected) drawRoundRect(Color(0xFFB8A7DD), cornerRadius = corner, alpha = .10f)
            if (light > .001f) {
                drawRoundRect(lens, cornerRadius = corner, alpha = light)
                drawRoundRect(
                    brush = rim,
                    topLeft = Offset(inset, inset),
                    size = Size(size.width - 2 * inset, size.height - 2 * inset),
                    cornerRadius = corner,
                    style = stroke,
                    alpha = light,
                )
            }
        }
    }
}

/** Space Grotesk caps eyebrow heading a right-pane section. */
@Composable
fun PaneEyebrow(text: String, modifier: Modifier = Modifier) {
    androidx.tv.material3.Text(
        text = text,
        style = VelourType.clockMini.copy(fontSize = 24.sp),
        color = SettingsPearl,
        modifier = modifier,
    )
}

/**
 * 48dp focusable text row. Focused: accent text + 2dp accent leading bar (150ms Spotlight).
 * [selected] draws a 6dp accent dot at the trailing edge; [trailing] is a secondary value.
 */
@Composable
fun SettingsTextRow(
    label: String,
    accent: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    trailing: String? = null,
    selected: Boolean = false,
    danger: Boolean = false,
) {
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    val textColor = when {
        danger -> VelourColors.Danger
        else -> SettingsPearl
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .height(50.dp)
            .onFocusChanged { focused = it.isFocused }
            .settingsFocusLens(focused, selected)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = 16.dp),
    ) {
        androidx.tv.material3.Text(
            text = label,
            style = VelourType.menuRow.copy(fontSize = 16.sp),
            color = textColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (trailing != null) {
            androidx.tv.material3.Text(
                text = trailing,
                style = VelourType.body.copy(fontSize = 14.sp),
                color = if (focused) SettingsPearl else SettingsSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(start = 14.dp).widthIn(max = 230.dp),
            )
        }
        if (selected) {
            Spacer(Modifier.width(12.dp))
            Box(
                Modifier
                    .size(6.dp)
                    .background(accent, CircleShape)
            )
        }
    }
}

/** Boolean row: OK toggles, trailing reads On/Off. */
@Composable
fun SettingsToggleRow(
    label: String,
    checked: Boolean,
    accent: Color,
    onToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    SettingsTextRow(
        label = label,
        accent = accent,
        trailing = if (checked) "On" else "Off",
        selected = checked,
        onClick = { onToggle(!checked) },
        modifier = modifier,
    )
}

/**
 * Text-entry row that plays nicely with the TV IME: at rest it is a plain focusable row
 * showing the current value; OK enters edit mode, focuses an inline BasicTextField and
 * summons the keyboard. IME Done or BACK commits and returns to row mode.
 */
@Composable
fun SettingsEditRow(
    label: String,
    value: String,
    placeholder: String,
    accent: Color,
    onCommit: (String) -> Unit,
    modifier: Modifier = Modifier,
    onValueChange: (String) -> Unit = {},
) {
    var editing by remember { mutableStateOf(false) }
    var text by remember { mutableStateOf(value) }
    var focused by remember { mutableStateOf(false) }
    val rowFocus = remember { FocusRequester() }
    val fieldFocus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val interaction = remember { MutableInteractionSource() }

    fun commit() {
        // Move focus before removing the editor. Otherwise Android's focus recovery
        // may jump to the first sidebar item and dispose the current settings pane.
        runCatching { rowFocus.requestFocus() }
        editing = false
        keyboard?.hide()
        onCommit(text)
    }
    BackHandler(enabled = editing) { commit() }
    LaunchedEffect(editing) {
        if (editing) {
            withFrameNanos { }
            runCatching { fieldFocus.requestFocus() }
            keyboard?.show()
        }
    }

    // Keep this focus target mounted in both modes. The editor receives focus
    // only after it attaches, so entering text cannot briefly focus the sidebar.
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .height(50.dp)
            .focusRequester(rowFocus)
            .onFocusChanged { focused = it.isFocused }
            .settingsFocusLens(focused || editing)
            .clickable(interactionSource = interaction, indication = null) {
                if (!editing) {
                    text = value
                    editing = true
                }
            }
            .padding(horizontal = 16.dp),
    ) {
        androidx.tv.material3.Text(
            text = label,
            style = VelourType.menuRow.copy(fontSize = 16.sp),
            color = SettingsPearl,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = if (editing) Modifier else Modifier.weight(1f),
        )
        Spacer(Modifier.width(16.dp))
        if (editing) {
            BasicTextField(
                value = text,
                onValueChange = {
                    text = it
                    onValueChange(it)
                },
                singleLine = true,
                textStyle = VelourType.body.copy(color = VelourColors.InkPrimary),
                cursorBrush = SolidColor(accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { commit() }),
                modifier = Modifier
                    .weight(1f)
                    .onPreviewKeyEvent { event ->
                        if (event.key == Key.Back) {
                            if (event.type == KeyEventType.KeyDown && event.nativeKeyEvent.repeatCount == 0) commit()
                            true
                        } else false
                    }
                    .focusRequester(fieldFocus),
            )
        } else {
            androidx.tv.material3.Text(
                text = value.ifEmpty { placeholder },
                style = VelourType.body.copy(fontSize = 14.sp),
                color = if (focused) SettingsPearl else SettingsSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 230.dp),
            )
        }
    }
}
