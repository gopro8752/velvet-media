package tv.velvet.ui.live

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import tv.velvet.VelvetApp
import tv.velvet.data.live.filterLiveChannels
import tv.velvet.data.live.LiveChannel
import tv.velvet.data.live.nowAndNext
import java.time.Instant
import kotlinx.coroutines.delay
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.settings.SettingsRow
import tv.velvet.ui.navigation.LocalDockContentInset
import tv.velvet.ui.theme.VelvetColors

@Composable
fun LiveScreen(onBack: () -> Unit, onPlay: (String) -> Unit, onSettings: () -> Unit) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: LiveViewModel = viewModel(factory = viewModelFactory { initializer { LiveViewModel(app.container.liveRepository) } })
    val state by vm.state.collectAsStateWithLifecycle()
    val lastChannel by vm.lastChannelId.collectAsStateWithLifecycle()
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsStateWithLifecycle()
    val keyboard = LocalSoftwareKeyboardController.current
    var query by rememberSaveable { mutableStateOf("") }
    var guideMode by rememberSaveable { mutableStateOf(false) }
    var schedule by remember { mutableStateOf<LiveChannel?>(null) }
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); now = Instant.now() } }
    var focusPending by remember { mutableStateOf(true) }
    var searchFocused by remember { mutableStateOf(false) }
    val grid = rememberLazyGridState()
    val backFocus = remember { FocusRequester() }
    val searchFocus = remember { FocusRequester() }
    val guideFocus = remember { FocusRequester() }
    val requests = remember { mutableMapOf<String, FocusRequester>() }
    val channels = state.catalog?.channels.orEmpty()
    val visible = remember(channels, query) { filterLiveChannels(channels, query, false) }
    val guide = remember(state.guide?.channels) { state.guide?.channels.orEmpty().associateBy { it.channelId } }
    fun requester(id: String) = requests.getOrPut(id) { FocusRequester() }

    LaunchedEffect(lifecycle) {
        if (lifecycle == Lifecycle.State.RESUMED) { focusPending = true; vm.refresh() }
    }
    LaunchedEffect(focusPending, state.loading, visible) {
        if (focusPending && !state.loading) {
            if (visible.isNotEmpty() && state.catalog?.enabled == true) {
                val index = visible.indexOfFirst { it.id == lastChannel }.coerceAtLeast(0)
                grid.scrollToItem(index)
                withFrameNanos { }
                runCatching { requester(visible[index].id).requestFocus() }
            } else runCatching { backFocus.requestFocus() }
            focusPending = false
        }
    }
    BackHandler { keyboard?.hide(); onBack() }

    Column(Modifier.fillMaxSize().background(VelvetColors.Background).padding(horizontal = 48.dp, vertical = 24.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Button(onClick = onBack, colors = velvetButtonColors(), modifier = Modifier.focusRequester(backFocus)) { Text("Back") }
            Text("Live TV", style = MaterialTheme.typography.headlineMedium, color = VelvetColors.TextPrimary)
            Spacer(Modifier.weight(1f))
            Button(onClick = vm::refresh, colors = velvetButtonColors()) { Text("Refresh") }
            Button(onClick = onSettings, colors = velvetButtonColors()) { Text("Settings") }
        }
        Spacer(Modifier.height(18.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            BasicTextField(query, onValueChange = { query = it.take(100) }, singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = VelvetColors.TextPrimary),
                cursorBrush = SolidColor(VelvetColors.FocusRing), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { keyboard?.hide(); focusPending = true }),
                modifier = Modifier.weight(1f).focusRequester(searchFocus).onFocusChanged { searchFocused = it.isFocused }
                    .onPreviewKeyEvent { event ->
                        if (event.type == KeyEventType.KeyDown && event.key == Key.DirectionDown) {
                            keyboard?.hide(); focusPending = true; true
                        } else if (event.type == KeyEventType.KeyDown && event.key == Key.DirectionRight) {
                            keyboard?.hide(); guideFocus.requestFocus(); true
                        } else false
                    }
                    .border(if (searchFocused) 2.dp else 1.dp,
                        if (searchFocused) VelvetColors.FocusRing else VelvetColors.TextTertiary,
                        RoundedCornerShape(8.dp)).padding(12.dp),
                decorationBox = { inner -> Box { if (query.isEmpty()) Text("Search channels", color = VelvetColors.TextTertiary); inner() } })
            Button(onClick = { keyboard?.hide(); guideMode = !guideMode }, modifier = Modifier.focusRequester(guideFocus).focusProperties { left = searchFocus }, colors = velvetButtonColors()) {
                Text(if (guideMode) "✓ Guide" else "Guide")
            }
            Text("${visible.size} channels", style = MaterialTheme.typography.bodyMedium, color = VelvetColors.TextSecondary)
        }
        Spacer(Modifier.height(18.dp))
        if (guideMode) Text(state.guideError ?: state.guide?.message ?: "Select a channel for its schedule.", color = VelvetColors.TextSecondary)
        state.error?.let { Text(it, color = VelvetColors.TextSecondary, modifier = Modifier.padding(bottom = 12.dp)) }
        when {
            state.loading && channels.isEmpty() -> Text("Loading channels…", color = VelvetColors.TextSecondary)
            state.catalog?.enabled == false -> Text(state.catalog?.message ?: "Live TV isn't set up yet. Connect a live source on Velvet Backend, then refresh.",
                color = VelvetColors.TextSecondary, modifier = Modifier.width(620.dp))
            visible.isEmpty() -> Text(if (query.isNotBlank()) "No channels match. Try another search."
                else state.catalog?.message ?: if (state.error != null) "Choose Refresh to try again, or check Settings."
                    else "No channels are available yet. Refresh after connecting your live source.", color = VelvetColors.TextSecondary)
            else -> LazyVerticalGrid(columns = GridCells.Fixed(3), state = grid,
                contentPadding = PaddingValues(start = 4.dp, end = 4.dp, top = 4.dp, bottom = 4.dp + LocalDockContentInset.current), verticalArrangement = Arrangement.spacedBy(14.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.weight(1f).focusRestorer()) {
                items(visible, key = { it.id }) { channel ->
                    SettingsRow(onClick = {
                        keyboard?.hide()
                        vm.lastChannelId.value = channel.id
                        if (guideMode) schedule = channel else onPlay(channel.id)
                    }, modifier = Modifier.fillMaxWidth().height(if (guideMode) 168.dp else 104.dp).focusRequester(requester(channel.id))
                        .focusProperties { if (visible.indexOf(channel) < 3) up = guideFocus }) {
                        if (channel.logoUrl != null) {
                            AsyncImage(channel.logoUrl, contentDescription = null, modifier = Modifier.size(46.dp))
                            Spacer(Modifier.width(12.dp))
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(channel.name, style = MaterialTheme.typography.titleMedium, color = VelvetColors.TextPrimary,
                                maxLines = 2, overflow = TextOverflow.Ellipsis)
                            if (guideMode) {
                                val programs = guide[channel.id]?.programs.orEmpty()
                                val (current, next) = remember(programs, now) { nowAndNext(programs, now) }
                                Text(current?.let { "Now · ${it.title}" } ?: "Now · Guide unavailable", maxLines = 2,
                                    overflow = TextOverflow.Ellipsis, color = VelvetColors.TextSecondary, style = MaterialTheme.typography.bodyMedium)
                                Text(next?.let { "Next · ${it.title}" } ?: "Next · Guide unavailable", maxLines = 2,
                                    overflow = TextOverflow.Ellipsis, color = VelvetColors.TextTertiary, style = MaterialTheme.typography.bodySmall)
                            }
                            listOfNotNull(channel.number?.takeIf { it.isNotBlank() }, channel.group?.takeIf { it.isNotBlank() })
                                .joinToString(" · ").takeIf { it.isNotBlank() }?.let {
                                    Text(it, style = MaterialTheme.typography.labelSmall, color = VelvetColors.TextSecondary,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                        }
                    }
                }
            }
        }
    }

    schedule?.let { channel ->
        LiveGuideDialog(channel, guide[channel.id]?.programs.orEmpty(), state.guideError ?: state.guide?.message,
            onWatch = { schedule = null; onPlay(channel.id) }, onDismiss = { schedule = null })
    }
}
