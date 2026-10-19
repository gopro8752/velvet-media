package tv.velvet.data.live

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Util
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class LiveTest {
    private val news = LiveChannel("station:news", "Local News", "4", group = "Local")
    private val sports = LiveChannel("station:sports", "Sports Network", "12", group = "Sports")
    private val sports2 = LiveChannel("station:sports2", "Sports Network", "13", group = "Sports")

    @Test fun channelCatalogKeepsOpaqueIdentityAndProviderOrder() {
        val catalog = LiveCatalog(true, "Bridge", listOf(news, sports, sports2, sports, news.copy(id = ""))).validated()
        val restored = Json.decodeFromString(LiveCatalog.serializer(), Json.encodeToString(LiveCatalog.serializer(), catalog))
        assertEquals(listOf(news, sports, sports2), restored.channels)
        assertEquals(sports, adjacentLiveChannel(restored.channels, news.id, 1))
        assertEquals(sports2, adjacentLiveChannel(restored.channels, news.id, -1))
        assertEquals(news, adjacentLiveChannel(restored.channels, sports2.id, 1))
        assertNull(adjacentLiveChannel(restored.channels, "removed", 1))
        assertNull(adjacentLiveChannel(listOf(news), news.id, 1))
        assertNull(adjacentLiveChannel(emptyList(), news.id, 1))
    }

    @Test fun searchAndSportsFilterDoNotInventGuideOrEntitlements() {
        val channels = listOf(news, sports, sports2)
        assertEquals(listOf(sports, sports2), filterLiveChannels(channels, "", true))
        assertEquals(listOf(sports), filterLiveChannels(channels, " 12 ", true))
        assertEquals(listOf(news), filterLiveChannels(channels, "LOCAL", false))
        assertEquals(emptyList<LiveChannel>(), filterLiveChannels(channels, "Local", true))
        assertFalse(sports.copy(group = null).isSports)
    }

    @Test fun playbackCapabilityUsesConfiguredPublicOriginWithoutCredentials() {
        val base = "https://velvet.example.net".toHttpUrl()
        assertEquals("https://velvet.example.net/live/streams/capability/index.m3u8",
            livePlaybackUrl(base, "/live/streams/capability/index.m3u8").toString())
        val local = "http://192.168.50.10:8800".toHttpUrl()
        assertEquals(8800, livePlaybackUrl(local, "/live/streams/session/index.m3u8").port)
        listOf("https://other.example/live/streams/key/index.m3u8", "//other.example/live/streams/key",
            "/stream/vod", "/live/streams/../../admin", "/live/streams/key/index.m3u8#fragment").forEach { bad ->
            assertTrue("Reject $bad", runCatching { livePlaybackUrl(base, bad) }.isFailure)
        }
    }

    @Test fun tuningContractDecodesExplicitLiveOnlyCapabilities() {
        val response = Json.decodeFromString(TuneResponse.serializer(), """{
            "sessionId":"opaque", "playbackPath":"/live/streams/opaque/index.m3u8",
            "mimeType":"application/vnd.apple.mpegurl", "channel":{"id":"station:news","name":"Local News"},
            "canPause":false,"canSeek":false
        }""")
        assertEquals(news.id, response.channel.id)
        assertFalse(response.canPause)
        assertFalse(response.canSeek)
        assertNull(response.drm)
        assertNull(liveWidevine("https://velvet.example.net".toHttpUrl(), response.drm, response.sessionId, response.playbackPath))
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    @Test fun bothWireHlsMimeTypesSelectMedia3HlsInsteadOfProgressiveExtraction() {
        val response = Json.decodeFromString(TuneResponse.serializer(), """{
            "sessionId":"opaque", "playbackPath":"/live/streams/opaque/index.m3u8",
            "mimeType":"application/vnd.apple.mpegurl", "channel":{"id":"station:news","name":"Local News"}
        }""")
        // With an explicit MIME, Media3 does not use the URL suffix; the Apple alias caused TYPE_OTHER.
        assertEquals(C.CONTENT_TYPE_OTHER, Util.inferContentTypeForUriAndMimeType(Uri.EMPTY, response.mimeType))
        listOf(response.mimeType, MimeTypes.APPLICATION_M3U8).forEach { wireMime ->
            assertEquals(C.CONTENT_TYPE_HLS, Util.inferContentTypeForUriAndMimeType(Uri.EMPTY, livePlayerMimeType(wireMime)))
        }
        assertThrows(IllegalArgumentException::class.java) { livePlayerMimeType("video/mp4") }
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    @Test fun protectedDashUsesOnlyTheBackendsExpiringWidevineLicenseRelay() {
        val response = Json.decodeFromString(TuneResponse.serializer(), """{
            "sessionId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "playbackPath":"/live/streams/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/manifest.mpd",
            "mimeType":"application/dash+xml", "channel":{"id":"station:news","name":"Local News"},
            "drm":{"scheme":"widevine","licensePath":"/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","multiSession":true}
        }""")
        val base = "https://velvet.example.net:8443".toHttpUrl()
        assertEquals(C.CONTENT_TYPE_DASH, Util.inferContentTypeForUriAndMimeType(Uri.EMPTY, livePlayerMimeType(response.mimeType)))
        assertEquals("https://velvet.example.net:8443/live/streams/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/manifest.mpd", livePlaybackUrl(base, response.playbackPath).toString())
        val drm = liveWidevine(base, response.drm, response.sessionId, response.playbackPath)!!
        assertEquals("https://velvet.example.net:8443/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", drm.licenseUrl)
        assertTrue(drm.multiSession)
        val defaultRotation = Json.decodeFromString(LiveDrmResponse.serializer(), """{"scheme":"widevine","licensePath":"/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}""")
        assertFalse(liveWidevine(base, defaultRotation, response.sessionId, response.playbackPath)!!.multiSession)
    }

    @Test fun licenseDescriptorsCannotSendDeviceChallengesToForeignOrUnscopedEndpoints() {
        val base = "https://velvet.example.net".toHttpUrl()
        for (path in listOf("https://provider.example/license", "//provider.example/license", "/admin", "/live/drm/short",
            "/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa?token=secret", "/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#fragment", "/live/drm/../1234567890abcdef",
            "/live/drm/%2e%2e%2f1234567890abcdef", "/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/extra", "/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\extra",
            "/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ", "/live/drm/" + "a".repeat(257))) {
            assertThrows("Reject $path", IllegalArgumentException::class.java) { liveWidevine(base, LiveDrmResponse("widevine", path), "a".repeat(48), "/live/streams/" + "a".repeat(48) + "/manifest.mpd") }
        }
        for (scheme in listOf("fairplay", "playready", "clearkey", "", "WIDEVINE")) {
            assertThrows(IllegalArgumentException::class.java) { liveWidevine(base, LiveDrmResponse(scheme, "/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "a".repeat(48), "/live/streams/" + "a".repeat(48) + "/manifest.mpd") }
        }
        assertThrows(IllegalArgumentException::class.java) {
            liveWidevine("https://user:password@velvet.example.net".toHttpUrl(), LiveDrmResponse("widevine", "/live/drm/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "a".repeat(48), "/live/streams/" + "a".repeat(48) + "/manifest.mpd")
        }
    }

    @Test fun protectedMediaAndLicenseCannotBorrowAnotherSessionsCapabilities() {
        val base = "https://velvet.example.net".toHttpUrl()
        val session = "a".repeat(48)
        val other = "b".repeat(48)
        val drm = LiveDrmResponse("widevine", "/live/drm/$session")
        for (path in listOf("/live/streams/$other/manifest.mpd", "/live/streams/$session/../$other/manifest.mpd",
            "/live/streams/$session/manifest.mpd?session=$other", "/live/streams/$session/%2e%2e/manifest.mpd")) {
            assertThrows(IllegalArgumentException::class.java) { liveWidevine(base, drm, session, path) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            liveWidevine(base, drm.copy(licensePath = "/live/drm/$other"), session, "/live/streams/$session/manifest.mpd")
        }
        assertNotNull(liveWidevine(base, drm, session, "/live/streams/$session/index.m3u8"))
    }

    @Test fun reconnectsAreBoundedUntilPlaybackIsHealthyOrUserRetries() {
        val budget = LiveReconnectBudget()
        assertTrue(budget.take()); assertTrue(budget.take()); assertFalse(budget.take())
        repeat(10) { assertFalse(budget.take()) }
        budget.reset()
        assertTrue(budget.take()); assertTrue(budget.take()); assertFalse(budget.take())
    }

    @Test fun lateTuneCannotReplaceCurrentChannelAndEveryKnownSessionIsReleased() = runBlocking {
        val service = FakeLiveService()
        val controller = LiveSessionController(service, Dispatchers.Unconfined)
        val played = mutableListOf<String>()
        controller.tune(news.id, { played += it.id }, { fail(it.message) })
        controller.tune(sports.id, { played += it.id }, { fail(it.message) })
        service.requests[0].complete(session("old", news))
        assertEquals(listOf("old"), service.released)
        assertTrue(played.isEmpty())
        service.requests[1].complete(session("current", sports))
        assertEquals(listOf("current"), played)
        assertEquals("current", controller.active?.id)
        controller.close(); controller.close()
        assertEquals(listOf("old", "current"), service.released)
        controller.tune(news.id, { fail("Closed controller played") }, { fail("Closed controller errored") })
        assertEquals(2, service.requests.size)
    }

    @Test fun leavingDuringTuneRevokesReturnedSessionWithoutPlaybackCallback() = runBlocking {
        val service = FakeLiveService()
        val controller = LiveSessionController(service, Dispatchers.Unconfined)
        controller.tune(news.id, { fail("Playback after exit") }, { fail("Error after exit") })
        controller.close()
        service.requests.single().complete(session("abandoned", news))
        assertEquals(listOf("abandoned"), service.released)
        assertNull(controller.active)
    }

    @Test fun stoppingReleasesCurrentSessionAndResumeGetsFreshIdentity() = runBlocking {
        val service = FakeLiveService()
        val controller = LiveSessionController(service, Dispatchers.Unconfined)
        controller.tune(news.id, {}, { fail(it.message) })
        service.requests[0].complete(session("first", news))
        controller.stop()
        assertNull(controller.active)
        assertEquals(listOf("first"), service.released)
        controller.tune(news.id, {}, { fail(it.message) })
        service.requests[1].complete(session("resumed", news))
        assertEquals("resumed", controller.active?.id)
        controller.close()
        assertEquals(listOf("first", "resumed"), service.released)
    }

    private fun session(id: String, channel: LiveChannel) = LiveSession(id, channel,
        "https://velvet.example/live/streams/$id/index.m3u8", "application/vnd.apple.mpegurl",
        "https://velvet.example/live/sessions/$id", null)

    private class FakeLiveService : LiveService {
        val requests = mutableListOf<CompletableDeferred<LiveSession>>()
        val released = mutableListOf<String>()
        override suspend fun tune(channelId: String): LiveSession = CompletableDeferred<LiveSession>()
            .also { requests += it }.await()
        override suspend fun release(session: LiveSession) { released += session.id }
    }
}
