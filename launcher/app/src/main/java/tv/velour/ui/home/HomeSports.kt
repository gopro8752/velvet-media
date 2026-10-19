package tv.velour.ui.home

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import tv.velour.data.velvet.VelvetGame
import tv.velour.ui.glass.GlassBackdrop
import tv.velour.ui.glass.GlassGlyph
import tv.velour.ui.glass.GlassIcon
import tv.velour.ui.glass.GlassPanel
import java.text.SimpleDateFormat
import java.time.OffsetDateTime
import java.util.Date
import java.util.Locale

/**
 * A quiet, spoiler-free header strip. Its height never changes as games arrive;
 * every selected game remains reachable by scrolling horizontally with the D-pad.
 * When the schedule is available but has no selected games, it takes no space.
 */
@Composable
internal fun TodayGames(
    games: List<VelvetGame>,
    selectedTeams: Set<String>,
    art: HomeArtwork,
    reduced: Boolean,
    onFocus: (FocusRequester) -> Unit,
    onOpen: (VelvetGame) -> Unit,
    modifier: Modifier = Modifier,
    backdrop: GlassBackdrop? = null,
    now: Long = System.currentTimeMillis(),
    unavailable: Boolean = false,
    onBrowse: (() -> Unit)? = null,
    use24Hour: Boolean = false,
    firstFocus: FocusRequester? = null,
    headerFocus: FocusRequester? = null,
) {
    val today = remember(games, selectedTeams, now / 60_000) {
        games.asSequence()
            .filter { it.matchesTeams(selectedTeams) && it.isToday(now) }
            .distinctBy { it.id }
            .sortedWith(compareBy<VelvetGame> {
                when {
                    it.status == "live" && !it.stale -> 0
                    it.status in setOf("scheduled", "delayed", "unknown") -> 1
                    else -> 2
                }
            }.thenBy { it.startTime })
            .toList()
    }
    if (today.isEmpty() && (!unavailable || selectedTeams.isEmpty())) return
    Row(modifier.height(44.dp).focusGroup(), verticalAlignment = Alignment.CenterVertically) {
        HomeText("TODAY", 10, color = PearlMuted.copy(alpha = .82f),
            weight = FontWeight.Medium, tracking = 1.8f)
        Spacer(Modifier.width(12.dp))
        HomeViewport(vertical = false, reduced = reduced) {
            // The anchor stays attached even when the first game scrolls out of
            // composition. Entering the group restores a visible chip. Only the
            // final chip exits Right; Up reaches the separately positioned header.
            LazyRow(Modifier.weight(1f)
                .then(if (firstFocus != null) Modifier.focusRequester(firstFocus) else Modifier)
                .focusGroup(), contentPadding = PaddingValues(horizontal = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically) {
                if (today.isEmpty()) {
                    item("unavailable") {
                        ScheduleUnavailableChip(reduced, backdrop, onFocus, onBrowse,
                            modifier = Modifier.focusProperties {
                                if (headerFocus != null) { up = headerFocus; right = headerFocus }
                            })
                    }
                } else {
                    itemsIndexed(today, key = { _, game -> game.id }) { index, game ->
                        TodayGameChip(game, selectedTeams, art, reduced, backdrop, use24Hour, onFocus,
                            modifier = Modifier.focusProperties {
                                if (headerFocus != null) {
                                    up = headerFocus
                                    if (index == today.lastIndex) right = headerFocus
                                }
                            }) { onOpen(game) }
                    }
                }
            }
        }
    }
}

@Composable
private fun TodayGameChip(
    game: VelvetGame,
    selectedTeams: Set<String>,
    art: HomeArtwork,
    reduced: Boolean,
    backdrop: GlassBackdrop?,
    use24Hour: Boolean,
    onFocus: (FocusRequester) -> Unit,
    modifier: Modifier = Modifier,
    onOpen: () -> Unit,
) {
    val favorite = if (game.homeTeam.key in selectedTeams) game.homeTeam else game.awayTeam
    val opponent = if (favorite.key == game.homeTeam.key) game.awayTeam else game.homeTeam
    val home = favorite.key == game.homeTeam.key
    val palette = LocalHomeAccent.current
    val teamColor = remember(favorite.colorHex, palette) {
        favorite.colorHex?.removePrefix("#")?.takeIf { it.length == 6 }
            ?.toLongOrNull(16)?.let { Color(0xFF000000 or it) } ?: palette
    }
    val accent = remember(teamColor) { lerp(teamColor, Color.White, .46f) }
    val logo = favorite.logoUrl?.takeIf(String::isNotBlank)?.let { rememberArtwork(art, it, 96) }
    val requester = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val illuminated = focused || hovered
    val focus = animateFloatAsState(if (illuminated) 1f else 0f, tween(if (reduced) 0 else 240), label = "gameFocus")
    val status = remember(game.startTime, game.status, game.statusDetail, game.stale, use24Hour) { scheduleLabel(game, use24Hour) }
    val live = game.status == "live" && !game.stale
    val watch = live && game.eventId != null
    val title = "${favorite.shortName.ifBlank { favorite.abbreviation }} ${if (home) "vs" else "at"} ${opponent.abbreviation}"
    val spoken = "${favorite.name} ${if (home) "versus" else "at"} ${opponent.name}, $status. ${if (watch) "Watch game" else "Open game in Velvet"}"

    GlassPanel(
        modifier = modifier.width(220.dp).height(44.dp)
            .focusRequester(requester)
            .onFocusChanged { focused = it.isFocused; if (focused) onFocus(requester) }
            .hoverable(interaction)
            .graphicsLayer {
                scaleX = if (reduced) 1f else 1f + focus.value * .025f
                scaleY = scaleX
                translationY = if (reduced) 0f else -focus.value * .5.dp.toPx()
            }
            .remoteAction(spoken, onOpen),
        radius = 13.dp,
        opacity = .30f,
        focused = illuminated,
        backdrop = backdrop,
        reduceMotion = reduced,
        livingRim = true,
        rimAccent = accent,
        rimSeed = game.id.hashCode(),
    ) {
        Box(Modifier.fillMaxHeight().width(3.dp).background(
            Brush.verticalGradient(listOf(accent.copy(alpha = .08f), accent.copy(alpha = .8f), accent.copy(alpha = .12f)))))
        Row(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 11.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(22.dp), contentAlignment = Alignment.Center) {
                if (logo != null) Image(logo, null, Modifier.fillMaxWidth(), contentScale = ContentScale.Fit)
                else HomeText(favorite.abbreviation, 9, color = accent, weight = FontWeight.SemiBold)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                HomeText(title, 12, weight = FontWeight.Medium)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (live) Box(Modifier.size(4.dp).background(Color(0xFFB1E8C0), CircleShape))
                    HomeText("$status · ${game.league.uppercase(Locale.getDefault())}", 10,
                        color = if (live) Color(0xFFC6E8D0) else PearlMuted)
                }
            }
            GlassGlyph(if (watch) GlassIcon.Play else GlassIcon.ArrowRight, Modifier.size(if (watch) 14.dp else 13.dp),
                if (illuminated) Pearl else PearlMuted.copy(alpha = .75f))
        }
    }
}

