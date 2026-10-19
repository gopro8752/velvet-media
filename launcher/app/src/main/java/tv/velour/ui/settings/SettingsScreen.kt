@file:OptIn(ExperimentalComposeUiApi::class)

package tv.velour.ui.settings

import android.content.Intent
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.foundation.focusGroup
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import tv.velour.core.AccentChoice
import tv.velour.core.WallpaperMode
import tv.velour.ui.components.velourFocus
import tv.velour.ui.components.WeatherGlyph
import tv.velour.ui.glass.GlassGlyph
import tv.velour.ui.glass.GlassIcon
import tv.velour.ui.glass.GlassPanel
import tv.velour.ui.theme.VelourColors
import tv.velour.ui.theme.VelourType
import tv.velour.ui.wallpaper.WallpaperLayer

private enum class SettingsSection(val label: String, val icon: GlassIcon?) {
    WALLPAPER("Atmosphere", GlassIcon.Moon),
    ACCENT("Accent", GlassIcon.Heart),
    CLOCK("Clock & greeting", GlassIcon.Clock),
    TEAMS("Teams", GlassIcon.Sports),
    WEATHER("Weather", null),
    HIDDEN("Hidden apps", GlassIcon.Apps),
    MOTION("Motion & idle", GlassIcon.Play),
    SYSTEM("System", GlassIcon.Settings),
}

