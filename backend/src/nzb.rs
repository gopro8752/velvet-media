//! NZB parsing: an NZB is XML listing, per file, the usenet article segments
//! (message-id + encoded byte size + ordinal) that make it up. We turn that into
//! an ordered segment map so the stream server can locate which segments cover a
//! requested byte range and fetch only those — no whole-file grab.

use quick_xml::events::Event;
use quick_xml::Reader;

#[derive(Debug, Clone)]
pub struct Segment {
    pub number: u32,
    /// Encoded (on-the-wire) size in bytes — decoded size is ~2–3% smaller.
    /// Used to build the cumulative offset map for range → segment lookup.
    pub bytes: u64,
    /// Message-id WITHOUT angle brackets.
    pub message_id: String,
}

#[derive(Debug, Clone)]
pub struct NzbFile {
    pub subject: String,
    pub groups: Vec<String>,
    pub segments: Vec<Segment>,
    /// Sum of segment `bytes` (encoded). Cheap proxy for file size / "largest".
    pub total_bytes: u64,
}

impl NzbFile {
    /// Raw media must not be confused with a release's cover, notes or subtitles.
    /// Archive volumes are handled separately by the caller. Keep extensionless
    /// obfuscated payloads eligible instead of requiring a known video suffix.
    pub fn is_media_candidate(&self) -> bool {
        let s = self.subject.to_ascii_lowercase();
        let extension = posted_filename(&s).rsplit_once('.').map(|(_, suffix)| suffix);
        !(s.contains(".par2")
            || matches!(extension,
                Some("jpg" | "jpeg" | "png" | "gif" | "bmp" | "webp" | "avif"
                    | "heic" | "tif" | "tiff" | "ico"
                    | "nfo" | "txt" | "diz" | "rtf" | "pdf" | "htm" | "html" | "url"
                    | "sfv" | "md5" | "sha1" | "sha256" | "srr" | "nzb" | "torrent"
                    | "srt" | "sub" | "idx" | "ass" | "ssa" | "vtt" | "sup" | "smi"
                    | "ttf" | "otf"))
            || s.contains("sample")
            || self.is_archive())
    }

    /// A RAR/7z/zip archive volume: `.rar`, `.7z`, `.zip`, or a split volume
    /// (`.r00`–`.r99`, `.partNN.rar`, `.NNN`).
    pub fn is_archive(&self) -> bool {
        let s = self.subject.to_ascii_lowercase();
        if s.contains(".rar") || s.contains(".7z") || s.contains(".zip") {
            return true;
        }
        let b = s.as_bytes();
        for i in 0..b.len().saturating_sub(3) {
            // ".r00".. ".r99" split volumes
            if b[i] == b'.' && b[i + 1] == b'r' && b[i + 2].is_ascii_digit() && b[i + 3].is_ascii_digit() {
                return true;
            }
            // ".001".. numeric split volumes (e.g. 7z/zip multi-part)
            if b[i] == b'.' && b[i + 1] == b'0' && b[i + 2].is_ascii_digit() && b[i + 3].is_ascii_digit() {
                return true;
            }
        }
        false
    }
}

/// NZB subjects usually end with `"filename.ext" yEnc (part/total)` or the
/// unquoted equivalent. Inspect the actual suffix before posting metadata, not
/// a title prefix or a substring such as `.jpg` inside `Movie.jpg.mkv`.
fn posted_filename(subject: &str) -> &str {
    let marker = subject.match_indices("yenc").find(|(at, _)| {
        (*at == 0 || subject[..*at].chars().next_back().is_some_and(char::is_whitespace))
            && subject[at + 4..].chars().next().is_none_or(|c| c.is_whitespace() || c == '(')
    });
    let mut name = subject[..marker.map_or(subject.len(), |(at, _)| at)].trim();
    // Some indexers omit yEnc but retain the final part counter.
    if let Some((prefix, count)) = name.rsplit_once('(') {
        if count.strip_suffix(')').and_then(|value| value.split_once('/'))
            .is_some_and(|(part, total)| !part.is_empty() && !total.is_empty()
                && part.bytes().all(|b| b.is_ascii_digit())
                && total.bytes().all(|b| b.is_ascii_digit())) {
            name = prefix.trim_end();
        }
    }
    if let Some(quoted) = name.strip_suffix('"') {
        if let Some((_, filename)) = quoted.rsplit_once('"') {
            return filename;
        }
    }
    name
}

#[derive(Debug, Clone)]
pub struct Nzb {
    pub files: Vec<NzbFile>,
}

