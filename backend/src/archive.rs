//! RAR5 store-mode streaming. Modern usenet releases are often posted as a set of
//! RAR volumes (`name.part01.rar`, `part02.rar`, …) with the media file STORED
//! (uncompressed) inside. Because it's stored, the media bytes sit contiguously in
//! each volume behind a small header — so we can stream from within the archive by
//! mapping a media byte-range to (volume, offset) without ever unpacking to disk.
//!
//! We parse each volume's RAR5 header to learn where its data area starts and how
//! many file bytes it holds, producing a list of [`Extent`]s. The media file is the
//! concatenation of every extent's data; the stream server serves a range by
//! reading the covering extents. Compressed (non-store) RARs are rejected — they
//! can't be seeked, so the caller fails over to another release.

use std::sync::Arc;

use crate::nzb::{NzbFile, Segment};
use crate::pool::{Fetched, Pool};

/// One contiguous run of media bytes living inside a single RAR volume.
#[derive(Clone)]
pub struct Extent {
    pub segments: Arc<Vec<Segment>>,
    pub group: String,
    /// Decoded bytes per full segment of this volume (uniform; last is smaller).
    pub part_size: u64,
    /// Byte offset within the volume's decoded stream where our media data starts.
    pub data_start: u64,
    /// Number of media bytes in this volume.
    pub data_len: u64,
}

/// A parsed RAR5 file header from one volume.
struct RarFileHeader {
    name: String,
    /// Compression method: 0 = store (streamable). Non-zero = compressed.
    method: u8,
    /// Offset of the data area within the volume's decoded stream.
    data_offset: u64,
    /// Size of the data area (file bytes in this volume).
    data_size: u64,
}

const RAR5_SIG: &[u8] = b"Rar!\x1a\x07\x01\x00";

