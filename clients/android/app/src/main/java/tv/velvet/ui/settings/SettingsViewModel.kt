package tv.velvet.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import tv.velvet.data.model.RowSpec
import tv.velvet.data.model.StreamSourceConfig
import tv.velvet.data.settings.SettingsRepository
import tv.velvet.data.settings.VelvetSettings
// Star import: the seasonal-row API (isSeasonalRowActive / seasonalRowIds) lives in
// this package alongside TmdbRepository itself.
import tv.velvet.data.tmdb.*
import tv.velvet.di.AppContainer
import tv.velvet.ui.HomeRowOrder

/** One Home row as displayed in Settings: enabled rows first (in user order), then disabled. */
data class HomeRowEntry(
    val spec: RowSpec,
    val enabled: Boolean,
    val canMoveUp: Boolean,
    val canMoveDown: Boolean,
)

data class SettingsUiState(
    val loaded: Boolean = false,
    val settings: VelvetSettings = VelvetSettings(
        tmdbApiKey = SettingsRepository.DEFAULT_TMDB_KEY,
        streamSources = emptyList(),
        rowOrder = emptyList(),
        autoplayNext = true,
        autoplayCountdownSecs = 8,
        preferredQuality = "2160p",
        tunneledPlayback = false,
    ),
    val rowEntries: List<HomeRowEntry> = emptyList(),
)

class SettingsViewModel(container: AppContainer) : ViewModel() {

    private val settingsRepository = container.settingsRepository
    private val syncEngine = container.syncEngine

    /** Last-sync result/time line shown under the "Sync now" row. */
    val syncStatus: StateFlow<String> = syncEngine.status

    private val tmdb = container.tmdbRepository

    /** Every row Velvet knows how to render, in default order. */
    private val allRows: List<RowSpec> = tmdb.allRows

    /** Ids of the seasonal/holiday rows — enabled by default only inside their window. */
    private val seasonalRowIds: Set<String> =
        runCatching { tmdb.seasonalRowIds().toSet() }.getOrDefault(emptySet())

