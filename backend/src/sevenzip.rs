//! 7-Zip store-mode ("Copy" coder) streaming.
//!
//! Like a store-mode RAR, a 7z whose single file is stored uncompressed keeps
//! that file's bytes as one contiguous packed stream — so we can serve a byte
//! range from inside it without unpacking. The catch versus RAR: 7z puts its
//! index (the "next header": which files, which coders, pack offsets/sizes) at
//! the END of the archive, and by default COMPRESSES that header with LZMA
//! (`kEncodedHeader`). We support the plain-header (`kHeader`) case fully; an
//! encoded header is reported so the caller can fail over (decoding it needs an
//! LZMA step we don't carry). Non-Copy data coders are likewise rejected — they
//! aren't seekable.
//!
//! Layout of the 32-byte signature header:
//!   0..6  magic 37 7A BC AF 27 1C   6..8 version   8..12 StartHeaderCRC
//!   12..20 NextHeaderOffset (u64 LE, relative to byte 32)
//!   20..28 NextHeaderSize   (u64 LE)   28..32 NextHeaderCRC

use std::sync::Arc;

use crate::archive::{read_volume_range, read_volume_range_background, Extent};
use crate::nzb::{NzbFile, Segment};
use crate::pool::{Fetched, Pool};

pub const SZ_SIG: &[u8] = &[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];

// 7z property ids (subset we walk).
const K_END: u8 = 0x00;
const K_HEADER: u8 = 0x01;
const K_MAIN_STREAMS_INFO: u8 = 0x04;
const K_PACK_INFO: u8 = 0x06;
const K_UNPACK_INFO: u8 = 0x07;
const K_SUBSTREAMS_INFO: u8 = 0x08;
const K_SIZE: u8 = 0x09;
const K_CRC: u8 = 0x0A;
const K_FOLDER: u8 = 0x0B;
const K_CODERS_UNPACK_SIZE: u8 = 0x0C;
const K_ENCODED_HEADER: u8 = 0x17;

