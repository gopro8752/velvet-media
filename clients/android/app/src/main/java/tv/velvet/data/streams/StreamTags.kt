package tv.velvet.data.streams

/**
 * Pure release-tag parser for the stream picker.
 *
 * Release filenames (e.g. "Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.7.1.Atmos-GROUP")
 * are far too long for a picker tile: the details the viewer actually cares about
 * (Dolby Vision, Atmos, codec, resolution, REMUX…) fall off the end behind the "…".
 * [parse] turns such a string into a short, ordered, de-duplicated set of pretty
 * tags so the tile can show those instead of the raw title. The releaser/group is
 * intentionally ignored.
 *
 * Zero dependencies, no allocation beyond the result list, deterministic, and a
 * byte-for-byte semantic twin of the iOS `StreamTags.swift` AND of velvet-backend's
 * `release.rs` (which was ported FROM this file — the rank helpers below mirror its
 * release::hdr_rank / audio_rank / is_remux exactly, so the backend's pre-warm and
 * this app's sort always agree on "best"). All matching is done
 * on the lower-cased string with boundary-aware regexes so tokens inside words
 * ("dd" in "reddit", "dts" in a random string, "hdr" mid-word) never fire.
 *
 * A title with no recognizable tags returns an empty list — the caller then falls
 * back to a trimmed title.
 */
enum class ReleaseTagKind {
    THREE_D,
    RESOLUTION,
    HDR,
    VIDEO_CODEC,
    AUDIO_CODEC,
    AUDIO_CHANNELS,
    EDITION,
}

data class ReleaseTag(val label: String, val kind: ReleaseTagKind)

object StreamTags {

    // Left boundary  = no alphanumeric before  -> (?<![a-z0-9])
    // Right boundary = no alphanumeric after   -> (?![a-z0-9])
    // For audio codecs the right side is only "no letter after" (?![a-z]) so a
    // glued channel like ddp5.1 / aac2 / dts5 still resolves the codec.

    // ---- 3D / stereoscopic (side-by-side, over-under, generic 3D) ----
    // A half-SBS/OU file plays as two half-width images side by side on a 2D screen,
    // so it is almost never what you want. The "3D" token catches the vast majority
    // (releases nearly always say "3D"); sbs/hsbs/ou/over-under back it up for the odd
    // one that only names the packing. "3dbd"/"bd3d" are their own tokens because the
    // bare "3d" match needs a non-alphanumeric boundary on both sides.
    private val THREE_D =
        Regex("""(?<![a-z0-9])(?:3d|3dbd|bd3d|h?sbs|fsbs|hou|over[\-. ]?under)(?![a-z0-9])""")

    // ---- RESOLUTION (one, top priority first) ----
    private val RESOLUTION: List<Pair<String, Regex>> = listOf(
        "4K" to Regex("""(?<![a-z0-9])(?:2160p|4k|uhd)(?![a-z0-9])"""),
        "1080p" to Regex("""(?<![a-z0-9])(?:1080p|fhd)(?![a-z0-9])"""),
        "720p" to Regex("""(?<![a-z0-9])720p(?![a-z0-9])"""),
        "480p" to Regex("""(?<![a-z0-9])480p(?![a-z0-9])"""),
    )

    // ---- HDR (one, best-first; SDR only as an explicit last resort) ----
    private val HDR: List<Pair<String, Regex>> = listOf(
        "Dolby Vision" to Regex("""(?<![a-z0-9])(?:dolby[\-. ]?vision|dovi|dvhe|dvh1|dv)(?![a-z0-9])"""),
        "HDR10+" to Regex("""(?<![a-z0-9])hdr10(?:\+|plus|p)(?![a-z0-9])"""),
        "HDR10" to Regex("""(?<![a-z0-9])hdr10(?![a-z0-9])"""),
        "HDR" to Regex("""(?<![a-z0-9])hdr(?![a-z0-9])"""),
        "SDR" to Regex("""(?<![a-z0-9])sdr(?![a-z0-9])"""),
    )