impl Nzb {
    /// The file we actually stream: the largest media candidate (movies/episodes
    /// are one big file; par2s and nfos are smaller and filtered out).
    pub fn primary_file(&self) -> Option<&NzbFile> {
        self.files
            .iter()
            .filter(|f| f.is_media_candidate() && !f.segments.is_empty())
            .max_by_key(|f| f.total_bytes)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum NzbError {
    #[error("xml parse error: {0}")]
    Xml(#[from] quick_xml::Error),
    #[error("nzb contained no files with segments")]
    Empty,
}

pub fn parse(xml: &[u8]) -> Result<Nzb, NzbError> {
    let mut reader = Reader::from_reader(xml);
    reader.config_mut().trim_text(true);

    let mut files = Vec::new();
    let mut cur_subject = String::new();
    let mut cur_groups: Vec<String> = Vec::new();
    let mut cur_segments: Vec<Segment> = Vec::new();
    let mut in_file = false;
    let mut seg_bytes = 0u64;
    let mut seg_number = 0u32;
    let mut text_target: Option<TextTarget> = None;
    let mut buf = Vec::new();

    enum TextTarget {
        Group,
        Segment,
    }

    loop {
        match reader.read_event_into(&mut buf)? {
            Event::Start(e) => match e.name().as_ref() {
                b"file" => {
                    in_file = true;
                    cur_subject.clear();
                    cur_groups.clear();
                    cur_segments.clear();
                    for attr in e.attributes().flatten() {
                        if attr.key.as_ref() == b"subject" {
                            cur_subject = attr.unescape_value().unwrap_or_default().into_owned();
                        }
                    }
                }
                b"group" => text_target = Some(TextTarget::Group),
                b"segment" if in_file => {
                    seg_bytes = 0;
                    seg_number = 0;
                    for attr in e.attributes().flatten() {
                        match attr.key.as_ref() {
                            b"bytes" => {
                                seg_bytes = attr
                                    .unescape_value()
                                    .unwrap_or_default()
                                    .parse()
                                    .unwrap_or(0);
                            }
                            b"number" => {
                                seg_number = attr
                                    .unescape_value()
                                    .unwrap_or_default()
                                    .parse()
                                    .unwrap_or(0);
                            }
                            _ => {}
                        }
                    }
                    text_target = Some(TextTarget::Segment);
                }
                _ => {}
            },
            Event::Text(e) => {
                let text = e.unescape().unwrap_or_default().into_owned();
                match text_target.take() {
                    Some(TextTarget::Group) => {
                        if !text.is_empty() {
                            cur_groups.push(text);
                        }
                    }
                    Some(TextTarget::Segment) => {
                        let id = text.trim().trim_start_matches('<').trim_end_matches('>');
                        if !id.is_empty() {
                            cur_segments.push(Segment {
                                number: seg_number,
                                bytes: seg_bytes,
                                message_id: id.to_string(),
                            });
                        }
                    }
                    None => {}
                }
            }
            Event::End(e) => {
                if e.name().as_ref() == b"file" && in_file {
                    in_file = false;
                    cur_segments.sort_by_key(|s| s.number);
                    let total = cur_segments.iter().map(|s| s.bytes).sum();
                    files.push(NzbFile {
                        subject: std::mem::take(&mut cur_subject),
                        groups: std::mem::take(&mut cur_groups),
                        segments: std::mem::take(&mut cur_segments),
                        total_bytes: total,
                    });
                }
            }
            Event::Eof => break,
            _ => {}
        }
        buf.clear();
    }

    if files.iter().all(|f| f.segments.is_empty()) {
        return Err(NzbError::Empty);
    }
    Ok(Nzb { files })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &[u8] = br#"<?xml version="1.0" encoding="UTF-8"?>
<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
  <file poster="x@y.com" date="1700000000" subject="[1/2] Movie.2024.1080p.mkv yEnc (1/3)">
    <groups><group>alt.binaries.movies</group></groups>
    <segments>
      <segment bytes="700000" number="1">abc-1@news</segment>
      <segment bytes="700000" number="3">abc-3@news</segment>
      <segment bytes="300000" number="2">&lt;abc-2@news&gt;</segment>
    </segments>
  </file>
  <file poster="x@y.com" date="1700000000" subject="[2/2] Movie.2024.1080p.par2 yEnc (1/1)">
    <groups><group>alt.binaries.movies</group></groups>
    <segments>
      <segment bytes="50000" number="1">par-1@news</segment>
    </segments>
  </file>
</nzb>"#;

    #[test]
    fn parses_files_and_orders_segments() {
        let nzb = parse(SAMPLE).unwrap();
        assert_eq!(nzb.files.len(), 2);
        let media = nzb.primary_file().unwrap();
        assert!(media.subject.contains(".mkv"));
        // Sorted by number, and the bracketed id is stripped.
        let nums: Vec<u32> = media.segments.iter().map(|s| s.number).collect();
        assert_eq!(nums, vec![1, 2, 3]);
        assert_eq!(media.segments[1].message_id, "abc-2@news");
        assert_eq!(media.total_bytes, 1_700_000);
        assert_eq!(media.groups, vec!["alt.binaries.movies"]);
    }

    #[test]
    fn par2_is_not_the_primary() {
        let nzb = parse(SAMPLE).unwrap();
        assert!(nzb.primary_file().unwrap().is_media_candidate());
        assert_eq!(nzb.files.iter().filter(|f| !f.is_media_candidate()).count(), 1);
    }

    #[test]
    fn archived_movie_with_cover_and_notes_has_no_raw_media() {
        let nzb = parse(br#"<nzb>
          <file subject="[1/4] &quot;Movie.part01.rar&quot; yEnc (1/100)">
            <segments><segment bytes="100000000" number="1">archive-1@fixture</segment></segments>
          </file>
          <file subject="[2/4] &quot;Movie.part02.rar&quot; yEnc (1/100)">
            <segments><segment bytes="100000000" number="1">archive-2@fixture</segment></segments>
          </file>
          <file subject="[3/4] &quot;Movie.jpg&quot; yEnc (1/1)">
            <segments><segment bytes="93712" number="1">cover@fixture</segment></segments>
          </file>
          <file subject="[4/4] &quot;Movie.nfo&quot; yEnc (1/1)">
            <segments><segment bytes="12000" number="1">notes@fixture</segment></segments>
          </file>
        </nzb>"#).unwrap();
        // The stream loader must take its archive branch instead of displaying
        // the cover for an instant and treating that as a completed movie.
        assert!(nzb.primary_file().is_none());
        assert_eq!(nzb.files.iter().filter(|file| file.is_archive()).count(), 2);
    }

    fn candidate(subject: &str, bytes: u64) -> NzbFile {
        NzbFile {
            subject: subject.into(), groups: vec![], total_bytes: bytes,
            segments: vec![Segment { number: 1, bytes, message_id: "file@fixture".into() }],
        }
    }

    #[test]
    fn raw_movie_is_selected_even_when_sidecars_are_larger() {
        let nzb = Nzb { files: vec![
            candidate("[1/3] Movie.mkv yEnc (1/50)", 500),
            candidate("[2/3] Movie.PNG yEnc (1/1)", 1000),
            candidate("[3/3] Movie.en.srt yEnc (1/1)", 2000),
        ] };
        assert!(nzb.primary_file().unwrap().subject.contains("Movie.mkv"));
    }

    #[test]
    fn sidecars_are_rejected_with_posting_metadata_and_quoted_prefixes() {
        for subject in [
            "[1/2] Movie.NFO yEnc (1/1)",
            "[1/2] \"Movie.JPEG\" yEnc (1/1)",
            "[1/2] \"Movie.PNG\" (1/1)",
            "Movie.webp\tyEnc (1/1)",
            "Movie.nfo",
            "Movie.en.SRT yEnc (1/1)",
            "Movie.idx yEnc (1/1)",
            "Movie.sfv yEnc (1/1)",
            "Movie.sha256 yEnc (1/1)",
            "Movie.url yEnc (1/1)",
            "\"Movie.mkv\" [1/1] \"cover.jpg\" yEnc (1/1)",
        ] {
            assert!(!candidate(subject, 100).is_media_candidate(), "{subject}");
        }
        assert!(Nzb { files: vec![candidate("Movie.jpg yEnc (1/1)", 56958)] }
            .primary_file().is_none());
    }

    #[test]
    fn obfuscated_payloads_and_video_names_containing_sidecar_words_remain_eligible() {
        for subject in [
            "[1/1] \"a6ed4c72efc9\" yEnc (1/400)",
            "a6ed4c72efc9 yEnc (1/400)",
            "Movie.jpg.mkv yEnc (1/400)",
            "[1/1] \"Movie.nfo.mp4\" yEnc (1/400)",
            "Movie.jpglossless yEnc (1/400)",
        ] {
            let nzb = Nzb { files: vec![candidate(subject, 10_000_000)] };
            assert!(nzb.primary_file().is_some(), "{subject}");
        }
    }
}

#[cfg(test)]
mod archive_tests {
    use super::*;
    fn f(subject: &str) -> NzbFile {
        NzbFile { subject: subject.into(), groups: vec![], segments: vec![], total_bytes: 0 }
    }
    #[test]
    fn detects_archives() {
        assert!(f("Movie.2024.1080p-GROUP.part01.rar").is_archive());
        assert!(f("Show.S01E05 [01/50] .r07 yEnc").is_archive());
        assert!(f("Thing.7z").is_archive());
        assert!(f("Split.001").is_archive());
        assert!(!f("Movie.2024.1080p.WEB-DL.x264-GROUP.mkv").is_archive());
        assert!(!f("Movie.2024.1080p.mp4").is_archive());
        // a raw mkv is a media candidate; a rar is not
        assert!(f("Movie.1080p.mkv").is_media_candidate());
        assert!(!f("Movie.1080p.part01.rar").is_media_candidate());
    }
}
