package tv.velour.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tv.velour.core.SportsTeams
import tv.velour.ui.theme.VelourType

/** Local, explicit preferences: never inferred from the network or weather location. */
@Composable
internal fun TeamsPane(
    selected: Set<String>,
    accent: Color,
    onToggle: (String) -> Unit,
    onAddCity: (Set<String>) -> Unit,
    onClear: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var league by remember { mutableStateOf("nba") }
    val cities = remember(query) { SportsTeams.matchingCities(query) }
    val shownLeagues = if (query.isBlank()) listOf(league) else SportsTeams.leagues
    val groups = remember(query, league) {
        shownLeagues.associateWith { SportsTeams.matchingTeams(query, it) }
    }
    LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        item("title") {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                PaneEyebrow("Your teams")
                TeamsHint("Follow any NBA, MLB or NFL team. Their games appear on Home. Choose none to hide game suggestions.")
            }
        }
        item("search") {
            SettingsEditRow(
                label = "Find a city or team",
                value = query,
                placeholder = "Search",
                accent = accent,
                onCommit = { query = it },
                onValueChange = { query = it },
            )
        }
        items(cities, key = { "city:${it.name}" }) { city ->
            Column(Modifier.fillMaxWidth()) {
                SettingsTextRow(
                    label = "Add ${city.name} teams",
                    accent = accent,
                    trailing = if (city.teamKeys.all { it in selected }) "Added" else "${city.teams.size} teams",
                    selected = city.teamKeys.all { it in selected },
                    onClick = { onAddCity(city.teamKeys) },
                )
                TeamsHint(
                    city.teams.joinToString(" · ") { it.name },
                    Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
                )
            }
        }
        if (cities.isNotEmpty()) {
            item("city-note") {
                TeamsHint("City suggestions group nearby teams. Adding them keeps your other favorites.")
            }
        }
        item("clear") {
            SettingsTextRow(
                label = "Clear all teams",
                accent = accent,
                trailing = if (selected.isEmpty()) "Game suggestions hidden" else "${selected.size} following",
                onClick = onClear,
            )
        }
        if (query.isBlank()) {
            item("leagues") {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    SportsTeams.leagues.forEach { value ->
                        SettingsTextRow(
                            label = value.uppercase(),
                            accent = accent,
                            selected = league == value,
                            onClick = { league = value },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
        groups.forEach { (group, teams) ->
            if (teams.isNotEmpty()) {
                item("league:$group") {
                    TeamsHint(
                        when (group) {
                            "nba" -> "NBA · Basketball"
                            "mlb" -> "MLB · Baseball"
                            else -> "NFL · Football"
                        },
                        Modifier.padding(top = 7.dp, bottom = 2.dp),
                    )
                }
                items(teams, key = { it.key }) { team ->
                    SettingsTextRow(
                        label = team.name,
                        accent = accent,
                        selected = team.key in selected,
                        trailing = if (team.key in selected) "Following" else "Follow",
                        onClick = { onToggle(team.key) },
                    )
                }
            }
        }
        if (groups.values.all { it.isEmpty() }) {
            item("empty") { TeamsHint("No teams match. Try a team name, city or abbreviation.") }
        }
    }
}

@Composable
private fun TeamsHint(text: String, modifier: Modifier = Modifier) {
    androidx.tv.material3.Text(
        text = text,
        style = VelourType.body.copy(fontSize = 13.sp),
        color = SettingsSecondary,
        modifier = modifier,
    )
}