    // ---- VIDEO_CODEC (one) ----
    private val VIDEO: List<Pair<String, Regex>> = listOf(
        "HEVC" to Regex("""(?<![a-z0-9])(?:x265|h[\-. ]?265|hevc)(?![a-z0-9])"""),
        "H.264" to Regex("""(?<![a-z0-9])(?:x264|h[\-. ]?264|avc)(?![a-z0-9])"""),
        "AV1" to Regex("""(?<![a-z0-9])av1(?![a-z0-9])"""),
        "VP9" to Regex("""(?<![a-z0-9])vp9(?![a-z0-9])"""),
    )

    // ---- AUDIO_CODEC (one, richest match) ----
    private val AUDIO_TRUEHD = Regex("""(?<![a-z0-9])true[\-. ]?hd(?![a-z])""")
    private val AUDIO_ATMOS = Regex("""(?<![a-z0-9])atmos(?![a-z])""")
    private val AUDIO_DTSX = Regex("""(?<![a-z0-9])dts[\-. ]?x(?![a-z0-9])""")
    private val AUDIO_DTSHD = Regex("""(?<![a-z0-9])dts[\-. ]?hd(?![a-z])""")
    private val AUDIO_DTS = Regex("""(?<![a-z0-9])dts(?![a-z])""")
    private val AUDIO_DDP = Regex("""(?<![a-z0-9])(?:ddp|e[\-. ]?ac[\-. ]?3|dd\+)(?![a-z])""")
    private val AUDIO_DD = Regex("""(?<![a-z0-9])(?:ac[\-. ]?3|dd|dolby[\-. ]?digital)(?![a-z])""")
    private val AUDIO_AAC = Regex("""(?<![a-z0-9])aac(?![a-z])""")
    private val AUDIO_FLAC = Regex("""(?<![a-z0-9])flac(?![a-z])""")
    private val AUDIO_OPUS = Regex("""(?<![a-z0-9])opus(?![a-z])""")

    // ---- AUDIO_CHANNELS (one, optional) ----
    private val CH_71 = Regex("""(?<![0-9])7\.1(?![0-9])""")
    private val CH_51 = Regex("""(?<![0-9])5\.1(?![0-9])""")
    private val CH_20 = Regex("""(?<![0-9])2\.0(?![0-9])""")
    private val CH_STEREO = Regex("""(?<![a-z0-9])stereo(?![a-z0-9])""")

    // ---- EDITION (multiple, emitted in this fixed order) ----
    // REMUX gets its own named regex: [isRemux] ranks on it, not just the tag chip.
    private val REMUX = Regex("""(?<![a-z0-9])remux(?![a-z0-9])""")
    private val EDITION: List<Pair<String, Regex>> = listOf(
        "REMUX" to REMUX,
        "PROPER" to Regex("""(?<![a-z0-9])proper(?![a-z0-9])"""),
        "REPACK" to Regex("""(?<![a-z0-9])repack(?![a-z0-9])"""),
        "EXTENDED" to Regex("""(?<![a-z0-9])extended(?:[\-. ]?cut)?(?![a-z0-9])"""),
        "DIRECTOR'S CUT" to Regex("""(?<![a-z0-9])director(?:'?s)?[\-. ]?cut(?![a-z0-9])"""),
        "IMAX" to Regex("""(?<![a-z0-9])imax(?![a-z0-9])"""),
        "10-bit" to Regex("""(?<![a-z0-9])(?:10bit|10[\-. ]bit|hi10p?)(?![a-z0-9])"""),
    )

