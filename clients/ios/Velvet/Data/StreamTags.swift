import Foundation

/// Pure release-tag parser for the stream picker — the byte-for-byte semantic
/// twin of the Android `StreamTags.kt`.
///
/// Release filenames (e.g.
/// "Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.7.1.Atmos-GROUP") are
/// far too long for a picker tile: the details the viewer cares about (Dolby
/// Vision, Atmos, codec, resolution, REMUX…) fall off the end behind the "…".
/// `parse` turns such a string into a short, ordered, de-duplicated set of pretty
/// tags. The releaser/group is intentionally ignored.
///
/// Foundation only. All matching is done on the lower-cased string with
/// boundary-aware regexes so tokens inside words ("dd" in "reddit", "dts" in a
/// random string, "hdr" mid-word) never fire. A title with no recognizable tags
/// returns an empty array — the caller then falls back to a trimmed title.

enum ReleaseTagKind {
    case resolution
    case hdr
    case videoCodec
    case audioCodec
    case audioChannels
    case edition
}

struct ReleaseTag: Hashable {
    let label: String
    let kind: ReleaseTagKind
}

enum StreamTags {

    // Left boundary  = no alphanumeric before  -> (?<![a-z0-9])
    // Right boundary = no alphanumeric after   -> (?![a-z0-9])
    // For audio codecs the right side is only "no letter after" (?![a-z]) so a
    // glued channel like ddp5.1 / aac2 / dts5 still resolves the codec.

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants validated by the parser's test
        // harness, so a failure here is a programmer error, not runtime input.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.firstMatch(in: s, options: [], range: range) != nil
    }

    // ---- 3D (sinks in ranking) ----
    // Word-boundary "3d" carries the load (releases nearly always say "3D");
    // sbs/hsbs/fsbs/hou/over-under back it up for the odd one that only names
    // the packing. "3dbd"/"bd3d" are their own tokens because the bare "3d"
    // match needs a non-alphanumeric boundary on BOTH sides. Same pattern as
    // the Android THREE_D and the Rust backend's release::THREE_D.
    private static let threeD = rx(#"(?<![a-z0-9])(?:3d|3dbd|bd3d|h?sbs|fsbs|hou|over[\-. ]?under)(?![a-z0-9])"#)

    // ---- RESOLUTION (one, top priority first) ----
    private static let resolution: [(String, NSRegularExpression)] = [
        ("4K", rx(#"(?<![a-z0-9])(?:2160p|4k|uhd)(?![a-z0-9])"#)),
        ("1080p", rx(#"(?<![a-z0-9])(?:1080p|fhd)(?![a-z0-9])"#)),
        ("720p", rx(#"(?<![a-z0-9])720p(?![a-z0-9])"#)),
        ("480p", rx(#"(?<![a-z0-9])480p(?![a-z0-9])"#)),
    ]

    // ---- HDR (one, best-first; SDR only as an explicit last resort) ----
    private static let hdr: [(String, NSRegularExpression)] = [
        ("Dolby Vision", rx(#"(?<![a-z0-9])(?:dolby[\-. ]?vision|dovi|dvhe|dvh1|dv)(?![a-z0-9])"#)),
        ("HDR10+", rx(#"(?<![a-z0-9])hdr10(?:\+|plus|p)(?![a-z0-9])"#)),
        ("HDR10", rx(#"(?<![a-z0-9])hdr10(?![a-z0-9])"#)),
        ("HDR", rx(#"(?<![a-z0-9])hdr(?![a-z0-9])"#)),
        ("SDR", rx(#"(?<![a-z0-9])sdr(?![a-z0-9])"#)),
    ]

    // ---- VIDEO_CODEC (one) ----
    private static let video: [(String, NSRegularExpression)] = [
        ("HEVC", rx(#"(?<![a-z0-9])(?:x265|h[\-. ]?265|hevc)(?![a-z0-9])"#)),
        ("H.264", rx(#"(?<![a-z0-9])(?:x264|h[\-. ]?264|avc)(?![a-z0-9])"#)),
        ("AV1", rx(#"(?<![a-z0-9])av1(?![a-z0-9])"#)),
        ("VP9", rx(#"(?<![a-z0-9])vp9(?![a-z0-9])"#)),
    ]

    // ---- AUDIO_CODEC (one, richest match) ----
    private static let audioTrueHD = rx(#"(?<![a-z0-9])true[\-. ]?hd(?![a-z])"#)
    private static let audioAtmos = rx(#"(?<![a-z0-9])atmos(?![a-z])"#)
    private static let audioDtsX = rx(#"(?<![a-z0-9])dts[\-. ]?x(?![a-z0-9])"#)
    private static let audioDtsHd = rx(#"(?<![a-z0-9])dts[\-. ]?hd(?![a-z])"#)
    private static let audioDts = rx(#"(?<![a-z0-9])dts(?![a-z])"#)
    private static let audioDdp = rx(#"(?<![a-z0-9])(?:ddp|e[\-. ]?ac[\-. ]?3|dd\+)(?![a-z])"#)
    private static let audioDd = rx(#"(?<![a-z0-9])(?:ac[\-. ]?3|dd|dolby[\-. ]?digital)(?![a-z])"#)
    private static let audioAac = rx(#"(?<![a-z0-9])aac(?![a-z])"#)
    private static let audioFlac = rx(#"(?<![a-z0-9])flac(?![a-z])"#)
    private static let audioOpus = rx(#"(?<![a-z0-9])opus(?![a-z])"#)

    // ---- AUDIO_CHANNELS (one, optional) ----
    private static let ch71 = rx(#"(?<![0-9])7\.1(?![0-9])"#)
    private static let ch51 = rx(#"(?<![0-9])5\.1(?![0-9])"#)
    private static let ch20 = rx(#"(?<![0-9])2\.0(?![0-9])"#)
    private static let chStereo = rx(#"(?<![a-z0-9])stereo(?![a-z0-9])"#)

    // ---- EDITION (multiple, emitted in this fixed order) ----
    // remux is a named constant because `isRemux` ranks on it too — the sort
    // and the "REMUX" chip must never drift apart on what counts as a remux.
    private static let remux = rx(#"(?<![a-z0-9])remux(?![a-z0-9])"#)
    private static let edition: [(String, NSRegularExpression)] = [
        ("REMUX", remux),
        ("PROPER", rx(#"(?<![a-z0-9])proper(?![a-z0-9])"#)),
        ("REPACK", rx(#"(?<![a-z0-9])repack(?![a-z0-9])"#)),
        ("EXTENDED", rx(#"(?<![a-z0-9])extended(?:[\-. ]?cut)?(?![a-z0-9])"#)),
        ("DIRECTOR'S CUT", rx(#"(?<![a-z0-9])director(?:'?s)?[\-. ]?cut(?![a-z0-9])"#)),
        ("IMAX", rx(#"(?<![a-z0-9])imax(?![a-z0-9])"#)),
        ("10-bit", rx(#"(?<![a-z0-9])(?:10bit|10[\-. ]bit|hi10p?)(?![a-z0-9])"#)),
    ]

    /// Parse a release title into ordered, de-duplicated pretty tags.
    static func parse(_ text: String) -> [ReleaseTag] {
        let s = text.lowercased()
        var out: [ReleaseTag] = []
        out.reserveCapacity(8)

        if let r = firstMatch(resolution, s) { out.append(ReleaseTag(label: r, kind: .resolution)) }
        if let h = firstMatch(hdr, s) { out.append(ReleaseTag(label: h, kind: .hdr)) }
        if let v = firstMatch(video, s) { out.append(ReleaseTag(label: v, kind: .videoCodec)) }
        if let a = audioLabel(s) { out.append(ReleaseTag(label: a, kind: .audioCodec)) }
        if let c = channelLabel(s) { out.append(ReleaseTag(label: c, kind: .audioChannels)) }
        for (label, re) in edition where has(re, s) {
            out.append(ReleaseTag(label: label, kind: .edition))
        }
        return out
    }

    // ---- ranking helpers (StreamClient.sortStreams — the byte-for-byte twin of
    // the backend's release::cmp_streams, so autopick agrees with the server's
    // pre-warm about which release is "best") ----

    /// True when the release is stereoscopic 3D (SBS/OU/generic 3D) — demoted
    /// below every 2D release in the sort: it's almost never wanted on a phone
    /// screen and only surfaces when nothing else exists.
    static func is3D(_ text: String) -> Bool {
        has(threeD, text.lowercased())
    }

    /// Untouched-disc releases (remux) beat re-encodes at equal resolution —
    /// the whole point of grabbing a 60 GB file over a 90 GB WEB-DL re-encode.
    static func isRemux(_ text: String) -> Bool {
        has(remux, text.lowercased())
    }

    /// Dynamic-range rank (higher = better): Dolby Vision=3, HDR10+=2,
    /// HDR10/HDR=1, SDR/none=0. DV wins the label when both DV and HDR10 are in
    /// the title (the `hdr` list is best-first), which is the right rank too —
    /// DV carries an HDR10 base layer.
    static func hdrRank(_ text: String) -> Int {
        switch firstMatch(hdr, text.lowercased()) {
        case "Dolby Vision": return 3
        case "HDR10+": return 2
        case "HDR10", "HDR": return 1
        default: return 0
        }
    }

    /// Audio rank (higher = better). Lossless object audio at the top, lossy
    /// stereo-era codecs at the bottom:
    /// TrueHD Atmos=7 > DTS-X=6 > TrueHD=5 > DTS-HD MA=4 > Atmos(EAC3)=3 >
    /// DTS=2 > DD+/DD=1 > AAC/FLAC/OPUS/unknown=0. Ranks over `audioLabel`'s
    /// exact spellings so a parser tweak can never silently strand the sort.
    static func audioRank(_ text: String) -> Int {
        switch audioLabel(text.lowercased()) {
        case "TrueHD Atmos": return 7
        case "DTS-X": return 6
        case "TrueHD": return 5
        case "DTS-HD MA": return 4
        case "Atmos": return 3
        case "DTS": return 2
        case "DD+", "DD": return 1
        default: return 0
        }
    }

    private static func firstMatch(_ pairs: [(String, NSRegularExpression)], _ s: String) -> String? {
        for (label, re) in pairs where has(re, s) { return label }
        return nil
    }

    private static func audioLabel(_ s: String) -> String? {
        let trueHd = has(audioTrueHD, s)
        let atmos = has(audioAtmos, s)
        if trueHd && atmos { return "TrueHD Atmos" }
        if trueHd { return "TrueHD" }
        if atmos { return "Atmos" }
        if has(audioDtsX, s) { return "DTS-X" }
        if has(audioDtsHd, s) { return "DTS-HD MA" }
        if has(audioDts, s) { return "DTS" }
        if has(audioDdp, s) { return "DD+" }
        if has(audioDd, s) { return "DD" }
        if has(audioAac, s) { return "AAC" }
        if has(audioFlac, s) { return "FLAC" }
        if has(audioOpus, s) { return "OPUS" }
        return nil
    }

    private static func channelLabel(_ s: String) -> String? {
        if has(ch71, s) { return "7.1" }
        if has(ch51, s) { return "5.1" }
        if has(ch20, s) || has(chStereo, s) { return "2.0" }
        return nil
    }
}
