//! Pure release-tag parser for the stream picker.
//!
//! This is the crate's complete, tested release-parsing library (a Rust port of
//! the app's StreamTags). The binary currently calls `quality`, `quality_rank`,
//! and `is_3d` for server-side stream ordering; the full `parse`/`ReleaseTag`
//! surface is retained for clients that want structured tags — hence the
//! module-level allow.
#![allow(dead_code)]
//
//! Release filenames (e.g. "Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.7.1.Atmos-GROUP")
//! are far too long for a picker tile: the details the viewer actually cares
//! about (Dolby Vision, Atmos, codec, resolution, REMUX…) fall off the end
//! behind the "…". [`parse`] turns such a string into a short, ordered,
//! de-duplicated set of pretty tags. The releaser/group is intentionally ignored.
//!
//! This is a faithful port of the Android app's
//! `tv.velvet.data.streams.StreamTags` (Kotlin) — same labels, same precedence,
//! same boundaries, same 3D detection. Zero dependencies: the Kotlin uses
//! boundary-aware regexes with lookaround (`(?<![a-z0-9])` / `(?![a-z0-9])`),
//! which the `regex` crate does not support, so the token/boundary matching is
//! hand-rolled here as ASCII case-insensitive substring scans that validate the
//! neighboring char themselves. All matching runs on the lower-cased string so
//! tokens inside words ("dd" in "reddit", "hdr" mid-word, "3d" in "3dfx") never
//! fire.
//!
//! A title with no recognizable tags returns an empty list — the caller then
//! falls back to a trimmed title.

/// The category a [`ReleaseTag`] belongs to. Emission order in [`parse`] follows
/// the declaration order used by the picker: 3D first, then resolution, HDR,
/// video codec, audio codec, audio channels, and finally editions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReleaseTagKind {
    ThreeD,
    Resolution,
    Hdr,
    VideoCodec,
    AudioCodec,
    AudioChannels,
    Edition,
}

/// A single pretty tag, e.g. `{ label: "Dolby Vision", kind: Hdr }`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseTag {
    pub label: String,
    pub kind: ReleaseTagKind,
}

// ---------------------------------------------------------------------------
// Hand-rolled boundary-aware token matcher (replaces regex lookaround).
// ---------------------------------------------------------------------------

/// Which characters are forbidden immediately before (left) or after (right) a
/// token for it to count as a match — the manual stand-in for the Kotlin
/// lookaround assertions.
#[derive(Clone, Copy)]
enum Boundary {
    /// `(?<![a-z0-9])` / `(?![a-z0-9])` — no ASCII alphanumeric neighbor.
    NoAlnum,
    /// `(?![a-z])` — no ASCII letter neighbor (digits are allowed, so a glued
    /// channel like `ddp5.1` / `aac2` still resolves the codec).
    NoAlpha,
    /// `(?<![0-9])` / `(?![0-9])` — no ASCII digit neighbor (used for channel
    /// tokens like `7.1` so `17.1` does not match).
    NoDigit,
}

/// One element of a token pattern. A pattern is a sequence of `Part`s; a token
/// is an alternation of such sequences plus left/right boundaries.
enum Part {
    /// A required literal, matched verbatim (ASCII, already lower-cased).
    Lit(&'static str),
    /// One of several required literals (regex `(?:a|b|c)`).
    OneOf(&'static [&'static str]),
    /// An optional single separator `[-. ]?`.
    OptSep,
    /// A required single separator `[-. ]`.
    Sep,
    /// An optional sub-sequence `(?:…)?`.
    Opt(&'static [Part]),
}

/// A boundary-bounded alternation of part-sequences — the Rust twin of one
/// Kotlin `Regex`.
struct Tok {
    left: Boundary,
    right: Boundary,
    alts: &'static [&'static [Part]],
}

const fn tok(left: Boundary, right: Boundary, alts: &'static [&'static [Part]]) -> Tok {
    Tok { left, right, alts }
}

