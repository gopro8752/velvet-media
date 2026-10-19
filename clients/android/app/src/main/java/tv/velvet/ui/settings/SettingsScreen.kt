package tv.velvet.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import tv.velvet.VelvetApp
import tv.velvet.ui.navigation.LocalDockContentInset
import tv.velvet.ui.theme.VelvetColors

private val COUNTDOWN_CHOICES = listOf(5, 8, 10, 15)
private val QUALITY_CHOICES = listOf("2160p", "1080p", "720p")

@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: SettingsViewModel = viewModel(
        factory = viewModelFactory { initializer { SettingsViewModel(app.container) } }
    )
    val state by vm.state.collectAsStateWithLifecycle()

    var showEditKey by remember { mutableStateOf(false) }
    var showEditBackendUrl by remember { mutableStateOf(false) }
    var showEditSyncToken by remember { mutableStateOf(false) }
    val syncStatus by vm.syncStatus.collectAsStateWithLifecycle()

    val backendFocus = remember { FocusRequester() }

    BackHandler { onBack() }

    LazyColumn(
        contentPadding = PaddingValues(start = 48.dp, end = 48.dp, top = 24.dp, bottom = 27.dp + LocalDockContentInset.current),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxSize()
            .focusRestorer()
            .background(VelvetColors.Background),
    ) {
        item {
            Text(
                text = "Settings",
                style = MaterialTheme.typography.headlineLarge,
                color = VelvetColors.TextPrimary,
            )
        }

        // ------------------------------------------------------------- Backend
        item { SettingsSectionHeader("Backend") }
        item {
            Text(
                text = "One URL to your Velvet backend — streaming and watch-state " +
                    "sync both use it.",
                style = MaterialTheme.typography.bodyMedium,
                color = VelvetColors.TextTertiary,
                modifier = Modifier.padding(bottom = 2.dp),
            )
        }
        item {
            SettingsRow(
                onClick = { showEditBackendUrl = true },
                modifier = Modifier
                    .width(SettingsDefaults.SectionWidth)
                    .focusRequester(backendFocus),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text = "Backend URL",
                        style = MaterialTheme.typography.titleMedium,
                        color = VelvetColors.TextPrimary,
                    )
                    Text(
                        text = state.settings.backendUrl.ifBlank { "Not set" },
                        style = MaterialTheme.typography.bodySmall,
                        color = VelvetColors.TextTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.width(16.dp))
                Icon(
                    imageVector = Icons.Default.Edit,
                    contentDescription = "Edit backend URL",
                    tint = VelvetColors.TextSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        item {
            SettingsRow(
                onClick = { showEditSyncToken = true },
                modifier = Modifier.width(SettingsDefaults.SectionWidth),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text = "Token (optional)",
                        style = MaterialTheme.typography.titleMedium,
                        color = VelvetColors.TextPrimary,
                    )
                    Text(
                        text = if (state.settings.syncToken.isBlank()) "Not set" else "••••••••",
                        style = MaterialTheme.typography.bodySmall,
                        color = VelvetColors.TextTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.width(16.dp))
                Icon(
                    imageVector = Icons.Default.Edit,
                    contentDescription = "Edit token",
                    tint = VelvetColors.TextSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        item {
            SettingsRow(
                onClick = { vm.syncNow() },
                modifier = Modifier.width(SettingsDefaults.SectionWidth),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text = "Sync now",
                        style = MaterialTheme.typography.titleMedium,
                        color = VelvetColors.TextPrimary,
                    )
                    Text(
                        text = syncStatus,
                        style = MaterialTheme.typography.bodySmall,
                        color = VelvetColors.TextTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.width(16.dp))
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = "Sync now",
                    tint = VelvetColors.TextSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        // ----------------------------------------------------------- Home Rows
        item { SettingsSectionHeader("Home Rows") }
        item {
            Text(
                text = "Rows appear on Home in this order. Select a row to show or hide it.",
                style = MaterialTheme.typography.bodyMedium,
                color = VelvetColors.TextTertiary,
                modifier = Modifier.padding(bottom = 2.dp),
            )
        }
        items(state.rowEntries, key = { "homerow_${it.spec.id}" }) { entry ->
            HomeRowItem(
                entry = entry,
                onToggle = { vm.toggleRow(entry.spec.id) },
                onMoveUp = { vm.moveRow(entry.spec.id, -1) },
                onMoveDown = { vm.moveRow(entry.spec.id, +1) },
            )
        }
        item {
            Column {
                Spacer(Modifier.height(4.dp))
                VelvetButton(
                    label = "Reset to default",
                    icon = Icons.Default.Refresh,
                    onClick = vm::resetRowOrder,
                )
            }
        }

        // ------------------------------------------------------------ Playback
        item { SettingsSectionHeader("Playback") }
        item {
            SettingsRow(
                onClick = { vm.setAutoplayNext(!state.settings.autoplayNext) },
                modifier = Modifier.width(SettingsDefaults.SectionWidth),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text = "Autoplay next episode",
                        style = MaterialTheme.typography.titleMedium,
                        color = VelvetColors.TextPrimary,
                    )
                    Text(
                        text = "Start the next episode automatically with a countdown",
                        style = MaterialTheme.typography.bodySmall,
                        color = VelvetColors.TextTertiary,
                    )
                }
                Spacer(Modifier.width(16.dp))
                VelvetSwitchIndicator(checked = state.settings.autoplayNext)
            }
        }
        item {
            ChipPickerRow(
                label = "Up next countdown",
                options = COUNTDOWN_CHOICES.map { "${it}s" },
                selectedIndex = COUNTDOWN_CHOICES.indexOf(state.settings.autoplayCountdownSecs),
                onSelect = { vm.setCountdownSecs(COUNTDOWN_CHOICES[it]) },
            )
        }
        item {
            ChipPickerRow(
                label = "Preferred quality",
                options = QUALITY_CHOICES,
                selectedIndex = QUALITY_CHOICES.indexOf(state.settings.preferredQuality),
                onSelect = { vm.setPreferredQuality(QUALITY_CHOICES[it]) },
            )
        }
        item {
            SettingsRow(
                onClick = { vm.setTunneledPlayback(!state.settings.tunneledPlayback) },
                modifier = Modifier.width(SettingsDefaults.SectionWidth),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text = "Tunneled playback",
                        style = MaterialTheme.typography.titleMedium,
                        color = VelvetColors.TextPrimary,
                    )
                    Text(
                        text = "Needed for some Dolby Vision releases. Turn off if video misbehaves.",
                        style = MaterialTheme.typography.bodySmall,
                        color = VelvetColors.TextTertiary,
                    )
                }
                Spacer(Modifier.width(16.dp))
                VelvetSwitchIndicator(checked = state.settings.tunneledPlayback)
            }
        }

        // ---------------------------------------------------------------- TMDB
        item { SettingsSectionHeader("TMDB") }
        item {
            SettingsRow(
                onClick = { showEditKey = true },
                modifier = Modifier.width(SettingsDefaults.SectionWidth),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text = "API Key",
                        style = MaterialTheme.typography.titleMedium,
                        color = VelvetColors.TextPrimary,
                    )
                    Text(
                        text = if (state.settings.tmdbApiKey.isBlank()) "Not configured" else "Configured",
                        style = MaterialTheme.typography.bodySmall,
                        color = VelvetColors.TextTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.width(16.dp))
                Icon(
                    imageVector = Icons.Default.Edit,
                    contentDescription = "Edit API key",
                    tint = VelvetColors.TextSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }

    if (showEditKey) {
        EditTmdbKeyDialog(
            currentKey = state.settings.tmdbApiKey,
            onSave = { key ->
                vm.setTmdbApiKey(key)
                showEditKey = false
            },
            onDismiss = { showEditKey = false },
        )
    }
    if (showEditBackendUrl) {
        EditSyncValueDialog(
            title = "Backend URL",
            hint = "https://backend.example.com",
            helper = "Your velvet-backend address. Streaming and sync both use this.",
            initialValue = state.settings.backendUrl,
            onSave = { url ->
                vm.setBackendUrl(url)
                showEditBackendUrl = false
            },
            onDismiss = { showEditBackendUrl = false },
        )
    }
    if (showEditSyncToken) {
        EditSyncValueDialog(
            title = "Token",
            hint = "Bearer token (optional)",
            helper = "Only needed if the backend was started with a token.",
            initialValue = state.settings.syncToken,
            onSave = { token ->
                vm.setSyncToken(token)
                showEditSyncToken = false
            },
            onDismiss = { showEditSyncToken = false },
        )
    }
}

// ------------------------------------------------------------------- home rows

@Composable
private fun HomeRowItem(
    entry: HomeRowEntry,
    onToggle: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.width(SettingsDefaults.SectionWidth),
    ) {
        SettingsRow(onClick = onToggle, modifier = Modifier.weight(1f)) {
            VelvetCheckIndicator(checked = entry.enabled)
            Spacer(Modifier.width(14.dp))
            Text(
                text = entry.spec.title,
                style = MaterialTheme.typography.titleMedium,
                color = if (entry.enabled) VelvetColors.TextPrimary else VelvetColors.TextTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
        }
        if (entry.enabled) {
            Spacer(Modifier.width(8.dp))
            // Arrows stay focusable at the edges (no-op) so focus never gets stranded
            // when a row reaches the top/bottom; they just dim.
            VelvetIconButton(
                icon = Icons.Default.KeyboardArrowUp,
                contentDescription = "Move ${entry.spec.title} up",
                onClick = { if (entry.canMoveUp) onMoveUp() },
                dimmed = !entry.canMoveUp,
            )
            Spacer(Modifier.width(6.dp))
            VelvetIconButton(
                icon = Icons.Default.KeyboardArrowDown,
                contentDescription = "Move ${entry.spec.title} down",
                onClick = { if (entry.canMoveDown) onMoveDown() },
                dimmed = !entry.canMoveDown,
            )
        }
    }
}

// -------------------------------------------------------------------- playback

@Composable
private fun ChipPickerRow(
    label: String,
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
) {
    Column(modifier = Modifier.width(SettingsDefaults.SectionWidth)) {
        Spacer(Modifier.height(6.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.titleMedium,
            color = VelvetColors.TextPrimary,
        )
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            options.forEachIndexed { index, option ->
                VelvetChip(
                    label = option,
                    selected = index == selectedIndex,
                    onClick = { onSelect(index) },
                )
            }
        }
    }
}

// ------------------------------------------------------------------------ sync

/** Edit dialog for the sync URL/token rows — same shape as [EditTmdbKeyDialog]. */
@Composable
private fun EditSyncValueDialog(
    title: String,
    hint: String,
    helper: String,
    initialValue: String,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var value by remember { mutableStateOf(initialValue) }
    val fieldFocus = remember { FocusRequester() }

    VelvetDialog(title = title, onDismiss = onDismiss) {
        VelvetTextField(
            value = value,
            onValueChange = { value = it },
            hint = hint,
            focusRequester = fieldFocus,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = helper,
            style = MaterialTheme.typography.labelMedium,
            color = VelvetColors.TextTertiary,
        )
        Spacer(Modifier.height(20.dp))
        DialogButtons(
            confirmLabel = "Save",
            onConfirm = { onSave(value) },
            onCancel = onDismiss,
        )
        LaunchedEffect(Unit) { fieldFocus.requestFocus() }
    }
}

// ------------------------------------------------------------------------ tmdb

@Composable
private fun EditTmdbKeyDialog(
    currentKey: String,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var key by remember { mutableStateOf(currentKey) }
    val fieldFocus = remember { FocusRequester() }

    VelvetDialog(title = "TMDB API Key", onDismiss = onDismiss) {
        VelvetTextField(
            value = key,
            onValueChange = { key = it },
            hint = "TMDB API key",
            focusRequester = fieldFocus,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Used for all discovery, search and artwork.",
            style = MaterialTheme.typography.labelMedium,
            color = VelvetColors.TextTertiary,
        )
        Spacer(Modifier.height(20.dp))
        DialogButtons(
            confirmLabel = "Save",
            onConfirm = { onSave(key) },
            onCancel = onDismiss,
            confirmEnabled = key.isNotBlank(),
        )
        LaunchedEffect(Unit) { fieldFocus.requestFocus() }
    }
}
