package tv.velvet.ui.live

import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Search
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.tv.material3.*
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import tv.velvet.VelvetApp
import tv.velvet.data.live.*
import tv.velvet.ui.components.velvetButtonColors
import tv.velvet.ui.navigation.LocalDockContentInset
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val GuideInk = Color(0xFF090C15)
private val GuideLilac = Color(0xFFD2C4FF)
private val GuideMuted = Color(0xFFA2A9BB)
private val GuideHairline = Color.White.copy(alpha = .09f)
private val railWidth = 154.dp
private const val windowSeconds = 7_200L
private val guideClockFormatter = DateTimeFormatter.ofPattern("h:mm a")
private fun clockTime(time: Instant) = guideClockFormatter.withZone(ZoneId.systemDefault()).format(time)
private fun programTime(program: LiveProgram) = "${clockTime(Instant.parse(program.startTime))} – ${clockTime(Instant.parse(program.endTime))}"

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LiveScreen(onBack: () -> Unit, onPlay: (String) -> Unit, onSettings: () -> Unit) {
    val app = LocalContext.current.applicationContext as VelvetApp
    val vm: LiveViewModel = viewModel(factory = viewModelFactory { initializer {
        LiveViewModel(app.container.liveRepository, LiveGuidePreferences(app, app.container.settingsRepository))
    } })
    val state by vm.state.collectAsStateWithLifecycle()
    val favorites by vm.favoriteIds.collectAsStateWithLifecycle()
    val lastChannel by vm.lastChannelId.collectAsStateWithLifecycle()
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsStateWithLifecycle()
    val keyboard = LocalSoftwareKeyboardController.current
    var query by rememberSaveable { mutableStateOf("") }
    var favoritesOnly by rememberSaveable { mutableStateOf(false) }
    var showSearch by remember { mutableStateOf(false) }
    var details by remember { mutableStateOf<Pair<LiveChannel, LiveProgram?>?>(null) }
    var now by remember { mutableStateOf(Instant.now()) }
    var windowEpoch by rememberSaveable { mutableLongStateOf(liveGuideWindowStart(Instant.now()).epochSecond) }
    var anchorEpoch by rememberSaveable { mutableLongStateOf(Instant.now().epochSecond) }
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var railSelected by rememberSaveable { mutableStateOf(false) }
    var followNow by rememberSaveable { mutableStateOf(true) }
    var gridFocused by remember { mutableStateOf(false) }
    var focusPending by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    val focusJob = remember { arrayOfNulls<Job>(1) }
    val list = rememberLazyListState()
    val guideScroll = remember { object : BringIntoViewSpec {
        override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float) = 0f
    } }
    val allFocus = remember { FocusRequester() }
    val requests = remember { mutableMapOf<String, FocusRequester>() }
    val start = Instant.ofEpochSecond(windowEpoch)
    val end = start.plusSeconds(windowSeconds)
    val anchor = Instant.ofEpochSecond(anchorEpoch)
    val channels = state.catalog?.channels.orEmpty()
    val schedules = remember(state.guide) { state.guide?.channels.orEmpty().associate { it.channelId to validPrograms(it.programs) } }
    val visible = remember(channels, schedules, query, favorites, favoritesOnly, now) {
        filterGuideChannels(channels, schedules, query, favorites, favoritesOnly, now)
    }
    // Parse only on-screen rows as the remote moves, rather than rebuilding a
    // 254-channel day on the UI thread each time the time window changes.
    val slotCache = remember(schedules, start) { mutableMapOf<String, List<LiveGuideSlot>>() }
    fun slotsFor(id: String?) = if (id == null) emptyList() else slotCache.getOrPut(id) { liveGuideSlots(schedules[id].orEmpty(), start, end) }
    val selected = visible.firstOrNull { it.id == selectedId } ?: visible.firstOrNull()
    val selectedSlots = slotsFor(selected?.id)
    val selectedSlot = selectedSlots.getOrNull(liveGuideSlotIndex(selectedSlots, anchor))
    val selectedProgram = if (railSelected) nowAndNext(schedules[selected?.id].orEmpty(), now).first else selectedSlot?.program
    fun requester(id: String) = requests.getOrPut(id) { FocusRequester() }
    fun focusChannel(index: Int) {
        if (visible.isEmpty()) return
        val target = index.coerceIn(0, visible.lastIndex)
        val targetId = visible[target].id
        selectedId = targetId
        focusJob[0]?.cancel()
        focusJob[0] = scope.launch {
            val info = list.layoutInfo
            val item = info.visibleItemsInfo.firstOrNull { it.index == target }
            if (item == null) list.scrollToItem(target.coerceAtMost((visible.size - 4).coerceAtLeast(0)))
            else if (item.offset < info.viewportStartOffset) list.scrollBy((item.offset - info.viewportStartOffset).toFloat())
            else if (item.offset + item.size > info.viewportEndOffset) list.scrollBy((item.offset + item.size - info.viewportEndOffset).toFloat())
            withFrameNanos { }
            if (selectedId == targetId) runCatching { requester(targetId).requestFocus() }
        }
    }
    fun watch(channel: LiveChannel) { vm.lastChannelId.value = channel.id; onPlay(channel.id) }
    fun activate(channel: LiveChannel) {
        val entry = slotsFor(channel.id).let { it.getOrNull(liveGuideSlotIndex(it, anchor)) }?.program
        if (railSelected || entry == null || (Instant.parse(entry.startTime) <= now && Instant.parse(entry.endTime) > now)) watch(channel)
        else details = channel to entry
    }
    fun returnToNow() {
        followNow = true
        windowEpoch = liveGuideWindowStart(now).epochSecond; anchorEpoch = now.epochSecond; railSelected = false
        focusChannel(visible.indexOfFirst { it.id == selected?.id }.coerceAtLeast(0))
    }
    fun shiftWindow(direction: Int) {
        followNow = false
        val minimum = liveGuideWindowStart(now).epochSecond
        windowEpoch = (windowEpoch + direction * windowSeconds).coerceIn(minimum, minimum + 22 * 3600)
        anchorEpoch = windowEpoch + 1; railSelected = false
    }
    fun updateClock() {
        now = Instant.now()
        if (followNow || windowEpoch + windowSeconds <= now.epochSecond) {
            followNow = true; windowEpoch = liveGuideWindowStart(now).epochSecond; anchorEpoch = now.epochSecond
        }
    }
    LaunchedEffect(Unit) { keyboard?.hide(); while (true) { delay(30_000); updateClock() } }
    LaunchedEffect(lifecycle) {
        if (lifecycle == Lifecycle.State.RESUMED) {
            updateClock(); focusPending = true; vm.refresh()
            while (true) { delay(300_000); vm.refresh() }
        }
    }
    LaunchedEffect(visible.map { it.id }) {
        if (selectedId != null && visible.none { it.id == selectedId }) {
            selectedId = visible.getOrNull(list.firstVisibleItemIndex.coerceAtMost((visible.size - 1).coerceAtLeast(0)))?.id
            focusPending = true
        }
    }
    LaunchedEffect(focusPending, state.loading, visible) {
        if (focusPending && !state.loading) {
            if (visible.isEmpty()) runCatching { allFocus.requestFocus() }
            else focusChannel(visible.indexOfFirst { it.id == (selectedId ?: lastChannel) }.coerceAtLeast(0))
            focusPending = false
        }
    }
    BackHandler { onBack() }
    Box(Modifier.fillMaxSize().background(GuideInk)) {
        Box(Modifier.fillMaxSize().background(Brush.radialGradient(
            listOf(Color(0xFF252137).copy(alpha = .8f), GuideInk.copy(alpha = 0f)), center = Offset(360f, 0f), radius = 1250f)))
        Column(Modifier.fillMaxSize().padding(start = 36.dp, end = 36.dp, top = 22.dp, bottom = 12.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Live TV", fontSize = 28.sp, fontWeight = FontWeight.SemiBold, color = Color.White, letterSpacing = (-.7).sp)
                Spacer(Modifier.width(14.dp))
                Text("THE GUIDE", fontSize = 9.sp, letterSpacing = 2.sp, color = GuideLilac.copy(alpha = .75f))
                Spacer(Modifier.weight(1f))
                Text(DateTimeFormatter.ofPattern("EEEE, MMMM d").withZone(ZoneId.systemDefault()).format(now), fontSize = 12.sp, color = GuideMuted)
                Spacer(Modifier.width(18.dp))
                Text(clockTime(now), fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Color.White)
            }
            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth().onPreviewKeyEvent {
                if (visible.isNotEmpty() && it.type == KeyEventType.KeyDown && it.key == Key.DirectionDown) {
                    focusChannel(visible.indexOfFirst { channel -> channel.id == selected?.id }.coerceAtLeast(0)); true
                } else false
            }, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                GuideChip("All channels", selected = !favoritesOnly, modifier = Modifier.focusRequester(allFocus)) { favoritesOnly = false; focusPending = true }
                GuideChip("★ Favorites", selected = favoritesOnly) { favoritesOnly = true; focusPending = true }
                GuideChip(if (query.isBlank()) "Search" else query.take(22), icon = Icons.Outlined.Search, selected = query.isNotBlank()) { showSearch = true }
                Spacer(Modifier.weight(1f))
                GuideChip("Now", selected = now >= start && now < end) { returnToNow() }
                GuideChip("Earlier", icon = Icons.Filled.KeyboardArrowLeft, compact = true) { shiftWindow(-1) }
                GuideChip("Later", icon = Icons.Filled.KeyboardArrowRight, compact = true) { shiftWindow(1) }
                if (selected != null) GuideChip(if (selected.id in favorites) "★ Saved" else "☆ Favorite") { vm.toggleFavorite(selected.id) }
            }
            Spacer(Modifier.height(14.dp))
            GuideSelection(selected, selectedProgram, state.loading && channels.isEmpty())
            Spacer(Modifier.height(14.dp))
            when {
                state.catalog?.enabled == false -> GuideEmpty("Your live lineup starts here", state.catalog?.message ?: "Connect a live source in Settings.", "Settings", onSettings)
                channels.isEmpty() && state.loading -> GuideEmpty("Finding your channels", "Your guide is loading…")
                channels.isEmpty() -> GuideEmpty("Couldn't load channels", state.error ?: "Check your connection and try again.", "Refresh", vm::refresh)
                visible.isEmpty() -> GuideEmpty(if (query.isNotBlank()) "No matches" else "Make this guide yours",
                    if (query.isNotBlank()) "Search for a channel, show, or channel number." else "Choose a channel in All channels, then select ☆ Favorite to keep it here.")
                else -> {
                    BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(16.dp))
                        .background(Color.White.copy(alpha = .025f)).border(1.dp, GuideHairline, RoundedCornerShape(16.dp))) {
                        val timelineWidth = maxWidth - railWidth - 16.dp
                        Column(Modifier.fillMaxSize().padding(8.dp)) {
                            Row(Modifier.height(30.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text("${visible.size} CHANNELS", modifier = Modifier.width(railWidth).padding(start = 10.dp), color = GuideMuted, fontSize = 9.sp, letterSpacing = 1.5.sp)
                                Row(Modifier.width(timelineWidth)) {
                                    repeat(4) { tick -> Text(clockTime(start.plusSeconds(tick * 1800L)), modifier = Modifier.weight(1f).padding(start = 10.dp),
                                        fontSize = 11.sp, color = if (tick == 0) GuideLilac else GuideMuted, fontWeight = FontWeight.Medium) }
                                }
                            }
                            Box(Modifier.weight(1f)) {
                                // Rows are revealed before focus moves; avoid a second TV pivot scroll.
                                CompositionLocalProvider(LocalBringIntoViewSpec provides guideScroll) { LazyColumn(state = list, verticalArrangement = Arrangement.spacedBy(5.dp),
                                    contentPadding = PaddingValues(top = 3.dp, bottom = 5.dp + LocalDockContentInset.current), modifier = Modifier.fillMaxSize()) {
                                    itemsIndexed(visible, key = { _, channel -> channel.id }) { index, channel ->
                                        val rowSlots = slotsFor(channel.id)
                                        val slotIndex = liveGuideSlotIndex(rowSlots, anchor)
                                        var focused by remember(channel.id) { mutableStateOf(false) }
                                        Row(Modifier.fillMaxWidth().height(64.dp).focusRequester(requester(channel.id))
                                            .onFocusChanged { focused = it.isFocused; if (it.isFocused) { selectedId = channel.id; gridFocused = true } else if (selectedId == channel.id) gridFocused = false }
                                            .onPreviewKeyEvent { event ->
                                                val key = event.key
                                                if (event.type == KeyEventType.KeyUp && key in listOf(Key.Enter, Key.NumPadEnter, Key.DirectionCenter)) return@onPreviewKeyEvent true
                                                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                                                when (key) {
                                                    Key.DirectionDown -> { focusChannel(visible.indexOfFirst { it.id == selectedId }.coerceAtLeast(index) + 1); true }
                                                    Key.DirectionUp -> { val active = visible.indexOfFirst { it.id == selectedId }.coerceAtLeast(0); if (active == 0) allFocus.requestFocus() else focusChannel(active - 1); true }
                                                    Key.DirectionLeft -> {
                                                        followNow = false
                                                        if (railSelected) allFocus.requestFocus()
                                                        else if (slotIndex > 0) anchorEpoch = rowSlots[slotIndex - 1].start.epochSecond + 1
                                                        else if (windowEpoch > liveGuideWindowStart(now).epochSecond) { shiftWindow(-1); anchorEpoch = windowEpoch + windowSeconds - 1 }
                                                        else railSelected = true
                                                        true
                                                    }
                                                    Key.DirectionRight -> {
                                                        followNow = false
                                                        if (railSelected) railSelected = false else if (slotIndex < rowSlots.lastIndex) anchorEpoch = rowSlots[slotIndex + 1].start.epochSecond + 1 else shiftWindow(1)
                                                        true
                                                    }
                                                    Key.Enter, Key.NumPadEnter, Key.DirectionCenter -> { if (event.nativeKeyEvent.repeatCount == 0) activate(channel); true }
                                                    else -> false
                                                }
                                            }.semantics { role = Role.Button; contentDescription = channel.name + ", " + (rowSlots.getOrNull(slotIndex)?.program?.title ?: "Schedule unavailable")
                                                onClick("Watch or view program") { activate(channel); true } }.focusable(), verticalAlignment = Alignment.CenterVertically) {
                                            GuideChannelRail(channel, channel.id in favorites, focused && railSelected, focused, Modifier.width(railWidth).fillMaxHeight())
                                            Row(Modifier.weight(1f).fillMaxHeight()) {
                                                rowSlots.forEachIndexed { cellIndex, slot -> GuideProgramCell(slot, now, focused && !railSelected && cellIndex == slotIndex,
                                                    Modifier.weight(slot.seconds.toFloat().coerceAtLeast(1f)).fillMaxHeight()) }
                                            }
                                        }
                                    }
                                }
                                }
                                if (now >= start && now < end) {
                                    val fraction = Duration.between(start, now).seconds.toFloat() / windowSeconds
                                    Box(Modifier.offset(x = railWidth + timelineWidth * fraction).width(1.dp).fillMaxHeight().background(GuideLilac.copy(alpha = .23f)))
                                    Box(Modifier.offset(x = railWidth + timelineWidth * fraction - 2.dp).size(5.dp).clip(RoundedCornerShape(3.dp)).background(GuideLilac))
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(state.guideError ?: if (now >= start && now < end) "●  On now" else DateTimeFormatter.ofPattern("EEE, MMM d").withZone(ZoneId.systemDefault()).format(start), fontSize = 10.sp, color = GuideLilac)
                        Spacer(Modifier.weight(1f))
                        Text(if (gridFocused) "↑ ↓  Channels     ← →  Programs     OK  ${if (selectedProgram != null && Instant.parse(selectedProgram.startTime) > now) "Details" else "Watch"}" else "Press ↓ to browse your guide", fontSize = 10.sp, color = GuideMuted)
                    }
                }
            }
        }
    }
    if (showSearch) GuideSearchDialog(query, onSearch = { value ->
        query = value; showSearch = false; favoritesOnly = false
        val first = filterGuideChannels(channels, schedules, value, favorites, false, now).firstOrNull()
        selectedId = first?.id
        val match = if (first != null && value.isNotBlank() && filterLiveChannels(listOf(first), value, false).isEmpty())
            schedules[first.id]?.firstOrNull { Instant.parse(it.endTime) > now && (it.title.contains(value.trim(), true) || it.episodeTitle?.contains(value.trim(), true) == true) } else null
        val target = match?.let { Instant.parse(it.startTime).coerceAtLeast(now) } ?: now
        windowEpoch = liveGuideWindowStart(target).epochSecond; anchorEpoch = target.epochSecond; railSelected = false; followNow = match == null; focusPending = true
    }, onDismiss = { showSearch = false; focusPending = true })
    details?.let { (channel, program) -> GuideProgramDialog(channel, program, now, onWatch = { details = null; watch(channel) }, onDismiss = { details = null; focusPending = true }) }
}

