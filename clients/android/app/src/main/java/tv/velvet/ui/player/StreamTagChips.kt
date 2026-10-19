package tv.velvet.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import tv.velvet.data.streams.ReleaseTag
import tv.velvet.data.streams.ReleaseTagKind
import tv.velvet.data.streams.StreamTags
import tv.velvet.ui.theme.VelvetColors

/**
 * Compact wrapping row of pretty release tags for a stream-picker tile.
 *
 * Self-contained: give it the raw [StreamOption.title] and its [quality] and it
 * parses, folds the old quality badge into the RESOLUTION chip, and wraps chips
 * onto up to two short lines. RESOLUTION and HDR chips are accent-emphasized;
 * everything else is a neutral surface chip.
 *
 * If the title yields no recognizable tags AND no [quality] is known, it falls
 * back to a two-line, ellipsized trimmed title so the tile is never blank.
 */
// FlowRow is @ExperimentalLayoutApi in compose-foundation — chip wrapping is exactly what
// it is for, and the call site below uses nothing beyond its stable arrangement params.
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun StreamTagChipRow(
    title: String,
    quality: String?,
    modifier: Modifier = Modifier,
    fallbackLabel: String? = null,
) {
    val chips = remember(title, quality) { buildChips(title, quality) }

    if (chips.isEmpty()) {
        Text(
            text = fallbackLabel ?: remember(title) { trimmedTitle(title) },
            style = MaterialTheme.typography.titleSmall,
            color = VelvetColors.TextPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = modifier,
        )
        return
    }

    FlowRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        for (tag in chips) TagChip(tag)
    }
}

@Composable
private fun TagChip(tag: ReleaseTag) {
    val emphasized = tag.kind == ReleaseTagKind.RESOLUTION ||
        tag.kind == ReleaseTagKind.HDR ||
        tag.kind == ReleaseTagKind.THREE_D
    val bg: Color = when (tag.kind) {
        ReleaseTagKind.THREE_D -> VelvetColors.Danger.copy(alpha = 0.32f)
        ReleaseTagKind.RESOLUTION -> VelvetColors.AccentDeep.copy(alpha = 0.35f)
        ReleaseTagKind.HDR -> VelvetColors.Accent.copy(alpha = 0.30f)
        else -> VelvetColors.SurfaceHighlight
    }
    val fg = if (emphasized) VelvetColors.TextPrimary else VelvetColors.TextSecondary
    Box(
        modifier = Modifier
            .background(color = bg, shape = RoundedCornerShape(6.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Text(
            text = tag.label,
            style = MaterialTheme.typography.labelSmall,
            color = fg,
            maxLines = 1,
        )
    }
}

/**
 * Parsed tags, with the quality badge folded in as a RESOLUTION chip when the
 * title itself carried no resolution but [StreamOption.quality] is known.
 */
private fun buildChips(title: String, quality: String?): List<ReleaseTag> {
    val tags = StreamTags.parse(title)
    val hasResolution = tags.any { it.kind == ReleaseTagKind.RESOLUTION }
    if (hasResolution || quality.isNullOrBlank()) return tags
    val label = qualityToResolutionLabel(quality) ?: return tags
    return buildList {
        add(ReleaseTag(label, ReleaseTagKind.RESOLUTION))
        addAll(tags)
    }
}

/** Mirror of the parser's RESOLUTION mapping, for the StreamOption.quality field. */
private fun qualityToResolutionLabel(quality: String): String? {
    return when (quality.lowercase()) {
        "2160p", "4k", "uhd" -> "4K"
        "1080p", "fhd" -> "1080p"
        "720p" -> "720p"
        "480p" -> "480p"
        else -> quality.uppercase()
    }
}

/** Fallback shown only when nothing parses: drop a trailing container extension. */
private fun trimmedTitle(title: String): String {
    val dot = title.lastIndexOf('.')
    if (dot > 0 && title.length - dot in 2..5) {
        val ext = title.substring(dot + 1).lowercase()
        if (ext in setOf("mkv", "mp4", "avi", "ts", "m2ts", "mov", "wmv")) {
            return title.substring(0, dot)
        }
    }
    return title
}
