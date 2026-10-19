package tv.velvet.data.streams

import kotlinx.serialization.Serializable

/**
 * Stremio stream-addon protocol wire shapes, verified against a live addon (curl, 2026-06-09):
 * GET {base}/stream/movie/{imdbId}.json → {"streams":[...]}
 * Notes from real responses:
 *  - "name"/"title" frequently contain newlines and emoji-decorated metadata ("💾 6.91 GB").
 *  - Torrent-only entries carry "infoHash" instead of "url" — those are not playable here.
 *  - behaviorHints.videoSize is a JSON number (bytes); declared Double so integer values parse too.
 */
@Serializable
internal data class StremioStreamsResponse(
    val streams: List<StremioStreamDto> = emptyList(),
)

@Serializable
internal data class StremioStreamDto(
    val url: String? = null,
    val name: String? = null,
    val title: String? = null,
    val description: String? = null,
    val behaviorHints: StremioBehaviorHintsDto? = null,
)

@Serializable
internal data class StremioBehaviorHintsDto(
    val bingeGroup: String? = null,
    val filename: String? = null,
    val videoSize: Double? = null,
    val proxyHeaders: StremioProxyHeadersDto? = null,
)

@Serializable
internal data class StremioProxyHeadersDto(
    val request: Map<String, String> = emptyMap(),
)
