package tv.velvet.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.OutlinedButtonDefaults
import tv.velvet.ui.theme.VelvetColors

/**
 * Shared Velvet button treatments. Theme.kt sets colorScheme.border to the white
 * FocusRing, which tv-material's OutlinedButtonDefaults uses for the REST-state
 * border — every OutlinedButton must override it or unfocused buttons look focused.
 */

/** Filled button: subdued at rest, white fill + dark content when focused. */
@Composable
fun velvetButtonColors() = ButtonDefaults.colors(
    containerColor = VelvetColors.SurfaceHighlight,
    contentColor = VelvetColors.TextPrimary,
    focusedContainerColor = VelvetColors.FocusRing,
    focusedContentColor = VelvetColors.Background,
    pressedContainerColor = VelvetColors.TextPrimary,
    pressedContentColor = VelvetColors.Background,
)

/** Outlined button: 35%-alpha rest border so only true focus shows the white ring. */
@Composable
fun velvetOutlinedButtonBorder() = OutlinedButtonDefaults.border(
    border = Border(border = BorderStroke(1.dp, VelvetColors.TextPrimary.copy(alpha = 0.35f))),
    focusedBorder = Border(border = BorderStroke(2.dp, VelvetColors.FocusRing)),
    pressedBorder = Border(border = BorderStroke(2.dp, VelvetColors.FocusRing)),
)