    private val _state = MutableStateFlow(SettingsUiState(rowEntries = buildRowEntries(emptyList())))
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            settingsRepository.settings.collect { s -> apply(s, loaded = true) }
        }
    }

    // ---------------------------------------------------------------- sources

    fun toggleSource(index: Int) {
        if (!_state.value.loaded) return
        val sources = _state.value.settings.streamSources
        if (index !in sources.indices) return
        persistSources(
            sources.mapIndexed { i, s -> if (i == index) s.copy(enabled = !s.enabled) else s }
        )
    }

    fun removeSource(index: Int) {
        if (!_state.value.loaded) return
        val sources = _state.value.settings.streamSources
        if (index !in sources.indices) return
        persistSources(sources.filterIndexed { i, _ -> i != index })
    }

    fun addSource(name: String, url: String) {
        if (!_state.value.loaded) return
        val baseUrl = normalizeSourceUrl(url)
        if (baseUrl.isEmpty()) return
        val sources = _state.value.settings.streamSources
        // No duplicate URLs: querying the same source twice is never useful, and
        // baseUrl doubles as the stable list key in the Settings UI.
        if (sources.any { it.baseUrl.equals(baseUrl, ignoreCase = true) }) return
        val displayName = name.trim().ifEmpty { "Source ${sources.size + 1}" }
        persistSources(sources + StreamSourceConfig(name = displayName, baseUrl = baseUrl, enabled = true))
    }

    private fun persistSources(sources: List<StreamSourceConfig>) {
        apply(_state.value.settings.copy(streamSources = sources))
        viewModelScope.launch { settingsRepository.setStreamSources(sources) }
    }

    // -------------------------------------------------------------- home rows

    /** Move an enabled row up (-1) or down (+1) within the effective order. Persists immediately. */
    fun moveRow(rowId: String, delta: Int) {
        if (!_state.value.loaded) return
        val order = effectiveEnabledOrder()
        val from = order.indexOf(rowId)
        if (from < 0) return // disabled rows have no persistable position
        val to = from + delta
        if (to !in order.indices) return
        val next = order.toMutableList().apply { add(to, removeAt(from)) }
        persistRowOrder(next)
    }

    /**
     * Include/exclude a row from rowOrder. When the persisted order is empty (= "all
     * enabled" default), the full default list is materialized first, then modified.
     * Re-enabled rows are appended to the end of the enabled list.
     */
    fun toggleRow(rowId: String) {
        if (!_state.value.loaded) return
        val order = effectiveEnabledOrder().toMutableList()
        if (rowId in order) {
            // Never allow zero enabled rows: an empty persisted order means "all enabled",
            // so removing the last entry would paradoxically re-enable everything.
            if (order.size == 1) return
            order.remove(rowId)
        } else {
            if (allRows.none { it.id == rowId }) return
            order.add(rowId)
        }
        persistRowOrder(order)
    }

    fun resetRowOrder() {
        persistRowOrder(emptyList())
    }

    private fun effectiveEnabledOrder(): List<String> = enabledOrder(_state.value.settings.rowOrder)

    /**
     * The enabled row ids as Settings displays (and persists) them.
     *
     * Empty stored order = "no preference": the default enabled set, which is every row
     * except seasonal ones outside their window — an out-of-season holiday row shouldn't
     * sit in the enabled list as noise (§4f; it stays listed below, so he can still pin it).
     *
     * A non-empty stored order gets renamed ids migrated and ids introduced SINCE it was
     * written appended (§4g), exactly like Home does — otherwise the first row edge he
     * ever made would freeze the v1.2.0 holiday rows out of Settings permanently. A
     * seasonal newcomer only joins the ENABLED list inside its window; out of season it
     * lands in the disabled list below, where he can still pin it by hand (and a pin he
     * makes there survives, because it is then part of the stored order).
     */
    private fun enabledOrder(rowOrder: List<String>): List<String> {
        val knownIds = allRows.map { it.id }.toSet()
        val stored = HomeRowOrder.migrate(rowOrder).filter { it in knownIds }
        if (stored.isEmpty()) return defaultEnabledIds()
        val present = stored.toHashSet()
        val appended = allRows.map { it.id }.filter { id ->
            id !in present && HomeRowOrder.isAddedAfterV1(id) && isEnabledByDefault(id)
        }
        return stored + appended
    }

    private fun defaultEnabledIds(): List<String> =
        allRows.map { it.id }.filter(::isEnabledByDefault)

    /** Seasonal rows are only enabled-by-default inside their calendar window (§4f). */
    private fun isEnabledByDefault(rowId: String): Boolean =
        rowId !in seasonalRowIds || tmdb.isSeasonalRowActive(rowId)

    private fun persistRowOrder(order: List<String>) {
        apply(_state.value.settings.copy(rowOrder = order))
        viewModelScope.launch { settingsRepository.setRowOrder(order) }
    }

    private fun buildRowEntries(rowOrder: List<String>): List<HomeRowEntry> {
        val byId = allRows.associateBy { it.id }
        val enabledSpecs = enabledOrder(rowOrder).mapNotNull { byId[it] }
        val enabledIds = enabledSpecs.map { it.id }.toSet()
        val disabledSpecs = allRows.filter { it.id !in enabledIds }
        return enabledSpecs.mapIndexed { i, spec ->
            HomeRowEntry(
                spec = spec,
                enabled = true,
                canMoveUp = i > 0,
                canMoveDown = i < enabledSpecs.lastIndex,
            )
        } + disabledSpecs.map { spec ->
            HomeRowEntry(spec = spec, enabled = false, canMoveUp = false, canMoveDown = false)
        }
    }

    // --------------------------------------------------------------- playback

    fun setAutoplayNext(enabled: Boolean) {
        apply(_state.value.settings.copy(autoplayNext = enabled))
        viewModelScope.launch { settingsRepository.setAutoplayNext(enabled) }
    }

    fun setCountdownSecs(secs: Int) {
        apply(_state.value.settings.copy(autoplayCountdownSecs = secs))
        viewModelScope.launch { settingsRepository.setAutoplayCountdownSecs(secs) }
    }

    fun setPreferredQuality(quality: String) {
        apply(_state.value.settings.copy(preferredQuality = quality))
        viewModelScope.launch { settingsRepository.setPreferredQuality(quality) }
    }

    fun setTunneledPlayback(enabled: Boolean) {
        apply(_state.value.settings.copy(tunneledPlayback = enabled))
        viewModelScope.launch { settingsRepository.setTunneledPlayback(enabled) }
    }

    // ---------------------------------------------------------------- backend

    /** The single URL that drives streaming + sync (writes both under the hood). */
    fun setBackendUrl(url: String) {
        val trimmed = url.trim().trimEnd('/')
        viewModelScope.launch { settingsRepository.setBackendUrl(trimmed) }
    }

    // ------------------------------------------------------------------- sync

    fun setSyncEnabled(enabled: Boolean) {
        apply(_state.value.settings.copy(syncEnabled = enabled))
        viewModelScope.launch { settingsRepository.setSyncEnabled(enabled) }
    }

    /** Blank is allowed — it leaves the toggle on but renders the engine inert. */
    fun setSyncUrl(url: String) {
        val trimmed = url.trim().trimEnd('/')
        apply(_state.value.settings.copy(syncUrl = trimmed))
        viewModelScope.launch { settingsRepository.setSyncUrl(trimmed) }
    }

    fun setSyncToken(token: String) {
        val trimmed = token.trim()
        apply(_state.value.settings.copy(syncToken = trimmed))
        viewModelScope.launch { settingsRepository.setSyncToken(trimmed) }
    }

    fun syncNow() = syncEngine.syncNow()

    // ------------------------------------------------------------------- tmdb

    fun setTmdbApiKey(key: String) {
        val trimmed = key.trim()
        if (trimmed.isEmpty()) return
        apply(_state.value.settings.copy(tmdbApiKey = trimmed))
        viewModelScope.launch { settingsRepository.setTmdbApiKey(trimmed) }
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Optimistic update; the DataStore flow re-emits the same values right after.
     * The stored row order is migrated on READ (trending_movies -> popular_now), so a
     * hand-tuned order survives the row rename and re-persists on the next edit. Only the
     * RENAME is applied to the mirrored value — [enabledOrder] appends newer ids on top of
     * it, so a stored "no preference" (empty) order is never fabricated into a pinned one.
     */
    private fun apply(settings: VelvetSettings, loaded: Boolean = _state.value.loaded) {
        val migrated = settings.copy(rowOrder = HomeRowOrder.migrate(settings.rowOrder))
        _state.value = SettingsUiState(
            loaded = loaded,
            settings = migrated,
            rowEntries = buildRowEntries(migrated.rowOrder),
        )
    }

    companion object {
        /** Trim whitespace, strip a trailing /manifest.json and any trailing slashes. */
        fun normalizeSourceUrl(raw: String): String {
            var url = raw.trim().trimEnd('/')
            if (url.endsWith("/manifest.json", ignoreCase = true)) {
                url = url.dropLast("/manifest.json".length)
            }
            return url.trimEnd('/')
        }
    }
}