/// LEB128 variable-length integer (RAR5), little-endian base-128.
fn read_vint(buf: &[u8], pos: &mut usize) -> Option<u64> {
    let mut result = 0u64;
    let mut shift = 0u32;
    loop {
        let b = *buf.get(*pos)?;
        *pos += 1;
        result |= ((b & 0x7f) as u64) << shift;
        if b & 0x80 == 0 {
            return Some(result);
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
    }
}

/// Parse a volume's decoded header bytes and return the first FILE header found.
fn parse_rar5_file_header(buf: &[u8]) -> Option<RarFileHeader> {
    if !buf.starts_with(RAR5_SIG) {
        return None;
    }
    let mut pos = RAR5_SIG.len();
    loop {
        // Common block header: CRC32(4), header_size(vint), then the header body
        // (header_size bytes, from header_type onward).
        if pos + 4 > buf.len() {
            return None;
        }
        pos += 4; // skip CRC32
        let header_size = read_vint(buf, &mut pos)? as usize;
        let body_start = pos; // header_size counts from here (header_type field)
        let header_type = read_vint(buf, &mut pos)?;
        let header_flags = read_vint(buf, &mut pos)?;
        let has_extra = header_flags & 0x0001 != 0;
        let has_data = header_flags & 0x0002 != 0;
        let _extra_size = if has_extra { read_vint(buf, &mut pos)? } else { 0 };
        let data_size = if has_data { read_vint(buf, &mut pos)? } else { 0 };
        let header_end = body_start + header_size; // data area begins here

        if header_type == 2 {
            // FILE header specific fields.
            let file_flags = read_vint(buf, &mut pos)?;
            let _unp_size = read_vint(buf, &mut pos)?;
            let _attr = read_vint(buf, &mut pos)?;
            if file_flags & 0x0002 != 0 {
                pos += 4; // mtime (u32)
            }
            if file_flags & 0x0004 != 0 {
                pos += 4; // data CRC32 (u32)
            }
            let comp_info = read_vint(buf, &mut pos)?;
            let method = ((comp_info >> 7) & 0x7) as u8;
            let _host_os = read_vint(buf, &mut pos)?;
            let name_len = read_vint(buf, &mut pos)? as usize;
            let name = buf
                .get(pos..pos + name_len)
                .map(|n| String::from_utf8_lossy(n).into_owned())
                .unwrap_or_default();
            return Some(RarFileHeader {
                name,
                method,
                data_offset: header_end as u64,
                data_size,
            });
        }

        // Not a file header — advance past this block's header + data area.
        pos = header_end + data_size as usize;
        if pos >= buf.len() {
            return None;
        }
    }
}

/// Order RAR volumes: `.partNN.rar` by NN, else `.rar`(0) then `.rNN`(NN+1).
fn volume_order_key(subject: &str) -> u64 {
    let s = subject.to_ascii_lowercase();
    if let Some(idx) = s.find("part") {
        let digits: String = s[idx + 4..].chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(n) = digits.parse::<u64>() {
            return n;
        }
    }
    // old scheme: .rar is the first volume, then .r00, .r01, …
    let b = s.as_bytes();
    for i in 0..b.len().saturating_sub(3) {
        if b[i] == b'.' && b[i + 1] == b'r' && b[i + 2].is_ascii_digit() && b[i + 3].is_ascii_digit() {
            let n: u64 = s[i + 2..i + 4].parse().unwrap_or(0);
            return n + 1;
        }
    }
    0 // ".rar"
}

/// Build the ordered RAR volume list from an NZB's archive files (RAR5 only).
pub fn rar_volumes(files: &[NzbFile]) -> Vec<NzbFile> {
    let mut vols: Vec<NzbFile> = files
        .iter()
        .filter(|f| {
            let s = f.subject.to_ascii_lowercase();
            !f.segments.is_empty() && (s.contains(".rar") || {
                let b = s.as_bytes();
                (0..b.len().saturating_sub(3)).any(|i| {
                    b[i] == b'.' && b[i + 1] == b'r' && b[i + 2].is_ascii_digit() && b[i + 3].is_ascii_digit()
                })
            })
        })
        .cloned()
        .collect();
    vols.sort_by_key(|f| volume_order_key(&f.subject));
    vols
}

#[derive(Debug, thiserror::Error)]
pub enum RarError {
    #[error("no rar volumes")]
    NoVolumes,
    #[error("volume {0} unreadable")]
    Volume(usize),
    #[error("not a RAR5 store-mode archive")]
    NotStore,
}

/// Fetch + decode a volume's first segment (holds the header for a store file).
async fn fetch_seg0(pool: &Arc<Pool>, group: &str, seg: &Segment) -> Option<Vec<u8>> {
    match pool.fetch(group, &seg.message_id).await {
        Fetched::Found(raw) => crate::yenc::decode(&raw).ok().map(|d| d.data),
        Fetched::Missing => None,
    }
}

/// Parse every volume's header and build the media file's extents + total size.
/// Returns Err if the archive is compressed (not seekable) or unreadable.
pub async fn build_extents(
    pool: &Arc<Pool>,
    volumes: &[NzbFile],
) -> Result<(Vec<Extent>, u64), RarError> {
    build_extents_with_admission(pool, volumes, false).await
}

pub async fn build_extents_background(
    pool: &Arc<Pool>,
    volumes: &[NzbFile],
) -> Result<(Vec<Extent>, u64), RarError> {
    build_extents_with_admission(pool, volumes, true).await
}

async fn build_extents_with_admission(
    pool: &Arc<Pool>, volumes: &[NzbFile], background: bool,
) -> Result<(Vec<Extent>, u64), RarError> {
    if volumes.is_empty() {
        return Err(RarError::NoVolumes);
    }
    // Fetch every volume's header segment CONCURRENTLY — sequential fetches on a
    // 20-volume release blew past the player's read timeout.
    let fetches: Vec<_> = volumes.iter().map(|vol| {
        let pool = Arc::clone(pool);
        let group = vol.groups.first().cloned().unwrap_or_default();
        let seg0 = vol.segments.first().cloned();
        async move {
            let seg0 = seg0?;
            let _background = if background { Some(pool.background_permit().await) } else { None };
            fetch_seg0(&pool, &group, &seg0).await
        }
    }).collect();
    let heads = if background {
        use futures::StreamExt;
        // A large archive must not queue hundreds of requests ahead of other
        // candidate sources on the shared background semaphore.
        let pending = futures::stream::iter(fetches).buffered(2);
        tokio::pin!(pending);
        let mut heads = Vec::new();
        while let Some(head) = pending.next().await {
            if head.is_none() { return Err(RarError::Volume(heads.len())); }
            heads.push(head);
        }
        heads
    } else {
        futures::future::join_all(fetches).await
    };

    let mut extents = Vec::with_capacity(volumes.len());
    let mut total = 0u64;
    for (i, (vol, head)) in volumes.iter().zip(heads).enumerate() {
        let group = vol.groups.first().cloned().unwrap_or_default();
        let head = head.ok_or(RarError::Volume(i))?;
        let part_size = head.len() as u64; // decoded size of a full segment
        let fh = parse_rar5_file_header(&head).ok_or(RarError::Volume(i))?;
        if fh.method != 0 {
            return Err(RarError::NotStore);
        }
        // A .partNN.rar can carry the media file OR a small sidecar (nfo). Only the
        // big data area is the media; skip tiny ones (< 1 segment) that aren't ours.
        if fh.data_size == 0 {
            continue;
        }
        // Ignore obvious non-media sidecars inside the archive by name when present.
        let n = fh.name.to_ascii_lowercase();
        if n.ends_with(".nfo") || n.ends_with(".sfv") || n.ends_with(".txt") {
            continue;
        }
        total += fh.data_size;
        extents.push(Extent {
            segments: Arc::new(vol.segments.clone()),
            group,
            part_size,
            data_start: fh.data_offset,
            data_len: fh.data_size,
        });
    }
    if extents.is_empty() {
        return Err(RarError::NoVolumes);
    }
    Ok((extents, total))
}

/// Fetch + decode one segment, returning its bytes and real 0-based decoded start
/// (from =ypart), falling back to the uniform estimate / zero-fill.
pub(crate) async fn fetch_seg(
    pool: &Arc<Pool>, group: &str, seg: &Segment, part_size: u64, idx: usize,
) -> (Vec<u8>, u64) {
    match pool.fetch(group, &seg.message_id).await {
        Fetched::Found(raw) => match crate::yenc::decode(&raw) {
            Ok(d) => {
                let start = d.part_begin.map(|b| b - 1).unwrap_or(idx as u64 * part_size);
                (d.data, start)
            }
            Err(_) => (vec![0u8; part_size as usize], idx as u64 * part_size),
        },
        Fetched::Missing => (vec![0u8; part_size as usize], idx as u64 * part_size),
    }
}

/// Read `[start, start+len)` of a single volume's decoded stream, self-correcting
/// the starting segment via =ypart so a non-uniform volume can't misalign.
pub async fn read_volume_range(
    pool: &Arc<Pool>, group: &str, segments: &[Segment], part_size: u64, start: u64, len: u64,
) -> Vec<u8> {
    let end = start + len;
    let mut out = Vec::with_capacity(len as usize);
    let mut idx = ((start / part_size.max(1)) as usize).min(segments.len().saturating_sub(1));
    // Position on the segment that contains `start`, then append its overlap.
    loop {
        if idx >= segments.len() {
            return out;
        }
        let (data, seg_start) = fetch_seg(pool, group, &segments[idx], part_size, idx).await;
        let seg_end = seg_start + data.len() as u64;
        if start < seg_start && idx > 0 {
            idx -= 1;
            continue;
        }
        if start >= seg_end && idx + 1 < segments.len() {
            idx += 1;
            continue;
        }
        let from = start.saturating_sub(seg_start) as usize;
        let to = (end.min(seg_end).saturating_sub(seg_start) as usize).min(data.len());
        if to > from {
            out.extend_from_slice(&data[from..to]);
        }
        idx += 1;
        break;
    }
    // Append contiguous following segments until satisfied.
    while (out.len() as u64) < len && idx < segments.len() {
        let (data, _) = fetch_seg(pool, group, &segments[idx], part_size, idx).await;
        let remaining = (len - out.len() as u64) as usize;
        let take = remaining.min(data.len());
        out.extend_from_slice(&data[..take]);
        idx += 1;
    }
    out.truncate(len as usize);
    out
}

/// Read `[start, start+len)` of the MEDIA file assembled across extents.
pub async fn read_media(pool: &Arc<Pool>, extents: &[Extent], start: u64, len: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(len as usize);
    let end = start + len;
    let mut cum = 0u64;
    for e in extents {
        let ext_start = cum;
        let ext_end = cum + e.data_len;
        cum = ext_end;
        if ext_end <= start {
            continue;
        }
        if ext_start >= end {
            break;
        }
        let ov_start = start.max(ext_start);
        let ov_end = end.min(ext_end);
        let vs = e.data_start + (ov_start - ext_start);
        let chunk = read_volume_range(pool, &e.group, &e.segments, e.part_size, vs, ov_end - ov_start).await;
        out.extend_from_slice(&chunk);
    }
    out
}

/// Flatten every extent's segment ids — what completeness-checks the whole media.
#[allow(dead_code)] // kept for the optional background completeness check
pub fn all_segment_ids(extents: &[Extent]) -> Vec<String> {
    extents
        .iter()
        .flat_map(|e| e.segments.iter().map(|s| s.message_id.clone()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vint_roundtrip() {
        // 0x90 0x01 = (0x10) | (0x01 << 7) = 0x90
        let mut pos = 0;
        assert_eq!(read_vint(&[0x90, 0x01], &mut pos), Some(0x90));
        assert_eq!(pos, 2);
        let mut pos = 0;
        assert_eq!(read_vint(&[0x7f], &mut pos), Some(0x7f));
    }

    #[test]
    fn volume_ordering() {
        assert_eq!(volume_order_key("x.part01.rar"), 1);
        assert_eq!(volume_order_key("x.part12.rar"), 12);
        assert_eq!(volume_order_key("x.rar"), 0);
        assert_eq!(volume_order_key("x.r00"), 1);
        assert_eq!(volume_order_key("x.r09"), 10);
    }

    #[tokio::test]
    async fn background_archive_failure_does_not_flood_all_volume_headers() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tokio::{io::{AsyncBufReadExt, AsyncWriteExt, BufReader}, net::TcpListener};
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let reads = Arc::new(AtomicUsize::new(0));
        let seen = reads.clone();
        let server = tokio::spawn(async move {
            loop {
                let Ok((socket,_)) = listener.accept().await else { return };
                let seen = seen.clone();
                tokio::spawn(async move {
                    let mut socket = BufReader::new(socket);
                    let _ = socket.get_mut().write_all(b"200 fixture\r\n").await;
                    loop {
                        let mut line = String::new();
                        if socket.read_line(&mut line).await.unwrap_or(0) == 0 { return; }
                        let response: &[u8] = if line.starts_with("AUTHINFO") { b"281 accepted\r\n" }
                            else if line.starts_with("GROUP") { b"211 fixture\r\n" }
                            else {
                                seen.fetch_add(1, Ordering::SeqCst);
                                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                                b"430 missing\r\n"
                            };
                        if socket.get_mut().write_all(response).await.is_err() { return; }
                    }
                });
            }
        });
        let pool = Pool::new(&[crate::config::Provider { name:"fixture".into(),host:"127.0.0.1".into(),port,tls:false,username:"fixture".into(),password:"fixture".into(),max_connections:100 }]);
        let volumes: Vec<_> = (0..50).map(|index| NzbFile {
            subject:format!("file.part{index:03}.rar"), groups:vec!["fixture".into()], total_bytes:100,
            segments:vec![Segment { number:1,bytes:100,message_id:format!("volume-{index}") }],
        }).collect();
        assert!(matches!(build_extents_background(&pool,&volumes).await,Err(RarError::Volume(0))));
        assert!(reads.load(Ordering::SeqCst) <= 2, "one failed archive must not queue every volume ahead of other sources");
        server.abort();
    }
}
