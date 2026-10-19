package tv.velvet.ui.sports

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.*
import coil.compose.AsyncImage
import tv.velvet.VelvetApp
import tv.velvet.data.sports.*
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.settings.SettingsRow
import tv.velvet.ui.navigation.LocalDockContentInset
import tv.velvet.ui.theme.VelvetColors
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

internal fun sportsTime(value: String): String = runCatching {
    DateTimeFormatter.ofPattern("EEE h:mm a").withZone(ZoneId.systemDefault()).format(Instant.parse(value))
}.getOrDefault("Time unavailable")

@Composable
fun SportsScreen(onBack: () -> Unit, onEvent: (String, String) -> Unit, onSettings: () -> Unit,
                 launcherSelection: tv.velvet.data.launcher.LauncherSportsSelection? = null) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: SportsViewModel = viewModel(factory = viewModelFactory { initializer { SportsViewModel(app.container.sportsRepository) } })
    val state by vm.state.collectAsStateWithLifecycle()
    var scope by rememberSaveable { mutableStateOf("live") }
    var sportId by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    var searchFocused by remember { mutableStateOf(false) }
    var focusPending by remember { mutableStateOf(true) }
    val keyboard = LocalSoftwareKeyboardController.current
    val searchFocus = remember { FocusRequester() }
    val backFocus = remember { FocusRequester() }
    val requests = remember { mutableMapOf<String, FocusRequester>() }
    val grid = rememberLazyGridState()
    val events = filterSportsEvents(state.catalog?.events.orEmpty(), query, sportId, scope == "upcoming", Instant.now())
    fun refresh() { focusPending = true; vm.refresh(if (scope == "upcoming") "all" else scope) }
    LaunchedEffect(launcherSelection?.requestId) {
        launcherSelection?.let {
            query = it.query
            sportId = it.sportId
            scope = "all"
            focusPending = true
        }
    }
    LaunchedEffect(scope) { refresh() }
    LaunchedEffect(focusPending, state.loading, events) {
        if (focusPending && !state.loading) {
            if (events.isEmpty()) runCatching { backFocus.requestFocus() }
            else {
                val index = events.indexOfFirst { it.id == vm.lastEventId }.coerceAtLeast(0)
                grid.scrollToItem(index); withFrameNanos { }
                runCatching { requests.getOrPut(events[index].id) { FocusRequester() }.requestFocus() }
            }
            focusPending = false
        }
    }
    BackHandler { keyboard?.hide(); onBack() }
    CompositionLocalProvider(LocalContentColor provides VelvetColors.TextPrimary) {
    Column(Modifier.fillMaxSize().background(VelvetColors.Background).padding(horizontal = 48.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Button(onClick = onBack, colors = velvetButtonColors(), modifier = Modifier.focusRequester(backFocus)) { Text("Back") }
            Text("Live Sports", style = MaterialTheme.typography.headlineMedium)
            Spacer(Modifier.weight(1f))
            Button(onClick = ::refresh, colors = velvetButtonColors()) { Text("Refresh") }
            Button(onClick = onSettings, colors = velvetButtonColors()) { Text("Settings") }
        }
        launcherSelection?.let { selection ->
            selection.title?.let { Text(it, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            selection.message?.let { Text(it, color = VelvetColors.TextSecondary, style = MaterialTheme.typography.bodySmall) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            listOf("live" to "Live", "today" to "Today", "upcoming" to "Upcoming", "all" to "All").forEach { (id, name) ->
                Button(onClick = { scope = id }, colors = velvetButtonColors()) { Text(if (scope == id) "✓ $name" else name) }
            }
            BasicTextField(query, onValueChange = { query = it.take(100) }, singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = VelvetColors.TextPrimary), cursorBrush = SolidColor(VelvetColors.FocusRing),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { keyboard?.hide(); focusPending = true }),
                modifier = Modifier.weight(1f).focusRequester(searchFocus).onFocusChanged { searchFocused = it.isFocused }
                    .onPreviewKeyEvent { if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionDown) { keyboard?.hide(); focusPending = true; true } else false }
                    .border(if (searchFocused) 2.dp else 1.dp, if (searchFocused) VelvetColors.FocusRing else VelvetColors.TextTertiary, RoundedCornerShape(8.dp)).padding(12.dp),
                decorationBox = { inner -> Box { if (query.isBlank()) Text("Search events or teams", color = VelvetColors.TextTertiary); inner() } })
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(4.dp), modifier = Modifier.focusRestorer()) {
            item { Button(onClick = { sportId = null }, colors = velvetButtonColors()) { Text(if (sportId == null) "✓ All sports" else "All sports") } }
            items(state.catalog?.sports.orEmpty(), key = { it.id }) { sport ->
                Button(onClick = { sportId = sport.id }, colors = velvetButtonColors()) { Text(if (sportId == sport.id) "✓ ${sport.name}" else sport.name) }
            }
        }
        when {
            state.loading -> Text("Loading events…", color = VelvetColors.TextSecondary)
            state.error != null -> Text(state.error.orEmpty(), color = VelvetColors.TextSecondary)
            state.catalog?.enabled == false -> Text(state.catalog?.message ?: "Live Sports isn't enabled on this backend yet.", color = VelvetColors.TextSecondary)
            events.isEmpty() -> Text(state.catalog?.message ?: "No events match this selection. Try Today, another sport, or a different search.", color = VelvetColors.TextSecondary)
            else -> LazyVerticalGrid(GridCells.Fixed(3), state = grid, verticalArrangement = Arrangement.spacedBy(16.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp), contentPadding = PaddingValues(start = 4.dp, end = 4.dp, top = 4.dp, bottom = 4.dp + LocalDockContentInset.current), modifier = Modifier.weight(1f).focusRestorer()) {
                items(events, key = { it.id }) { event ->
                    val eventFocus = remember(requests, event.id) { requests.getOrPut(event.id) { FocusRequester() } }
                    SettingsRow(onClick = { vm.lastEventId = event.id; onEvent(event.id, event.title) },
                        modifier = Modifier.fillMaxWidth().height(142.dp).focusRequester(eventFocus)) {
                        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                            Text(if (event.isLive) "● LIVE · ${event.sportName}" else "${sportsTime(event.startTime)} · ${event.sportName}",
                                style = MaterialTheme.typography.labelMedium, color = if (event.isLive) VelvetColors.Accent else VelvetColors.TextSecondary)
                            Text(event.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(if (event.sourceCount == 0) "Sources not posted yet" else "${event.sourceCount} sources", color = VelvetColors.TextTertiary,
                                style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
    }
    }
}
