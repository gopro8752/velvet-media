package tv.velvet.data.streams

import org.junit.Assert.*
import org.junit.Test

class DisplayHdrPolicyTest {
    private val samsungPath = DisplayHdrPolicy(hdr10 = true)
    private val dolbyPath = DisplayHdrPolicy(dolbyVision = true, hdr10 = true, hlg = true)

    @Test fun hdr10DisplayRejectsDolbyVisionIncludingAmbiguousMixedLabels() {
        listOf("Movie.2160p.DV.HEVC", "Movie.Dolby.Vision", "Movie.DoVi.HDR10",
            "Movie.2160p.DV.HDR.H265", "Movie.dvhe.HEVC").forEach {
            assertFalse(it, samsungPath.supportsRelease(it))
            assertTrue(it, dolbyPath.supportsRelease(it))
        }
    }

    @Test fun hdr10PlusKeepsItsHdr10BaseOnAnHdr10OnlyDisplay() {
        listOf("Movie.HDR10+", "Movie.HDR10Plus.HEVC", "Movie.HDR10P", "Movie.HDR", "Movie.HDR10").forEach {
            assertTrue(it, samsungPath.supportsRelease(it))
            assertFalse(it, DisplayHdrPolicy().supportsRelease(it))
        }
    }

    @Test fun sdrAndUnknownReleasesRemainAvailableWithoutHdrCapabilities() {
        listOf("Movie.2160p.SDR.10bit", "Movie.1080p.x264", "Adventure.2016.HEVC", "movie.unknown").forEach {
            assertTrue(it, DisplayHdrPolicy().supportsRelease(it))
        }
    }

    @Test fun hlgIsNotMistakenForHdr10() {
        assertFalse(samsungPath.supportsRelease("Movie.2160p.HLG"))
        assertTrue(dolbyPath.supportsRelease("Movie.2160p.HLG"))
        assertTrue(DisplayHdrPolicy(hdr10Plus = true).supportsRelease("Movie.HDR10"))
    }

    @Test fun actualDolbyFormatCatchesUntaggedSources() {
        assertFalse(samsungPath.supportsVideo("video/dolby-vision", null, false, false))
        assertFalse(samsungPath.supportsVideo("video/hevc", "dvhe.05.06", false, false))
        assertFalse(samsungPath.supportsVideo("video/hevc", "hvc1.1.6, DVH1.08.06", true, false))
        assertTrue(dolbyPath.supportsVideo("video/dolby-vision", "dvhe.05.06", true, false))
    }

    @Test fun actualHdrTransferRejectsUntaggedHdrOnSdrDisplay() {
        assertFalse(DisplayHdrPolicy().supportsVideo("video/hevc", "hvc1", true, false))
        assertTrue(samsungPath.supportsVideo("video/hevc", "hvc1", true, false))
        assertFalse(samsungPath.supportsVideo("video/hevc", "hvc1", false, true))
        assertTrue(dolbyPath.supportsVideo("video/hevc", "hvc1", false, true))
        assertTrue(DisplayHdrPolicy().supportsVideo("video/avc", "avc1", false, false))
    }

    @Test fun displayChangeReevaluatesPreviouslyUsableRelease() {
        val prefetched = listOf("Movie.2160p.DV.HDR", "Movie.2160p.HDR10+", "Movie.1080p.SDR")
        assertEquals(3, prefetched.filter(dolbyPath::supportsRelease).size)
        assertEquals(listOf("Movie.2160p.HDR10+", "Movie.1080p.SDR"), prefetched.filter(samsungPath::supportsRelease))
        assertEquals(listOf("Movie.1080p.SDR"), prefetched.filter(DisplayHdrPolicy()::supportsRelease))
    }

    @Test fun discoveredVideoCanBecomeCompatibleAfterHdmiCapabilitiesChange() {
        val mime = "video/dolby-vision"
        val codecs = "dvhe.05.06"
        assertFalse(samsungPath.supportsVideo(mime, codecs, true, false))
        assertTrue(dolbyPath.supportsVideo(mime, codecs, true, false))
        assertFalse(DisplayHdrPolicy().supportsVideo(mime, codecs, true, false))
    }
}
