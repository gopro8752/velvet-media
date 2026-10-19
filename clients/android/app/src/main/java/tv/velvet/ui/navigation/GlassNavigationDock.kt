package tv.velvet.ui.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.outlined.Search
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.*
import tv.velvet.Routes

/** Add destinations here; the shell shares selection, saved tab state and remote routing. */
data class TvDestination(val route: String, val label: String, val icon: ImageVector)
val TvDestinations = listOf(
    TvDestination(Routes.HOME, "Home", DockIcons.PlayHouse),
    TvDestination(Routes.SEARCH, "Search", Icons.Outlined.Search),
    TvDestination(Routes.LIVE, "Live TV", Icons.Filled.Tv),
    TvDestination(Routes.SPORTS, "Live Sports", DockIcons.SportsCourt),
    TvDestination(Routes.SETTINGS, "Settings", Icons.Filled.Settings),
)

/** Scroll content clears the floating dock only at its end; artwork uses the full window. */
val LocalDockContentInset = staticCompositionLocalOf { 0.dp }

/** Focus restoration keeps Up from the dock attached to the card/control just left. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun NavigationPage(
    focusRequester: FocusRequester,
    onLaidOut: () -> Unit,
    onBack: () -> Unit,
    dockVisible: Boolean = true,
    content: @Composable () -> Unit,
) {
    // Register inside the destination, after NavHost's own back callback, but
    // before any dialog/IME handlers contributed by the page's content.
    BackHandler(onBack = onBack)
    CompositionLocalProvider(LocalDockContentInset provides if (dockVisible) 106.dp else 0.dp) {
        Box(Modifier.fillMaxSize().onGloballyPositioned { onLaidOut() }
            .focusRequester(focusRequester).focusRestorer().focusGroup()) { content() }
    }
}

/** Layered translucent glass, with stable item geometry so D-pad focus never chases an animation. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun GlassNavigationDock(
    backdrop: DockBackdropState,
    selectedRoute: String,
    requests: Map<String, FocusRequester>,
    onReturnToContent: () -> Unit,
    onNavigate: (String) -> Unit,
    onExit: () -> Unit,
    onFocusChanged: (Boolean) -> Unit,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(42.dp)
    val exitRequest = remember { FocusRequester() }
    Box(
        modifier = modifier
            .shadow(12.dp, shape, ambientColor = Color.Black.copy(alpha = .3f), spotColor = Color.Black.copy(alpha = .3f))
            .clip(shape)
            .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = .48f), Color.White.copy(alpha = .08f), Color.White.copy(alpha = .24f))), shape),
    ) {
    DockBackdrop(backdrop, Modifier.matchParentSize())
    Row(
        modifier = Modifier
            .background(Brush.verticalGradient(listOf(Color(0x1AEBE8FF), Color(0x24333145))))
            .padding(horizontal = 7.dp, vertical = 6.dp)
            .onPreviewKeyEvent { event ->
                // Use the same saved target as Back, rather than spatial search,
                // which can jump to the overlaid Create button above a long list.
                if (enabled && event.type == KeyEventType.KeyDown && event.key == Key.DirectionUp) {
                    onReturnToContent()
                    true
                } else false
            }
            .onFocusChanged { onFocusChanged(it.hasFocus) }.focusGroup(),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TvDestinations.forEachIndexed { index, destination ->
            DockButton(
                label = destination.label,
                icon = destination.icon,
                active = destination.route == selectedRoute,
                isTab = true,
                enabled = enabled,
                requester = requests.getValue(destination.route),
                left = TvDestinations.getOrNull(index - 1)?.let { requests.getValue(it.route) } ?: FocusRequester.Cancel,
                right = TvDestinations.getOrNull(index + 1)?.let { requests.getValue(it.route) } ?: exitRequest,
                onClick = { onNavigate(destination.route) },
            )
        }
        DockButton(
            label = "Exit",
            icon = Icons.AutoMirrored.Filled.ExitToApp,
            active = false,
            isTab = false,
            enabled = enabled,
            requester = exitRequest,
            left = requests.getValue(TvDestinations.last().route),
            right = FocusRequester.Cancel,
            onClick = onExit,
        )
    }
    }
}

/** Exit shares dock styling and remote routing, but is an action rather than a tab. */
@Composable
private fun DockButton(
    label: String,
    icon: ImageVector,
    active: Boolean,
    isTab: Boolean,
    enabled: Boolean,
    requester: FocusRequester,
    left: FocusRequester,
    right: FocusRequester,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val containerColor = if (active) Color(0x48564C6F) else Color.Transparent
    val contentColor = if (active) Color(0xFFD6C5FF) else Color.White
    Surface(
        onClick = { if (enabled) onClick() },
        enabled = enabled,
        interactionSource = interaction,
        modifier = Modifier.width(76.dp).height(58.dp)
            .focusRequester(requester)
            .focusProperties {
                // TV Material surfaces may remain focusable while disabled.
                // A dock retained only for its exit animation must not be one
                // of the destinations found by the remote's spatial search.
                canFocus = enabled
                this.left = left
                this.right = right
                up = FocusRequester.Cancel
                down = FocusRequester.Cancel
            }
            .semantics {
                role = if (isTab) Role.Tab else Role.Button
                if (isTab) selected = active
                contentDescription = label
            },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(30.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = containerColor,
            focusedContainerColor = Color(0x685F527D),
            contentColor = contentColor,
            focusedContentColor = Color(0xFFE4D8FF),
            pressedContainerColor = Color(0x885F527D),
            // Disabling input for exit must not flash a second visual state;
            // AnimatedVisibility already owns the dock's fading opacity.
            disabledContainerColor = containerColor,
            disabledContentColor = contentColor,
        ),
        border = ClickableSurfaceDefaults.border(
            border = Border(BorderStroke(1.dp, Color.Transparent), shape = RoundedCornerShape(30.dp)),
            focusedBorder = Border(BorderStroke(1.5.dp, Color(0xFFE4D8FF)), shape = RoundedCornerShape(30.dp)),
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        glow = ClickableSurfaceDefaults.glow(focusedGlow = Glow(Color(0xFFB9ABFF).copy(alpha = .16f), 8.dp)),
    ) {
        Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(26.dp))
            Spacer(Modifier.height(3.dp))
            Text(label, style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp), maxLines = 1)
        }
    }
}

