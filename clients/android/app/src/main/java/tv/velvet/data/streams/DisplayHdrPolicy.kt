package tv.velvet.data.streams

/** Capabilities of the connected screen, not the decoder in the streaming box. */
data class DisplayHdrPolicy(
    val dolbyVision: Boolean = false,
    val hdr10: Boolean = false,
    val hdr10Plus: Boolean = false,
    val hlg: Boolean = false,
) {
    /**
     * A filename is enough to exclude an unsupported format, never to prove that
     * Dolby Vision has an HDR10-compatible base layer. Profile 5 does not. Until
     * we inspect the actual profile, even a mixed DV/HDR label requires DV output.
     * HDR10+, on the other hand, is backward compatible with ordinary HDR10.
     */
    fun supportsRelease(title: String): Boolean = when (releaseRange(title)) {
        DynamicRange.DOLBY_VISION -> dolbyVision
        DynamicRange.HDR10_PLUS, DynamicRange.HDR10 -> hdr10 || hdr10Plus
        DynamicRange.HLG -> hlg
        DynamicRange.SDR_OR_UNKNOWN -> true
    }

    /** Actual container/codec metadata catches sources with missing release tags. */
    fun supportsVideo(sampleMimeType: String?, codecs: String?, pq: Boolean, hybridLogGamma: Boolean): Boolean = when {
        sampleMimeType.equals("video/dolby-vision", true) ||
            codecs.orEmpty().split(',').any { DOLBY_CODEC.containsMatchIn(it.trim()) } -> dolbyVision
        hybridLogGamma -> hlg
        pq -> hdr10 || hdr10Plus
        else -> true
    }

    companion object {
        private val DOLBY_CODEC = Regex("^(?:dvhe|dvh1|dvav|dva1)(?:\\.|$)", RegexOption.IGNORE_CASE)
        private val HLG = Regex("(?<![a-z0-9])hlg(?![a-z0-9])", RegexOption.IGNORE_CASE)

        fun releaseRange(title: String): DynamicRange {
            val hdr = StreamTags.parse(title).firstOrNull { it.kind == ReleaseTagKind.HDR }?.label
            return when (hdr) {
                "Dolby Vision" -> DynamicRange.DOLBY_VISION
                "HDR10+" -> DynamicRange.HDR10_PLUS
                "HDR10", "HDR" -> DynamicRange.HDR10
                else -> if (HLG.containsMatchIn(title)) DynamicRange.HLG else DynamicRange.SDR_OR_UNKNOWN
            }
        }
    }
}

enum class DynamicRange { SDR_OR_UNKNOWN, DOLBY_VISION, HDR10, HDR10_PLUS, HLG }
