//! yEnc decoding — the binary encoding usenet articles use.
//!
//! An article body looks like:
//! ```text
//! =ybegin part=1 line=128 size=500000 name=movie.mkv
//! =ypart begin=1 end=384000
//! <encoded data lines…>
//! =yend size=384000 part=1 pcrc32=abcd1234
//! ```
//! Each data byte is stored as `(b + 42) mod 256`; bytes that would land on a
//! control character are escaped as `=` followed by `(b + 42 + 64) mod 256`.
//! Lines beginning with the literal keywords `=ybegin` / `=ypart` / `=yend` are
//! metadata; everywhere else a leading `=` is the escape prefix.
//!
//! For streaming we care about two things per segment: the decoded bytes, and
//! the `=ypart` begin/end offsets that say WHERE those bytes sit in the whole
//! file (1-based, inclusive) — that mapping is what lets us serve a byte range
//! by fetching only the segments it covers.

/// A decoded yEnc segment.
#[derive(Debug, Clone)]
pub struct DecodedSegment {
    pub data: Vec<u8>,
    /// 1-based inclusive file offset of the first byte, from `=ypart begin=`.
    /// `None` for a single-part post that omits `=ypart` (begin is then 1).
    pub part_begin: Option<u64>,
    pub part_end: Option<u64>,
    /// `size=` from `=ybegin` (whole-file size) when present.
    pub total_size: Option<u64>,
    /// `name=` from `=ybegin` (parsed for completeness; not needed for streaming).
    #[allow(dead_code)]
    pub name: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum YencError {
    #[error("no =ybegin marker in article body")]
    NoBegin,
}

/// Decode a full article body (the bytes AFTER the NNTP headers, with the final
/// `.` line already stripped). Lines may be CRLF- or LF-terminated.
pub fn decode(body: &[u8]) -> Result<DecodedSegment, YencError> {
    let mut out = Vec::with_capacity(body.len());
    let mut part_begin = None;
    let mut part_end = None;
    let mut total_size = None;
    let mut name = None;
    let mut seen_begin = false;

    for line in split_lines(body) {
        if line.starts_with(b"=ybegin") {
            seen_begin = true;
            total_size = parse_kv_u64(line, b"size=");
            name = parse_kv_name(line);
        } else if line.starts_with(b"=ypart") {
            part_begin = parse_kv_u64(line, b"begin=");
            part_end = parse_kv_u64(line, b"end=");
        } else if line.starts_with(b"=yend") {
            break;
        } else if seen_begin {
            decode_line_into(line, &mut out);
        }
        // Lines before =ybegin (stray article prefix) are ignored.
    }

    if !seen_begin {
        return Err(YencError::NoBegin);
    }
    Ok(DecodedSegment { data: out, part_begin, part_end, total_size, name })
}

/// Decode one data line, appending raw bytes to `out`.
fn decode_line_into(line: &[u8], out: &mut Vec<u8>) {
    let mut i = 0;
    while i < line.len() {
        let c = line[i];
        if c == b'=' {
            // Escape: the next byte carries the value.
            if i + 1 < line.len() {
                out.push(line[i + 1].wrapping_sub(106)); // -42-64
                i += 2;
            } else {
                // Trailing '=' with no payload (line-wrapped escape): skip.
                i += 1;
            }
        } else {
            out.push(c.wrapping_sub(42));
            i += 1;
        }
    }
}

/// Split on LF, trimming a trailing CR so both CRLF and LF bodies work.
fn split_lines(body: &[u8]) -> impl Iterator<Item = &[u8]> {
    body.split(|&b| b == b'\n').map(|l| {
        if l.last() == Some(&b'\r') { &l[..l.len() - 1] } else { l }
    })
}

/// Parse `key=<digits>` from a keyword line.
fn parse_kv_u64(line: &[u8], key: &[u8]) -> Option<u64> {
    let pos = find(line, key)? + key.len();
    let mut end = pos;
    while end < line.len() && line[end].is_ascii_digit() {
        end += 1;
    }
    std::str::from_utf8(&line[pos..end]).ok()?.parse().ok()
}

/// Parse `name=…` (runs to end of line; yEnc names may contain spaces).
fn parse_kv_name(line: &[u8]) -> Option<String> {
    let pos = find(line, b"name=")? + 5;
    Some(String::from_utf8_lossy(&line[pos..]).trim().to_string())
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

// ─── encoder (used only by tests + potential re-post tooling) ────────────────

#[cfg(test)]
pub fn encode_data(data: &[u8], line_len: usize) -> Vec<u8> {
    let mut out = Vec::new();
    let mut col = 0;
    for &b in data {
        let e = b.wrapping_add(42);
        let critical = matches!(e, 0x00 | 0x0A | 0x0D | b'=');
        if critical {
            out.push(b'=');
            out.push(e.wrapping_add(64));
            col += 2;
        } else {
            out.push(e);
            col += 1;
        }
        if col >= line_len {
            out.extend_from_slice(b"\r\n");
            col = 0;
        }
    }
    out.extend_from_slice(b"\r\n");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wrap(data: &[u8], begin: u64, end: u64, size: u64) -> Vec<u8> {
        let mut body = format!(
            "=ybegin part=1 line=128 size={size} name=test.bin\r\n\
             =ypart begin={begin} end={end}\r\n"
        )
        .into_bytes();
        body.extend_from_slice(&encode_data(data, 128));
        body.extend_from_slice(format!("=yend size={} part=1\r\n", data.len()).as_bytes());
        body
    }

    #[test]
    fn round_trip_all_byte_values() {
        // Every possible byte, so every escape path (00, 0A, 0D, 3D land) is hit.
        let data: Vec<u8> = (0..=255u8).cycle().take(4096).collect();
        let body = wrap(&data, 1, data.len() as u64, data.len() as u64);
        let seg = decode(&body).unwrap();
        assert_eq!(seg.data, data);
        assert_eq!(seg.part_begin, Some(1));
        assert_eq!(seg.part_end, Some(data.len() as u64));
        assert_eq!(seg.total_size, Some(data.len() as u64));
        assert_eq!(seg.name.as_deref(), Some("test.bin"));
    }

    #[test]
    fn round_trip_lf_only_body() {
        let data: Vec<u8> = vec![0x00, 0x0A, 0x0D, 0x3D, 0xFF, 0x2A, 0x13, 0x9A];
        // Force LF-only line endings.
        let crlf = wrap(&data, 100, 100 + data.len() as u64 - 1, 999);
        let lf: Vec<u8> = crlf.into_iter().filter(|&b| b != b'\r').collect();
        let seg = decode(&lf).unwrap();
        assert_eq!(seg.data, data);
        assert_eq!(seg.part_begin, Some(100));
    }

    #[test]
    fn missing_begin_errors() {
        assert!(matches!(decode(b"just noise\r\n"), Err(YencError::NoBegin)));
    }

    #[test]
    fn stops_at_yend_ignores_trailing() {
        let data = vec![1u8, 2, 3, 4, 5];
        let mut body = wrap(&data, 1, 5, 5);
        body.extend_from_slice(b"garbage after yend that must be ignored\r\n");
        let seg = decode(&body).unwrap();
        assert_eq!(seg.data, data);
    }
}
