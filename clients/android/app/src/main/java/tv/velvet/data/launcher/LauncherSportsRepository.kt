package tv.velvet.data.launcher

import tv.velvet.BuildConfig

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import tv.velvet.data.net.await
import tv.velvet.data.sports.SportsRepository
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private val Context.sportsScheduleStore by preferencesDataStore("launcher_sports_schedule")
@Serializable
internal data class SportsScheduleCache(
    val day: String = "", val games: List<LauncherGame> = emptyList(), val updatedAt: Long = 0,
    val attemptedAt: Long = 0, val failedLeagues: Set<String> = emptySet(),
)
internal data class LauncherSportsSnapshot(val games: List<LauncherGame>, val updatedAt: Long, val unavailable: Boolean)

/** Public ESPN schedule, independent of stream availability. A provider read never waits for HTTP. */
class LauncherSportsRepository(private val context: Context, client: OkHttpClient, private val streams: SportsRepository) {
    private val client = client.newBuilder().callTimeout(12, TimeUnit.SECONDS).readTimeout(10, TimeUnit.SECONDS).build()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val refreshing = AtomicBoolean(false)
    private val json = Json { ignoreUnknownKeys = true }
    private val key = stringPreferencesKey("scoreboards_v1")
    private suspend fun cached(): SportsScheduleCache = context.sportsScheduleStore.data.first()[key]?.let {
        runCatching { json.decodeFromString(SportsScheduleCache.serializer(), it) }.getOrNull()
    } ?: SportsScheduleCache()

    internal suspend fun snapshot(now: Long = System.currentTimeMillis()): LauncherSportsSnapshot {
        refreshIfNeeded()
        // A schedule cache failure must never hide the viewer's library rails.
        val cached = try { withTimeoutOrNull(350) { cached() } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { null }
            ?: return LauncherSportsSnapshot(emptyList(), 0, true)
        val unattempted = cached.updatedAt == 0L && cached.attemptedAt == 0L && cached.failedLeagues.isEmpty()
        return LauncherSportsSnapshot(publicTodayGames(cached.games, now), cached.updatedAt,
            !unattempted && (cached.day != sportsDay(now).toString() || cached.failedLeagues.isNotEmpty() || cached.updatedAt == 0L))
    }

    /** Only cached, same-day, fresh, available events may bypass the selection screen. */
    internal suspend fun resolve(gameId: String): LauncherGame? {
        val cached = cached()
        val now = System.currentTimeMillis()
        return publicTodayGames(cached.games, now).firstOrNull { it.id == gameId }
            ?: cached.games.firstOrNull { it.id == gameId }?.copy(eventId = null, stale = true)
    }

    private fun refreshIfNeeded() {
        if (!refreshing.compareAndSet(false, true)) return
        scope.launch {
            try {
                val now = System.currentTimeMillis()
                val previous = cached()
                val sameDay = previous.day == sportsDay(now).toString()
                val activeWindow = previous.games.any { game -> game.isToday(now) &&
                    (game.status in setOf("live", "delayed") || (game.status == "scheduled" &&
                        sportsInstant(game.startTime)?.let { kotlin.math.abs(it.toEpochMilli() - now) <= 90 * 60_000L } == true)) }
                val interval = if (activeWindow || previous.failedLeagues.isNotEmpty()) 60_000L else 5 * 60_000L
                if (sameDay && now - previous.attemptedAt in 0 until interval) return@launch
                val formatter = DateTimeFormatter.BASIC_ISO_DATE
                val dates = (-1L..1L).map { formatter.format(sportsDay(now).plusDays(it)) }
                // ESPN rejects date ranges for some leagues. Three individual days
                // cover device-local midnight; leagues run in parallel, dates serially
                // so there are never more than three schedule requests in flight.
                val refreshed = coroutineScope {
                    SupportedLeagues.map { (league, sport) -> async {
                        val outcomes = dates.map { date -> runCatching {
                            val url = "https://site.api.espn.com/apis/site/v2/sports/$sport/$league/scoreboard?dates=$date&limit=1000"
                            val body = client.await(Request.Builder().url(url).build()).use { response ->
                                check(response.isSuccessful) { "Schedule unavailable" }
                                val source = response.body?.source() ?: error("No schedule")
                                check(!source.request(2_000_001)) { "Schedule response too large" }
                                source.readUtf8()
                            }
                            parseSchedule(league, body, now)
                        } }
                        val fresh = outcomes.flatMap { it.getOrNull().orEmpty() }.distinctBy { it.id }
                        val failed = outcomes.any { it.isFailure }
                        val retained = if (failed) previous.games.filter { old -> old.league == league && old.isToday(now) && fresh.none { it.id == old.id } }
                            .map { it.copy(eventId = null, stale = true) } else emptyList()
                        Triple(league, fresh + retained, failed)
                    } }.awaitAll()
                }
                val failed = refreshed.filter { it.third }.map { it.first }.toSet()
                val schedule = refreshed.flatMap { it.second }
                // Publish the schedule before consulting the optional playback catalog.
                // A backend outage cannot hold today's real games off the launcher.
                val result = SportsScheduleCache(sportsDay(now).toString(), schedule.map { it.copy(eventId = null) }.take(100),
                    if (failed.size < SupportedLeagues.size) now else previous.updatedAt, now, failed)
                suspend fun publish(value: SportsScheduleCache) {
                    context.sportsScheduleStore.edit { it[key] = json.encodeToString(SportsScheduleCache.serializer(), value) }
                    context.contentResolver.notifyChange(android.net.Uri.parse("content://${BuildConfig.APPLICATION_ID}.launcher/snapshot"), null)
                }
                publish(result)
                val available = if (schedule.any { !it.stale && it.status in setOf("scheduled", "live", "delayed") })
                    runCatching { streams.launcherEvents().takeIf { it.enabled }?.events.orEmpty() }.getOrDefault(emptyList())
                else emptyList()
                val games = result.games.map { game -> game.copy(eventId = matchScheduledEvent(game, available)?.id) }
                if (games != result.games) publish(result.copy(games = games))

            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* Existing cached schedule remains available. Next foreground poll retries. */ }
            finally { refreshing.set(false) }
        }
    }
}
