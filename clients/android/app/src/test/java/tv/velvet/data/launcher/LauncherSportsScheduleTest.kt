package tv.velvet.data.launcher

import org.junit.Assert.*
import org.junit.Test
import tv.velvet.data.sports.SportsEvent
import tv.velvet.data.sports.SportsTeam
import java.time.Instant
import java.time.ZoneId

class LauncherSportsScheduleTest {
    private val east = ZoneId.of("America/New_York")
    private val west = ZoneId.of("America/Los_Angeles")
    private val now = Instant.parse("2026-10-15T16:00:00Z").toEpochMilli()
    private fun fixture(league: String) = javaClass.getResource("/launcher-sports/$league-20261015.json")!!.readText()
    private fun guardians() = parseSchedule("mlb", fixture("mlb"), now, east).single { it.homeTeam.key == "mlb:5" }
    private fun event(game: LauncherGame, id: String = "rays-guardians", title: String = game.title,
                      start: String = game.startTime, sourceCount: Int = 1, sport: String = "baseball") = SportsEvent(
        id, title, sport, "Baseball", start, false, sourceCount = sourceCount)

    @Test fun `real league fixtures retain scheduled games independent of stream catalogs`() {
        val mlb = parseSchedule("mlb", fixture("mlb"), now, east)
        assertEquals(2, mlb.size)
        val game = guardians()
        assertEquals("mlb:401908025", game.id)
        assertEquals("Cleveland Guardians", game.homeTeam.name)
        assertEquals("Tampa Bay Rays", game.awayTeam.name)
        assertEquals("scheduled", game.status)
        assertNull(game.eventId)
        assertTrue(game.matchesTeams(setOf("mlb:5")))
        assertFalse(game.matchesTeams(setOf("nba:5", "nfl:5")))
        assertEquals(2, parseSchedule("nba", fixture("nba"), now, east).size) // Preseason survives.
        assertEquals(1, parseSchedule("nfl", fixture("nfl"), now, east).size)
        assertTrue(parseSchedule("mlb", fixture("mlb"), now + 86_400_000L, east).isEmpty())
    }

    @Test fun `postponed canceled final and time TBD preserve honest schedule state`() {
        val source = fixture("mlb")
        for ((name, status) in listOf("STATUS_POSTPONED" to "postponed", "STATUS_CANCELED" to "canceled")) {
            val game = parseSchedule("mlb", source.replace("STATUS_SCHEDULED", name), now, east).first()
            assertEquals(status, game.status)
            assertNull(matchScheduledEvent(game, listOf(event(game))))
        }
        assertEquals("final", parseSchedule("mlb", source.replace("\"completed\": false", "\"completed\": true"), now, east).first().status)
        val tbd = parseSchedule("mlb", source.replace("\"timeValid\": true", "\"timeValid\": false"), now, east).first()
        assertEquals("Time TBD", tbd.statusDetail)
        assertNull(matchScheduledEvent(tbd, listOf(event(tbd))))
    }

    @Test fun `device local day handles west coast midnight and DST without fixed offsets`() {
        val game = guardians().copy(startTime = "2026-10-16T06:30:00Z") // 11:30pm Los Angeles, next day in New York.
        val instant = Instant.parse("2026-10-15T19:00:00Z").toEpochMilli()
        assertTrue(game.isToday(instant, west))
        assertFalse(game.isToday(instant, east))
        val dst = game.copy(startTime = "2026-11-01T06:30:00Z") // Second 1:30am after fall-back.
        assertTrue(dst.isToday(Instant.parse("2026-11-01T17:00:00Z").toEpochMilli(), east))
        assertEquals("2026-10-15", sportsDay(Instant.parse("2026-10-16T03:30:00Z").toEpochMilli(), east).toString())
    }

    @Test fun `fresh live game may cross midnight but stale and finished games expire`() {
        val afterMidnight = Instant.parse("2026-10-16T04:30:00Z").toEpochMilli()
        val live = guardians().copy(startTime = "2026-10-16T02:00:00Z", status = "live", updatedAt = afterMidnight - 30_000)
        assertTrue(live.isToday(afterMidnight, east))
        assertFalse(live.copy(status = "final").isToday(afterMidnight, east))
        assertFalse(live.copy(updatedAt = afterMidnight - 16 * 60_000).isToday(afterMidnight, east))
        assertFalse(live.copy(startTime = "2026-10-15T13:00:00Z").isToday(afterMidnight, east))
        assertTrue(publicTodayGames(listOf(live.copy(status = "final")), afterMidnight, east).isEmpty())
    }