@Composable
private fun ScheduleUnavailableChip(
    reduced: Boolean,
    backdrop: GlassBackdrop?,
    onFocus: (FocusRequester) -> Unit,
    onBrowse: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val requester = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    val action = if (onBrowse == null) Modifier else Modifier.focusRequester(requester)
        .onFocusChanged { focused = it.isFocused; if (focused) onFocus(requester) }
        .remoteAction("Schedule unavailable. Open sports.", onBrowse)
    GlassPanel(modifier.width(220.dp).height(44.dp).then(action), radius = 13.dp,
        opacity = .30f, focused = focused, backdrop = backdrop, reduceMotion = reduced) {
        Row(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 11.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GlassGlyph(GlassIcon.Sports, Modifier.size(22.dp), PearlMuted)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                HomeText("Schedule unavailable", 12, weight = FontWeight.Medium)
                if (onBrowse != null) HomeText("Open sports", 10, color = PearlMuted)
            }
            if (onBrowse != null) GlassGlyph(GlassIcon.ArrowRight, Modifier.size(13.dp), PearlMuted)
        }
    }
}

/** Status never reads a score or a potentially spoiler-bearing provider summary. */
private fun scheduleLabel(game: VelvetGame, use24Hour: Boolean): String {
    if (game.stale) return "Updated earlier"
    return when (game.status) {
        "live" -> "Live"
        "final" -> "Final"
        "postponed" -> "Postponed"
        "canceled" -> "Canceled"
        "delayed" -> "Delayed"
        else -> if (game.statusDetail == "Time TBD") "Time TBD" else runCatching {
            val instant = OffsetDateTime.parse(game.startTime).toInstant()
            SimpleDateFormat(if (use24Hour) "HH:mm" else "h:mm a", Locale.getDefault()).format(Date.from(instant))
        }.getOrDefault("Time TBD")
    }
}
