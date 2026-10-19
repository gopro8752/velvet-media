package tv.velvet.data.launcher

import kotlinx.serialization.json.*
import tv.velvet.data.sports.SportsEvent
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.util.Locale
import kotlin.math.abs

internal val SportsDayZone: ZoneId get() = ZoneId.systemDefault()
internal val SupportedLeagues = mapOf("nba" to "basketball", "mlb" to "baseball", "nfl" to "football")
internal const val SportsStaleMs = 15 * 60_000L
internal fun sportsDay(now: Long, zone: ZoneId = SportsDayZone) = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
internal fun sportsInstant(value: String?) = value?.let { runCatching { OffsetDateTime.parse(it).toInstant() }.getOrNull() }
private fun JsonObject.text(key: String) = (get(key) as? JsonPrimitive)?.contentOrNull
private fun JsonObject.obj(key: String) = get(key) as? JsonObject
private fun JsonObject.array(key: String) = get(key) as? JsonArray ?: JsonArray(emptyList())

/** League + exact primary-source team ID defines identity; city names never select teams. */
internal fun parseSchedule(league: String, raw: String, now: Long, zone: ZoneId = SportsDayZone): List<LauncherGame> {
    require(league in SupportedLeagues)
    val root = Json.parseToJsonElement(raw).jsonObject
    val events = root["events"] as? JsonArray ?: error("Schedule response has no events")
    return events.take(200).mapNotNull { element -> runCatching {
        val event = element.jsonObject
        val eventId = event.text("id")?.takeIf { it.matches(Regex("[0-9]{1,20}")) } ?: return@runCatching null
        val competition = event.array("competitions").firstOrNull()?.jsonObject ?: return@runCatching null
        val start = sportsInstant(competition.text("date") ?: event.text("date")) ?: return@runCatching null
        val competitors = competition.array("competitors").mapNotNull { it as? JsonObject }
        val home = competitors.singleOrNull { it.text("homeAway") == "home" } ?: return@runCatching null
        val away = competitors.singleOrNull { it.text("homeAway") == "away" } ?: return@runCatching null
        val homeTeam = parseSportsTeam(league, home.obj("team") ?: return@runCatching null) ?: return@runCatching null
        val awayTeam = parseSportsTeam(league, away.obj("team") ?: return@runCatching null) ?: return@runCatching null
        if (homeTeam.key == awayTeam.key) return@runCatching null
        val statusObject = (competition.obj("status") ?: event.obj("status"))?.obj("type")
        val name = statusObject?.text("name").orEmpty()
        val status = when {
            name in setOf("STATUS_POSTPONED") -> "postponed"
            name in setOf("STATUS_CANCELED", "STATUS_CANCELLED") -> "canceled"
            name in setOf("STATUS_DELAYED", "STATUS_SUSPENDED", "STATUS_RAIN_DELAY") -> "delayed"
            statusObject?.text("completed") == "true" || statusObject?.text("state") == "post" -> "final"
            statusObject?.text("state") == "in" -> "live"
            statusObject?.text("state") == "pre" -> "scheduled"
            else -> "unknown"
        }
        val timeTbd = status == "scheduled" && competition.text("timeValid") == "false"
        LauncherGame("$league:$eventId", league, homeTeam, awayTeam, start.toString(), status,
            if (timeTbd) "Time TBD" else (statusObject?.text("shortDetail") ?: statusObject?.text("detail") ?: status).take(120),
            homeScore = home.text("score")?.take(12), awayScore = away.text("score")?.take(12),
            title = "${awayTeam.name} at ${homeTeam.name}", updatedAt = now)
    }.getOrNull() }.filter { it.isToday(now, zone) }.distinctBy { it.id }.sortedBy { it.startTime }.take(100)
}