    @Test fun `stale live is unknown and expired stream match does not remove schedule`() {
        val original = guardians().copy(status = "live", eventId = "source-id")
        val expiredSource = publicTodayGames(listOf(original), now + 3 * 60_000, east).single()
        assertNull(expiredSource.eventId)
        assertFalse(expiredSource.stale)
        val old = publicTodayGames(listOf(original), now + 16 * 60_000, east).single()
        assertTrue(old.stale)
        assertEquals("unknown", old.status)
        assertNull(old.eventId)
        assertEquals(original.id, old.id)
    }

    @Test fun `exact opponents sport and nearby time required for stream join`() {
        val game = guardians()
        val matching = event(game)
        assertEquals(matching, matchScheduledEvent(game, listOf(matching)))
        assertNull(matchScheduledEvent(game, listOf(event(game, title = "Cleveland Cavaliers at Tampa Bay Rays"))))
        assertNull(matchScheduledEvent(game, listOf(event(game, title = "Cleveland State at Tampa Bay Rays"))))
        assertNull(matchScheduledEvent(game, listOf(event(game, title = "Guardians U21 vs Rays U21"))))
        assertNull(matchScheduledEvent(game, listOf(event(game, sport = "basketball"))))
        assertNull(matchScheduledEvent(game, listOf(event(game, start = "2026-10-14T17:00:00Z"))))
        assertNull(matchScheduledEvent(game, listOf(event(game, sourceCount = 0))))
        assertNull(matchScheduledEvent(game.copy(status = "final"), listOf(matching)))
        assertNull(matchScheduledEvent(game.copy(stale = true), listOf(matching)))
        assertNull(matchScheduledEvent(game.copy(statusDetail = "Time TBD"), listOf(matching)))
        val exactTeams = matching.copy(homeTeam = SportsTeam("Guardians"), awayTeam = SportsTeam("Rays"), title = "MLB Game")
        assertEquals(exactTeams, matchScheduledEvent(game, listOf(exactTeams)))
    }

    @Test fun `duplicates dedupe but ambiguous broadcasts open event selection`() {
        val game = guardians()
        val first = event(game)
        assertEquals(first, matchScheduledEvent(game, listOf(first, first)))
        assertNull(matchScheduledEvent(game, listOf(first, first.copy(id = "other-source"))))
        val secondGame = first.copy(id = "doubleheader-2", startTime = "2026-10-15T19:00:00Z")
        assertEquals(first, matchScheduledEvent(game, listOf(secondGame, first)))
        assertEquals(1, publicTodayGames(listOf(game, game), now, east).size)
    }

    @Test fun `missing upstream events is an error not a false no games result`() {
        assertThrows(Exception::class.java) { parseSchedule("nba", "{\"error\":\"unavailable\"}", now, east) }
        assertTrue(parseSchedule("nba", "{\"events\":[]}", now, east).isEmpty())
        assertThrows(Exception::class.java) { parseSchedule("not-a-league", fixture("nba"), now, east) }
    }

    @Test fun `sports deep links accept only schedule identities and map bounded league filters`() {
        assertNotNull(LauncherRequest.validated("game", null, gameId = "mlb:401908025"))
        for (invalid in listOf("https://example.com/embed", "mlb:../stream", "soccer:123", "nba:", "nba:abc")) {
            assertNull(LauncherRequest.validated("game", null, gameId = invalid))
        }
        assertNull(LauncherRequest.validated("home", null, gameId = "nba:1"))
        assertNull(LauncherRequest.validated("game", null))
        assertEquals("baseball", launcherSportsFilter("mlb"))
        assertEquals("basketball", launcherSportsFilter("nba"))
        assertEquals("american-football", launcherSportsFilter("nfl"))
        assertNull(launcherSportsFilter("anything"))
    }
}
