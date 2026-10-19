package tv.velvet.data.live

import kotlinx.serialization.Serializable
import java.time.Instant

@Serializable data class LiveProgram(val id: String, val title: String, val startTime: String, val endTime: String,
    val description: String? = null, val episodeTitle: String? = null)
@Serializable data class LiveGuideChannel(val channelId: String, val programs: List<LiveProgram> = emptyList())
@Serializable data class LiveGuide(val enabled: Boolean = false, val sourceName: String = "Spectrum", val updatedAt: String? = null,
    val channels: List<LiveGuideChannel> = emptyList(), val message: String? = null)
fun validPrograms(programs: List<LiveProgram>): List<LiveProgram> = programs.filter {
    runCatching { it.title.isNotBlank() && Instant.parse(it.endTime).isAfter(Instant.parse(it.startTime)) }.getOrDefault(false)
}.distinctBy { it.id }.sortedBy { Instant.parse(it.startTime) }
fun nowAndNext(programs: List<LiveProgram>, now: Instant): Pair<LiveProgram?, LiveProgram?> {
    val valid = validPrograms(programs)
    val current = valid.firstOrNull { !Instant.parse(it.startTime).isAfter(now) && Instant.parse(it.endTime).isAfter(now) }
    val next = valid.firstOrNull { Instant.parse(it.startTime).isAfter(now) }
    return current to next
}