#[derive(Debug, thiserror::Error)]
pub enum SzError {
    #[error("no 7z file in nzb")]
    NoFile,
    #[error("bad 7z signature")]
    BadSig,
    #[error("truncated 7z header")]
    Truncated,
    #[error("multi-volume 7z not supported")]
    MultiVolume,
    #[error("LZMA-encoded 7z header (header compression on) — not seekable")]
    EncodedHeader,
    #[error("7z data is not store-mode (coder {0}) — not seekable")]
    NotStore(String),
    #[error("unsupported 7z layout: {0}")]
    Unsupported(&'static str),
}

/// The 7z variable-length number: the high bits of the first byte are a unary
/// count of how many little-endian bytes follow; the remaining low bits of the
/// first byte are the top bits of the value.
fn read_number(buf: &[u8], pos: &mut usize) -> Option<u64> {
    let first = *buf.get(*pos)?;
    *pos += 1;
    let mut mask = 0x80u8;
    let mut value = 0u64;
    for i in 0..8 {
        if first & mask == 0 {
            let high = (first & (mask.wrapping_sub(1))) as u64;
            value |= high << (8 * i);
            return Some(value);
        }
        let b = *buf.get(*pos)? as u64;
        *pos += 1;
        value |= b << (8 * i);
        mask >>= 1;
    }
    Some(value)
}

/// A 7z number that must fit usize for indexing.
fn read_num_usize(buf: &[u8], pos: &mut usize) -> Option<usize> {
    read_number(buf, pos).map(|n| n as usize)
}

struct SigHeader {
    next_offset: u64,
    next_size: u64,
}

fn parse_sig(buf: &[u8]) -> Result<SigHeader, SzError> {
    if buf.len() < 32 {
        return Err(SzError::Truncated);
    }
    if !buf.starts_with(SZ_SIG) {
        return Err(SzError::BadSig);
    }
    Ok(SigHeader {
        next_offset: u64::from_le_bytes(buf[12..20].try_into().unwrap()),
        next_size: u64::from_le_bytes(buf[20..28].try_into().unwrap()),
    })
}

/// What we learn from a plain (kHeader) next-header: the store file's packed
/// stream position/size, so we can map it to a media byte range.
#[derive(Debug, Clone)]
pub struct SzLayout {
    /// Offset of the packed data within the archive body (i.e. after byte 32).
    pub pack_pos: u64,
    /// Size of the (single) packed stream = the stored file's byte length.
    pub pack_size: u64,
    /// Coder id of the one folder, for diagnostics (`00` = Copy/store).
    pub coder_id: Vec<u8>,
}

/// Parse the next-header bytes. `kEncodedHeader` (LZMA-compressed header) and
/// anything but a single Copy-coder folder are surfaced as typed errors.
pub fn parse_next_header(buf: &[u8]) -> Result<SzLayout, SzError> {
    let mut pos = 0usize;
    let tag = *buf.get(pos).ok_or(SzError::Truncated)?;
    pos += 1;
    match tag {
        K_ENCODED_HEADER => Err(SzError::EncodedHeader),
        K_HEADER => parse_header_body(buf, &mut pos),
        _ => Err(SzError::Unsupported("unexpected top-level header id")),
    }
}

fn parse_header_body(buf: &[u8], pos: &mut usize) -> Result<SzLayout, SzError> {
    // Header := { properties* } kEnd. We only need MainStreamsInfo.
    loop {
        let id = *buf.get(*pos).ok_or(SzError::Truncated)?;
        *pos += 1;
        match id {
            K_END => return Err(SzError::Unsupported("no main streams info")),
            K_MAIN_STREAMS_INFO => return parse_streams_info(buf, pos),
            // kArchiveProperties / kAdditionalStreamsInfo / kFilesInfo: we don't
            // need them and can't reliably skip their variable bodies, so bail.
            _ => return Err(SzError::Unsupported("header property before streams info")),
        }
    }
}

fn parse_streams_info(buf: &[u8], pos: &mut usize) -> Result<SzLayout, SzError> {
    let mut pack_pos = 0u64;
    let mut pack_sizes: Vec<u64> = Vec::new();
    let mut coder_id: Option<Vec<u8>> = None;

    loop {
        let id = *buf.get(*pos).ok_or(SzError::Truncated)?;
        *pos += 1;
        match id {
            K_END => break,
            K_PACK_INFO => {
                pack_pos = read_number(buf, pos).ok_or(SzError::Truncated)?;
                let num_pack = read_num_usize(buf, pos).ok_or(SzError::Truncated)?;
                // Sub-structures until kEnd of PackInfo.
                loop {
                    let sub = *buf.get(*pos).ok_or(SzError::Truncated)?;
                    *pos += 1;
                    match sub {
                        K_END => break,
                        K_SIZE => {
                            for _ in 0..num_pack {
                                pack_sizes.push(read_number(buf, pos).ok_or(SzError::Truncated)?);
                            }
                        }
                        K_CRC => return Err(SzError::Unsupported("pack CRC digests")),
                        _ => return Err(SzError::Unsupported("unknown pack-info id")),
                    }
                }
            }
            K_UNPACK_INFO => {
                coder_id = Some(parse_unpack_info(buf, pos)?);
            }
            K_SUBSTREAMS_INFO => {
                // A single stored file needs no sub-stream split; if present with
                // more than the implicit one, we don't support it. Skip to kEnd
                // conservatively: only tolerate an immediately-empty block.
                skip_substreams_info(buf, pos)?;
            }
            _ => return Err(SzError::Unsupported("unknown streams-info id")),
        }
    }

    let coder_id = coder_id.ok_or(SzError::Unsupported("no unpack info"))?;
    if coder_id != [0x00] {
        return Err(SzError::NotStore(hex(&coder_id)));
    }
    if pack_sizes.len() != 1 {
        return Err(SzError::Unsupported("expected exactly one packed stream"));
    }
    Ok(SzLayout {
        pack_pos,
        pack_size: pack_sizes[0],
        coder_id,
    })
}

/// UnpackInfo := kFolder NumFolders External Folders[] kCodersUnpackSize sizes[] [kCRC ...] kEnd.
/// Returns the coder id of the single folder (must be one folder, one coder).
fn parse_unpack_info(buf: &[u8], pos: &mut usize) -> Result<Vec<u8>, SzError> {
    let id = *buf.get(*pos).ok_or(SzError::Truncated)?;
    *pos += 1;
    if id != K_FOLDER {
        return Err(SzError::Unsupported("expected kFolder"));
    }
    let num_folders = read_num_usize(buf, pos).ok_or(SzError::Truncated)?;
    let external = *buf.get(*pos).ok_or(SzError::Truncated)?;
    *pos += 1;
    if external != 0 {
        return Err(SzError::Unsupported("external folder definitions"));
    }
    if num_folders != 1 {
        return Err(SzError::Unsupported("expected exactly one folder"));
    }
    let coder_id = parse_one_coder_folder(buf, pos)?;
    // Remaining: kCodersUnpackSize (one size per out-stream) then optional kCRC,
    // then kEnd. We don't need the values, but must consume to kEnd cleanly.
    loop {
        let sub = *buf.get(*pos).ok_or(SzError::Truncated)?;
        *pos += 1;
        match sub {
            K_END => break,
            K_CODERS_UNPACK_SIZE => {
                // One unpack size for the single out-stream.
                read_number(buf, pos).ok_or(SzError::Truncated)?;
            }
            K_CRC => {
                // AllAreDefined byte, then (if 0) a bit-vector; then digests.
                // A store folder with CRC: 1 defined digest. Handle the common
                // all-defined case; anything fancier we reject.
                let all_defined = *buf.get(*pos).ok_or(SzError::Truncated)?;
                *pos += 1;
                if all_defined == 0 {
                    return Err(SzError::Unsupported("partial CRC bit-vector"));
                }
                *pos += 4; // one CRC32
            }
            _ => return Err(SzError::Unsupported("unknown unpack-info id")),
        }
    }
    Ok(coder_id)
}

/// Parse a Folder with exactly one coder and return its id.
fn parse_one_coder_folder(buf: &[u8], pos: &mut usize) -> Result<Vec<u8>, SzError> {
    let num_coders = read_num_usize(buf, pos).ok_or(SzError::Truncated)?;
    if num_coders != 1 {
        return Err(SzError::Unsupported("multi-coder folder"));
    }
    let flags = *buf.get(*pos).ok_or(SzError::Truncated)?;
    *pos += 1;
    let id_size = (flags & 0x0f) as usize;
    let is_complex = flags & 0x10 != 0;
    let has_attrs = flags & 0x20 != 0;
    let id = buf
        .get(*pos..*pos + id_size)
        .ok_or(SzError::Truncated)?
        .to_vec();
    *pos += id_size;
    if is_complex {
        // NumInStreams, NumOutStreams — a store folder is simple, so reject.
        return Err(SzError::Unsupported("complex coder"));
    }
    if has_attrs {
        let props_size = read_num_usize(buf, pos).ok_or(SzError::Truncated)?;
        *pos += props_size; // Copy has none, but be general.
    }
    Ok(id)
}

/// Tolerate a SubStreamsInfo only if it carries nothing that changes our
/// single-stream assumption; otherwise reject. We consume up to its kEnd.
fn skip_substreams_info(buf: &[u8], pos: &mut usize) -> Result<(), SzError> {
    loop {
        let id = *buf.get(*pos).ok_or(SzError::Truncated)?;
        *pos += 1;
        match id {
            K_END => return Ok(()),
            // Any explicit content here (extra num-streams, sizes, CRCs) means a
            // layout we don't model — refuse rather than mis-map.
            _ => return Err(SzError::Unsupported("non-trivial substreams info")),
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Find the single `.7z` file in an NZB (rejects `.7z.001` multi-volume sets).
pub fn seven_zip_file(files: &[NzbFile]) -> Result<NzbFile, SzError> {
    let sevens: Vec<&NzbFile> = files
        .iter()
        .filter(|f| {
            let s = f.subject.to_ascii_lowercase();
            !f.segments.is_empty() && s.contains(".7z")
        })
        .collect();
    if sevens.is_empty() {
        return Err(SzError::NoFile);
    }
    // A split set looks like name.7z.001 / .002 …; we only do single-file 7z.
    if sevens.iter().any(|f| {
        let s = f.subject.to_ascii_lowercase();
        s.contains(".7z.0") || s.contains(".7z.1")
    }) {
        return Err(SzError::MultiVolume);
    }
    Ok(sevens
        .into_iter()
        .max_by_key(|f| f.segments.len())
        .unwrap()
        .clone())
}

async fn seg0_part_size(pool: &Arc<Pool>, group: &str, seg: &Segment, background: bool) -> Option<(Vec<u8>, u64)> {
    let fetched = if background { pool.fetch_background(group, &seg.message_id).await }
        else { pool.fetch(group, &seg.message_id).await };
    match fetched {
        Fetched::Found(raw) => crate::yenc::decode(&raw).ok().map(|d| {
            let n = d.data.len() as u64;
            (d.data, n)
        }),
        Fetched::Missing => None,
    }
}

/// Read the signature header + (plain) next header of a single-file 7z and build
/// the one store-mode extent for its media file.
pub async fn build_extents(
    pool: &Arc<Pool>,
    files: &[NzbFile],
) -> Result<(Vec<Extent>, u64), SzError> {
    build_extents_with_admission(pool, files, false).await
}

pub async fn build_extents_background(
    pool: &Arc<Pool>, files: &[NzbFile],
) -> Result<(Vec<Extent>, u64), SzError> {
    build_extents_with_admission(pool, files, true).await
}

async fn build_extents_with_admission(
    pool: &Arc<Pool>, files: &[NzbFile], background: bool,
) -> Result<(Vec<Extent>, u64), SzError> {
    let file = seven_zip_file(files)?;
    let group = file.groups.first().cloned().unwrap_or_default();
    let segments = file.segments.clone();
    let seg0 = segments.first().ok_or(SzError::NoFile)?;

    // First segment gives us both the signature header and the uniform part size.
    let (head0, part_size) = seg0_part_size(pool, &group, seg0, background)
        .await
        .ok_or(SzError::Truncated)?;
    let sig = parse_sig(&head0)?;

    // The next header sits at body offset next_offset (i.e. archive offset
    // 32 + next_offset), length next_size. Read it across segments.
    let header_start = 32 + sig.next_offset;
    let header_bytes = if background {
        read_volume_range_background(pool, &group, &segments, part_size, header_start, sig.next_size).await
    } else {
        read_volume_range(pool, &group, &segments, part_size, header_start, sig.next_size).await
    };
    if (header_bytes.len() as u64) < sig.next_size {
        return Err(SzError::Truncated);
    }
    let layout = parse_next_header(&header_bytes)?;

    // The stored file's bytes are at archive offset 32 + pack_pos, length
    // pack_size. That's exactly one media extent over this file's segments.
    let data_start = 32 + layout.pack_pos;
    let extent = Extent {
        segments: Arc::new(segments),
        group,
        part_size,
        data_start,
        data_len: layout.pack_size,
    };
    Ok((vec![extent], layout.pack_size))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn number_encoding() {
        // Single byte, high bit clear → value is the low 7 bits.
        let mut p = 0;
        assert_eq!(read_number(&[0x7f], &mut p), Some(0x7f));
        assert_eq!(p, 1);
        // 0x80 0x2a → one following byte, value = 0x2a.
        let mut p = 0;
        assert_eq!(read_number(&[0x80, 0x2a], &mut p), Some(0x2a));
        assert_eq!(p, 2);
        // 0xC0 0x34 0x12 → two following bytes LE → 0x1234.
        let mut p = 0;
        assert_eq!(read_number(&[0xC0, 0x34, 0x12], &mut p), Some(0x1234));
        assert_eq!(p, 3);
        // High-bits case: 0xA0 = 1010_0000 → one leading 1 → one following byte
        // (0x34), and the low bits after the terminating 0 give high part
        // (0xA0 & 0x3f)=0x20 at byte-index 1 → 0x34 | (0x20<<8) = 0x2034.
        let mut p = 0;
        assert_eq!(read_number(&[0xA0, 0x34], &mut p), Some(0x2034));
        assert_eq!(p, 2);
    }

    #[test]
    fn sig_parse() {
        let mut buf = vec![0u8; 32];
        buf[..6].copy_from_slice(SZ_SIG);
        buf[12..20].copy_from_slice(&1000u64.to_le_bytes());
        buf[20..28].copy_from_slice(&50u64.to_le_bytes());
        let s = parse_sig(&buf).unwrap();
        assert_eq!(s.next_offset, 1000);
        assert_eq!(s.next_size, 50);
    }

    #[test]
    fn plain_store_header() {
        // kHeader → kMainStreamsInfo → kPackInfo(pos=0,num=1,kSize[123])kEnd
        //   → kUnpackInfo kFolder num=1 external=0 [1 coder id=00]
        //       kCodersUnpackSize 123 kEnd → kEnd(streamsinfo) → kEnd(header)
        let h = [
            K_HEADER,
            K_MAIN_STREAMS_INFO,
            K_PACK_INFO,
            0x00, // pack_pos = 0
            0x01, // num pack streams = 1
            K_SIZE,
            0x7b, // 123
            K_END, // end packinfo
            K_UNPACK_INFO,
            K_FOLDER,
            0x01, // num folders
            0x00, // external = 0
            0x01, // num coders = 1
            0x01, // flags: id_size=1, simple, no attrs
            0x00, // coder id = Copy
            K_CODERS_UNPACK_SIZE,
            0x7b, // unpack size 123
            K_END, // end unpackinfo
            K_END, // end streamsinfo
            K_END, // end header
        ];
        let layout = parse_next_header(&h).unwrap();
        assert_eq!(layout.pack_pos, 0);
        assert_eq!(layout.pack_size, 123);
        assert_eq!(layout.coder_id, vec![0x00]);
    }

    #[test]
    fn encoded_header_rejected() {
        assert!(matches!(
            parse_next_header(&[K_ENCODED_HEADER]),
            Err(SzError::EncodedHeader)
        ));
    }

    #[test]
    fn lzma_data_rejected() {
        // Same as plain_store_header but coder id 0x21 (LZMA2) → NotStore.
        let h = [
            K_HEADER, K_MAIN_STREAMS_INFO, K_PACK_INFO, 0x00, 0x01, K_SIZE, 0x7b, K_END,
            K_UNPACK_INFO, K_FOLDER, 0x01, 0x00, 0x01, 0x01, 0x21, K_CODERS_UNPACK_SIZE, 0x7b,
            K_END, K_END, K_END,
        ];
        assert!(matches!(parse_next_header(&h), Err(SzError::NotStore(_))));
    }
}