private fun parseSportsTeam(league: String, team: JsonObject): LauncherSportsTeam? {
    val id = team.text("id")?.takeIf { it.matches(Regex("[0-9]{1,10}")) } ?: return null
    val name = team.text("displayName")?.takeIf { it.isNotBlank() }?.take(100) ?: return null
    val logo = team.text("logo") ?: (team.array("logos").firstOrNull() as? JsonObject)?.text("href")
    val safeLogo = logo?.takeIf { value -> runCatching {
        val uri = java.net.URI(value)
        uri.scheme == "https" && uri.host == "a.espncdn.com" && uri.userInfo == null && uri.query == null && uri.fragment == null
    }.getOrDefault(false) }
    val color = team.text("color")?.takeIf { it.matches(Regex("[0-9a-fA-F]{6}")) }?.let { "#$it" }
    return LauncherSportsTeam("$league:$id", league, id, name,
        (team.text("shortDisplayName") ?: team.text("name") ?: name).take(100),
        team.text("abbreviation").orEmpty().take(12), safeLogo, color)
}

private fun normalizeTeam(value: String): String = value.lowercase(Locale.ROOT).replace("&", " and ")
    .replace(Regex("[^\\p{L}\\p{N}]+"), " ").trim().replace(Regex("\\s+"), " ")
private fun LauncherSportsTeam.aliases() = listOf(name, shortName).map(::normalizeTeam).filter { it.length >= 4 }.toSet()
private fun String.containsTeam(team: LauncherSportsTeam) = team.aliases().any { " ${normalizeTeam(this)} ".contains(" $it ") }
private fun isSameTeam(value: String, team: LauncherSportsTeam) = normalizeTeam(value) in team.aliases()

/** Never join on Cleveland alone, just one opponent, or an unbounded old catalog entry. */
internal fun matchScheduledEvent(game: LauncherGame, events: List<SportsEvent>): SportsEvent? {
    if (game.status !in setOf("scheduled", "live", "delayed") || game.stale || game.statusDetail == "Time TBD") return null
    val scheduled = sportsInstant(game.startTime) ?: return null
    val sports = when (game.league) {
        "nba" -> setOf("basketball", "nba")
        "mlb" -> setOf("baseball", "mlb")
        "nfl" -> setOf("american-football", "american football", "football", "nfl")
        else -> return null
    }
    val candidates = events.asSequence().filter { it.sourceCount > 0 && it.sportId.lowercase(Locale.ROOT) in sports }
        .filter { event ->
            val pair = listOfNotNull(event.homeTeam?.name, event.awayTeam?.name)
            if (pair.size == 2) (isSameTeam(pair[0], game.homeTeam) && isSameTeam(pair[1], game.awayTeam)) ||
                (isSameTeam(pair[1], game.homeTeam) && isSameTeam(pair[0], game.awayTeam))
            else event.title.containsTeam(game.homeTeam) && event.title.containsTeam(game.awayTeam) &&
                !Regex("(?i)\\b(u[0-9]{2}|women|women's|summer league|g league)\\b").containsMatchIn(event.title)
        }
        .mapNotNull { event -> sportsInstant(event.startTime)?.let { event to abs(it.toEpochMilli() - scheduled.toEpochMilli()) } }
        .filter { it.second <= 2 * 60 * 60_000L }.sortedBy { it.second }.distinctBy { it.first.id }.toList()
    val best = candidates.firstOrNull() ?: return null
    // Two equally plausible broadcasts/doubleheaders should open selection, never an arbitrary game.
    if (candidates.getOrNull(1)?.let { it.second - best.second < 15 * 60_000L } == true) return null
    return best.first
}

internal fun publicTodayGames(games: List<LauncherGame>, now: Long, zone: ZoneId = SportsDayZone): List<LauncherGame> = games
    .filter { it.isToday(now, zone) }.distinctBy { it.id }.take(100).map { game ->
        val age = now - game.updatedAt
        val stale = game.stale || age !in 0..SportsStaleMs
        val expiredLive = stale && game.status in setOf("live", "delayed")
        game.copy(stale = stale, status = if (expiredLive) "unknown" else game.status,
            statusDetail = if (expiredLive) "Schedule not updated" else game.statusDetail,
            eventId = game.eventId.takeUnless { stale || age > 2 * 60_000L || game.status !in setOf("scheduled", "live", "delayed") })
    }.sortedWith(compareBy<LauncherGame> { when (it.status) { "live", "delayed" -> 0; "scheduled" -> 1; else -> 2 } }.thenBy { it.startTime })
