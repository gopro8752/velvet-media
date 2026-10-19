@file:OptIn(ExperimentalComposeUiApi::class)

package tv.velour

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.graphics.graphicsLayer
import androidx.core.view.WindowCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import tv.velour.ui.home.HomeScreen
import tv.velour.ui.home.HomeViewModel
import tv.velour.ui.settings.SettingsScreen
import tv.velour.ui.settings.SettingsViewModel
import tv.velour.ui.theme.VelourColors

/** The launcher's two screens — a plain state machine, no Navigation lib (ARCHITECTURE.md). */
private enum class VelourScreen { Home, Settings }

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Full-bleed: content draws behind transparent system bars; the wallpaper owns
        // every pixel. windowBackground stays #060709 (no flash on cold start).
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT

        // Velour IS the ambient screensaver: keep the panel awake while the launcher is
        // foreground so the system never blanks the display or hands it to a dream. (With
        // the stock Daydream disabled, idle would otherwise just turn the screen off.)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val container = (application as VelourApp).container
        val factory = viewModelFactory {
            initializer {
                HomeViewModel(
                    appRepository = container.appRepository,
                    settingsRepository = container.settingsRepository,
                    weatherRepository = container.weatherRepository,
                    velvetRepository = container.velvetRepository,
                )
            }
            initializer {
                SettingsViewModel(
                    appRepository = container.appRepository,
                    settingsRepository = container.settingsRepository,
                    weatherRepository = container.weatherRepository,
                )
            }
        }

        setContent {
            val homeViewModel: HomeViewModel = viewModel(factory = factory)
            val settingsViewModel: SettingsViewModel = viewModel(factory = factory)
            VelourRoot(homeViewModel, settingsViewModel)
        }
    }
}

@Composable
private fun VelourRoot(
    homeViewModel: HomeViewModel,
    settingsViewModel: SettingsViewModel,
) {
    var screen by remember { mutableStateOf(VelourScreen.Home) }

    Box(
        Modifier
            .fillMaxSize()
            .background(VelourColors.Void),
    ) {
        // Home stays composed beneath Settings so its scroll and ViewModel-fed state
        // survive the round trip. Focus restoration is owned by HomeScreen itself,
        // keyed on `active` (an outer focusRestorer proved racy: a failed restore left
        // nothing focused and key events stopped reaching the home tree entirely).
        // While Settings covers it, the subtree drops to alpha 0 and `active = false`
        // stops the home wallpaper's frame loop (alpha-0 alone only skips the GPU
        // composite, not the per-frame field render).
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = if (screen == VelourScreen.Settings) 0f else 1f },
        ) {
            // Inner gate: while Settings covers Home, focus search must never land in
            // the invisible home tree (Settings flows that release focus — edit-row
            // commits, un-hiding the last app — would otherwise let the next D-pad
            // event silently navigate, and OK launch, an unseen home screen). The
            // gate sits on its own group so the outer focusRestorer keeps working;
            // programmatic restore bypasses `enter` by design.
            Box(
                Modifier
                    .fillMaxSize()
                    .focusProperties {
                        canFocus = screen == VelourScreen.Home
                        enter = {
                            if (screen == VelourScreen.Home) FocusRequester.Default
                            else FocusRequester.Cancel
                        }
                    }
                    .focusGroup(),
            ) {
                HomeScreen(
                    onOpenSettings = { screen = VelourScreen.Settings },
                    viewModel = homeViewModel,
                    active = screen == VelourScreen.Home,
                )
            }
        }

        if (screen == VelourScreen.Settings) {
            // Composed after Home, so its BackHandler registers later and wins.
            SettingsScreen(
                onBack = { screen = VelourScreen.Home },
                viewModel = settingsViewModel,
            )
        }
    }

    // Home never left composition, so its LaunchedEffect(Unit) "resume" hook does not
    // re-fire — consume the settings-touched flag ("LOOKS GOOD.") from here instead.
    // (HomeScreen restores focus itself when `active` flips back on.)
    var cameFromSettings by remember { mutableStateOf(false) }
    LaunchedEffect(screen) {
        if (screen == VelourScreen.Home && cameFromSettings) {
            homeViewModel.onHomeResumed()
        }
        cameFromSettings = screen == VelourScreen.Settings
    }
}
