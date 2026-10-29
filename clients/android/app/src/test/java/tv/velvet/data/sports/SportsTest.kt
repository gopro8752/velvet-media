package tv.velvet.data.sports

import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.live.*
import java.time.Instant

class SportsTest {
    private val now = Instant.parse("2026-10-12T00:00:00Z")
    @Test fun `embed policy accepts verified provider mirrors and Unicode team names only`() {
        assertTrue(isSafeEmbed("https://strmfree.st/embed/basketball/wizards-vs-cavaliers1080p"))
        assertTrue(isSafeEmbed("https://streamfree.top/embed/soccer/cf-montr%C3%A9al-vs-charlotte-fc"))
        assertTrue(isSafeEmbed("https://strmfree.st/embed/soccer/cf-montréal-vs-charlotte-fc"))
        listOf(
            "http://strmfree.st/embed/basketball/game", "https://strmfree.st:443/embed/basketball/game",
            "https://evil.strmfree.st/embed/basketball/game", "https://strmfree.st.evil.com/embed/basketball/game",
            "https://user:pass@strmfree.st/embed/basketball/game", "https://127.0.0.1/embed/basketball/game",
            "https://embed.st/embed/golf/2180/1", "https://strmfree.st/ad.html", "file:///embed/basketball/game",
            "https://strmfree.st/embed/basketball/..", "https://strmfree.st/embed/basketball/%2e%2e",
            "https://strmfree.st/embed/basketball/a%2fb", "https://strmfree.st/embed/basketball/a%252fb",
            "https://strmfree.st/embed/basketball/%FF", "https://strmfree.st/embed/basketball/game/",
            "https://strmfree.st/embed/basketball/game?redirect=https://ads.example", "https://strmfree.st/embed/basketball/game#redirect"
        ).forEach { assertFalse(it, isSafeEmbed(it)) }
    }
    @Test fun `only selected top level player may navigate or report playback`() {
        val embed = "https://strmfree.st/embed/basketball/wizards-vs-cavaliers1080p"
        assertTrue(isEmbedNavigationAllowed(embed, "$embed#player"))
        assertTrue(isSportsStartupFrameAllowed(embed, embed, true))
        assertFalse(isSportsStartupFrameAllowed(embed, embed, false))
        assertFalse(isEmbedNavigationAllowed(embed, "https://streamfree.top/embed/basketball/wizards-vs-cavaliers1080p"))
        assertFalse(isEmbedNavigationAllowed(embed, "https://strmfree.st/embed/basketball/wizards-vs-cavaliers1080p2"))
        assertFalse(isSportsStartupFrameAllowed(embed, "https://strmfree.st/ad.html", false))
        assertFalse(isEmbedNavigationAllowed(embed, "$embed?redirect=https://ads.example"))
        assertFalse(isEmbedNavigationAllowed("https://ads.example/embed/basketball/game", embed))
    }
    @Test fun `DNS recovery preserves the exact Unicode event and permits only one mirror`() {
        val original = "https://strmfree.st/embed/soccer/cf-montr%C3%A9al1080p"
        val recovery = SportsEmbedRecovery(original)
        val alternate = recovery.retryDnsFailure(original, true, false, 20_000)
        assertEquals("https://streamfree.top/embed/soccer/cf-montr%C3%A9al1080p", alternate)
        assertEquals(alternate, recovery.currentUrl)
        assertFalse(isSportsStartupFrameAllowed(recovery.currentUrl, original, true))
        assertTrue(isSportsStartupFrameAllowed(recovery.currentUrl, alternate!!, true))
        assertNull(recovery.retryDnsFailure(alternate, true, false, 15_000))
        val reverse = SportsEmbedRecovery(alternate)
        assertEquals(original, reverse.retryDnsFailure(alternate, true, false, 20_000))
    }
    @Test fun `DNS recovery never retries other failures documents or an expired startup`() {
        val original = "https://strmfree.st/embed/basketball/game1080p"
        val recovery = SportsEmbedRecovery(original)
        assertNull(recovery.retryDnsFailure(original, false, false, 20_000)) // TLS/network errors stay errors.
        assertNull(recovery.retryDnsFailure(original, true, true, 20_000)) // No hidden mid-game restarts.
        assertNull(recovery.retryDnsFailure(original, true, false, 1_000))
        assertNull(recovery.retryDnsFailure(null, true, false, 20_000))
        for (other in listOf("https://strmfree.st/ad.html", "https://strmfree.st/embed/basketball/game1080p2", "$original?next=ads"))
            assertNull(recovery.retryDnsFailure(other, true, false, 20_000))
        assertEquals(original, recovery.currentUrl)
        assertNotNull(recovery.retryDnsFailure(original, true, false, 20_000))
    }
    @Test fun `embed document requires official player origin without sandboxing it`() {
        val url = "https://strmfree.st/embed/basketball/wizards-vs-cavaliers1080p"
        val html = sportsEmbedDocument(url)
        assertTrue(html.contains("<iframe src=\"$url\""))
        assertTrue(html.contains("allowfullscreen"))
        assertFalse(html.contains("<script"))
        assertFalse(html.contains("sandbox"))
        assertThrows(IllegalArgumentException::class.java) { sportsEmbedDocument("https://example.com/embed/player") }
    }
    @Test fun `live and future classification does not invent a live flag from start time`() {
        val live = SportsEvent("live", "Team A vs Team B", "basketball", "Basketball", "2026-10-11T23:00:00Z", true)
        val future = live.copy(id = "future", title = "Team C vs Team D", startTime = "2026-10-12T01:00:00Z", isLive = false)
        val ended = live.copy(id = "past", isLive = false)
        assertEquals(listOf(future), filterSportsEvents(listOf(live, future, ended), "", null, true, now))
        assertEquals(listOf(live), filterSportsEvents(listOf(live, future), "team b", "basketball", false, now))
        assertTrue(filterSportsEvents(listOf(live), "", "football", false, now).isEmpty())
    }
    @Test fun `stream identity preserves different quality language and provider choices`() {
        val decoded = Json { ignoreUnknownKeys = true }.decodeFromString(SportsStreams.serializer(), """{"eventId":"match","message":null,"streams":[
            {"id":"2180","source":"streamfree","streamNo":1,"language":"English","hd":true,"embedUrl":"https://strmfree.st/embed/basketball/game1080p"},
            {"id":"2180","source":"streamfree","streamNo":2,"language":"Spanish","hd":false,"embedUrl":"https://strmfree.st/embed/basketball/game540p"}]}""")
        assertEquals(2, decoded.streams.distinctBy { it.key }.size)
        assertEquals("streamfree 2 · Spanish · SD", decoded.streams[1].label)
    }
    @Test fun `guide uses exclusive end inclusive start and never fills missing now with next`() {
        val previous = LiveProgram("past", "Previous", "2026-10-11T23:00:00Z", "2026-10-12T00:00:00Z")
        val current = LiveProgram("now", "Current", "2026-10-12T00:00:00Z", "2026-10-12T00:30:00Z")
        val next = LiveProgram("next", "Next", "2026-10-12T00:30:00Z", "2026-10-12T01:00:00Z")
        val invalid = current.copy(id = "bad", startTime = "bad")
        assertEquals(current to next, nowAndNext(listOf(next, previous, invalid, current), now))
        assertEquals(null to next, nowAndNext(listOf(previous, next), now))
        assertEquals(null to null, nowAndNext(emptyList(), now))
        assertEquals(listOf(previous, current, next), validPrograms(listOf(next, invalid, current, previous, current)))
    }
}