#[inline]
fn is_alnum(b: u8) -> bool {
    b.is_ascii_lowercase() || b.is_ascii_digit()
}

#[inline]
fn is_sep(b: u8) -> bool {
    b == b'-' || b == b'.' || b == b' '
}

#[inline]
fn left_ok(bound: Boundary, s: &[u8], pos: usize) -> bool {
    if pos == 0 {
        return true;
    }
    let c = s[pos - 1];
    match bound {
        Boundary::NoAlnum => !is_alnum(c),
        Boundary::NoAlpha => !c.is_ascii_lowercase(),
        Boundary::NoDigit => !c.is_ascii_digit(),
    }
}

#[inline]
fn right_ok(bound: Boundary, s: &[u8], end: usize) -> bool {
    if end >= s.len() {
        return true;
    }
    let c = s[end];
    match bound {
        Boundary::NoAlnum => !is_alnum(c),
        Boundary::NoAlpha => !c.is_ascii_lowercase(),
        Boundary::NoDigit => !c.is_ascii_digit(),
    }
}

/// All positions reachable by consuming `part` at `pos`, appended to `out`.
fn advance_part(part: &Part, s: &[u8], pos: usize, out: &mut Vec<usize>) {
    match part {
        Part::Lit(t) => {
            let tb = t.as_bytes();
            if pos + tb.len() <= s.len() && &s[pos..pos + tb.len()] == tb {
                out.push(pos + tb.len());
            }
        }
        Part::OneOf(alts) => {
            for a in *alts {
                let ab = a.as_bytes();
                if pos + ab.len() <= s.len() && &s[pos..pos + ab.len()] == ab {
                    out.push(pos + ab.len());
                }
            }
        }
        Part::OptSep => {
            out.push(pos); // matched zero separators
            if pos < s.len() && is_sep(s[pos]) {
                out.push(pos + 1);
            }
        }
        Part::Sep => {
            if pos < s.len() && is_sep(s[pos]) {
                out.push(pos + 1);
            }
        }
        Part::Opt(sub) => {
            out.push(pos); // matched the empty option
            match_seq(sub, s, pos, out); // …or the whole sub-sequence
        }
    }
}

/// All end positions of matching the part-sequence `parts` starting at `pos`.
fn match_seq(parts: &[Part], s: &[u8], pos: usize, out: &mut Vec<usize>) {
    match parts.split_first() {
        None => out.push(pos),
        Some((first, rest)) => {
            let mut mids = Vec::new();
            advance_part(first, s, pos, &mut mids);
            for mid in mids {
                match_seq(rest, s, mid, out);
            }
        }
    }
}

/// True when `tok` matches anywhere in `s` — the twin of `Regex.containsMatchIn`.
fn contains(t: &Tok, s: &[u8]) -> bool {
    for pos in 0..s.len() {
        if !left_ok(t.left, s, pos) {
            continue;
        }
        for alt in t.alts {
            let mut ends = Vec::new();
            match_seq(alt, s, pos, &mut ends);
            for e in ends {
                if e > pos && right_ok(t.right, s, e) {
                    return true;
                }
            }
        }
    }
    false
}

// ---------------------------------------------------------------------------
// Token tables — a byte-for-byte mirror of StreamTags.kt.
// ---------------------------------------------------------------------------

// 3D / stereoscopic (side-by-side, over-under, generic 3D).
static THREE_D: Tok = tok(
    Boundary::NoAlnum,
    Boundary::NoAlnum,
    &[
        &[Part::Lit("3d")],
        &[Part::Lit("3dbd")],
        &[Part::Lit("bd3d")],
        &[Part::Opt(&[Part::Lit("h")]), Part::Lit("sbs")], // h?sbs
        &[Part::Lit("fsbs")],
        &[Part::Lit("hou")],
        &[Part::Lit("over"), Part::OptSep, Part::Lit("under")],
    ],
);