@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    viewModel: SettingsViewModel,
) {
    val ui by viewModel.uiState.collectAsStateWithLifecycle()
    val settings = ui.settings
    val accent = VelourColors.accent(settings.accent)
    val accentDeep = VelourColors.accentDeep(settings.accent)

    // Registered before every child handler, so edit-mode BACK (text rows) wins first.
    BackHandler { onBack() }

    var section by remember { mutableStateOf(SettingsSection.WALLPAPER) }
    val firstNavFocus = remember { FocusRequester() }
    // Attached to the ACTIVE section's nav row — panes whose focused row can disappear
    // (un-hiding the last hidden app) fall back here so focus is never silently
    // released into a root search.
    val activeNavFocus = remember { FocusRequester() }
    val paneFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        // Pull focus out of the home tree once the nav column is attached.
        repeat(5) {
            withFrameNanos { }
            if (runCatching { firstNavFocus.requestFocus() }.isSuccess) return@LaunchedEffect
        }
    }

    CompositionLocalProvider(LocalSettingsReduceMotion provides settings.reduceMotion) {
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(listOf(Color(0xFF191A2A), Color(0xFF0C111A), Color(0xFF1B1426))),
            )
            .onKeyEvent { event ->
                // Bubble phase lets inline editors consume Back before this fallback.
                if (event.key == Key.Back) {
                    if (event.type == KeyEventType.KeyDown && event.nativeKeyEvent.repeatCount == 0) onBack()
                    true
                } else false
            }
            // Modal: focus search must never escape into the (covered) home tree —
            // same containment trick as the long-press menu.
            .focusProperties { exit = { FocusRequester.Cancel } }
            .focusGroup(),
    ) {
        // Static ambient light keeps Settings restful and leaves the GPU to the
        // focused wallpaper preview. Home's renderer is already gated by active=false.
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 38.dp, vertical = 28.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                androidx.tv.material3.Text(
                    text = "Settings",
                    style = VelourType.clockMini.copy(fontSize = 30.sp),
                    color = SettingsPearl,
                )
                Spacer(Modifier.weight(1f))
                androidx.tv.material3.Text(
                    text = "Make yourself at home.",
                    style = VelourType.body.copy(fontSize = 13.sp),
                    color = SettingsSecondary,
                )
            }
            Spacer(Modifier.height(22.dp))
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(22.dp)) {
            GlassPanel(Modifier.width(228.dp).fillMaxHeight(), radius = 26.dp, opacity = .25f) {
            Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SettingsSection.entries.forEachIndexed { index, s ->
                    var navModifier: Modifier = Modifier
                    if (index == 0) navModifier = navModifier.focusRequester(firstNavFocus)
                    if (section == s) navModifier = navModifier.focusRequester(activeNavFocus)
                    NavRow(
                        label = s.label,
                        icon = s.icon,
                        active = section == s,
                        onFocused = { section = s },
                        onEnter = { runCatching { paneFocus.requestFocus() } },
                        modifier = navModifier.focusProperties { right = paneFocus },
                    )
                }
                }
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    GlassGlyph(GlassIcon.Back, Modifier.size(14.dp), SettingsSecondary)
                    Spacer(Modifier.width(8.dp))
                    androidx.tv.material3.Text("Back to home", style = VelourType.body.copy(fontSize = 11.sp), color = SettingsSecondary)
                }
            }
            }

            GlassPanel(Modifier.weight(1f).fillMaxHeight(), radius = 26.dp, opacity = .20f) {
            Box(
                Modifier.fillMaxSize().padding(24.dp)
                    .focusRequester(paneFocus)
                    .focusProperties {
                        exit = { direction ->
                            if (direction == FocusDirection.Left) activeNavFocus else FocusRequester.Default
                        }
                    }
                    .focusGroup(),
            ) {
                when (section) {
                    SettingsSection.WALLPAPER -> WallpaperPane(
                        current = settings.wallpaperMode,
                        accent = accent,
                        accentDeep = accentDeep,
                        reduceMotion = settings.reduceMotion,
                        onSelect = viewModel::setWallpaperMode,
                    )
                    SettingsSection.ACCENT -> AccentPane(
                        current = settings.accent,
                        reduceMotion = settings.reduceMotion,
                        onSelect = viewModel::setAccent,
                    )
                    SettingsSection.CLOCK -> ClockPane(
                        use24Hour = settings.use24Hour,
                        displayName = settings.displayName.orEmpty(),
                        accent = accent,
                        onUse24Hour = viewModel::setUse24Hour,
                        onDisplayName = viewModel::setDisplayName,
                    )
                    SettingsSection.TEAMS -> TeamsPane(
                        selected = settings.sportsTeams,
                        accent = accent,
                        onToggle = viewModel::toggleSportsTeam,
                        onAddCity = viewModel::addSportsTeams,
                        onClear = viewModel::clearSportsTeams,
                    )
                    SettingsSection.WEATHER -> WeatherPane(
                        ui = ui,
                        accent = accent,
                        onQueryChanged = viewModel::onCityQueryChanged,
                        onSelectPlace = viewModel::selectPlace,
                        onClearLocation = viewModel::clearWeatherLocation,
                    )
                    SettingsSection.HIDDEN -> HiddenAppsPane(
                        ui = ui,
                        accent = accent,
                        banner = viewModel::banner,
                        onUnhide = viewModel::unhideApp,
                        fallbackFocus = activeNavFocus,
                    )
                    SettingsSection.MOTION -> MotionPane(
                        reduceMotion = settings.reduceMotion,
                        idleTimeoutSec = settings.idleTimeoutSec,
                        accent = accent,
                        onReduceMotion = viewModel::setReduceMotion,
                        onIdleTimeout = viewModel::setIdleTimeoutSec,
                    )
                    SettingsSection.SYSTEM -> SystemPane(accent)
                }
            }
            }
                }
            }
        }
    }
}

/** Focusing a section previews its pane; OK or Right moves into its controls. */
@Composable
private fun NavRow(
    label: String,
    icon: GlassIcon?,
    active: Boolean,
    onFocused: () -> Unit,
    onEnter: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .height(40.dp)
            .onFocusChanged {
                focused = it.isFocused
                if (it.isFocused) onFocused()
            }
            .settingsFocusLens(focused, active)
            .clickable(interactionSource = interaction, indication = null, onClick = onEnter)
            .padding(horizontal = 14.dp),
    ) {
        val ink = if (active || focused) SettingsPearl else SettingsSecondary
        if (icon != null) GlassGlyph(icon, Modifier.size(18.dp), ink)
        else WeatherGlyph(0, false, ink, Modifier.size(18.dp))
        Spacer(Modifier.width(12.dp))
            androidx.tv.material3.Text(
                text = label,
                style = VelourType.body.copy(fontSize = 14.sp),
                color = if (active || focused) SettingsPearl else SettingsSecondary,
                maxLines = 1,
            )
    }
}

