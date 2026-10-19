package tv.velour.data.settings

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import tv.velour.core.AccentChoice
import tv.velour.core.SportsTeams
import tv.velour.core.VelourSettings
import tv.velour.core.WallpaperMode
import java.io.IOException

private val Context.dataStore by preferencesDataStore(name = "velour_settings")

private inline fun <reified T : Enum<T>> String.toEnumOrNull(): T? =
    runCatching { enumValueOf<T>(this) }.getOrNull()

class SettingsRepository(private val context: Context) {

    private object Keys {
        val WALLPAPER = stringPreferencesKey("wallpaper_mode")
        val ACCENT = stringPreferencesKey("accent")
        val USE_24H = booleanPreferencesKey("use_24_hour")
        val DISPLAY_NAME = stringPreferencesKey("display_name")
        val WEATHER_LAT = doublePreferencesKey("weather_lat")
        val WEATHER_LON = doublePreferencesKey("weather_lon")
        val WEATHER_PLACE = stringPreferencesKey("weather_place")
        val FAVORITES = stringPreferencesKey("favorites_json")
        val HIDDEN = stringSetPreferencesKey("hidden_packages")
        val SPORTS_TEAMS = stringSetPreferencesKey("sports_team_ids")
        val REDUCE_MOTION = booleanPreferencesKey("reduce_motion")
        val IDLE_TIMEOUT = intPreferencesKey("idle_timeout_sec")
        val SETTINGS_TOUCHED = booleanPreferencesKey("settings_touched")
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val favoritesSerializer = ListSerializer(String.serializer())

    /** Preferences DataStore ("velour_settings"); favorites stored as JSON string list. */
    val settings: Flow<VelourSettings> = context.dataStore.data
        .catch { e -> if (e is IOException) emit(emptyPreferences()) else throw e }
        .map { p ->
            VelourSettings(
                wallpaperMode = p[Keys.WALLPAPER]?.toEnumOrNull<WallpaperMode>()
                    ?: WallpaperMode.NOCTURNE,
                accent = p[Keys.ACCENT]?.toEnumOrNull<AccentChoice>() ?: AccentChoice.TUNGSTEN,
                use24Hour = p[Keys.USE_24H] ?: false,
                displayName = p[Keys.DISPLAY_NAME]?.takeIf { it.isNotBlank() },
                weatherLat = p[Keys.WEATHER_LAT],
                weatherLon = p[Keys.WEATHER_LON],
                weatherPlace = p[Keys.WEATHER_PLACE],
                favorites = decodeFavorites(p[Keys.FAVORITES]),
                hidden = p[Keys.HIDDEN] ?: emptySet(),
                // New installs choose their own teams in Settings; no region is assumed.
                sportsTeams = p[Keys.SPORTS_TEAMS] ?: SportsTeams.defaultKeys,
                reduceMotion = p[Keys.REDUCE_MOTION] ?: false,
                idleTimeoutSec = p[Keys.IDLE_TIMEOUT] ?: 45,
            )
        }

    suspend fun setWallpaperMode(mode: WallpaperMode) {
        context.dataStore.edit { it[Keys.WALLPAPER] = mode.name }
    }

    /** For the booth cycler button. */
    suspend fun cycleWallpaperMode() {
        context.dataStore.edit { p ->
            val current = p[Keys.WALLPAPER]?.toEnumOrNull<WallpaperMode>()
                ?: WallpaperMode.NOCTURNE
            val all = WallpaperMode.entries
            p[Keys.WALLPAPER] = all[(current.ordinal + 1) % all.size].name
        }
    }

    suspend fun setAccent(accent: AccentChoice) {
        context.dataStore.edit { it[Keys.ACCENT] = accent.name }
    }

    suspend fun setUse24Hour(value: Boolean) {
        context.dataStore.edit { it[Keys.USE_24H] = value }
    }

    suspend fun setDisplayName(name: String?) {
        context.dataStore.edit { p ->
            val trimmed = name?.trim()
            if (trimmed.isNullOrEmpty()) p.remove(Keys.DISPLAY_NAME)
            else p[Keys.DISPLAY_NAME] = trimmed
        }
    }