@Composable
private fun GuideChip(label: String, modifier: Modifier = Modifier, selected: Boolean = false, icon: ImageVector? = null, compact: Boolean = false, onClick: () -> Unit) {
    Surface(onClick = onClick, modifier = modifier.height(32.dp).semantics { contentDescription = label }, shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(18.dp)),
        colors = ClickableSurfaceDefaults.colors(containerColor = if (selected) Color(0xFF363047) else Color.White.copy(alpha = .045f), focusedContainerColor = Color(0xFFEBE5FF), contentColor = if (selected) GuideLilac else GuideMuted, focusedContentColor = GuideInk),
        border = ClickableSurfaceDefaults.border(border = Border(BorderStroke(1.dp, if (selected) GuideLilac.copy(alpha = .25f) else GuideHairline), shape = RoundedCornerShape(18.dp)), focusedBorder = Border(BorderStroke(1.5.dp, Color.White), shape = RoundedCornerShape(18.dp))),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f)) {
        Row(Modifier.padding(horizontal = if (compact) 8.dp else 13.dp).fillMaxHeight(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            if (icon != null) Icon(icon, null, modifier = Modifier.size(16.dp))
            if (!compact) Text(label, fontSize = 11.sp, fontWeight = FontWeight.Medium, maxLines = 1)
        }
    }
}

