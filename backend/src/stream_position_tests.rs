//! HTTP range regressions for unequal yEnc article sizes and invalid offsets.
use super::*;
use std::time::Duration;

fn state() -> StreamState {
    let db = crate::db::open(":memory:").unwrap();
    crate::sync::migrate(&db.lock().unwrap()).unwrap();
    StreamState::new(Pool::new(&[]), reqwest::Client::new(), db)
}

async fn fixture(volumes: Vec<(u64, u64, u64, Vec<(u64, Vec<u8>)>)>) -> (StreamState, String, u64) {
    let st = state();
    let sid = st
        .register("https://fixture.invalid/unequal-articles.nzb")
        .await;
    let mut extents = Vec::new();
    let mut starts = Vec::new();
    let mut total = 0;
    for (volume, (part_size, data_start, data_len, articles)) in volumes.into_iter().enumerate() {
        let mut segments = Vec::new();
        for (idx, (offset, bytes)) in articles.into_iter().enumerate() {
            let id = format!("volume-{volume}-article-{idx}@fixture.invalid");
            segments.push(crate::nzb::Segment {
                number: idx as u32 + 1,
                bytes: bytes.len() as u64,
                message_id: id.clone(),
            });
            st.cache.put(&id, bytes, offset);
        }
        starts.push(total);
        total += data_len;
        extents.push(Extent {
            segments: Arc::new(segments),
            group: "fixture".into(),
            part_size,
            data_start,
            data_len,
        });
    }
    *st.lookup(&sid).unwrap().loaded.lock().unwrap() = Some(Loaded {
        extents: Arc::new(extents),
        ext_media_start: Arc::new(starts),
        total_size: total,
        complete: Some(true),
    });
    (st, sid, total)
}

fn articles(sizes: &[usize]) -> (Vec<u8>, Vec<(u64, Vec<u8>)>) {
    let data: Vec<u8> = (0..sizes.iter().sum())
        .map(|i: usize| ((i * 31 + i / 11) % 256) as u8)
        .collect();
    let mut pos = 0;
    let pieces = sizes
        .iter()
        .map(|size| {
            let old = pos;
            pos += size;
            (old as u64, data[old..pos].to_vec())
        })
        .collect();
    (data, pieces)
}

async fn range(
    st: &StreamState,
    sid: &str,
    start: u64,
    end: u64,
    total: u64,
) -> Result<Bytes, axum::Error> {
    let mut headers = HeaderMap::new();
    headers.insert(
        header::RANGE,
        format!("bytes={start}-{end}").parse().unwrap(),
    );
    let response = serve(State(st.clone()), Path(sid.to_owned()), headers).await;
    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        response.headers()[header::CONTENT_RANGE],
        format!("bytes {start}-{end}/{total}")
    );
    assert_eq!(
        response.headers()[header::CONTENT_LENGTH],
        (end - start + 1).to_string()
    );
    tokio::time::timeout(
        Duration::from_secs(2),
        axum::body::to_bytes(response.into_body(), 1024 * 1024),
    )
    .await
    .expect("range body must make finite progress")
}

#[tokio::test]
async fn resume_and_seek_use_real_article_offsets_in_both_directions() {
    for (sizes, seek) in [([128, 64, 128, 128], 350), ([64, 128, 128, 128], 150)] {
        let (data, pieces) = articles(&sizes);
        let (st, sid, total) = fixture(vec![(sizes[0] as u64, 0, data.len() as u64, pieces)]).await;
        // A resumed player commonly opens a header range, then a distant media
        // range. The old positioning loop reset every correction to its guess.
        assert_eq!(
            range(&st, &sid, 0, 31, total).await.unwrap().as_ref(),
            &data[..32]
        );
        assert_eq!(
            range(&st, &sid, seek, seek + 31, total)
                .await
                .unwrap()
                .as_ref(),
            &data[seek as usize..seek as usize + 32]
        );
        assert_eq!(
            range(&st, &sid, 0, total - 1, total)
                .await
                .unwrap()
                .as_ref(),
            data
        );
        assert_eq!(
            range(&st, &sid, total - 1, total - 1, total)
                .await
                .unwrap()
                .as_ref(),
            &data[data.len() - 1..]
        );
        // Repeat and seek backward after consuming the whole stream: no state
        // left by another HTTP request may shift these bytes.
        assert_eq!(
            range(&st, &sid, 63, 199, total).await.unwrap().as_ref(),
            &data[63..200]
        );
    }
}

#[tokio::test]
async fn range_crosses_unequal_archive_extents_with_nonzero_media_offsets() {
    let (first, a) = articles(&[128, 64, 128, 128]);
    let (second, b) = articles(&[64, 128, 128]);
    let expected: Vec<u8> = first[37..437]
        .iter()
        .chain(second[99..299].iter())
        .copied()
        .collect();
    let (st, sid, total) = fixture(vec![(128, 37, 400, a), (64, 99, 200, b)]).await;
    assert_eq!(
        range(&st, &sid, 300, 500, total).await.unwrap().as_ref(),
        &expected[300..501]
    );
    assert_eq!(
        range(&st, &sid, 0, total - 1, total)
            .await
            .unwrap()
            .as_ref(),
        expected
    );
}

#[tokio::test]
async fn missing_offsets_empty_articles_and_truncated_tail_fail_without_wrong_bytes() {
    for (pieces, start, end) in [
        (vec![(10, vec![1; 10])], 0, 5), // first article starts after requested data
        (vec![(0, vec![1; 10]), (20, vec![2; 10])], 15, 19), // hole between articles
        (vec![(0, vec![1; 10]), (20, vec![2; 10])], 0, 29), // sequential path reaches hole
        (vec![(0, vec![1; 10])], 0, 19), // declared file longer than final article
        (vec![(0, Vec::new())], 0, 5),
        (vec![(20, vec![2; 10]), (0, vec![1; 10])], 10, 19), // inconsistent order
        (Vec::new(), 0, 5),
    ] {
        let (st, sid, total) = fixture(vec![(10, 0, 30, pieces)]).await;
        assert!(
            range(&st, &sid, start, end, total).await.is_err(),
            "invalid layout must terminate with an error"
        );
    }
}

#[tokio::test]
async fn overlapping_article_is_trimmed_to_the_exact_requested_offset() {
    let data: Vec<u8> = (0..30).collect();
    let pieces = vec![(0, data[..20].to_vec()), (10, data[10..].to_vec())];
    let (st, sid, total) = fixture(vec![(20, 0, 30, pieces)]).await;
    assert_eq!(range(&st, &sid, 0, 29, total).await.unwrap().as_ref(), data);
    assert_eq!(
        range(&st, &sid, 22, 29, total).await.unwrap().as_ref(),
        &data[22..]
    );
}

#[tokio::test]
async fn overflowing_article_and_volume_offsets_fail_without_panicking() {
    for (data_start, pieces) in [
        (0, vec![(u64::MAX - 2, vec![1; 10])]),
        (u64::MAX - 5, vec![(u64::MAX - 5, vec![1; 10])]),
    ] {
        let (st, sid, total) = fixture(vec![(10, data_start, 10, pieces)]).await;
        assert!(range(&st, &sid, 0, 9, total).await.is_err());
    }
}