// RESOLUTION (one, top priority first).
static RESOLUTION: [(&str, Tok); 4] = [
    (
        "4K",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[&[Part::Lit("2160p")], &[Part::Lit("4k")], &[Part::Lit("uhd")]],
        ),
    ),
    (
        "1080p",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[&[Part::Lit("1080p")], &[Part::Lit("fhd")]],
        ),
    ),
    (
        "720p",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("720p")]]),
    ),
    (
        "480p",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("480p")]]),
    ),
];

// HDR (one, best-first; SDR only as an explicit last resort).
static HDR: [(&str, Tok); 5] = [
    (
        "Dolby Vision",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[
                &[Part::Lit("dolby"), Part::OptSep, Part::Lit("vision")],
                &[Part::Lit("dovi")],
                &[Part::Lit("dvhe")],
                &[Part::Lit("dvh1")],
                &[Part::Lit("dv")],
            ],
        ),
    ),
    (
        "HDR10+",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[&[Part::Lit("hdr10"), Part::OneOf(&["+", "plus", "p"])]],
        ),
    ),
    (
        "HDR10",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("hdr10")]]),
    ),
    (
        "HDR",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("hdr")]]),
    ),
    (
        "SDR",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("sdr")]]),
    ),
];

// VIDEO_CODEC (one).
static VIDEO: [(&str, Tok); 4] = [
    (
        "HEVC",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[
                &[Part::Lit("x265")],
                &[Part::Lit("h"), Part::OptSep, Part::Lit("265")],
                &[Part::Lit("hevc")],
            ],
        ),
    ),
    (
        "H.264",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[
                &[Part::Lit("x264")],
                &[Part::Lit("h"), Part::OptSep, Part::Lit("264")],
                &[Part::Lit("avc")],
            ],
        ),
    ),
    (
        "AV1",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("av1")]]),
    ),
    (
        "VP9",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("vp9")]]),
    ),
];

// AUDIO_CODEC building blocks (one, richest match). Right side is NoAlpha for
// most so a glued channel resolves the codec; DTS-X keeps NoAlnum like Kotlin.
static AUDIO_TRUEHD: Tok = tok(
    Boundary::NoAlnum,
    Boundary::NoAlpha,
    &[&[Part::Lit("true"), Part::OptSep, Part::Lit("hd")]],
);
static AUDIO_ATMOS: Tok = tok(Boundary::NoAlnum, Boundary::NoAlpha, &[&[Part::Lit("atmos")]]);
static AUDIO_DTSX: Tok = tok(
    Boundary::NoAlnum,
    Boundary::NoAlnum,
    &[&[Part::Lit("dts"), Part::OptSep, Part::Lit("x")]],
);
static AUDIO_DTSHD: Tok = tok(
    Boundary::NoAlnum,
    Boundary::NoAlpha,
    &[&[Part::Lit("dts"), Part::OptSep, Part::Lit("hd")]],
);
static AUDIO_DTS: Tok = tok(Boundary::NoAlnum, Boundary::NoAlpha, &[&[Part::Lit("dts")]]);
static AUDIO_DDP: Tok = tok(
    Boundary::NoAlnum,
    Boundary::NoAlpha,
    &[
        &[Part::Lit("ddp")],
        &[
            Part::Lit("e"),
            Part::OptSep,
            Part::Lit("ac"),
            Part::OptSep,
            Part::Lit("3"),
        ],
        &[Part::Lit("dd+")],
    ],
);
static AUDIO_DD: Tok = tok(
    Boundary::NoAlnum,
    Boundary::NoAlpha,
    &[
        &[Part::Lit("ac"), Part::OptSep, Part::Lit("3")],
        &[Part::Lit("dd")],
        &[Part::Lit("dolby"), Part::OptSep, Part::Lit("digital")],
    ],
);
static AUDIO_AAC: Tok = tok(Boundary::NoAlnum, Boundary::NoAlpha, &[&[Part::Lit("aac")]]);
static AUDIO_FLAC: Tok = tok(Boundary::NoAlnum, Boundary::NoAlpha, &[&[Part::Lit("flac")]]);
static AUDIO_OPUS: Tok = tok(Boundary::NoAlnum, Boundary::NoAlpha, &[&[Part::Lit("opus")]]);

