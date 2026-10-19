package tv.velvet.ui.settings

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.tv.material3.Border
import androidx.tv.material3.Button
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.IconButton
import androidx.tv.material3.IconButtonDefaults
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.SurfaceDefaults
import androidx.tv.material3.Text
import tv.velvet.ui.theme.VelvetColors

/**
 * Reusable, d-pad-first building blocks for the Settings screen: focusable rows,
 * switch/checkbox indicators (drawn, never independently focusable — the row is the
 * focus target), Accent-fill selection chips, buttons, dialogs and text fields.
 */
object SettingsDefaults {
    /** Max content width — full-bleed 864dp rows make for huge eye travel on TV. */
    val SectionWidth = 640.dp
    val RowShape = RoundedCornerShape(10.dp)
}

@Composable
fun SettingsSectionHeader(title: String, modifier: Modifier = Modifier) {
    Text(
        text = title,
        style = MaterialTheme.typography.headlineSmall,
        color = VelvetColors.TextPrimary,
        modifier = modifier.padding(top = 18.dp, bottom = 4.dp),
    )
}

/**
 * A focusable settings row. Focus = white ring + brighter container (no scale —
 * full-width rows shouldn't zoom). The whole row is the click/toggle target.
 */
@Composable
fun SettingsRow(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(SettingsDefaults.RowShape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = VelvetColors.Surface,
            focusedContainerColor = VelvetColors.SurfaceElevated,
            pressedContainerColor = VelvetColors.SurfaceHighlight,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = SettingsDefaults.RowShape,
            ),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        modifier = modifier,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            content = content,
        )
    }
}

/** Switch-look toggle visual. Not focusable by itself — embed it in a [SettingsRow]. */
@Composable
fun VelvetSwitchIndicator(checked: Boolean, modifier: Modifier = Modifier) {
    val trackColor by animateColorAsState(
        targetValue = if (checked) VelvetColors.Accent else VelvetColors.SurfaceHighlight,
        label = "switchTrack",
    )
    val thumbOffset by animateDpAsState(
        targetValue = if (checked) 18.dp else 2.dp,
        label = "switchThumb",
    )
    Box(
        modifier = modifier
            .size(width = 38.dp, height = 22.dp)
            .clip(RoundedCornerShape(11.dp))
            .background(trackColor),
    ) {
        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .padding(start = thumbOffset)
                .size(18.dp)
                .clip(CircleShape)
                .background(if (checked) VelvetColors.TextPrimary else VelvetColors.TextSecondary),
        )
    }
}

/** Checkbox-look indicator. Not focusable by itself — embed it in a [SettingsRow]. */
@Composable
fun VelvetCheckIndicator(checked: Boolean, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(6.dp)
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(22.dp)
            .clip(shape)
            .background(if (checked) VelvetColors.Accent else Color.Transparent)
            .border(
                width = 1.5.dp,
                color = if (checked) VelvetColors.Accent else VelvetColors.TextTertiary,
                shape = shape,
            ),
    ) {
        if (checked) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = null,
                tint = VelvetColors.TextPrimary,
                modifier = Modifier.size(15.dp),
            )
        }
    }
}

/** Selection chip: selected = Accent fill with dark text; focus = white ring. */
@Composable
fun VelvetChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(18.dp)
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(shape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) VelvetColors.Accent else VelvetColors.SurfaceElevated,
            focusedContainerColor = if (selected) VelvetColors.Accent else VelvetColors.SurfaceHighlight,
            pressedContainerColor = if (selected) VelvetColors.AccentDeep else VelvetColors.SurfaceHighlight,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = shape,
            ),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.05f),
        modifier = modifier,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) VelvetColors.Background else VelvetColors.TextSecondary,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

/**
 * Standard Velvet button (tv-material Button): subdued at rest, white fill with dark
 * text when focused (Apple TV style). Optional leading icon.
 */
