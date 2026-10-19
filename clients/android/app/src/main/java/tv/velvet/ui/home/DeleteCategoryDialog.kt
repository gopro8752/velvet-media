package tv.velvet.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.theme.VelvetColors

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun DeleteCategoryDialog(
    title: String,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
    deleting: Boolean = false,
    error: String? = null,
) {
    val cancelFocus = remember { FocusRequester() }
    val deleteFocus = remember { FocusRequester() }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        // Keep an enabled escape route focused while deletion is in progress.
        LaunchedEffect(deleting) {
            withFrameNanos { }
            cancelFocus.requestFocus()
        }
        Column(
            Modifier.width(560.dp).background(VelvetColors.SurfaceElevated, RoundedCornerShape(18.dp))
                .padding(28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Delete category?", style = MaterialTheme.typography.headlineSmall,
                color = VelvetColors.TextPrimary)
            Text(title, style = MaterialTheme.typography.titleMedium, color = VelvetColors.TextPrimary,
                maxLines = 3, overflow = TextOverflow.Ellipsis)
            Text("Only this saved category will be removed.", style = MaterialTheme.typography.bodyMedium,
                color = VelvetColors.TextSecondary)
            error?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = VelvetColors.TextSecondary)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Button(onClick = onDismiss, colors = velvetButtonColors(),
                    modifier = Modifier.focusRequester(cancelFocus).focusProperties {
                        left = FocusRequester.Cancel
                        right = if (deleting) FocusRequester.Cancel else deleteFocus
                    }) { Text("Cancel") }
                Button(onClick = onDelete, enabled = !deleting, colors = velvetButtonColors(),
                    modifier = Modifier.focusRequester(deleteFocus).focusProperties {
                        left = cancelFocus
                        right = FocusRequester.Cancel
                    }) { Text(if (deleting) "Deleting…" else "Delete category") }
            }
        }
    }
}
