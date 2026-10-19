package tv.velvet.data.sports

import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.live.*
import java.time.Instant

class SportsTest {
    private val now = Instant.parse("2026-10-12T00:00:00Z")
    @Test fun `embed policy rejects popup destinations local origins and credential-bearing URLs`() {
        assertTrue(isSafeEmbed("https://embed.st/embed/golf/2180/1"))
        assertTrue(isSafeEmbed("https://embed.pk/embed/alpha/game/1"))
        listOf("http://embed.st/embed/a", "https://embed.st:443/embed/a", "https://evil.embed.st/embed/a", "https://embed.st.evil.com/embed/a",
            "https://user:pass@embed.st/embed/a", "https://127.0.0.1/embed/a", "intent://embed/a", "https://embed.st/ads", "file:///embed/a").forEach { assertFalse(it, isSafeEmbed(it)) }
        val embed = "https://embed.st/embed/golf/2180/1"
        assertTrue(isEmbedNavigationAllowed(embed, "$embed#player"))
        assertFalse(isEmbedNavigationAllowed(embed, "https://embed.st/embed/golf/other/1"))
        assertFalse(isEmbedNavigationAllowed(embed, "$embed?redirect=https://ads.example"))
    }
    @Test fun `startup messages only come from selected embed or intended Golf frame`() {
        val golf = "https://embed.st/embed/golf/2181/1"
        assertTrue(isSportsStartupFrameAllowed(golf, golf, true))
        assertFalse(isSportsStartupFrameAllowed(golf, "https://rockylive.st/source/streamed1.php?hd=531&id=2181&no=1", false))
        listOf("https://rockylive.st/ad.html", "https://rockylive.st:443/source/streamed1.php",
            "https://user@rockylive.st/source/streamed1.php", "https://rockylive.st.evil.com/source/streamed1.php",
            "http://rockylive.st/source/streamed1.php", "https://rockylive.st/source/other.php", "https://rockylive.st/source/streamed1.php?id=other&no=1",
            "https://rockylive.st/source/streamed1.php?id=2181&no=2", "https://rockylive.st/source/streamed1.php?id=2181&id=2181&no=1",
            "https://rockylive.st/source/streamed1.php?id=2181&no=1&no=2", "https://rockylive.st/source/streamed1.php?id=2181").forEach {
            assertFalse(it, isSportsStartupFrameAllowed(golf, it, false))
        }
        assertFalse(isSportsStartupFrameAllowed(golf, "https://embed.st/embed/golf/2181/2", true))
        assertFalse(isSportsStartupFrameAllowed("https://embed.st/embed/admin/match/1", "https://rockylive.st/source/streamed1.php", false))
    }
    @Test fun `only accepted Golf parent registers bounded exact visible ingest children`() {
        val golf = "https://embed.st/embed/golf/2181/2"
        val policy = SportsStartupFramePolicy(golf)
        val parent = "https://rockylive.st/source/streamed.php?hd=531&id=2181&no=1"
        val child = "https://embed.st/embed/ingest/streamedportlandtrailblazers/1"
        assertTrue(policy.mayWait(child, false))
        assertTrue(policy.mayWait("$child/", false))
        assertTrue(policy.mayWait("$child/#player=clappr&autoplay=true", false))
        assertFalse(policy.mayWait("$child/#redirect=elsewhere", false))
        assertFalse(policy.mayWait("$child//", false))
        assertFalse(policy.accepts(child, false))
        assertFalse(policy.register("https://rockylive.st/ad.html", false, child, 1280, 720))
        assertFalse(policy.register(parent.replace("no=1", "no=2"), false, child, 1280, 720))
        assertFalse(policy.register(parent, false, child, 1, 1))
        assertFalse(policy.register(parent, false, "$child?token=other", 1280, 720))
        assertFalse(policy.register(parent, false, child, 1280, 720))
        assertTrue(policy.mayWait(parent, false))
        assertTrue(policy.allowsFrameNavigation(parent))
        assertTrue(policy.allowsFrameNavigation(child))
        assertFalse(policy.allowsFrameNavigation("https://embed.st/ad.html"))
        assertFalse(policy.allowsFrameNavigation("https://ads.example/player"))
        assertFalse(policy.allowsFrameNavigation(parent.replace("id=2181", "id=other")))
        assertFalse(policy.accepts(parent, false))
        assertFalse(policy.register(golf, true, parent.replace("id=2181", "id=other"), 1280, 720))
        assertFalse(policy.register(golf, true, "$parent&no=2", 1280, 720))
        assertFalse(policy.register(golf, false, parent, 1280, 720))
        assertTrue(policy.register(golf, true, parent, 1280, 720))
        assertTrue(policy.accepts(parent, false))
        assertTrue(policy.register(parent, false, child, 1280, 720))
        assertTrue(policy.accepts(child, false))
        assertFalse(policy.register(child, false, "https://embed.st/embed/ingest/another/1", 1280, 720))
        for (i in 2..4) assertTrue(policy.register(parent, false, "https://embed.st/embed/ingest/item/$i", 1280, 720))
        assertFalse(policy.register(parent, false, "https://embed.st/embed/ingest/fifth/1", 1280, 720))
        policy.clear()
        assertFalse(policy.accepts(child, false))
    }
    @Test fun `embed document escapes attributes and requires official player origin`() {
        val html = sportsEmbedDocument("https://embed.st/embed/golf/2180/1?a=1&b=2")
        assertTrue(html.contains("<iframe src=\"https://embed.st/embed/golf/2180/1?a=1&amp;b=2\""))
        assertTrue(html.contains("allowfullscreen"))
        assertFalse(html.contains("<script"))
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
            {"id":"2180","source":"golf","streamNo":1,"language":"English","hd":true,"embedUrl":"https://embed.st/embed/golf/2180/1"},
            {"id":"2180","source":"golf","streamNo":2,"language":"Spanish","hd":false,"embedUrl":"https://embed.st/embed/golf/2180/2"}]}""")
        assertEquals(2, decoded.streams.distinctBy { it.key }.size)
        assertEquals("golf 2 · Spanish · SD", decoded.streams[1].label)
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
