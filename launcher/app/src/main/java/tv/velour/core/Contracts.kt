package tv.velour.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.setValue

data class AppEntry(
    val packageName: String,
    val label: String,
    val isGame: Boolean,
)

enum class WallpaperMode { NOCTURNE, HORIZON, TUNGSTEN, SODIUM_COAST, CELLULOID, DEEP_FIELD }

enum class AccentChoice { TUNGSTEN, ION, SIGNAL, BIAS }

data class VelourSettings(
    val wallpaperMode: WallpaperMode = WallpaperMode.NOCTURNE,
    val accent: AccentChoice = AccentChoice.TUNGSTEN,
    val use24Hour: Boolean = false,
    val displayName: String? = null,
    val weatherLat: Double? = null,
    val weatherLon: Double? = null,
    val weatherPlace: String? = null,
    val favorites: List<String> = emptyList(),
    val hidden: Set<String> = emptySet(),
    /** ESPN team keys (league:id). Empty means the sports row is hidden. */
    val sportsTeams: Set<String> = SportsTeams.defaultKeys,
    val reduceMotion: Boolean = false,
    val idleTimeoutSec: Int = 45, // 0 = off
)

data class WeatherSnapshot(
    val tempC: Double,
    val conditionCode: Int,     // WMO weather code from Open-Meteo
    val conditionLabel: String, // "Clear", "Partly cloudy", "Rain", ...
    val isNight: Boolean,
)

data class PlaceResult(
    val name: String,
    val region: String, // admin1 + country, for disambiguation
    val lat: Double,
    val lon: Double,
)

enum class AppAction { ToggleFavorite, Move, Hide, AppInfo, Uninstall }

/** Published by the focus system, read by the wallpaper inside its draw lambda. 0f..1f screen-x. */
class FocusLight {
    var normX by mutableFloatStateOf(0.5f)
}
