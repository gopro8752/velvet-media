package tv.velvet.data.live

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class LiveTimelineTest {
    private val start = Instant.parse("2026-10-19T12:00:00Z")
    private val end = start.plusSeconds(7200)
    private fun program(id: String, from: Long, to: Long, title: String = id) =
        LiveProgram(id, title, start.plusSeconds(from).toString(), start.plusSeconds(to).toString())

    @Test fun rowsShareExactAxisWithClippedProgramsAndHonestGaps() {
        val slots = liveGuideSlots(listOf(program("before", -1800, 900), program("later", 1800, 10800)), start, end)
        assertEquals(listOf("before", null, "later"), slots.map { it.program?.id })
        assertEquals(start, slots.first().start)
        assertEquals(end, slots.last().end)
        assertEquals(7200L, slots.sumOf { it.seconds })
        slots.zipWithNext().forEach { (a, b) -> assertEquals(a.end, b.start) }
    }

    @Test fun invalidAndOverlappingListingsCannotDistortTimeWidths() {
        val slots = liveGuideSlots(listOf(program("one", 0, 3600), program("overlap", 1800, 5400),
            program("bad", 7200, 0), program("one", 0, 3600), LiveProgram("malformed", "Bad", "?", "?")), start, end)
        assertEquals(7200L, slots.sumOf { it.seconds })
        assertEquals(listOf("one", "overlap", null), slots.map { it.program?.id })
        assertEquals(start.plusSeconds(3600), slots[1].start)
        assertTrue(slots.all { it.seconds > 0 })
    }

    @Test fun verticalNavigationPreservesTimeAcrossDifferentProgramDurations() {
        val row = liveGuideSlots(listOf(program("short", 0, 900), program("long", 900, 7200)), start, end)
        assertEquals(1, liveGuideSlotIndex(row, start.plusSeconds(1800)))
        assertEquals(1, liveGuideSlotIndex(row, start.plusSeconds(900)))
        assertEquals(0, liveGuideSlotIndex(row, start.minusSeconds(1)))
        assertEquals(1, liveGuideSlotIndex(row, end))
    }

    @Test fun emptyScheduleStillHasAWatchableWholeWindow() {
        val row = liveGuideSlots(emptyList(), start, end)
        assertEquals(1, row.size); assertNull(row[0].program); assertEquals(7200L, row[0].seconds)
        assertTrue(liveGuideSlots(emptyList(), end, start).isEmpty())
    }

    @Test fun searchFindsUpcomingShowsButNotExpiredProgramsAndHonorsFavorites() {
        val channel = LiveChannel("a", "Station", "54")
        val other = LiveChannel("b", "Network")
        val guide = mapOf("a" to listOf(program("new", 1800, 3600, "Family Guy")), "b" to listOf(program("old", -3600, -1, "Family Guy")))
        assertEquals(listOf(channel), filterGuideChannels(listOf(channel, other), guide, " family guy ", emptySet(), false, start))
        assertEquals(emptyList<LiveChannel>(), filterGuideChannels(listOf(channel, other), guide, "family", setOf("b"), true, start))
        assertEquals(listOf(channel), filterGuideChannels(listOf(channel, other), guide, "54", setOf("a"), true, start))
    }

    @Test fun windowUsesLocalHalfHourIncludingQuarterHourTimezones() {
        assertEquals(Instant.parse("2026-10-19T11:45:00Z"), liveGuideWindowStart(start, ZoneId.of("Asia/Kathmandu")))
        assertEquals(start, liveGuideWindowStart(start.plusSeconds(899), ZoneId.of("UTC")))
    }
}