@Composable
private fun GuideSelection(channel: LiveChannel?, program: LiveProgram?, loading: Boolean) {
    Row(Modifier.fillMaxWidth().height(82.dp), horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(channel?.name ?: "YOUR CHANNELS, TOGETHER", color = GuideLilac, fontSize = 10.sp, letterSpacing = .6.sp, fontWeight = FontWeight.Medium)
                if (program != null) {
                    Text("·", color = GuideMuted, fontSize = 10.sp); Text(programTime(program), color = GuideMuted, fontSize = 10.sp)
                    if (program.isLive) GuideTag("LIVE") else if (program.isNew) GuideTag("NEW")
                    program.rating?.takeIf { it.isNotBlank() }?.let { Text(it, color = GuideMuted, fontSize = 9.sp) }
                }
            }
            Text(program?.title ?: if (loading) "Something good is on." else channel?.name ?: "Find your next favorite.", fontSize = 24.sp, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis, letterSpacing = (-.4).sp)
            Text(listOfNotNull(program?.episodeTitle?.takeIf { it.isNotBlank() }, program?.description?.takeIf { it.isNotBlank() }).joinToString(" · ")
                .ifBlank { if (program != null) "Select a program to watch live or see what’s coming next." else if (channel != null) "Schedule information isn't available. Select this channel to watch live." else "Browse what's on, see what's next, and settle into something you love." }, color = GuideMuted, fontSize = 11.sp, lineHeight = 16.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (program?.imageUrl != null) AsyncImage(program.imageUrl, null, modifier = Modifier.width(138.dp).height(78.dp).clip(RoundedCornerShape(10.dp)), contentScale = ContentScale.Fit, alignment = Alignment.CenterEnd)
        else if (channel?.logoUrl != null) AsyncImage(channel.logoUrl, null, modifier = Modifier.width(112.dp).height(58.dp).padding(6.dp), contentScale = ContentScale.Fit)
    }
}

