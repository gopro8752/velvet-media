package tv.velvet.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.SurfaceDefaults
import androidx.tv.material3.Text
import tv.velvet.ui.theme.VelvetColors

/**
 * One entry in a [MediaActionsSheet]. Destructive actions ("Remove…", "Clear…")
 * require a second press to confirm — the sheet handles that dance itself, callers
 * just mark [destructive] and provide the final [onSelect].
 */
data class MediaAction(
    val icon: ImageVector,
    val label: String,
    val destructive: Boolean = false,
    val onSelect: () -> Unit,
)

/**
 * Long-press context menu for media cards — the TV answer to a right-click menu.
 *
 * Renders in its own dialog window (same focus-capture guarantee as the Settings
 * dialogs): the screen behind it is unreachable by d-pad until dismissed, and focus
 * returns to the long-pressed card afterwards. Centered SurfaceElevated panel over a
 * 60%-black scrim; first action auto-focused; BACK dismisses.
 *
 * Selecting any action dismisses the sheet (onSelect runs first). Destructive rows
 * swap their label to "Press again to confirm" on the first press; the armed state
 * resets as soon as focus leaves the row.
 */
@Composable
fun MediaActionsSheet(
    title: String,
    subtitle: String?,
    actions: List<MediaAction>,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        // We draw our own scrim below — kill the window's default dim so the
        // result is exactly 60% black, not 60% + platform dim stacked.
        val dialogWindow = (LocalView.current.parent as? DialogWindowProvider)?.window
        SideEffect { dialogWindow?.setDimAmount(0f) }

        BackHandler { onDismiss() }

        val firstActionFocus = remember { FocusRequester() }
        LaunchedEffect(Unit) { runCatching { firstActionFocus.requestFocus() } }

        // Index of the destructive action armed for its confirming second press.
        var confirmingIndex by remember { mutableStateOf(-1) }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.60f)),
            contentAlignment = Alignment.Center,
        ) {
            Surface(
                shape = RoundedCornerShape(14.dp),
                colors = SurfaceDefaults.colors(
                    containerColor = VelvetColors.SurfaceElevated,
                    contentColor = VelvetColors.TextPrimary,
                ),
                modifier = Modifier.width(360.dp),
            ) {
                Column(modifier = Modifier.padding(20.dp)) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleLarge,
                        color = VelvetColors.TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (subtitle != null) {
                        Spacer(Modifier.height(2.dp))
                        Text(
                            text = subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = VelvetColors.TextSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Spacer(Modifier.height(14.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        actions.forEachIndexed { index, action ->
                            MediaActionRow(
                                action = action,
                                confirming = confirmingIndex == index,
                                onFocusLost = {
                                    if (confirmingIndex == index) confirmingIndex = -1
                                },
                                onClick = {
                                    if (action.destructive && confirmingIndex != index) {
                                        confirmingIndex = index
                                    } else {
                                        action.onSelect()
                                        onDismiss()
                                    }
                                },
                                modifier = if (index == 0) {
                                    Modifier.focusRequester(firstActionFocus)
                                } else {
                                    Modifier
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * One focusable action row: 18dp icon + titleSmall label, white-ring pill on focus
 * (mirrors the Settings rows — no scale, full-width rows shouldn't zoom). Destructive
 * rows tint icon + label [VelvetColors.Danger] while focused.
 */
@Composable
private fun MediaActionRow(
    action: MediaAction,
    confirming: Boolean,
    onFocusLost: () -> Unit,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val shape = RoundedCornerShape(10.dp)
    val labelColor = if (action.destructive && focused) {
        VelvetColors.Danger
    } else {
        VelvetColors.TextPrimary
    }
    val iconTint = when {
        action.destructive && focused -> VelvetColors.Danger
        focused -> VelvetColors.TextPrimary
        else -> VelvetColors.TextSecondary
    }
    Surface(
        onClick = onClick,
        interactionSource = interactionSource,
        shape = ClickableSurfaceDefaults.shape(shape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            focusedContainerColor = VelvetColors.SurfaceHighlight,
            pressedContainerColor = VelvetColors.SurfaceHighlight,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = BorderStroke(2.dp, VelvetColors.FocusRing),
                shape = shape,
            ),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        modifier = modifier
            .fillMaxWidth()
            // Arm/disarm is per-row: moving focus away cancels a pending confirm.
            .onFocusChanged { if (!it.isFocused) onFocusLost() },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 11.dp),
        ) {
            Icon(
                imageVector = action.icon,
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(12.dp))
            Text(
                text = if (confirming) "Press again to confirm" else action.label,
                style = MaterialTheme.typography.titleSmall,
                color = labelColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