// AUDIO_CHANNELS (one, optional).
static CH_71: Tok = tok(Boundary::NoDigit, Boundary::NoDigit, &[&[Part::Lit("7.1")]]);
static CH_51: Tok = tok(Boundary::NoDigit, Boundary::NoDigit, &[&[Part::Lit("5.1")]]);
static CH_20: Tok = tok(Boundary::NoDigit, Boundary::NoDigit, &[&[Part::Lit("2.0")]]);
static CH_STEREO: Tok = tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("stereo")]]);

// EDITION (multiple, emitted in this fixed order).
static EDITION: [(&str, Tok); 7] = [
    (
        "REMUX",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("remux")]]),
    ),
    (
        "PROPER",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("proper")]]),
    ),
    (
        "REPACK",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("repack")]]),
    ),
    (
        "EXTENDED",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[&[
                Part::Lit("extended"),
                Part::Opt(&[Part::OptSep, Part::Lit("cut")]),
            ]],
        ),
    ),
    (
        "DIRECTOR'S CUT",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[&[
                Part::Lit("director"),
                Part::Opt(&[Part::Opt(&[Part::Lit("'")]), Part::Lit("s")]),
                Part::OptSep,
                Part::Lit("cut"),
            ]],
        ),
    ),
    (
        "IMAX",
        tok(Boundary::NoAlnum, Boundary::NoAlnum, &[&[Part::Lit("imax")]]),
    ),
    (
        "10-bit",
        tok(
            Boundary::NoAlnum,
            Boundary::NoAlnum,
            &[
                &[Part::Lit("10bit")],
                &[Part::Lit("10"), Part::Sep, Part::Lit("bit")],
                &[Part::Lit("hi10"), Part::Opt(&[Part::Lit("p")])],
            ],
        ),
    ),
];

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

/// Parse a release title into ordered, de-duplicated pretty tags.
///
/// The 3D chip leads (it is a warning — a half-SBS file ruins the watch), then
/// resolution, HDR, video codec, audio codec, audio channels, and finally any
/// editions in their fixed order.
pub fn parse(title: &str) -> Vec<ReleaseTag> {
    let lowered = title.to_lowercase();
    let s = lowered.as_bytes();
    let mut out: Vec<ReleaseTag> = Vec::with_capacity(8);

    if contains(&THREE_D, s) {
        out.push(mk("3D", ReleaseTagKind::ThreeD));
    }
    if let Some(l) = first_match(&RESOLUTION, s) {
        out.push(mk(l, ReleaseTagKind::Resolution));
    }
    if let Some(l) = first_match(&HDR, s) {
        out.push(mk(l, ReleaseTagKind::Hdr));
    }
    if let Some(l) = first_match(&VIDEO, s) {
        out.push(mk(l, ReleaseTagKind::VideoCodec));
    }
    if let Some(l) = audio_label(s) {
        out.push(mk(l, ReleaseTagKind::AudioCodec));
    }
    if let Some(l) = channel_label(s) {
        out.push(mk(l, ReleaseTagKind::AudioChannels));
    }
    for (label, t) in EDITION.iter() {
        if contains(t, s) {
            out.push(mk(label, ReleaseTagKind::Edition));
        }
    }
    out
}

/// True when the release is stereoscopic 3D (SBS/OU/generic 3D) — demoted in
/// ranking. Mirrors `StreamTags.is3D`.
pub fn is_3d(title: &str) -> bool {
    let lowered = title.to_lowercase();
    contains(&THREE_D, lowered.as_bytes())
}

/// The single best resolution label, or `None` — the same matching the picker
/// uses for its "4K"/"1080p"/… quality badge.
pub fn quality(title: &str) -> Option<&'static str> {
    let lowered = title.to_lowercase();
    first_match(&RESOLUTION, lowered.as_bytes())
}

