@file:OptIn(ExperimentalCoroutinesApi::class)

package tv.velour.ui.home

import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import tv.velour.core.AppAction
import tv.velour.core.AppEntry
import tv.velour.core.VelourSettings
import tv.velour.core.WeatherSnapshot
import tv.velour.data.apps.AppRepository
import tv.velour.data.settings.SettingsRepository
import tv.velour.data.weather.WeatherRepository
import tv.velour.data.velvet.VelvetRepository
import tv.velour.data.velvet.VelvetSnapshot
import tv.velour.data.velvet.VelvetConnection
import tv.velour.data.velvet.VelvetAction
import java.util.Calendar
import kotlin.math.roundToInt

private const val FAVORITES_CAP = 12
private const val FALLBACK_SHELF_SIZE = 8
private const val LOOKS_GOOD_HOLD_MS = 120_000L
private const val WEATHER_POLL_MS = 30L * 60L * 1000L

class HomeViewModel(
    private val appRepository: AppRepository,
    private val settingsRepository: SettingsRepository,
    private val weatherRepository: WeatherRepository,
    private val velvetRepository: VelvetRepository,
) : ViewModel() {

    private val _velvet = MutableStateFlow(VelvetSnapshot(connection = VelvetConnection.UNAVAILABLE))
    val velvet: StateFlow<VelvetSnapshot> = _velvet
    val velvetChanges = velvetRepository.observeChanges()
    private val velvetRefresh = Mutex()
    suspend fun refreshVelvet() = velvetRefresh.withLock { _velvet.value = velvetRepository.snapshot() }
    fun openVelvet(action: VelvetAction): Boolean = velvetRepository.launch(action)

    data class UiState(
        val favorites: List<AppEntry> = emptyList(),   // resolved: curated or alphabetical fallback
        val library: List<AppEntry> = emptyList(),     // all minus hidden
        val settings: VelourSettings = VelourSettings(),
        val weather: WeatherSnapshot? = null,
        val greeting: String = "",
        val favoritePackages: Set<String> = emptySet(),
    )

    init {
        // CONTRACT-NOTE: someone has to kick the package scan; the repository is
        // expected to make start() idempotent if the integrator also calls it.
        appRepository.start()
    }

    /** Minute-aligned ticker so the greeting copy/hour boundary flips on time. */
    private val minuteTick: Flow<Long> = flow {
        while (true) {
            emit(System.currentTimeMillis())
            delay(60_000L - System.currentTimeMillis() % 60_000L + 50L)
        }
    }

    /** "LOOKS GOOD." holds this long after a settings change is consumed. */
    private val looksGoodUntil = MutableStateFlow(0L)

    /**
     * Weather: poll ~30min while a location is set; WeatherRepository carries its own
     * 30-min cache, so quicker restarts (location change) hit the cache, not the network.
     */
    private val weatherFlow: Flow<WeatherSnapshot?> = settingsRepository.settings
        .map { it.weatherLat to it.weatherLon }
        .distinctUntilChanged()
        .flatMapLatest { (lat, lon) ->
            if (lat == null || lon == null) {
                flowOf(null)
            } else {
                flow {
                    while (true) {
                        emit(weatherRepository.current(lat, lon))
                        delay(WEATHER_POLL_MS)
                    }
                }
            }
        }

    val uiState: StateFlow<UiState> = combine(
        appRepository.apps,
        settingsRepository.settings,
        weatherFlow,
        minuteTick,
        looksGoodUntil,
    ) { apps, settings, weather, nowMs, looksGood ->
        val visible = apps.filter { it.packageName !in settings.hidden }
        val curated = settings.favorites
            .mapNotNull { pkg -> visible.firstOrNull { it.packageName == pkg } }
            .take(FAVORITES_CAP)
        val favorites = if (curated.isNotEmpty()) {
            curated
        } else {
            // First boot is never an empty shelf: alphabetical fallback until curated.
            visible.take(FALLBACK_SHELF_SIZE)
        }
        UiState(
            favorites = favorites,
            library = visible,
            settings = settings,
            weather = weather,
            greeting = greetingCopy(
                nowMs = nowMs,
                displayName = settings.displayName,
                looksGood = nowMs < looksGood,
            ),
            favoritePackages = settings.favorites.toSet(),
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), UiState())

    /**
     * Greeting copy table (DESIGN.md Zone A). Hours are half-open: 05–11 morning,
     * 11–17 afternoon (no name), 17–22 evening with name, 22–01 evening without,
     * 01–05 "STILL UP?". Friday >= 20:00 overrides with "IT'S FRIDAY"; the first
     * home resume after a settings change overrides everything with "LOOKS GOOD."
     */
    private fun greetingCopy(nowMs: Long, displayName: String?, looksGood: Boolean): String {
        if (looksGood) return "LOOKS GOOD."
        val cal = Calendar.getInstance().apply { timeInMillis = nowMs }
        val hour = cal.get(Calendar.HOUR_OF_DAY)
        if (cal.get(Calendar.DAY_OF_WEEK) == Calendar.FRIDAY && hour >= 20) return "IT'S FRIDAY"
        val name = displayName?.trim()?.takeIf { it.isNotEmpty() }?.uppercase()
        return when (hour) {
            in 5..10 -> if (name != null) "GOOD MORNING, $name" else "GOOD MORNING"
            in 11..16 -> "GOOD AFTERNOON"
            in 17..21 -> if (name != null) "GOOD EVENING, $name" else "GOOD EVENING"
            22, 23, 0 -> "GOOD EVENING"
            else -> "STILL UP?" // 01–05
        }
    }

    /** Call when Home re-enters composition/resumes — consumes the settings-touched flag. */
    fun onHomeResumed() {
        viewModelScope.launch {
            if (settingsRepository.consumeSettingsTouched()) {
                looksGoodUntil.value = System.currentTimeMillis() + LOOKS_GOOD_HOLD_MS
            }
        }
    }

    /** Except Move which is UI-local until commit. */
    fun onAppAction(entry: AppEntry, action: AppAction) {
        viewModelScope.launch {
            when (action) {
                AppAction.ToggleFavorite -> {
                    if (entry.packageName in uiState.value.favoritePackages) {
                        settingsRepository.removeFavorite(entry.packageName)
                    } else {
                        settingsRepository.addFavorite(entry.packageName)
                    }
                }
                AppAction.Move -> Unit // UI-local until commitMove
                AppAction.Hide -> settingsRepository.setHidden(entry.packageName, true)
                AppAction.AppInfo -> appRepository.openAppInfo(entry.packageName)
                AppAction.Uninstall -> appRepository.requestUninstall(entry.packageName)
            }
        }
    }

    fun commitMove(packages: List<String>) {
        viewModelScope.launch { settingsRepository.setFavorites(packages) }
    }

    fun launch(entry: AppEntry, bounds: Rect) {
        appRepository.launch(
            entry.packageName,
            android.graphics.Rect(
                bounds.left.roundToInt(),
                bounds.top.roundToInt(),
                bounds.right.roundToInt(),
                bounds.bottom.roundToInt(),
            ),
        )
    }

    fun cycleWallpaper() {
        viewModelScope.launch { settingsRepository.cycleWallpaperMode() }
    }

    // Art passthroughs for the card composables (LruCache'd inside the repository).
    suspend fun banner(packageName: String): ImageBitmap? = appRepository.banner(packageName)
    suspend fun accentWhisper(packageName: String): Color? = appRepository.accentWhisper(packageName)
}