@Composable
fun VelvetButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    enabled: Boolean = true,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        colors = ButtonDefaults.colors(
            containerColor = VelvetColors.SurfaceHighlight,
            contentColor = VelvetColors.TextPrimary,
            focusedContainerColor = VelvetColors.FocusRing,
            focusedContentColor = VelvetColors.Background,
            pressedContainerColor = VelvetColors.TextPrimary,
            pressedContentColor = VelvetColors.Background,
            disabledContainerColor = VelvetColors.SurfaceElevated,
            disabledContentColor = VelvetColors.TextTertiary,
        ),
        modifier = modifier,
    ) {
        if (icon != null) {
            Icon(imageVector = icon, contentDescription = null, modifier = Modifier.size(16.dp))
            Box(Modifier.width(8.dp))
        }
        Text(text = label, style = MaterialTheme.typography.labelLarge)
    }
}

/**
 * Small round icon button for Up/Down/Remove actions. Stays focusable even when the
 * action is a no-op ([dimmed]) so d-pad focus never gets stranded mid-interaction.
 */
@Composable
fun VelvetIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    dimmed: Boolean = false,
    focusedContainerColor: Color = VelvetColors.FocusRing,
    focusedContentColor: Color = VelvetColors.Background,
) {
    IconButton(
        onClick = onClick,
        colors = IconButtonDefaults.colors(
            containerColor = VelvetColors.Surface,
            contentColor = if (dimmed) VelvetColors.TextTertiary else VelvetColors.TextSecondary,
            focusedContainerColor = focusedContainerColor,
            focusedContentColor = focusedContentColor,
            pressedContainerColor = focusedContainerColor,
            pressedContentColor = focusedContentColor,
        ),
        modifier = modifier.size(36.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            modifier = Modifier.size(20.dp),
        )
    }
}

/**
 * Modal dialog: dimmed window with a tv-material Surface card. Using a window keeps
 * d-pad focus contained — the settings list behind it is unreachable until dismissed.
 */
@Composable
fun VelvetDialog(
    title: String,
    onDismiss: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            shape = RoundedCornerShape(14.dp),
            colors = SurfaceDefaults.colors(
                containerColor = VelvetColors.SurfaceElevated,
                contentColor = VelvetColors.TextPrimary,
            ),
            modifier = Modifier.width(440.dp),
        ) {
            Column(modifier = Modifier.padding(24.dp)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.headlineSmall,
                    color = VelvetColors.TextPrimary,
                )
                Box(Modifier.height(16.dp))
                content()
            }
        }
    }
}

/** Right-aligned Cancel / confirm pair for dialogs. */
@Composable
fun DialogButtons(
    confirmLabel: String,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
    confirmEnabled: Boolean = true,
) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.End) {
        VelvetButton(label = "Cancel", onClick = onCancel)
        Box(Modifier.width(12.dp))
        VelvetButton(label = confirmLabel, onClick = onConfirm, enabled = confirmEnabled)
    }
}

/** Velvet text field for dialogs: dark inset, rounded, white cursor, focus ring. */
@Composable
fun VelvetTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    hint: String = "",
    focusRequester: FocusRequester? = null,
) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(10.dp)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = MaterialTheme.typography.bodyLarge.copy(color = VelvetColors.TextPrimary),
        cursorBrush = SolidColor(VelvetColors.FocusRing),
        modifier = modifier
            .fillMaxWidth()
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .onFocusChanged { focused = it.isFocused },
        decorationBox = { innerTextField ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(shape)
                    .background(VelvetColors.Surface)
                    .border(
                        width = 1.5.dp,
                        color = if (focused) VelvetColors.FocusRing else VelvetColors.SurfaceHighlight,
                        shape = shape,
                    )
                    .padding(horizontal = 14.dp, vertical = 11.dp),
            ) {
                if (value.isEmpty()) {
                    Text(
                        text = hint,
                        style = MaterialTheme.typography.bodyLarge,
                        color = VelvetColors.TextTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                innerTextField()
            }
        },
    )
}
