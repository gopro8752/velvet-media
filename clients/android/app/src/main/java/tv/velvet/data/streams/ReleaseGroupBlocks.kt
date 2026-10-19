package tv.velvet.data.streams

import kotlinx.serialization.Serializable
import tv.velvet.data.model.StreamOption
import java.util.Locale

/** A source-provided continuity key, plus a readable name for its explicit block action. */
@Serializable
data class ReleaseGroup(val key: String, val label: String)

private val unidentifiedVelvetGroups = setOf(
    "", "rls", "unknown", "none", "null", "mkv", "mp4", "avi", "mov", "ts", "m2ts",
    "web", "dl", "hd", "ma", "bluray", "webrip", "hdtv", "remux", "proper", "repack",
    "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "aac", "ac3", "eac3",
    "dts", "truehd", "atmos", "hdr", "hdr10", "dv", "2160p", "1080p", "720p", "480p",
)

/**
 * Never infer a group from sourceName (an addon name) or an arbitrary display title.
 * Velvet namespaces its release-group metadata; other addons own opaque binge keys,
 * whose case and punctuation must survive unchanged to avoid blocking another group.
 */
fun StreamOption.releaseGroupForBlocking(): ReleaseGroup? = releaseGroupForBlocking(bingeGroup)

fun releaseGroupForBlocking(bingeGroup: String?): ReleaseGroup? {
    val key = bingeGroup?.trim()?.takeIf { it.isNotEmpty() && it.length <= 512 && it.none(Char::isISOControl) }
        ?: return null
    val label = if (key.startsWith("velvet-")) {
        key.removePrefix("velvet-").takeUnless { it.lowercase(Locale.ROOT) in unidentifiedVelvetGroups }
            ?: return null
    } else key
    return ReleaseGroup(key, label)
}

/** Blocking is exact and scoped by the caller to a single show's stored list. */
fun StreamOption.isReleaseGroupBlocked(groups: Collection<ReleaseGroup>): Boolean {
    val group = releaseGroupForBlocking() ?: return false
    return groups.any { it.key == group.key }
}

fun blockedReleaseGroupsForShow(
    blocks: Map<String, List<ReleaseGroup>>,
    imdbId: String?,
): List<ReleaseGroup> = imdbId?.trim()?.takeIf(String::isNotEmpty)?.let { blocks[it] }.orEmpty()

/** Pure updates used by the DataStore transaction, so overlapping edits cannot lose another show. */
internal fun withBlockedReleaseGroup(
    blocks: Map<String, List<ReleaseGroup>>,
    imdbId: String,
    group: ReleaseGroup,
): Map<String, List<ReleaseGroup>> {
    val show = imdbId.trim().takeIf(String::isNotEmpty) ?: return blocks
    val safeGroup = releaseGroupForBlocking(group.key) ?: return blocks
    return blocks + (show to (blocks[show].orEmpty().filterNot { it.key == safeGroup.key } + safeGroup))
}

internal fun withoutBlockedReleaseGroup(
    blocks: Map<String, List<ReleaseGroup>>,
    imdbId: String,
    groupKey: String,
): Map<String, List<ReleaseGroup>> {
    val show = imdbId.trim()
    val remaining = blocks[show].orEmpty().filterNot { it.key == groupKey }
    return if (remaining.isEmpty()) blocks - show else blocks + (show to remaining)
}