@Composable
private fun GuideTag(label: String) {
    Text(label, modifier = Modifier.background(GuideLilac.copy(alpha = .12f), RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 2.dp), color = GuideLilac, fontSize = 8.sp, fontWeight = FontWeight.SemiBold, letterSpacing = .6.sp)
}

@Composable
private fun GuideChannelRail(channel: LiveChannel, favorite: Boolean, focused: Boolean, selected: Boolean, modifier: Modifier) {
    val shape = RoundedCornerShape(10.dp)
    Row(modifier.padding(end = 6.dp).background(if (selected) Color.White.copy(alpha = .06f) else Color.Transparent, shape).border(1.5.dp, if (focused) GuideLilac else Color.Transparent, shape).padding(horizontal = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(38.dp).clip(RoundedCornerShape(8.dp)).background(Color(0xFFEAE8F0)), contentAlignment = Alignment.Center) {
            if (channel.logoUrl != null) AsyncImage(channel.logoUrl, null, modifier = Modifier.fillMaxSize().padding(5.dp), contentScale = ContentScale.Fit)
            else Text(channel.name.take(2).uppercase(), fontSize = 12.sp, color = GuideInk, fontWeight = FontWeight.Bold)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(channel.name, fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 14.sp)
            Text(listOfNotNull(channel.number?.takeIf { it.isNotBlank() }, if (favorite) "★" else null).joinToString("  "), fontSize = 9.sp, color = if (favorite) GuideLilac else GuideMuted)
        }
    }
}