/// Numeric quality rank for sorting (higher = better): 4K=4, 1080p=3, 720p=2,
/// 480p=1, unknown=0.
pub fn quality_rank(title: &str) -> u8 {
    match quality(title) {
        Some("4K") => 4,
        Some("1080p") => 3,
        Some("720p") => 2,
        Some("480p") => 1,
        _ => 0,
    }
}

/// Dynamic-range rank (higher = better): Dolby Vision=3, HDR10+=2,
/// HDR10/HDR=1, SDR/none=0. DV wins the label when both DV and HDR10 are in
/// the title (best-first match), which is the right rank too — DV carries an
/// HDR10 base layer.
pub fn hdr_rank(title: &str) -> u8 {
    let lowered = title.to_lowercase();
    match first_match(&HDR, lowered.as_bytes()) {
        Some("Dolby Vision") => 3,
        Some("HDR10+") => 2,
        Some("HDR10") | Some("HDR") => 1,
        _ => 0,
    }
}

/// Audio rank (higher = better). Lossless object audio at the top, lossy
/// stereo-era codecs at the bottom:
/// TrueHD Atmos=7 > DTS-X=6 > TrueHD=5 > DTS-HD MA=4 > Atmos(EAC3)=3 >
/// DTS=2 > DD+/DD=1 > AAC/FLAC/OPUS/unknown=0.
pub fn audio_rank(title: &str) -> u8 {
    let lowered = title.to_lowercase();
    match audio_label(lowered.as_bytes()) {
        Some("TrueHD Atmos") => 7,
        Some("DTS-X") => 6,
        Some("TrueHD") => 5,
        Some("DTS-HD MA") => 4,
        Some("Atmos") => 3,
        Some("DTS") => 2,
        Some("DD+") | Some("DD") => 1,
        _ => 0,
    }
}

/// Untouched-disc releases (remux) beat re-encodes at equal resolution.
pub fn is_remux(title: &str) -> bool {
    let lowered = title.to_lowercase();
    contains(&EDITION[0].1, lowered.as_bytes())
}

/// THE stream ordering — best playable quality first:
/// 2D > 3D, then resolution, remux, dynamic range (DoVi > HDR10+ > HDR10/HDR),
/// audio (TrueHD Atmos > DTS-X > TrueHD > DTS-HD MA > …), then size.
/// Shared by the resolver endpoint and the pre-warm engine so they always agree.
pub fn cmp_streams(a_title: &str, a_size: u64, b_title: &str, b_size: u64) -> std::cmp::Ordering {
    is_3d(a_title)
        .cmp(&is_3d(b_title))
        .then(quality_rank(b_title).cmp(&quality_rank(a_title)))
        .then(is_remux(b_title).cmp(&is_remux(a_title)))
        .then(hdr_rank(b_title).cmp(&hdr_rank(a_title)))
        .then(audio_rank(b_title).cmp(&audio_rank(a_title)))
        .then(b_size.cmp(&a_size))
}

// ---------------------------------------------------------------------------
// Internals.
// ---------------------------------------------------------------------------

fn mk(label: &str, kind: ReleaseTagKind) -> ReleaseTag {
    ReleaseTag {
        label: label.to_string(),
        kind,
    }
}