// -------------------------------------------------------------------------- WALLPAPER

private val WallpaperModeNames = mapOf(
    WallpaperMode.NOCTURNE to "Nocturne",
    WallpaperMode.HORIZON to "Horizon",
    WallpaperMode.TUNGSTEN to "Tungsten",
    WallpaperMode.SODIUM_COAST to "Sodium Coast",
    WallpaperMode.CELLULOID to "Celluloid",
    WallpaperMode.DEEP_FIELD to "Deep Field",
)

/** The real atmosphere renderer in miniature; only focused/selected previews animate. */
@Composable
private fun WallpaperPane(
    current: WallpaperMode,
    accent: Color,
    accentDeep: Color,
    reduceMotion: Boolean,
    onSelect: (WallpaperMode) -> Unit,
) {
    Column(Modifier.fillMaxHeight().verticalScroll(rememberScrollState())) {
        PaneEyebrow("Atmosphere")
        Spacer(Modifier.height(10.dp))
        androidx.tv.material3.Text(
            text = "One atmosphere for Home, your apps and idle moments. Browsing titles keeps your chosen backdrop in place.",
            style = VelourType.body.copy(fontSize = 14.sp),
            color = SettingsSecondary,
        )
        Spacer(Modifier.height(18.dp))
        val modes = WallpaperMode.entries
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            modes.chunked(2).forEach { rowModes ->
                Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                    rowModes.forEach { mode ->
                        WallpaperPreviewCard(
                            mode = mode,
                            selected = mode == current,
                            accent = accent,
                            accentDeep = accentDeep,
                            reduceMotion = reduceMotion,
                            onSelect = { onSelect(mode) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun WallpaperPreviewCard(
    mode: WallpaperMode,
    selected: Boolean,
    accent: Color,
    accentDeep: Color,
    reduceMotion: Boolean,
    onSelect: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .size(220.dp, 124.dp)
                .onFocusChanged { focused = it.isFocused }
                .velourFocus(
                    focused = focused,
                    accent = accent,
                    radius = 16.dp,
                    focusedScale = 1.035f,
                    reduceMotion = reduceMotion,
                )
                .clickable(interactionSource = interaction, indication = null, onClick = onSelect),
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(16.dp))
            ) {
                // Same code path as the full-screen wallpaper — a true miniature.
                WallpaperLayer(
                    mode = mode,
                    accent = accent,
                    accentDeep = accentDeep,
                    leanX = { 0.5f },
                    weather = null,
                    reduceMotion = reduceMotion,
                    modifier = Modifier.fillMaxSize(),
                    active = (focused || selected) && !reduceMotion,
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            androidx.tv.material3.Text(
                text = WallpaperModeNames.getValue(mode),
                style = VelourType.body.copy(fontSize = 13.sp),
                color = when {
                    focused -> accent
                    selected -> SettingsPearl
                    else -> SettingsSecondary
                },
            )
            if (selected) {
                Spacer(Modifier.width(8.dp))
                Box(
                    Modifier
                        .size(6.dp)
                        .background(accent, CircleShape)
                )
            }
        }
    }
}

// ----------------------------------------------------------------------------- ACCENT

/** Four 56dp circles, 24dp gaps; the focused circle's glow blooms over 250ms. */
@Composable
private fun AccentPane(
    current: AccentChoice,
    reduceMotion: Boolean,
    onSelect: (AccentChoice) -> Unit,
) {
    Column {
        PaneEyebrow("Accent")
        Spacer(Modifier.height(24.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            AccentChoice.entries.forEach { choice ->
                AccentSwatch(
                    choice = choice,
                    selected = choice == current,
                    reduceMotion = reduceMotion,
                    onSelect = { onSelect(choice) },
                )
            }
        }
        Spacer(Modifier.height(24.dp))
        androidx.tv.material3.Text(
            text = accentLabel(current),
            style = VelourType.body.copy(fontSize = 14.sp),
            color = SettingsSecondary,
        )
    }
}

private fun accentLabel(choice: AccentChoice): String = when (choice) {
    AccentChoice.TUNGSTEN -> "Tungsten — warm filament amber"
    AccentChoice.ION -> "Ion — cold display cyan"
    AccentChoice.SIGNAL -> "Signal — projection-booth red"
    AccentChoice.BIAS -> "Bias — bias-light violet"
}

@Composable
private fun AccentSwatch(
    choice: AccentChoice,
    selected: Boolean,
    reduceMotion: Boolean,
    onSelect: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    val color = VelourColors.accent(choice)
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(56.dp)
            .onFocusChanged { focused = it.isFocused }
            .velourFocus(
                focused = focused,
                accent = color,
                radius = 28.dp, // 56dp circle
                focusedScale = 1.06f,
                reduceMotion = reduceMotion,
                glowIgniteMs = 250, // DESIGN.md ACCENT: "glow blooms over 250ms"
            )
            .clickable(interactionSource = interaction, indication = null, onClick = onSelect)
            .background(color, CircleShape)
            .border(1.dp, Color.White.copy(alpha = 0.08f), CircleShape),
    ) {
        if (selected) {
            Box(
                Modifier
                    .size(10.dp)
                    .background(VelourColors.Void, CircleShape)
            )
        }
    }
}

// ------------------------------------------------------------------------------ CLOCK

@Composable
private fun ClockPane(
    use24Hour: Boolean,
    displayName: String,
    accent: Color,
    onUse24Hour: (Boolean) -> Unit,
    onDisplayName: (String) -> Unit,
) {
    Column {
        PaneEyebrow("Clock")
        Spacer(Modifier.height(18.dp))
        SettingsTextRow(
            label = "Time format",
            accent = accent,
            trailing = if (use24Hour) "24-hour" else "12-hour",
            onClick = { onUse24Hour(!use24Hour) },
        )
        SettingsEditRow(
            label = "Display name",
            value = displayName,
            placeholder = "Not set",
            accent = accent,
            onCommit = onDisplayName,
        )
        Spacer(Modifier.height(18.dp))
        androidx.tv.material3.Text(
            text = "The greeting uses your name in the morning and evening.",
            style = VelourType.body.copy(fontSize = 14.sp),
            color = SettingsSecondary,
        )
    }
}

// ---------------------------------------------------------------------------- WEATHER

@Composable
private fun WeatherPane(
    ui: SettingsViewModel.UiState,
    accent: Color,
    onQueryChanged: (String) -> Unit,
    onSelectPlace: (tv.velour.core.PlaceResult) -> Unit,
    onClearLocation: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    // Deterministic focus restoration: "Clear location" and selecting a place result
    // both dispose the row that currently holds focus (the location rows / the results
    // list). Move focus onto the always-present City-search row FIRST so it is never
    // released into a root focus search.
    val searchRowFocus = remember { FocusRequester() }
    var refocusSearch by remember { mutableStateOf(false) }
    LaunchedEffect(refocusSearch) {
        if (refocusSearch) {
            withFrameNanos { }
            runCatching { searchRowFocus.requestFocus() }
            refocusSearch = false
        }
    }
    Column(
        Modifier
            .fillMaxHeight()
            .verticalScroll(rememberScrollState())
    ) {
        PaneEyebrow("Weather")
        Spacer(Modifier.height(18.dp))
        val place = ui.settings.weatherPlace
        if (place != null) {
            SettingsTextRow(
                label = "Location",
                accent = accent,
                trailing = place,
                selected = true,
                onClick = {},
            )
            SettingsTextRow(
                label = "Clear location",
                accent = accent,
                danger = true,
                onClick = {
                    refocusSearch = true
                    onClearLocation()
                },
            )
            Spacer(Modifier.height(12.dp))
        }
        SettingsEditRow(
            label = "City search",
            value = query,
            placeholder = "Search…",
            accent = accent,
            onValueChange = {
                query = it
                onQueryChanged(it)
            },
            onCommit = { query = it },
            modifier = Modifier.focusRequester(searchRowFocus),
        )
        if (ui.searching) {
            Spacer(Modifier.height(8.dp))
            androidx.tv.material3.Text(
                text = "Searching…",
                style = VelourType.body.copy(fontSize = 14.sp),
                color = SettingsSecondary,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
        ui.placeResults.forEach { result ->
            SettingsTextRow(
                label = result.name,
                accent = accent,
                trailing = result.region,
                onClick = {
                    refocusSearch = true
                    onSelectPlace(result)
                },
            )
        }
        if (place == null && ui.placeResults.isEmpty() && !ui.searching) {
            Spacer(Modifier.height(18.dp))
            androidx.tv.material3.Text(
                text = "Pick a city to show weather beside the date. Open-Meteo, no account needed.",
                style = VelourType.body.copy(fontSize = 14.sp),
                color = SettingsSecondary,
            )
        }
    }
}

// ------------------------------------------------------------------------ HIDDEN APPS

@Composable
private fun HiddenAppsPane(
    ui: SettingsViewModel.UiState,
    accent: Color,
    banner: suspend (String) -> ImageBitmap?,
    onUnhide: (String) -> Unit,
    fallbackFocus: FocusRequester,
) {
    // Deterministic focus restoration: un-hiding disposes the focused row. Hand focus
    // to a neighboring row (next, else previous) once the list updates — or back to
    // the active nav row when the last hidden app was just un-hidden — so focus is
    // never released into a root focus search.
    val neighborFocus = remember { FocusRequester() }
    var refocusKey by remember { mutableStateOf<String?>(null) }
    var refocusPending by remember { mutableStateOf(false) }
    LaunchedEffect(ui.hiddenApps) {
        if (!refocusPending) return@LaunchedEffect
        refocusPending = false
        val key = refocusKey
        withFrameNanos { }
        val landed = key != null && ui.hiddenApps.any { it.packageName == key } &&
            runCatching { neighborFocus.requestFocus() }.isSuccess
        if (!landed) runCatching { fallbackFocus.requestFocus() }
        refocusKey = null
    }
    Column(Modifier.fillMaxHeight()) {
        PaneEyebrow("Hidden apps · ${ui.hiddenApps.size}")
        Spacer(Modifier.height(18.dp))
        if (ui.hiddenApps.isEmpty()) {
            androidx.tv.material3.Text(
                text = "Nothing hidden. Long-press any card on home to hide it.",
                style = VelourType.body.copy(fontSize = 14.sp),
                color = SettingsSecondary,
            )
        } else {
            LazyColumn {
                items(ui.hiddenApps, key = { it.packageName }) { entry ->
                    HiddenAppRow(
                        label = entry.label,
                        packageName = entry.packageName,
                        accent = accent,
                        banner = banner,
                        onUnhide = {
                            val idx = ui.hiddenApps.indexOfFirst {
                                it.packageName == entry.packageName
                            }
                            val neighbor = ui.hiddenApps.getOrNull(idx + 1)
                                ?: ui.hiddenApps.getOrNull(idx - 1)
                            refocusKey = neighbor?.packageName
                            refocusPending = true
                            onUnhide(entry.packageName)
                        },
                        modifier = if (entry.packageName == refocusKey) {
                            Modifier.focusRequester(neighborFocus)
                        } else {
                            Modifier
                        },
                    )
                }
            }
        }
    }
}

/** 48dp row with a 64x36dp banner thumb + name (Inter 16sp); OK un-hides. */
@Composable
private fun HiddenAppRow(
    label: String,
    packageName: String,
    accent: Color,
    banner: suspend (String) -> ImageBitmap?,
    onUnhide: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    var art by remember(packageName) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(packageName) {
        art = banner(packageName)
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .height(48.dp)
            .onFocusChanged { focused = it.isFocused }
            .settingsFocusLens(focused)
            .clickable(interactionSource = interaction, indication = null, onClick = onUnhide)
            .padding(horizontal = 16.dp),
    ) {
        Box(
            Modifier
                .size(64.dp, 36.dp)
                .clip(RoundedCornerShape(4.dp))
                .background(VelourColors.Surface),
        ) {
            art?.let {
                androidx.compose.foundation.Image(
                    bitmap = it,
                    contentDescription = label,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
        Spacer(Modifier.width(16.dp))
        androidx.tv.material3.Text(
            text = label,
            style = VelourType.body.copy(fontSize = 14.sp),
            color = SettingsPearl,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        androidx.tv.material3.Text(
            text = "Unhide",
            style = VelourType.body.copy(fontSize = 14.sp),
            color = if (focused) SettingsPearl else SettingsSecondary,
        )
    }
}

// ------------------------------------------------------------------------------ MOTION

private val IdleTimeoutChoices = listOf(30, 45, 90, 0)

private fun idleLabel(sec: Int): String = if (sec == 0) "Off" else "${sec}s"

@Composable
private fun MotionPane(
    reduceMotion: Boolean,
    idleTimeoutSec: Int,
    accent: Color,
    onReduceMotion: (Boolean) -> Unit,
    onIdleTimeout: (Int) -> Unit,
) {
    Column(Modifier.fillMaxHeight().verticalScroll(rememberScrollState())) {
        PaneEyebrow("Motion")
        Spacer(Modifier.height(18.dp))
        SettingsToggleRow(
            label = "Reduce motion",
            checked = reduceMotion,
            accent = accent,
            onToggle = onReduceMotion,
        )
        Spacer(Modifier.height(24.dp))
        PaneEyebrow("Idle timeout")
        Spacer(Modifier.height(8.dp))
        IdleTimeoutChoices.forEach { sec ->
            SettingsTextRow(
                label = idleLabel(sec),
                accent = accent,
                selected = sec == idleTimeoutSec,
                onClick = { onIdleTimeout(sec) },
            )
        }
        Spacer(Modifier.height(18.dp))
        androidx.tv.material3.Text(
            text = "After a quiet moment, the launcher settles into its ambient display. Any remote button brings you back.",
            style = VelourType.body.copy(fontSize = 14.sp),
            color = SettingsSecondary,
        )
    }
}

@Composable
private fun SystemPane(accent: Color) {
    val context = LocalContext.current
    fun open(vararg actions: String) {
        for (action in actions.distinct()) {
            val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (runCatching { context.startActivity(intent) }.isSuccess) return
        }
        Toast.makeText(context, "System settings aren't available on this device.", Toast.LENGTH_SHORT).show()
    }
    Column(Modifier.fillMaxHeight().verticalScroll(rememberScrollState())) {
        PaneEyebrow("Your TV, connected")
        Spacer(Modifier.height(14.dp))
        androidx.tv.material3.Text(
            text = "Connections, remotes, picture and sound. Open your TV's system controls without leaving home behind.",
            style = VelourType.body.copy(fontSize = 14.sp),
            color = SettingsSecondary,
        )
        Spacer(Modifier.height(24.dp))
        SettingsTextRow(
            label = "Network & internet",
            trailing = "Wi-Fi · Ethernet",
            accent = accent,
            onClick = { open(Settings.ACTION_WIFI_SETTINGS, Settings.ACTION_WIRELESS_SETTINGS, Settings.ACTION_SETTINGS) },
        )
        SettingsTextRow(
            label = "Remotes & accessories",
            trailing = "Bluetooth",
            accent = accent,
            onClick = { open(Settings.ACTION_BLUETOOTH_SETTINGS, Settings.ACTION_SETTINGS) },
        )
        SettingsTextRow(
            label = "All system settings",
            trailing = "Open",
            accent = accent,
            onClick = { open(Settings.ACTION_SETTINGS) },
        )
    }
}