@Composable
private fun GuideProgramCell(slot: LiveGuideSlot, now: Instant, focused: Boolean, modifier: Modifier) {
    val program = slot.program
    val began = remember(program) { program?.let { Instant.parse(it.startTime) } }
    val ended = remember(program) { program?.let { Instant.parse(it.endTime) } }
    val current = began != null && ended != null && began <= now && ended > now
    // Read the animated color while drawing so each transition does not
    // recompose/reformat all the program labels on every animation frame.
    val background = animateColorAsState(if (focused) Color(0xFF49405F) else if (current) Color(0xFF242633) else Color(0xFF181C27), tween(140), label = "guide-focus")
    val subtitle = remember(program) { program?.episodeTitle?.takeIf { it.isNotBlank() } ?: program?.let { programTime(it) } ?: "Watch channel live" }
    val shape = RoundedCornerShape(10.dp)
    Box(modifier.padding(end = 4.dp).clip(shape).drawBehind { drawRect(background.value) }.border(if (focused) 1.5.dp else .5.dp, if (focused) GuideLilac else Color.White.copy(alpha = .055f), shape)) {
        Column(Modifier.fillMaxSize().padding(horizontal = 11.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(program?.title ?: "Schedule unavailable", color = if (program == null) GuideMuted else Color.White, fontSize = 12.sp, fontWeight = if (focused) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, color = if (focused) Color(0xFFD2CADF) else GuideMuted, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (current) {
            val progress = (Duration.between(began, now).seconds.toFloat() / Duration.between(began, ended).seconds.coerceAtLeast(1)).coerceIn(0f, 1f)
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(progress).height(2.dp).background(if (focused) GuideLilac else GuideLilac.copy(alpha = .38f)))
        }
    }
}

@Composable
private fun GuideEmpty(title: String, message: String, actionLabel: String = "", action: (() -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().padding(vertical = 48.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(title, fontSize = 23.sp, color = Color.White)
        Text(message, fontSize = 14.sp, color = GuideMuted, modifier = Modifier.widthIn(max = 580.dp))
        if (action != null) GuideChip(actionLabel, onClick = action)
    }
}

@Composable
private fun GuideSearchDialog(initial: String, onSearch: (String) -> Unit, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf(initial) }
    val focus = remember { FocusRequester() }
    val searchFocus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        LaunchedEffect(Unit) { withFrameNanos { }; focus.requestFocus(); keyboard?.show() }
        Column(Modifier.width(590.dp).background(Color(0xFF191C29), RoundedCornerShape(24.dp)).border(1.dp, GuideHairline, RoundedCornerShape(24.dp)).padding(28.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Text("Find something to watch", color = Color.White, fontSize = 25.sp, fontWeight = FontWeight.SemiBold)
            Text("Search channels, shows, or channel numbers.", color = GuideMuted, fontSize = 14.sp)
            BasicTextField(query, { query = it.take(100) }, modifier = Modifier.fillMaxWidth().focusRequester(focus).onPreviewKeyEvent {
                if (it.type == KeyEventType.KeyDown && it.key == Key.DirectionDown) {
                    keyboard?.hide(); searchFocus.requestFocus(); true
                } else false
            }.background(GuideInk, RoundedCornerShape(12.dp)).border(1.dp, GuideLilac, RoundedCornerShape(12.dp)).padding(16.dp),
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = Color.White), cursorBrush = SolidColor(GuideLilac), singleLine = true, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { keyboard?.hide(); onSearch(query.trim()) }))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { keyboard?.hide(); onSearch(query.trim()) }, colors = velvetButtonColors(), modifier = Modifier.focusRequester(searchFocus)) { Text("Search") }
                Button(onClick = { keyboard?.hide(); onSearch("") }, colors = velvetButtonColors()) { Text("Clear search") }
                Button(onClick = onDismiss, colors = velvetButtonColors()) { Text("Cancel") }
            }
        }
    }
}

