package tv.velvet.data.streams

import tv.velvet.data.model.MediaType
import tv.velvet.data.model.StreamOption

/**
 * Resolves playable streams from the user's configured stream sources.
 * Implementation: StreamRepositoryImpl (Stremio-protocol-compatible adapter), this package.
 *
 * Contract notes for the implementation:
 *  - Sources come from SettingsRepository.settings.streamSources (enabled only), queried in
 *    parallel with a per-source timeout (~12s) — one dead source must not block the rest.
 *  - Stremio-compat endpoint shapes:
 *      movies:  GET {baseUrl}/stream/movie/{imdbId}.json
 *      shows:   GET {baseUrl}/stream/series/{imdbId}:{season}:{episode}.json
 *    Response: {"streams":[{ "url", "name", "title"|"description", "behaviorHints":{"bingeGroup","filename","videoSize"} }]}
 *  - Parse quality ("2160p"/"4k"→2160p etc.) and size from name/title/description text and
 *    behaviorHints. sourceName = configured source name.
 *  - sortStreams(): 2D first, preferred quality (from settings), quality rank, then the
 *    real-quality tiers — remux > HDR rank (DoVi > HDR10+ > HDR10/HDR) > audio rank
 *    (TrueHD Atmos > DTS-X > …) — with size only as the final tiebreaker.
 *  - autoPick(previousBingeGroup, manualGroup): a persisted MANUAL release-group pick for
 *    this show wins first, then the session bingeGroup (binge continuity), else first of
 *    sortStreams(). A group with no match this episode falls through silently.
 */
interface StreamRepository {
    suspend fun streamsFor(
        imdbId: String,
        type: MediaType,
        season: Int? = null,
        episode: Int? = null,
    ): List<StreamOption>

    fun sortStreams(streams: List<StreamOption>, preferredQuality: String): List<StreamOption>

    fun autoPick(
        streams: List<StreamOption>,
        preferredQuality: String,
        previousBingeGroup: String? = null,
        manualGroup: String? = null,
    ): StreamOption?

    /**
     * Health-checks the head of an ALREADY-SORTED list (pass the output of [sortStreams])
     * so the player never starts on a dead/incomplete NZB.
     *
     * Probes the first [limit] candidates IN PARALLEL — HTTP GET with
     * `Range: bytes=0-131071`, ~6 s timeout, redirects followed, the stream's own headers
     * sent — and returns the healthy ones in their original sorted order. Healthy =
     * HTTP 200/206 with at least one byte of body; anything else (4xx/5xx, timeout, reset,
     * empty body) drops that candidate. Never throws.
     *
     * If EVERY probe fails, returns [streams] unchanged: trying and failing loudly beats
     * telling the user there are no streams.
     */
    suspend fun probeStreams(streams: List<StreamOption>, limit: Int = 5): List<StreamOption>
}
