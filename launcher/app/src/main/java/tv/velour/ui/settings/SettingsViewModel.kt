package tv.velour.ui.settings

// Owned by agent E. Mirrors the HomeViewModel pattern; exposes settings + hidden-app entries +
// debounced Open-Meteo place search. Constructor wired by MainActivity (agent F) via the
// AppContainer factory — the three-repository shape is the scaffold contract; do not change it.

import androidx.compose.ui.graphics.ImageBitmap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import tv.velour.core.AccentChoice
import tv.velour.core.AppEntry
import tv.velour.core.PlaceResult
import tv.velour.core.VelourSettings
import tv.velour.core.WallpaperMode
import tv.velour.data.apps.AppRepository
import tv.velour.data.settings.SettingsRepository
import tv.velour.data.weather.WeatherRepository

class SettingsViewModel(
    private val appRepository: AppRepository,
    private val settingsRepository: SettingsRepository,
    private val weatherRepository: WeatherRepository,
) : ViewModel() {

    data class UiState(
        val settings: VelourSettings = VelourSettings(),
        val hiddenApps: List<AppEntry> = emptyList(),
        val placeResults: List<PlaceResult> = emptyList(),
        val searching: Boolean = false,
    )

    private val placeResults = MutableStateFlow<List<PlaceResult>>(emptyList())
    private val searching = MutableStateFlow(false)
    private var searchJob: Job? = null

    val uiState: StateFlow<UiState> = combine(
        settingsRepository.settings,
        appRepository.apps,
        placeResults,
        searching,
    ) { settings, apps, places, busy ->
        UiState(
            settings = settings,
            hiddenApps = apps.filter { it.packageName in settings.hidden },
            placeResults = places,
            searching = busy,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState())

    // ------------------------------------------------------------------ wallpaper / accent

    fun setWallpaperMode(mode: WallpaperMode) {
        persist { settingsRepository.setWallpaperMode(mode) }
    }

    fun setAccent(accent: AccentChoice) {
        persist { settingsRepository.setAccent(accent) }
    }

    // ---------------------------------------------------------------------------- clock

    fun setUse24Hour(value: Boolean) {
        persist { settingsRepository.setUse24Hour(value) }
    }

    /** Blank persists as null — the greeting drops the name entirely. */
    fun setDisplayName(raw: String) {
        persist { settingsRepository.setDisplayName(raw.trim().ifEmpty { null }) }
    }

    // -------------------------------------------------------------------------- weather

    /** Debounced Open-Meteo geocoding; results flow into [UiState.placeResults]. */
    fun onCityQueryChanged(query: String) {
        searchJob?.cancel()
        val q = query.trim()
        if (q.length < 2) {
            searching.value = false
            placeResults.value = emptyList()
            return
        }
        searchJob = viewModelScope.launch {
            delay(350) // debounce: wait out the TV-keyboard keystroke burst
            searching.value = true
            try {
                placeResults.value = weatherRepository.searchPlaces(q)
            } finally {
                searching.value = false
            }
        }
    }

    fun selectPlace(place: PlaceResult) {
        searchJob?.cancel()
        searching.value = false
        placeResults.value = emptyList()
        persist { settingsRepository.setWeatherLocation(place.lat, place.lon, place.name) }
    }

    fun clearWeatherLocation() {
        persist { settingsRepository.clearWeatherLocation() }
    }

    // ---------------------------------------------------------------------- hidden apps

    fun unhideApp(packageName: String) {
        persist { settingsRepository.setHidden(packageName, false) }
    }

    fun toggleSportsTeam(teamKey: String) {
        persist { settingsRepository.toggleSportsTeam(teamKey) }
    }

    fun addSportsTeams(teamKeys: Set<String>) {
        persist { settingsRepository.addSportsTeams(teamKeys) }
    }

    fun clearSportsTeams() {
        persist { settingsRepository.setSportsTeams(emptySet()) }
    }

    /** Banner thumb loader for hidden-app rows; delegates to the repository's LruCache. */
    suspend fun banner(packageName: String): ImageBitmap? = appRepository.banner(packageName)

    // --------------------------------------------------------------------------- motion

    fun setReduceMotion(value: Boolean) {
        persist { settingsRepository.setReduceMotion(value) }
    }

    fun setIdleTimeoutSec(value: Int) {
        persist { settingsRepository.setIdleTimeoutSec(value) }
    }

    // -------------------------------------------------------------------------- helpers

    /** Every persisted change also arms the one-shot "LOOKS GOOD." greeting flag. */
    private fun persist(write: suspend () -> Unit) {
        viewModelScope.launch {
            write()
            settingsRepository.markSettingsTouched()
        }
    }
}
