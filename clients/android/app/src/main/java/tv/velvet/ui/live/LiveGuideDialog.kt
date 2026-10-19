package tv.velvet.ui.live

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.tv.material3.*
import tv.velvet.data.live.*
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.settings.SettingsRow
import tv.velvet.ui.theme.VelvetColors
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

internal fun guideTime(value: String) = runCatching {
    DateTimeFormatter.ofPattern("EEE h:mm a").withZone(ZoneId.systemDefault()).format(Instant.parse(value))
}.getOrDefault("Time unavailable")

@Composable
fun LiveGuideDialog(channel: LiveChannel, programs: List<LiveProgram>, message: String?, onWatch: () -> Unit, onDismiss: () -> Unit) {
    val closeFocus = remember { FocusRequester() }
    val entries = validPrograms(programs).filter { Instant.parse(it.endTime).isAfter(Instant.now()) }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        LaunchedEffect(Unit) { withFrameNanos { }; closeFocus.requestFocus() }
        CompositionLocalProvider(LocalContentColor provides VelvetColors.TextPrimary) {
        Column(Modifier.width(740.dp).heightIn(max = 470.dp).background(VelvetColors.Background).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(channel.name, style = MaterialTheme.typography.headlineSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Button(onClick = onDismiss, colors = velvetButtonColors(), modifier = Modifier.focusRequester(closeFocus)) { Text("Close") }
                Button(onClick = onWatch, colors = velvetButtonColors()) { Text("Watch live") }
            }
            if (entries.isEmpty()) Text(message ?: "Program information isn't available for this channel yet.", color = VelvetColors.TextSecondary)
            else LazyColumn(Modifier.weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(4.dp)) {
                items(entries, key = { it.id }) { program ->
                    // Focusable rows allow the remote to scroll the complete schedule.
                    SettingsRow(onClick = { }, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(4.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                            Text("${guideTime(program.startTime)} – ${guideTime(program.endTime)}", style = MaterialTheme.typography.labelMedium, color = VelvetColors.TextSecondary)
                            Text(program.title, style = MaterialTheme.typography.titleMedium)
                            program.episodeTitle?.let { Text(it, color = VelvetColors.TextSecondary) }
                            program.description?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = VelvetColors.TextSecondary, maxLines = 4) }
                        }
                    }
                }
            }
        }
    }
    }
}
