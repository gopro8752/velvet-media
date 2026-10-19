package tv.velour.ui.home

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.focus.*
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import tv.velour.core.AppEntry
import tv.velour.data.velvet.*
import tv.velour.ui.glass.*
import tv.velour.ui.theme.VelourType
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal val Pearl = Color(0xFFF4F4F8)
internal val PearlMuted = Color(0xFFB5BAC8)
internal val LocalHomeAccent = staticCompositionLocalOf { Color(0xFFC9C0F8) }

@Composable
internal fun HomeText(text: String, size: Int, modifier: Modifier = Modifier, color: Color = Pearl,
    weight: FontWeight = FontWeight.Normal, maxLines: Int = 1, tracking: Float = 0f) {
    BasicText(text, modifier, style = VelourType.body.copy(color = color, fontSize = size.sp,
        lineHeight = (size * 1.22f).sp, fontWeight = weight, letterSpacing = tracking.sp),
        maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

@Composable
internal fun HomeWordmark() {
    val accent = LocalHomeAccent.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Canvas(Modifier.size(26.dp)) {
            val stroke = 1.5.dp.toPx()
            drawLine(Pearl, Offset(size.width * .12f, size.height * .2f), Offset(size.width * .48f, size.height * .84f), stroke, StrokeCap.Round)
            drawLine(Pearl, Offset(size.width * .48f, size.height * .84f), Offset(size.width * .85f, size.height * .2f), stroke, StrokeCap.Round)
            drawLine(accent.copy(alpha = .65f), Offset(size.width * .48f, size.height * .52f), Offset(size.width * .67f, size.height * .2f), stroke, StrokeCap.Round)
        }
        HomeText("velour", 25, weight = FontWeight.Medium, tracking = -.7f)
    }
}

/** One native key owner: long press does not leak its release into the menu. */
@Composable
internal fun Modifier.remoteAction(label: String, onClick: () -> Unit, onLongPress: (() -> Unit)? = null): Modifier {
    val scope = rememberCoroutineScope()
    var held by remember { mutableStateOf(false) }
    var longFired by remember { mutableStateOf(false) }
    var job by remember { mutableStateOf<Job?>(null) }
    val click by rememberUpdatedState(onClick)
    val longClick by rememberUpdatedState(onLongPress)
    DisposableEffect(Unit) { onDispose { job?.cancel() } }
    return this.semantics { contentDescription = label; role = Role.Button; onClick { click(); true } }
        .onFocusChanged { if (!it.isFocused) { job?.cancel(); held = false } }
        .onPreviewKeyEvent { event ->
            if (event.key !in listOf(Key.DirectionCenter, Key.Enter, Key.NumPadEnter)) return@onPreviewKeyEvent false
            when (event.type) {
                KeyEventType.KeyDown -> {
                    if (event.nativeKeyEvent.repeatCount == 0) {
                        held = true; longFired = false
                        job?.cancel()
                        if (longClick != null) job = scope.launch { delay(500); if (held) { longFired = true; longClick?.invoke() } }
                    }
                    // Some CEC remotes and Android's accessibility input send the
                    // platform long-press flag before a wall-clock timer fires.
                    if (held && !longFired && longClick != null &&
                        (event.nativeKeyEvent.isLongPress ||
                            event.nativeKeyEvent.eventTime - event.nativeKeyEvent.downTime >= 500L)) {
                        job?.cancel()
                        longFired = true
                        longClick?.invoke()
                    }
                    true
                }
                KeyEventType.KeyUp -> {
                    job?.cancel()
                    if (held && !longFired && !event.nativeKeyEvent.isCanceled) click()
                    held = false
                    true
                }
                else -> false
            }
        }.focusable()
}

@Composable
internal fun HomeAction(label: String, icon: GlassIcon, onClick: () -> Unit, reduced: Boolean,
    modifier: Modifier = Modifier, onFocused: () -> Unit = {}, primary: Boolean = false,
    focusTracker: ((FocusRequester) -> Unit)? = null) {
    val requester = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    val focus by animateFloatAsState(if (focused) 1f else 0f, tween(if (reduced) 0 else 180), label = "actionFocus")
    Row(modifier.focusRequester(requester).height(40.dp).graphicsLayer { scaleX = 1f + focus * .035f; scaleY = scaleX }
        .onFocusChanged { focused = it.isFocused; if (it.isFocused) { onFocused(); focusTracker?.invoke(requester) } }
        .clip(RoundedCornerShape(50)).background(if (primary || focused) Pearl else Color.White.copy(alpha = .12f))
        .border(1.dp, if (focused) Color.White else Color.White.copy(alpha = .2f), RoundedCornerShape(50))
        .remoteAction(label, onClick).padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
        val color = if (primary || focused) Color(0xFF151925) else Pearl
        GlassGlyph(icon, Modifier.size(17.dp), color)
        HomeText(label, 14, color = color, weight = FontWeight.Medium)
    }
}

@Composable
internal fun HeaderButton(icon: GlassIcon, label: String, reduced: Boolean, backdrop: GlassBackdrop?,
    onFocus: (FocusRequester) -> Unit, onClick: () -> Unit) {
    val requester = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    GlassPanel(Modifier.size(36.dp).focusRequester(requester).onFocusChanged { focused = it.isFocused; if (focused) onFocus(requester) }
        .remoteAction(label, onClick), radius = 18.dp, opacity = .3f, focused = focused, backdrop = backdrop, reduceMotion = reduced) {
        GlassGlyph(icon, Modifier.align(Alignment.Center).size(19.dp), Pearl)
    }
}

@Composable
internal fun ProfileButton(name: String, reduced: Boolean, backdrop: GlassBackdrop?, onFocus: (FocusRequester) -> Unit, onClick: () -> Unit) {
    val requester = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    GlassPanel(Modifier.size(36.dp).focusRequester(requester).onFocusChanged { focused = it.isFocused; if (focused) onFocus(requester) }
        .remoteAction("Profile: $name", onClick), radius = 18.dp, tint = Color(0xFF80719E), opacity = .5f,
        focused = focused, backdrop = backdrop, reduceMotion = reduced) {
        HomeText(name.take(1).uppercase(), 15, Modifier.align(Alignment.Center), weight = FontWeight.Medium)
    }
}

@Composable
internal fun CinemaHero(title: VelvetTitle?, snapshot: VelvetSnapshot, art: HomeArtwork, greeting: String, backdrop: GlassBackdrop?, reduced: Boolean,
    firstFocus: FocusRequester, onFocused: () -> Unit, onControlFocus: (FocusRequester) -> Unit, onOpen: (VelvetAction) -> Unit, modifier: Modifier) {
    val logo = if (title?.logoUrl != null) rememberArtwork(art, title.logoUrl, 700) else null
    Column(modifier, verticalArrangement = Arrangement.Center) {
        if (logo != null) Image(logo, title?.title, Modifier.widthIn(max = 370.dp).height(53.dp), contentScale = ContentScale.Fit, alignment = Alignment.CenterStart)
        else if (title != null) HomeText(title.title, if (title.title.length > 30) 35 else 43,
            Modifier.widthIn(max = 620.dp), weight = FontWeight.Medium, tracking = -1.3f)
        val metadata = title?.let { t -> listOfNotNull(t.year, t.episodeLabel,
            t.rating?.takeIf { it > 0 }?.let { "★ ${String.format(Locale.US, "%.1f", it)}" },
            t.remainingMinutes?.takeIf { t.positionMs > 0 }?.let { "$it min left" }).joinToString("   ·   ") }
        if (!metadata.isNullOrBlank()) {
            Spacer(Modifier.height(9.dp))
            HomeText(metadata, 13, Modifier.widthIn(max = 540.dp), color = PearlMuted)
        } else if (title == null && (!snapshot.connected || snapshot.profile == null)) {
            HomeText(if (snapshot.connected) "Choose a profile in Velvet." else "Open Velvet to connect your library.",
                13, color = PearlMuted)
        }
        Spacer(Modifier.height(18.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            HomeAction(if (title == null) "Open Velvet" else if (title.positionMs > 0) "Resume" else "Play",
                GlassIcon.Play, { onOpen(if (title == null) VelvetAction.Home else VelvetAction.Resume(title)) }, reduced,
                Modifier.focusRequester(firstFocus), onFocused, primary = true)
            if (title != null) HomeAction("Details", GlassIcon.Info, { onOpen(VelvetAction.Details(title)) }, reduced, focusTracker = onControlFocus)
        }
    }
}

@Composable
internal fun TitleShelf(title: String, eyebrow: String?, titles: List<VelvetTitle>, art: HomeArtwork, reduced: Boolean,
    onFocused: (VelvetTitle, FocusRequester) -> Unit, onOpen: (VelvetTitle) -> Unit, progress: Boolean = false) {
    Column {
        HomeText((eyebrow?.takeIf { it.isNotBlank() } ?: title).uppercase(Locale.getDefault()), 10,
            Modifier.padding(horizontal = 48.dp), color = PearlMuted.copy(alpha = .82f),
            weight = FontWeight.Medium, tracking = 1.8f)
        HomeViewport(vertical = false, reduced = reduced) {
        LazyRow(contentPadding = PaddingValues(horizontal = 48.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            items(titles, key = { it.key }) { item ->
                MediaTile(item, art, reduced, progress, { onFocused(item, it) }, { onOpen(item) })
            }
        }
        }
    }
}

@Composable
private fun MediaTile(title: VelvetTitle, art: HomeArtwork, reduced: Boolean, progress: Boolean,
    onFocused: (FocusRequester) -> Unit, onOpen: () -> Unit,
    initialFocus: FocusRequester? = null, upFocus: FocusRequester? = null) {
    val accent = LocalHomeAccent.current
    val requester = initialFocus ?: remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    val focus by animateFloatAsState(if (focused) 1f else 0f, tween(if (reduced) 0 else 200), label = "tileFocus")
    val image = rememberArtwork(art, title.backdropUrl ?: title.posterUrl, 480)
    Column(Modifier.width(194.dp).focusRequester(requester).focusProperties { if (upFocus != null) up = upFocus }
        .onFocusChanged { focused = it.isFocused; if (focused) onFocused(requester) }
        .remoteAction("${title.title}${title.episodeLabel?.let { ", $it" }.orEmpty()}", onOpen)) {
        Box(Modifier.fillMaxWidth().height(109.dp).graphicsLayer { scaleX = 1f + focus * .035f; scaleY = scaleX }
            .clip(RoundedCornerShape(12.dp)).background(Color(0xFF242C3C))
            .drawWithCache {
                val rim = Brush.linearGradient(listOf(Color.White.copy(alpha = .95f), Color.White.copy(alpha = .2f), accent.copy(alpha = .6f)))
                onDrawWithContent {
                    drawContent()
                    drawRoundRect(rim, cornerRadius = CornerRadius(12.dp.toPx()), style = Stroke((1f + focus).dp.toPx()), alpha = .18f + focus * .82f)
                }
            }) {
            if (image != null) Image(image, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else HomeText(title.title, 18, Modifier.align(Alignment.Center).padding(15.dp), maxLines = 2)
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = .45f)))))
            if (progress && title.progress > 0) {
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color.White.copy(alpha = .2f)))
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth(title.progress).height(3.dp).background(accent))
            }
            if (focused) GlassGlyph(GlassIcon.Play, Modifier.align(Alignment.Center).size(27.dp), Pearl)
        }
        Spacer(Modifier.height(8.dp))
        HomeText(title.title, 14, weight = FontWeight.Medium)
        Spacer(Modifier.height(3.dp))
        HomeText(listOfNotNull(title.episodeLabel ?: title.year,
            if (progress) title.remainingMinutes?.let { "$it min left" } else title.type.takeIf { title.year == null }?.replaceFirstChar { it.uppercase() }).joinToString("  ·  "),
            11, color = PearlMuted)
    }
}

