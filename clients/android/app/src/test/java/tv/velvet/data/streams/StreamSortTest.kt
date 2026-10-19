package tv.velvet.data.streams

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tv.velvet.data.model.StreamOption

/**
 * Regression tests for the real-quality stream ordering, mirroring velvet-backend's
 * release.rs `best_quality_wins_the_sort` test — the backend's cmp_streams was ported
 * FROM this app and now pre-warms whatever this order puts first, so the two sides
 * must keep agreeing on "best" or the pre-warm warms the wrong file.
 *
 * Exercises [StreamRepositoryImpl.streamComparator] directly: it is the exact
 * production comparator (sortStreams delegates to it), pure, and free of Android
 * plumbing — no Context/DataStore needed to pin the ordering down.
 */
class StreamSortTest {

    /** Minimal StreamOption: quality is what parseQuality would read off the title. */
    private fun stream(title: String, quality: String?, sizeGb: Long) = StreamOption(
        url = "http://example/$title",
        title = title,
        quality = quality,
        sizeBytes = sizeGb * 1_073_741_824L,
        sourceName = "test",
    )

    // The backend regression cast, byte-for-byte titles:
    private val doviRemux =
        stream("Movie.2026.2160p.UHD.BluRay.REMUX.DV.HDR10.TrueHD.Atmos.7.1-FraMeSToR", "2160p", 60)
    private val bigHdr10 =
        stream("Movie.2026.2160p.WEB-DL.HDR10.DDP5.1.HEVC-BLOAT", "2160p", 90)
    private val dtsHdEncode =
        stream("Movie.2026.2160p.BluRay.HDR10.DTS-HD.MA.5.1.x265-GRP", "2160p", 70)
    private val plainEncode =
        stream("Movie.2026.2160p.WEB-DL.HEVC-PLAIN", "2160p", 50)
    private val fullHdRemux =
        stream("Movie.2026.1080p.BluRay.REMUX.TrueHD.Atmos-GRP", "1080p", 30)
    private val threeD =
        stream("Movie.2026.2160p.3D.SBS.BluRay.TrueHD-X", "2160p", 80)

    private fun sort(vararg streams: StreamOption): List<StreamOption> =
        streams.toList().sortedWith(StreamRepositoryImpl.streamComparator("2160p"))

    @Test
    fun bestQualityWinsTheSort() {
        // The exact complaint the hierarchy fixes: a BIGGER plain-HDR10 encode must NOT
        // outrank a DoVi TrueHD remux, and remux beats re-encode.
        val sorted = sort(bigHdr10, fullHdRemux, doviRemux, dtsHdEncode, plainEncode)
        assertEquals(doviRemux, sorted[0])   // remux + DV + TrueHD Atmos wins outright
        assertEquals(dtsHdEncode, sorted[1]) // then better audio among the 4K encodes
        assertEquals(bigHdr10, sorted[2])    // sheer size no longer buys the top slot
        assertEquals(plainEncode, sorted[3]) // nothing-better encode trails every HDR one
        assertEquals(fullHdRemux, sorted[4]) // resolution still trumps everything below 4K
    }

    @Test
    fun threeDSinksBelowEverything2D() {
        // Even a tiny 1080p AAC web encode beats a 4K TrueHD release that plays as two
        // squished half-frames on a normal screen.
        val tiny = stream("Movie.1080p.WEB.AAC-Y", "1080p", 2)
        assertEquals(listOf(tiny, threeD), sort(threeD, tiny))
    }

    @Test
    fun sizeIsOnlyATiebreaker() {
        // Identical tags — only now may the bigger file win.
        val big = stream("Movie.2026.2160p.WEB-DL.HDR10.DDP5.1.HEVC-A", "2160p", 40)
        val small = stream("Movie.2026.2160p.WEB-DL.HDR10.DDP5.1.HEVC-B", "2160p", 20)
        assertEquals(listOf(big, small), sort(small, big))
    }

    // ---- rank helpers (StreamTags) — pinned against release.rs's tables ----

    @Test
    fun hdrRankLadder() {
        // DV leads even with HDR10 alongside (a DoVi release carries an HDR10 base layer).
        assertEquals(3, StreamTags.hdrRank("Movie.2160p.DV.HDR10.HEVC"))
        assertEquals(3, StreamTags.hdrRank("Movie.2160p.DoVi.HEVC"))
        assertEquals(3, StreamTags.hdrRank("Movie.2160p.Dolby.Vision.HEVC"))
        assertEquals(2, StreamTags.hdrRank("Movie.2160p.HDR10+.HEVC"))
        assertEquals(2, StreamTags.hdrRank("Movie.2160p.HDR10Plus.HEVC"))
        assertEquals(1, StreamTags.hdrRank("Movie.2160p.HDR10.HEVC"))
        assertEquals(1, StreamTags.hdrRank("Movie.2160p.HDR.HEVC"))
        assertEquals(0, StreamTags.hdrRank("Movie.2160p.SDR.HEVC"))
        assertEquals(0, StreamTags.hdrRank("Movie.2160p.HEVC"))
        // "dv" must not fire inside "dvd".
        assertEquals(0, StreamTags.hdrRank("Movie.DVDRip.XviD"))
    }

    @Test
    fun audioRankLadder() {
        assertEquals(7, StreamTags.audioRank("Movie.REMUX.TrueHD.7.1.Atmos-GRP"))
        assertEquals(6, StreamTags.audioRank("Movie.BluRay.DTS-X.7.1-GRP"))
        assertEquals(5, StreamTags.audioRank("Movie.REMUX.TrueHD.5.1-GRP"))
        assertEquals(4, StreamTags.audioRank("Movie.BluRay.DTS-HD.MA.5.1-GRP"))
        // EAC3 Atmos (no TrueHD): Atmos alone outranks plain DTS and DD+.
        assertEquals(3, StreamTags.audioRank("Movie.WEB-DL.DDP5.1.Atmos-GRP"))
        assertEquals(2, StreamTags.audioRank("Movie.BluRay.DTS.5.1-GRP"))
        assertEquals(1, StreamTags.audioRank("Movie.WEB-DL.DDP5.1-GRP"))
        assertEquals(1, StreamTags.audioRank("Movie.WEB-DL.DD5.1-GRP"))
        assertEquals(0, StreamTags.audioRank("Movie.WEB.AAC2.0-GRP"))
        assertEquals(0, StreamTags.audioRank("Movie.WEB.NoAudioTag-GRP"))
    }

    @Test
    fun remuxDetection() {
        assertTrue(StreamTags.isRemux("Movie.2160p.UHD.BluRay.REMUX.DV-GRP"))
        assertTrue(StreamTags.isRemux("Movie.1080p.Remux.AVC.TrueHD-GRP"))
        assertFalse(StreamTags.isRemux("Movie.2160p.WEB-DL.HEVC-GRP"))
        // Boundary-aware: no firing inside a longer word.
        assertFalse(StreamTags.isRemux("Movie.Premuxed.Nonsense"))
    }
}