/** Same visual vocabulary as the iOS play.house and sportscourt tab symbols. */
private object DockIcons {
    val PlayHouse = ImageVector.Builder("PlayHouse", 24.dp, 24.dp, 24f, 24f).apply {
        path(fill = SolidColor(Color.White), pathFillType = PathFillType.EvenOdd) {
            moveTo(12f, 3.4f); lineTo(3.8f, 10.6f); lineTo(3.8f, 21f); lineTo(20.2f, 21f)
            lineTo(20.2f, 10.6f); close()
            moveTo(10f, 10.3f); lineTo(16.2f, 14.4f); lineTo(10f, 18.5f); close()
        }
        path(stroke = SolidColor(Color.White), strokeLineWidth = 1.7f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round) {
            moveTo(1.3f, 10.3f); lineTo(12f, 1.2f); lineTo(22.7f, 10.3f)
            moveTo(18.4f, 6.5f); lineTo(18.4f, 2.8f)
        }
    }.build()
    val SportsCourt = ImageVector.Builder("SportsCourt", 28.dp, 24.dp, 28f, 24f).apply {
        path(fill = SolidColor(Color.White), pathFillType = PathFillType.EvenOdd) {
            moveTo(3f, 3f); lineTo(25f, 3f); quadTo(27f, 3f, 27f, 5f)
            lineTo(27f, 19f); quadTo(27f, 21f, 25f, 21f); lineTo(3f, 21f)
            quadTo(1f, 21f, 1f, 19f); lineTo(1f, 5f); quadTo(1f, 3f, 3f, 3f); close()
            moveTo(13.2f, 3f); lineTo(14.8f, 3f); lineTo(14.8f, 21f); lineTo(13.2f, 21f); close()
            moveTo(1f, 7f); lineTo(6f, 7f); lineTo(6f, 17f); lineTo(1f, 17f); lineTo(1f, 15.4f)
            lineTo(4.4f, 15.4f); lineTo(4.4f, 8.6f); lineTo(1f, 8.6f); close()
            moveTo(27f, 7f); lineTo(22f, 7f); lineTo(22f, 17f); lineTo(27f, 17f); lineTo(27f, 15.4f)
            lineTo(23.6f, 15.4f); lineTo(23.6f, 8.6f); lineTo(27f, 8.6f); close()
            // Cut the center ring out of the filled field as on the iOS court icon.
            moveTo(13.2f, 7.6f); curveTo(8f, 8.5f, 8f, 15.5f, 13.2f, 16.4f)
            lineTo(13.2f, 14.7f); curveTo(10.2f, 13.9f, 10.2f, 10.1f, 13.2f, 9.3f); close()
            moveTo(14.8f, 7.6f); curveTo(20f, 8.5f, 20f, 15.5f, 14.8f, 16.4f)
            lineTo(14.8f, 14.7f); curveTo(17.8f, 13.9f, 17.8f, 10.1f, 14.8f, 9.3f); close()
        }
    }.build()
}
