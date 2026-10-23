package tv.velvet.ui.player

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.IconButton
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import tv.velvet.ui.theme.VelvetColors
import tv.velvet.BuildConfig
import tv.velvet.data.streams.ExactRecoveryState
import tv.velvet.data.streams.ExactRepairState
import java.util.Locale

internal enum class PlaybackOption { AUDIO, SUBTITLES, BLOCK, RESET, RECOVERY }

/** One home for track choices and reversible actions on this show's current release. */
@Composable
internal fun PlaybackOptionsSheet(
    state: PlayerUiState,
    initialFocus: PlaybackOption,
    onFocus: (PlaybackOption) -> Unit,
    onAudio: () -> Unit,
    onSubtitles: () -> Unit,
    onBlockCurrent: () -> Unit,
    onResetBlocks: () -> Unit,
    onBack: () -> Unit,
) {
    val requesters = remember { PlaybackOption.entries.associateWith { FocusRequester() } }
    val backFocus = remember { FocusRequester() }
    val available = buildList {
        if (state.audioOptions.isNotEmpty()) add(PlaybackOption.AUDIO)
        if (state.subtitleOptions.isNotEmpty()) add(PlaybackOption.SUBTITLES)
        if (state.canBlockCurrentRelease) add(PlaybackOption.BLOCK)
        if (state.isShow && state.blockedGroups.isNotEmpty()) add(PlaybackOption.RESET)
        if (BuildConfig.EXACT_RECOVERY) add(PlaybackOption.RECOVERY)
    }
    LaunchedEffect(available, initialFocus) {
        withFrameNanos { }
        val target = initialFocus.takeIf { it in available } ?: available.firstOrNull()
        runCatching { (requesters[target] ?: backFocus).requestFocus() }
    }
    fun focusModifier(option: PlaybackOption) = Modifier
        .focusRequester(requesters.getValue(option))
        .onFocusChanged { if (it.isFocused) onFocus(option) }

    Box(Modifier.fillMaxSize().background(VelvetColors.Scrim)) {
        Column(
            modifier = Modifier.align(Alignment.CenterEnd).width(380.dp).fillMaxHeight()
                .background(VelvetColors.Surface).verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack, modifier = Modifier.size(36.dp).focusRequester(backFocus)) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to player", tint = VelvetColors.TextPrimary)
                }
                Spacer(Modifier.width(10.dp))
                Text("Playback options", style = MaterialTheme.typography.headlineSmall,
                    color = VelvetColors.TextPrimary)
            }
            Spacer(Modifier.height(6.dp))
            PlaybackOptionRow(
                title = "Audio",
                subtitle = state.audioOptions.firstOrNull { it.selected }?.label ?: "Unavailable",
                enabled = state.audioOptions.isNotEmpty(),
                onClick = onAudio, modifier = focusModifier(PlaybackOption.AUDIO),
            )
            PlaybackOptionRow(
                title = "Subtitles", subtitle = state.subtitleLabel ?: "Off",
                enabled = state.subtitleOptions.isNotEmpty(),
                onClick = onSubtitles, modifier = focusModifier(PlaybackOption.SUBTITLES),
            )
            if (state.canBlockCurrentRelease) {
                PlaybackOptionRow(
                    title = "Block this release", subtitle = "For this show only", navigates = false,
                    onClick = onBlockCurrent, modifier = focusModifier(PlaybackOption.BLOCK),
                )
            }
            if (state.isShow && state.blockedGroups.isNotEmpty()) {
                PlaybackOptionRow(
                    title = "Reset blocked releases", subtitle = "For this show only", navigates = false,
                    onClick = onResetBlocks, modifier = focusModifier(PlaybackOption.RESET),
                )
            }
            if (BuildConfig.EXACT_RECOVERY) {
                Spacer(Modifier.height(6.dp))
                var focused by remember { mutableStateOf(false) }
                Column(
                    Modifier.fillMaxWidth().border(2.dp,
                        if (focused) VelvetColors.FocusRing else VelvetColors.Surface,
                        RoundedCornerShape(10.dp))
                        .then(focusModifier(PlaybackOption.RECOVERY))
                        .onFocusChanged { focused = it.isFocused }.focusable().padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text("Stream recovery", style = MaterialTheme.typography.titleSmall, color = VelvetColors.TextSecondary)
                    Text(recoveryDiagnosticText(state.recoveryDiagnostics, state.repairDiagnostics),
                        style = MaterialTheme.typography.bodySmall, color = VelvetColors.TextTertiary)
                }
            }
            state.groupActionError?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = VelvetColors.Gold)
            }
        }
    }
}

@Composable
internal fun PlaybackOptionRow(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    navigates: Boolean = true,
) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.fillMaxWidth().focusProperties { canFocus = enabled },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(10.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = VelvetColors.SurfaceElevated,
            focusedContainerColor = VelvetColors.SurfaceHighlight,
            disabledContainerColor = VelvetColors.SurfaceElevated.copy(alpha = 0.45f),
        ),
        border = ClickableSurfaceDefaults.border(focusedBorder = Border(
            border = BorderStroke(2.dp, VelvetColors.FocusRing), shape = RoundedCornerShape(10.dp))),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
    ) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, style = MaterialTheme.typography.titleSmall,
                    color = if (enabled) VelvetColors.TextPrimary else VelvetColors.TextTertiary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(subtitle, style = MaterialTheme.typography.labelMedium,
                    color = VelvetColors.TextTertiary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            if (navigates) {
                Spacer(Modifier.width(12.dp))
                Icon(Icons.Default.ChevronRight, null, tint = VelvetColors.TextTertiary,
                    modifier = Modifier.size(20.dp))
            }
        }
    }
}

/** Only fixed labels and numerical measurements are displayed, never upstream errors or URLs. */
internal fun recoveryDiagnosticText(state: ExactRecoveryState?, repair: ExactRepairState? = null): String {
    if (state == null) return "Waiting for recovery status from the backend."
    if (!state.enabled) return "Exact recovery is disabled on this backend."
    val status = when (state.status) {
        "ready", "healthy", "verified" -> "Ahead verified"
        "repairing", "recovering" -> "Repairing ahead"
        "verifying", "prefetching", "warming", "checking" -> "Checking ahead"
        "failed", "unavailable", "exhausted" -> "Recovery unavailable"
        "paused", "stopped" -> "Paused"
        else -> "Monitoring"
    }
    val verified = state.verifiedAheadSeconds?.takeIf { it.isFinite() && it >= 0.0 }
        ?.let { String.format(Locale.US, "%.1f s verified ahead", it) }
        ?: "Verified time unavailable until the media index is ready"
    val repairLine = when (repair?.phase) {
        "ready" -> "PAR2 repair verified"
        "failed" -> "PAR2 repair unavailable"
        "repairing", "downloading" -> "PAR2 recovery in progress"
        else -> null
    }
    val downloaded = repair?.chargedDownloadBytes?.takeIf { it > 0 }
        ?.let { String.format(Locale.US, "Repair budget used: %.1f MiB", it / (1024.0 * 1024.0)) }
    return listOfNotNull(status, verified, repairLine, downloaded).joinToString("\n")
}