    /** Parse a release title into ordered, de-duplicated pretty tags. */
    fun parse(text: String): List<ReleaseTag> {
        val s = text.lowercase()
        val out = ArrayList<ReleaseTag>(8)

        // 3D leads: it's a warning chip, and the one detail that ruins the watch.
        if (THREE_D.containsMatchIn(s)) out += ReleaseTag("3D", ReleaseTagKind.THREE_D)
        firstMatch(RESOLUTION, s)?.let { out += ReleaseTag(it, ReleaseTagKind.RESOLUTION) }
        firstMatch(HDR, s)?.let { out += ReleaseTag(it, ReleaseTagKind.HDR) }
        firstMatch(VIDEO, s)?.let { out += ReleaseTag(it, ReleaseTagKind.VIDEO_CODEC) }
        audioLabel(s)?.let { out += ReleaseTag(it, ReleaseTagKind.AUDIO_CODEC) }
        channelLabel(s)?.let { out += ReleaseTag(it, ReleaseTagKind.AUDIO_CHANNELS) }
        for ((label, re) in EDITION) {
            if (re.containsMatchIn(s)) out += ReleaseTag(label, ReleaseTagKind.EDITION)
        }
        return out
    }

    /** True when the release is stereoscopic 3D (SBS/OU/generic 3D) — demoted in ranking. */
    fun is3D(text: String): Boolean = THREE_D.containsMatchIn(text.lowercase())

    // ---- rank helpers for stream sorting (semantic twins of velvet-backend release.rs) ----

    /** Untouched-disc releases (remux) beat re-encodes at equal resolution. */
    fun isRemux(text: String): Boolean = REMUX.containsMatchIn(text.lowercase())

    /**
     * Dynamic-range rank (higher = better): Dolby Vision=3, HDR10+=2, HDR10/HDR=1,
     * SDR/none=0. DV wins the label when both DV and HDR10 are in the title
     * (best-first match), which is the right rank too — DV carries an HDR10 base layer.
     */
    fun hdrRank(text: String): Int = when (firstMatch(HDR, text.lowercase())) {
        "Dolby Vision" -> 3
        "HDR10+" -> 2
        "HDR10", "HDR" -> 1
        else -> 0 // SDR, or nothing recognizable
    }

    /**
     * Audio rank (higher = better). Lossless object audio at the top, lossy stereo-era
     * codecs at the bottom: TrueHD Atmos=7 > DTS-X=6 > TrueHD=5 > DTS-HD MA=4 >
     * Atmos(EAC3)=3 > DTS=2 > DD+/DD=1 > AAC/FLAC/OPUS/unknown=0. Ranks reuse
     * [audioLabel]'s exact output labels so the picker chip and the sort can never
     * disagree about what a release carries.
     */
    fun audioRank(text: String): Int = when (audioLabel(text.lowercase())) {
        "TrueHD Atmos" -> 7
        "DTS-X" -> 6
        "TrueHD" -> 5
        "DTS-HD MA" -> 4
        "Atmos" -> 3
        "DTS" -> 2
        "DD+", "DD" -> 1
        else -> 0
    }

    private fun firstMatch(pairs: List<Pair<String, Regex>>, s: String): String? {
        for ((label, re) in pairs) if (re.containsMatchIn(s)) return label
        return null
    }

    private fun audioLabel(s: String): String? {
        val trueHd = AUDIO_TRUEHD.containsMatchIn(s)
        val atmos = AUDIO_ATMOS.containsMatchIn(s)
        if (trueHd && atmos) return "TrueHD Atmos"
        if (trueHd) return "TrueHD"
        if (atmos) return "Atmos"
        if (AUDIO_DTSX.containsMatchIn(s)) return "DTS-X"
        if (AUDIO_DTSHD.containsMatchIn(s)) return "DTS-HD MA"
        if (AUDIO_DTS.containsMatchIn(s)) return "DTS"
        if (AUDIO_DDP.containsMatchIn(s)) return "DD+"
        if (AUDIO_DD.containsMatchIn(s)) return "DD"
        if (AUDIO_AAC.containsMatchIn(s)) return "AAC"
        if (AUDIO_FLAC.containsMatchIn(s)) return "FLAC"
        if (AUDIO_OPUS.containsMatchIn(s)) return "OPUS"
        return null
    }

    private fun channelLabel(s: String): String? {
        if (CH_71.containsMatchIn(s)) return "7.1"
        if (CH_51.containsMatchIn(s)) return "5.1"
        if (CH_20.containsMatchIn(s) || CH_STEREO.containsMatchIn(s)) return "2.0"
        return null
    }
}