    suspend fun setWeatherLocation(lat: Double, lon: Double, place: String) {
        context.dataStore.edit { p ->
            p[Keys.WEATHER_LAT] = lat
            p[Keys.WEATHER_LON] = lon
            p[Keys.WEATHER_PLACE] = place
        }
    }

    suspend fun clearWeatherLocation() {
        context.dataStore.edit { p ->
            p.remove(Keys.WEATHER_LAT)
            p.remove(Keys.WEATHER_LON)
            p.remove(Keys.WEATHER_PLACE)
        }
    }

    suspend fun setFavorites(packages: List<String>) {
        editFavorites { packages.distinct().take(MAX_FAVORITES) }
    }

    /** Appends, cap 12. */
    suspend fun addFavorite(packageName: String) {
        editFavorites { current ->
            if (packageName in current || current.size >= MAX_FAVORITES) current
            else current + packageName
        }
    }

    suspend fun removeFavorite(packageName: String) {
        editFavorites { it - packageName }
    }

    /** -1 left, +1 right, clamped. */
    suspend fun moveFavorite(packageName: String, delta: Int) {
        editFavorites { current ->
            val from = current.indexOf(packageName)
            if (from < 0) return@editFavorites current
            val to = (from + delta).coerceIn(0, current.lastIndex)
            if (to == from) current
            else current.toMutableList().apply { add(to, removeAt(from)) }
        }
    }

    suspend fun setHidden(packageName: String, hidden: Boolean) {
        context.dataStore.edit { p ->
            val current = p[Keys.HIDDEN] ?: emptySet()
            p[Keys.HIDDEN] = if (hidden) current + packageName else current - packageName
        }
    }

    suspend fun setReduceMotion(value: Boolean) {
        context.dataStore.edit { it[Keys.REDUCE_MOTION] = value }
    }

    suspend fun setSportsTeams(teamKeys: Set<String>) {
        context.dataStore.edit { it[Keys.SPORTS_TEAMS] = teamKeys.intersect(SportsTeams.byKey.keys) }
    }

    suspend fun toggleSportsTeam(teamKey: String) {
        if (teamKey !in SportsTeams.byKey) return
        context.dataStore.edit { p ->
            val current = p[Keys.SPORTS_TEAMS] ?: SportsTeams.defaultKeys
            p[Keys.SPORTS_TEAMS] = if (teamKey in current) current - teamKey else current + teamKey
        }
    }

    /** Explicit city presets add teams without replacing other favorites. */
    suspend fun addSportsTeams(teamKeys: Set<String>) {
        context.dataStore.edit { p ->
            val current = p[Keys.SPORTS_TEAMS] ?: SportsTeams.defaultKeys
            p[Keys.SPORTS_TEAMS] = current + teamKeys.intersect(SportsTeams.byKey.keys)
        }
    }

    suspend fun setIdleTimeoutSec(value: Int) {
        context.dataStore.edit { it[Keys.IDLE_TIMEOUT] = value.coerceAtLeast(0) }
    }

    /** For the "LOOKS GOOD." greeting; one-shot flag consumed by HomeViewModel. */
    suspend fun markSettingsTouched() {
        context.dataStore.edit { it[Keys.SETTINGS_TOUCHED] = true }
    }

    suspend fun consumeSettingsTouched(): Boolean {
        var touched = false
        context.dataStore.edit { p ->
            touched = p[Keys.SETTINGS_TOUCHED] ?: false
            p.remove(Keys.SETTINGS_TOUCHED)
        }
        return touched
    }

    // ---- internals -------------------------------------------------------------------------

    /** Read-modify-write of the JSON-encoded ordered favorites list inside one atomic edit. */
    private suspend fun editFavorites(transform: (List<String>) -> List<String>) {
        context.dataStore.edit { p ->
            val current = decodeFavorites(p[Keys.FAVORITES])
            val next = transform(current)
            if (next != current || p[Keys.FAVORITES] == null) {
                p[Keys.FAVORITES] = json.encodeToString(favoritesSerializer, next)
            }
        }
    }

    private fun decodeFavorites(raw: String?): List<String> = raw?.let {
        runCatching { json.decodeFromString(favoritesSerializer, it) }.getOrNull()
    } ?: emptyList()

    private companion object {
        const val MAX_FAVORITES = 12
    }
}