@Composable
internal fun AppShelf(title: String, apps: List<AppEntry>, viewModel: HomeViewModel, reduced: Boolean,
    onFocus: (FocusRequester) -> Unit, onMenu: (AppEntry) -> Unit, onAllApps: (() -> Unit)? = null,
    initialFocus: FocusRequester? = null, upFocus: FocusRequester? = null,
    listState: LazyListState? = null) {
    val shelfState = listState ?: rememberLazyListState()
    Column {
        HomeText(title.uppercase(Locale.getDefault()), 10, Modifier.padding(horizontal = 48.dp),
            color = PearlMuted.copy(alpha = .82f), weight = FontWeight.Medium, tracking = 1.8f)
        HomeViewport(vertical = false, reduced = reduced) {
        LazyRow(state = shelfState, contentPadding = PaddingValues(horizontal = 48.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            items(apps, key = { it.packageName }) { app ->
                LauncherAppCard(app, viewModel, reduced, 156.dp,
                    initialFocus = if (app.packageName == apps.firstOrNull()?.packageName) initialFocus else null,
                    onFocused = onFocus, onMenu = { onMenu(app) }, upFocus = upFocus)
            }
            if (onAllApps != null) item("all-apps") {
                AllAppsTile(reduced, onFocus, onAllApps,
                    initialFocus = initialFocus.takeIf { apps.isEmpty() }, upFocus = upFocus)
            }
        }
        }
    }
}

@Composable
private fun AllAppsTile(reduced: Boolean, onFocus: (FocusRequester) -> Unit, onOpen: () -> Unit,
    initialFocus: FocusRequester? = null, upFocus: FocusRequester? = null) {
    val requester = initialFocus ?: remember { FocusRequester() }
    val accent = LocalHomeAccent.current
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val illuminated = focused || hovered
    val focus = animateFloatAsState(if (illuminated) 1f else 0f, tween(if (reduced) 0 else 240), label = "allAppsFocus")
    Column(Modifier.width(94.dp).focusRequester(requester).focusProperties { if (upFocus != null) up = upFocus }
        .onFocusChanged { focused = it.isFocused; if (focused) onFocus(requester) }
        .hoverable(interaction)
        .remoteAction("All apps", onOpen), horizontalAlignment = Alignment.CenterHorizontally) {
        GlassPanel(Modifier.fillMaxWidth().height(87.75.dp).graphicsLayer {
            scaleX = if (reduced) 1f else 1f + focus.value * .055f
            scaleY = scaleX
            translationY = if (reduced) 0f else -focus.value * 2.dp.toPx()
        }, radius = 14.dp, opacity = .24f, focused = illuminated, reduceMotion = reduced,
            livingRim = true, rimAccent = accent, rimSeed = 47) {
            GlassGlyph(GlassIcon.Apps, Modifier.align(Alignment.Center).size(26.dp), if (illuminated) Pearl else PearlMuted)
        }
        Spacer(Modifier.height(9.dp))
        HomeText("All apps", 13, color = if (illuminated) Pearl else PearlMuted, weight = FontWeight.Medium)
    }
}

@Composable
internal fun LauncherAppCard(app: AppEntry, vm: HomeViewModel, reduced: Boolean, width: Dp,
    initialFocus: FocusRequester? = null, onFocused: (FocusRequester) -> Unit, onMenu: () -> Unit,
    upFocus: FocusRequester? = null) {
    val requester = initialFocus ?: remember { FocusRequester() }
    val accent = LocalHomeAccent.current
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val illuminated = focused || hovered
    var bounds by remember { mutableStateOf(Rect.Zero) }
    val focus = animateFloatAsState(if (illuminated) 1f else 0f, tween(if (reduced) 0 else 240), label = "appFocus")
    var banner by remember(app.packageName) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(vm, app.packageName) { banner = vm.banner(app.packageName) }
    Column(Modifier.width(width).focusRequester(requester).focusProperties { if (upFocus != null) up = upFocus }
        .onGloballyPositioned { bounds = it.boundsInRoot() }
        .onFocusChanged { focused = it.isFocused; if (focused) onFocused(requester) }
        .hoverable(interaction)
        .remoteAction(app.label, { vm.launch(app, bounds) }, onMenu)) {
        Box(Modifier.fillMaxWidth().height(width * .5625f).graphicsLayer {
            scaleX = if (reduced) 1f else 1f + focus.value * .06f
            scaleY = scaleX
            translationY = if (reduced) 0f else -focus.value * 2.dp.toPx()
        }.clip(RoundedCornerShape(14.dp)).background(Brush.linearGradient(listOf(Color(0xFF2F3549), Color(0xFF141C2D)))),
            contentAlignment = Alignment.Center) {
            if (banner != null) Image(banner!!, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else HomeText(app.label, 20, Modifier.padding(18.dp), weight = FontWeight.Medium, maxLines = 2)
            LivingGlassRim(Modifier.matchParentSize(), radius = 14.dp, focused = illuminated,
                reduceMotion = reduced, accent = accent, seed = app.packageName.hashCode())
        }
        Spacer(Modifier.height(9.dp))
        HomeText(app.label, 13, color = if (illuminated) Pearl else PearlMuted, weight = FontWeight.Medium)
    }
}

@Composable
internal fun CategoryShelf(category: VelvetCategory, art: HomeArtwork, reduced: Boolean,
    onFocused: (VelvetTitle, FocusRequester) -> Unit, onControlFocus: (FocusRequester) -> Unit, onOpen: (VelvetAction) -> Unit) {
    if (category.items.isEmpty()) return
    val play = remember { FocusRequester() }
    val shuffle = remember { FocusRequester() }
    val firstCard = remember { FocusRequester() }
    Column {
        Row(Modifier.fillMaxWidth().padding(horizontal = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            HomeText(category.title, 16, Modifier.weight(1f), weight = FontWeight.Medium)
            HomeAction("Play all", GlassIcon.Play, { onOpen(VelvetAction.Category(category.id)) }, reduced,
                Modifier.focusRequester(play).focusProperties { down = firstCard; right = shuffle }, onFocused = { onControlFocus(play) })
            Spacer(Modifier.width(9.dp))
            HomeAction("Shuffle", GlassIcon.Apps, { onOpen(VelvetAction.Category(category.id, true)) }, reduced,
                Modifier.focusRequester(shuffle).focusProperties { down = firstCard; left = play }, onFocused = { onControlFocus(shuffle) })
        }
        HomeViewport(vertical = false, reduced = reduced) {
        LazyRow(contentPadding = PaddingValues(horizontal = 48.dp, vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            items(category.items, key = { it.key }) { item -> MediaTile(item, art, reduced, false,
                { onFocused(item, it) }, { onOpen(VelvetAction.Details(item)) },
                initialFocus = if (item.key == category.items.firstOrNull()?.key) firstCard else null, upFocus = play) }
        }
        }
    }
}

@Composable
internal fun ConnectionCard(snapshot: VelvetSnapshot, reduced: Boolean, onControlFocus: (FocusRequester) -> Unit, onOpen: () -> Unit) {
    Column(Modifier.padding(horizontal = 48.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HomeText(if (snapshot.connected) "Make it yours." else "Bring Velvet home.", 25)
        HomeText(when (snapshot.connection) {
            VelvetConnection.CONNECTED -> "Choose a profile in Velvet to see your library here."
            VelvetConnection.NOT_INSTALLED -> "Install Velvet to see your shows, movies, and categories."
            VelvetConnection.UPDATE_REQUIRED -> "Update Velvet to connect your library to Velour."
            VelvetConnection.UNAVAILABLE -> "Open Velvet to reconnect your library."
        }, 14, color = PearlMuted)
        HomeAction(if (snapshot.connected) "Choose profile" else "Open Velvet", GlassIcon.Velvet, onOpen, reduced, focusTracker = onControlFocus)
    }
}

@Composable
internal fun ArrangePanel(entry: AppEntry, order: List<String>, apps: List<AppEntry>, reduced: Boolean,
    onMove: (Int) -> Unit, onDone: () -> Unit) {
    val accent = LocalHomeAccent.current
    val firstFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) { firstFocus.requestFocus() }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .72f)), contentAlignment = Alignment.Center) {
        GlassPanel(Modifier.width(550.dp), radius = 26.dp, opacity = .92f) {
            Column(Modifier.padding(28.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                HomeText("Arrange your favorites", 27, weight = FontWeight.Medium)
                HomeText("${entry.label} · Position ${order.indexOf(entry.packageName) + 1} of ${order.size}", 16, color = accent)
                HomeText(order.joinToString("   /   ") { pkg -> apps.firstOrNull { it.packageName == pkg }?.label ?: pkg }, 13, maxLines = 2, color = PearlMuted)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    HomeAction("Move left", GlassIcon.Back, { onMove(-1) }, reduced, Modifier.focusRequester(firstFocus))
                    HomeAction("Move right", GlassIcon.ArrowRight, { onMove(1) }, reduced)
                    HomeAction("Done", GlassIcon.Check, onDone, reduced, primary = true)
                }
                HomeText("Back cancels your changes.", 12, color = PearlMuted)
            }
        }
    }
}

@Composable
internal fun AmbientClock(now: Long, use24Hour: Boolean, reduced: Boolean, modifier: Modifier = Modifier) {
    val drift = remember { Animatable(0f) }
    LaunchedEffect(reduced) {
        if (reduced) drift.snapTo(0f)
        else while (true) { drift.animateTo(1f, tween(31_000, easing = LinearEasing)); drift.animateTo(-1f, tween(31_000, easing = LinearEasing)) }
    }
    Column(modifier.graphicsLayer { translationX = drift.value * 38.dp.toPx(); translationY = drift.value * 20.dp.toPx() }, horizontalAlignment = Alignment.CenterHorizontally) {
        HomeText(SimpleDateFormat(if (use24Hour) "HH:mm" else "h:mm", Locale.getDefault()).format(Date(now)), 92, tracking = -4f)
        Spacer(Modifier.height(12.dp))
        HomeText(SimpleDateFormat("EEEE, MMMM d", Locale.getDefault()).format(Date(now)), 18, color = PearlMuted)
    }
}