fn first_match(pairs: &[(&'static str, Tok)], s: &[u8]) -> Option<&'static str> {
    for (label, t) in pairs {
        if contains(t, s) {
            return Some(label);
        }
    }
    None
}

fn audio_label(s: &[u8]) -> Option<&'static str> {
    let true_hd = contains(&AUDIO_TRUEHD, s);
    let atmos = contains(&AUDIO_ATMOS, s);
    if true_hd && atmos {
        return Some("TrueHD Atmos");
    }
    if true_hd {
        return Some("TrueHD");
    }
    if atmos {
        return Some("Atmos");
    }
    if contains(&AUDIO_DTSX, s) {
        return Some("DTS-X");
    }
    if contains(&AUDIO_DTSHD, s) {
        return Some("DTS-HD MA");
    }
    if contains(&AUDIO_DTS, s) {
        return Some("DTS");
    }
    if contains(&AUDIO_DDP, s) {
        return Some("DD+");
    }
    if contains(&AUDIO_DD, s) {
        return Some("DD");
    }
    if contains(&AUDIO_AAC, s) {
        return Some("AAC");
    }
    if contains(&AUDIO_FLAC, s) {
        return Some("FLAC");
    }
    if contains(&AUDIO_OPUS, s) {
        return Some("OPUS");
    }
    None
}

fn channel_label(s: &[u8]) -> Option<&'static str> {
    if contains(&CH_71, s) {
        return Some("7.1");
    }
    if contains(&CH_51, s) {
        return Some("5.1");
    }
    if contains(&CH_20, s) || contains(&CH_STEREO, s) {
        return Some("2.0");
    }
    None
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(title: &str) -> Vec<String> {
        parse(title).into_iter().map(|t| t.label).collect()
    }

    fn has(title: &str, label: &str) -> bool {
        labels(title).iter().any(|l| l == label)
    }

    #[test]
    fn inception_full_uhd_remux() {
        let t = "Inception.2010.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.7.1.Atmos-GROUP";
        assert_eq!(
            labels(t),
            vec!["4K", "Dolby Vision", "HEVC", "TrueHD Atmos", "7.1", "REMUX"]
        );
        assert!(!is_3d(t));
        assert_eq!(quality(t), Some("4K"));
    }

    #[test]
    fn tangled_half_sbs_is_3d() {
        let t = "Tangled.2010.3D.Half-SBS.1080p.HebDub-SBS";
        assert!(is_3d(t));
        let l = labels(t);
        assert_eq!(l.first().map(String::as_str), Some("3D"));
        assert!(l.contains(&"1080p".to_string()));
    }

    #[test]
    fn cloudy_dtshd() {
        let t = "Cloudy.with.a.Chance.of.Meatballs.2.2013.BluRay.x264.DTS-HD.MA.5.1";
        assert!(!is_3d(t));
        assert!(has(t, "DTS-HD MA"));
        assert!(has(t, "5.1"));
        assert!(has(t, "H.264"));
        assert_eq!(quality(t), None);
    }

    #[test]
    fn plain_web_dl() {
        let t = "Some.Movie.720p.WEB-DL.AAC";
        assert_eq!(labels(t), vec!["720p", "AAC"]);
        assert_eq!(quality(t), Some("720p"));
        assert!(!is_3d(t));
    }

    #[test]
    fn is_3d_positives() {
        assert!(is_3d("Movie.2020.1080p.SBS"));
        assert!(is_3d("Movie.HSBS.1080p"));
        assert!(is_3d("Movie.FSBS.1080p"));
        assert!(is_3d("Film.Over-Under.720p"));
        assert!(is_3d("Film.OverUnder.720p"));
        assert!(is_3d("Film.Over.Under.720p"));
        assert!(is_3d("Film.HOU.720p"));
        assert!(is_3d("Movie.BD3D.1080p"));
        assert!(is_3d("Movie.3DBD.1080p"));
        assert!(is_3d("Some.Movie.3D.2019.1080p"));
    }

    #[test]
    fn is_3d_no_false_positives_midword() {
        // "3d" glued to alphanumerics on either side must not fire.
        assert!(!is_3d("3dfx.Voodoo.1998.1080p")); // 3d followed by 'f'
        assert!(!is_3d("wd3drive.2020.1080p")); // 3d surrounded by letters
        // "hou" inside a word.
        assert!(!is_3d("Grindhouse.2007.1080p.BluRay"));
        assert!(!is_3d("Thousand.Suns.2019.720p"));
        // "sbs" mid-word.
        assert!(!is_3d("absbsc.2020.1080p"));
        assert!(!is_3d("Newsboys.Documentary.720p")); // no "sbs" substring, sanity
        // "over"/"under" only counts as the joined stereoscopic token.
        assert!(!is_3d("Discover.the.World.2021.1080p"));
        assert!(!is_3d("Underworld.2003.1080p.BluRay"));
        assert!(!is_3d("Nothing.To.See.Here.720p"));
    }

    #[test]
    fn resolution_precedence_and_quality() {
        assert_eq!(quality("Movie.2160p.BluRay"), Some("4K"));
        assert_eq!(quality("Movie.UHD.BluRay"), Some("4K"));
        assert_eq!(quality("Movie.4K.WEB"), Some("4K"));
        assert_eq!(quality("Movie.1080p.WEB"), Some("1080p"));
        assert_eq!(quality("Movie.FHD.WEB"), Some("1080p"));
        assert_eq!(quality("Movie.720p.WEB"), Some("720p"));
        assert_eq!(quality("Movie.480p.WEB"), Some("480p"));
        assert_eq!(quality("Movie.Without.Resolution"), None);
        // 4K wins over 1080p when both are present.
        assert_eq!(quality("Movie.2160p.upscaled.from.1080p"), Some("4K"));
    }

    #[test]
    fn best_quality_wins_the_sort() {
        // The exact complaint the hierarchy fixes: a BIGGER plain-HDR10 encode
        // must NOT outrank a DoVi TrueHD Atmos remux, and remux beats encode.
        let dovi_remux = "Movie.2026.2160p.UHD.BluRay.REMUX.DV.HDR10.TrueHD.Atmos.7.1-FraMeSToR";
        let big_hdr10 = "Movie.2026.2160p.WEB-DL.HDR10.DDP5.1.HEVC-BLOAT";
        let dtshd_enc = "Movie.2026.2160p.BluRay.HDR10.DTS-HD.MA.5.1.x265-GRP";
        let full_hd = "Movie.2026.1080p.BluRay.REMUX.TrueHD.Atmos-GRP";
        let mut v = [
            (big_hdr10, 90_000_000_000u64),
            (full_hd, 30_000_000_000),
            (dovi_remux, 60_000_000_000),
            (dtshd_enc, 70_000_000_000),
        ];
        v.sort_by(|a, b| cmp_streams(a.0, a.1, b.0, b.1));
        assert_eq!(v[0].0, dovi_remux); // remux + DV + TrueHD Atmos wins outright
        assert_eq!(v[1].0, dtshd_enc);  // then better audio among 4K encodes
        assert_eq!(v[2].0, big_hdr10);  // sheer size no longer buys the top slot
        assert_eq!(v[3].0, full_hd);    // resolution still trumps everything below 4K
        // And 3D always sinks.
        let mut w = [("Movie.2160p.3D.SBS.TrueHD-X", 80u64), ("Movie.1080p.WEB.AAC-Y", 2)];
        w.sort_by(|a, b| cmp_streams(a.0, a.1, b.0, b.1));
        assert_eq!(w[0].0, "Movie.1080p.WEB.AAC-Y");
    }

    #[test]
    fn hdr_precedence() {
        // Dolby Vision leads even when HDR10 is also present.
        assert!(has("Movie.2160p.DV.HDR10.HEVC", "Dolby Vision"));
        assert!(has("Movie.2160p.DoVi.HEVC", "Dolby Vision"));
        assert!(has("Movie.2160p.Dolby.Vision.HEVC", "Dolby Vision"));
        assert!(has("Movie.2160p.HDR10Plus.HEVC", "HDR10+"));
        assert!(has("Movie.2160p.HDR10+.HEVC", "HDR10+"));
        assert!(has("Movie.2160p.HDR10.HEVC", "HDR10"));
        assert!(has("Movie.2160p.HDR.HEVC", "HDR"));
        assert!(has("Movie.2160p.SDR.HEVC", "SDR"));
        // "dv" must not fire inside "dvd".
        assert!(!has("Movie.DVDRip.XviD", "Dolby Vision"));
    }

    #[test]
    fn video_codecs() {
        assert!(has("Movie.1080p.x265", "HEVC"));
        assert!(has("Movie.1080p.H.265", "HEVC"));
        assert!(has("Movie.1080p.H265", "HEVC"));
        assert!(has("Movie.1080p.HEVC", "HEVC"));
        assert!(has("Movie.1080p.x264", "H.264"));
        assert!(has("Movie.1080p.H.264", "H.264"));
        assert!(has("Movie.1080p.AVC", "H.264"));
        assert!(has("Movie.1080p.AV1", "AV1"));
        assert!(has("Movie.1080p.VP9", "VP9"));
    }

    #[test]
    fn audio_codecs() {
        assert!(has("Movie.1080p.TrueHD.7.1", "TrueHD"));
        assert!(has("Movie.1080p.Atmos", "Atmos"));
        assert!(has("Movie.1080p.TrueHD.Atmos", "TrueHD Atmos"));
        assert!(has("Movie.1080p.DTS-X.7.1", "DTS-X"));
        assert!(has("Movie.1080p.DTS-HD.MA.5.1", "DTS-HD MA"));
        assert!(has("Movie.1080p.DTS.5.1", "DTS"));
        assert!(has("Movie.1080p.DDP5.1", "DD+"));
        assert!(has("Movie.1080p.E-AC-3", "DD+"));
        assert!(has("Movie.1080p.EAC3", "DD+"));
        assert!(has("Movie.1080p.AC3.2.0", "DD"));
        assert!(has("Movie.1080p.DD5.1", "DD"));
        assert!(has("Movie.1080p.AAC", "AAC"));
        assert!(has("Movie.1080p.FLAC", "FLAC"));
        assert!(has("Movie.1080p.Opus", "OPUS"));
        // "dd" inside a word must not resolve a codec.
        assert!(!has("Reddit.Rip.1080p.x264", "DD"));
    }

    #[test]
    fn audio_channels() {
        assert!(has("Movie.1080p.TrueHD.7.1", "7.1"));
        assert!(has("Movie.1080p.DTS.5.1", "5.1"));
        assert!(has("Movie.1080p.AAC.2.0", "2.0"));
        assert!(has("Movie.1080p.FLAC.Stereo", "2.0"));
        // A digit-glued number must not read as a channel layout.
        assert!(!has("Movie.Part.17.1.1080p", "7.1"));
    }

    #[test]
    fn editions_fixed_order() {
        let t = "Movie.2010.REPACK.PROPER.BluRay.REMUX.1080p";
        let l = labels(t);
        let editions: Vec<&String> = l
            .iter()
            .filter(|x| ["REMUX", "PROPER", "REPACK"].contains(&x.as_str()))
            .collect();
        assert_eq!(
            editions,
            vec![
                &"REMUX".to_string(),
                &"PROPER".to_string(),
                &"REPACK".to_string()
            ]
        );
    }

    #[test]
    fn editions_variants() {
        assert!(has("Movie.2010.Extended.1080p", "EXTENDED"));
        assert!(has("Movie.2010.Extended.Cut.1080p", "EXTENDED"));
        assert!(has("Movie.2010.Directors.Cut.1080p", "DIRECTOR'S CUT"));
        assert!(has("Movie.2010.Director's.Cut.1080p", "DIRECTOR'S CUT"));
        assert!(has("Movie.2010.Director.Cut.1080p", "DIRECTOR'S CUT"));
        assert!(has("Movie.2010.IMAX.1080p", "IMAX"));
        assert!(has("Movie.1080p.x264.10bit", "10-bit"));
        assert!(has("Movie.1080p.x264.10-bit", "10-bit"));
        assert!(has("Movie.720p.Hi10P", "10-bit"));
    }

    #[test]
    fn empty_when_nothing_recognized() {
        assert!(parse("Just.A.Plain.Movie.Title.2020").is_empty());
        assert!(!is_3d("Just.A.Plain.Movie.Title.2020"));
        assert_eq!(quality("Just.A.Plain.Movie.Title.2020"), None);
    }
}