@Composable
private fun GuideProgramDialog(channel: LiveChannel, program: LiveProgram?, now: Instant, onWatch: () -> Unit, onDismiss: () -> Unit) {
    val focus = remember { FocusRequester() }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        LaunchedEffect(Unit) { withFrameNanos { }; focus.requestFocus() }
        Column(Modifier.width(600.dp).background(Color(0xFF191C29), RoundedCornerShape(24.dp)).border(1.dp, GuideHairline, RoundedCornerShape(24.dp)).padding(28.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(channel.name + (program?.let { "  ·  " + programTime(it) } ?: ""), color = GuideLilac, fontSize = 13.sp)
            Text(program?.title ?: channel.name, color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
            program?.episodeTitle?.takeIf { it.isNotBlank() }?.let { Text(it, color = Color.White, fontSize = 16.sp) }
            program?.description?.takeIf { it.isNotBlank() }?.let { Text(it, color = GuideMuted, fontSize = 14.sp, maxLines = 8, overflow = TextOverflow.Ellipsis) }
            if (program != null && Instant.parse(program.startTime) > now) Text("Upcoming program. Watch live opens what's airing on ${channel.name} now.", color = GuideMuted, fontSize = 12.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onDismiss, colors = velvetButtonColors(), modifier = Modifier.focusRequester(focus)) { Text("Back to guide") }
                Button(onClick = onWatch, colors = velvetButtonColors()) { Text("Watch live") }
            }
        }
    }
}
