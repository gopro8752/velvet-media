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
    /// par2/nfo/sfv/sample files are never the thing we stream — and neither are
    /// RAR/7z/zip archive volumes (we can't stream from inside an archive yet, so
    /// a release whose payload is archived has NO direct media file → the caller
    /// refuses it and the app fails over to a raw-media release).
    pub fn is_media_candidate(&self) -> bool {
        let s = self.subject.to_ascii_lowercase();
        !(s.contains(".par2")
            || s.ends_with(".nfo")
            || s.contains(".sfv")
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
