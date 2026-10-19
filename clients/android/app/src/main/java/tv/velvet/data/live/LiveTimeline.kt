package tv.velvet.data.live

import java.time.Duration
import java.time.Instant
import java.time.ZoneId

/** A gap is an honest, selectable channel cell, never a fabricated broadcast. */
data class LiveGuideSlot(val start: Instant, val end: Instant, val program: LiveProgram?) {
    val key: String get() = program?.id ?: "gap:$start"
    val seconds: Long get() = Duration.between(start, end).seconds
    fun contains(time: Instant) = !time.isBefore(start) && time.isBefore(end)
}

fun liveGuideWindowStart(now: Instant, zone: ZoneId = ZoneId.systemDefault()): Instant {
    val local = now.atZone(zone)
    return local.withMinute(local.minute / 30 * 30).withSecond(0).withNano(0).toInstant()
}

/** Clip, de-overlap, and fill each row to exactly the same time axis. */
fun liveGuideSlots(programs: List<LiveProgram>, start: Instant, end: Instant): List<LiveGuideSlot> {
    if (!end.isAfter(start)) return emptyList()
    val slots = mutableListOf<LiveGuideSlot>()
    var cursor = start
    for (program in validPrograms(programs)) {
        val begin = Instant.parse(program.startTime).coerceAtLeast(start)
        val finish = Instant.parse(program.endTime).coerceAtMost(end)
        if (!finish.isAfter(cursor) || !begin.isBefore(end)) continue
        if (begin.isAfter(cursor)) slots += LiveGuideSlot(cursor, begin, null)
        val clipped = begin.coerceAtLeast(cursor)
        if (finish.isAfter(clipped)) slots += LiveGuideSlot(clipped, finish, program)
        cursor = finish
        if (!cursor.isBefore(end)) break
    }
    if (cursor.isBefore(end)) slots += LiveGuideSlot(cursor, end, null)
    return slots
}

fun liveGuideSlotIndex(slots: List<LiveGuideSlot>, anchor: Instant): Int =
    slots.indexOfFirst { it.contains(anchor) }.takeIf { it >= 0 }
        ?: if (slots.isNotEmpty() && anchor >= slots.last().end) slots.lastIndex else 0

fun filterGuideChannels(channels: List<LiveChannel>, schedules: Map<String, List<LiveProgram>>,
    query: String, favorites: Set<String>, favoritesOnly: Boolean, now: Instant): List<LiveChannel> {
    val term = query.trim()
    return channels.filter { channel ->
        (!favoritesOnly || channel.id in favorites) && (term.isEmpty() ||
            filterLiveChannels(listOf(channel), term, false).isNotEmpty() ||
            validPrograms(schedules[channel.id].orEmpty()).any {
                Instant.parse(it.endTime).isAfter(now) &&
                    (it.title.contains(term, true) || it.episodeTitle?.contains(term, true) == true)
            })
    }
}
