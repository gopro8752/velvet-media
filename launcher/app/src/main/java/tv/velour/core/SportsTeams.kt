package tv.velour.core

import java.util.Locale

/** Offline picker identities, shared with the ESPN scoreboards exposed by Velvet. */
data class SportsTeamDefinition(
    val key: String,
    val league: String,
    val id: String,
    val name: String,
    val shortName: String,
    val abbreviation: String,
    /** A suggested market grouping, not a claim about a stadium's exact municipality. */
    val city: String,
)

data class SportsCityPreset(
    val name: String,
    val teams: List<SportsTeamDefinition>,
    val aliases: List<String> = emptyList(),
) {
    val teamKeys: Set<String> get() = teams.mapTo(linkedSetOf()) { it.key }
}

/**
 * Team names and IDs verified 2026-10-15 against ESPN's first-party team directories:
 * https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams?limit=100
 * https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/teams?limit=100
 * https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams?limit=100
 *
 * Bundled so choosing teams works without a network connection. City presets are
 * explicit convenience groups; applying one adds its listed teams, never replaces
 * other favorites or changes the weather location. Relocated teams retain ESPN IDs.
 */
object SportsTeams {
    val defaultKeys: Set<String> = emptySet()
    val leagues: List<String> = listOf("nba", "mlb", "nfl")
    val all: List<SportsTeamDefinition> = listOf(
        SportsTeamDefinition("nba:1", "nba", "1", "Atlanta Hawks", "Hawks", "ATL", "Atlanta"),
        SportsTeamDefinition("nba:2", "nba", "2", "Boston Celtics", "Celtics", "BOS", "Boston"),
        SportsTeamDefinition("nba:17", "nba", "17", "Brooklyn Nets", "Nets", "BKN", "New York"),
        SportsTeamDefinition("nba:30", "nba", "30", "Charlotte Hornets", "Hornets", "CHA", "Charlotte"),
        SportsTeamDefinition("nba:4", "nba", "4", "Chicago Bulls", "Bulls", "CHI", "Chicago"),
        SportsTeamDefinition("nba:5", "nba", "5", "Cleveland Cavaliers", "Cavaliers", "CLE", "Cleveland"),
        SportsTeamDefinition("nba:6", "nba", "6", "Dallas Mavericks", "Mavericks", "DAL", "Dallas–Fort Worth"),
        SportsTeamDefinition("nba:7", "nba", "7", "Denver Nuggets", "Nuggets", "DEN", "Denver"),
        SportsTeamDefinition("nba:8", "nba", "8", "Detroit Pistons", "Pistons", "DET", "Detroit"),
        SportsTeamDefinition("nba:9", "nba", "9", "Golden State Warriors", "Warriors", "GS", "San Francisco Bay Area"),
        SportsTeamDefinition("nba:10", "nba", "10", "Houston Rockets", "Rockets", "HOU", "Houston"),
        SportsTeamDefinition("nba:11", "nba", "11", "Indiana Pacers", "Pacers", "IND", "Indianapolis"),
        SportsTeamDefinition("nba:12", "nba", "12", "LA Clippers", "Clippers", "LAC", "Los Angeles"),
        SportsTeamDefinition("nba:13", "nba", "13", "Los Angeles Lakers", "Lakers", "LAL", "Los Angeles"),
        SportsTeamDefinition("nba:29", "nba", "29", "Memphis Grizzlies", "Grizzlies", "MEM", "Memphis"),
        SportsTeamDefinition("nba:14", "nba", "14", "Miami Heat", "Heat", "MIA", "Miami"),
        SportsTeamDefinition("nba:15", "nba", "15", "Milwaukee Bucks", "Bucks", "MIL", "Milwaukee"),
        SportsTeamDefinition("nba:16", "nba", "16", "Minnesota Timberwolves", "Timberwolves", "MIN", "Minneapolis–Saint Paul"),
        SportsTeamDefinition("nba:3", "nba", "3", "New Orleans Pelicans", "Pelicans", "NO", "New Orleans"),
        SportsTeamDefinition("nba:18", "nba", "18", "New York Knicks", "Knicks", "NY", "New York"),
        SportsTeamDefinition("nba:25", "nba", "25", "Oklahoma City Thunder", "Thunder", "OKC", "Oklahoma City"),
        SportsTeamDefinition("nba:19", "nba", "19", "Orlando Magic", "Magic", "ORL", "Orlando"),
        SportsTeamDefinition("nba:20", "nba", "20", "Philadelphia 76ers", "76ers", "PHI", "Philadelphia"),
        SportsTeamDefinition("nba:21", "nba", "21", "Phoenix Suns", "Suns", "PHX", "Phoenix"),
        SportsTeamDefinition("nba:22", "nba", "22", "Portland Trail Blazers", "Trail Blazers", "POR", "Portland"),
        SportsTeamDefinition("nba:23", "nba", "23", "Sacramento Kings", "Kings", "SAC", "Sacramento"),
        SportsTeamDefinition("nba:24", "nba", "24", "San Antonio Spurs", "Spurs", "SA", "San Antonio"),
        SportsTeamDefinition("nba:28", "nba", "28", "Toronto Raptors", "Raptors", "TOR", "Toronto"),
        SportsTeamDefinition("nba:26", "nba", "26", "Utah Jazz", "Jazz", "UTAH", "Salt Lake City"),
        SportsTeamDefinition("nba:27", "nba", "27", "Washington Wizards", "Wizards", "WSH", "Washington"),
        SportsTeamDefinition("mlb:29", "mlb", "29", "Arizona Diamondbacks", "Diamondbacks", "ARI", "Phoenix"),
        SportsTeamDefinition("mlb:11", "mlb", "11", "Athletics", "Athletics", "ATH", "Sacramento"),
        SportsTeamDefinition("mlb:15", "mlb", "15", "Atlanta Braves", "Braves", "ATL", "Atlanta"),
        SportsTeamDefinition("mlb:1", "mlb", "1", "Baltimore Orioles", "Orioles", "BAL", "Baltimore"),
        SportsTeamDefinition("mlb:2", "mlb", "2", "Boston Red Sox", "Red Sox", "BOS", "Boston"),
        SportsTeamDefinition("mlb:16", "mlb", "16", "Chicago Cubs", "Cubs", "CHC", "Chicago"),
        SportsTeamDefinition("mlb:4", "mlb", "4", "Chicago White Sox", "White Sox", "CHW", "Chicago"),
        SportsTeamDefinition("mlb:17", "mlb", "17", "Cincinnati Reds", "Reds", "CIN", "Cincinnati"),
        SportsTeamDefinition("mlb:5", "mlb", "5", "Cleveland Guardians", "Guardians", "CLE", "Cleveland"),
        SportsTeamDefinition("mlb:27", "mlb", "27", "Colorado Rockies", "Rockies", "COL", "Denver"),
        SportsTeamDefinition("mlb:6", "mlb", "6", "Detroit Tigers", "Tigers", "DET", "Detroit"),
        SportsTeamDefinition("mlb:18", "mlb", "18", "Houston Astros", "Astros", "HOU", "Houston"),
        SportsTeamDefinition("mlb:7", "mlb", "7", "Kansas City Royals", "Royals", "KC", "Kansas City"),
        SportsTeamDefinition("mlb:3", "mlb", "3", "Los Angeles Angels", "Angels", "LAA", "Los Angeles"),
        SportsTeamDefinition("mlb:19", "mlb", "19", "Los Angeles Dodgers", "Dodgers", "LAD", "Los Angeles"),
        SportsTeamDefinition("mlb:28", "mlb", "28", "Miami Marlins", "Marlins", "MIA", "Miami"),
        SportsTeamDefinition("mlb:8", "mlb", "8", "Milwaukee Brewers", "Brewers", "MIL", "Milwaukee"),
        SportsTeamDefinition("mlb:9", "mlb", "9", "Minnesota Twins", "Twins", "MIN", "Minneapolis–Saint Paul"),
        SportsTeamDefinition("mlb:21", "mlb", "21", "New York Mets", "Mets", "NYM", "New York"),
        SportsTeamDefinition("mlb:10", "mlb", "10", "New York Yankees", "Yankees", "NYY", "New York"),
        SportsTeamDefinition("mlb:22", "mlb", "22", "Philadelphia Phillies", "Phillies", "PHI", "Philadelphia"),
        SportsTeamDefinition("mlb:23", "mlb", "23", "Pittsburgh Pirates", "Pirates", "PIT", "Pittsburgh"),
        SportsTeamDefinition("mlb:25", "mlb", "25", "San Diego Padres", "Padres", "SD", "San Diego"),
        SportsTeamDefinition("mlb:26", "mlb", "26", "San Francisco Giants", "Giants", "SF", "San Francisco Bay Area"),
        SportsTeamDefinition("mlb:12", "mlb", "12", "Seattle Mariners", "Mariners", "SEA", "Seattle"),
        SportsTeamDefinition("mlb:24", "mlb", "24", "St. Louis Cardinals", "Cardinals", "STL", "St. Louis"),
        SportsTeamDefinition("mlb:30", "mlb", "30", "Tampa Bay Rays", "Rays", "TB", "Tampa Bay"),
        SportsTeamDefinition("mlb:13", "mlb", "13", "Texas Rangers", "Rangers", "TEX", "Dallas–Fort Worth"),
        SportsTeamDefinition("mlb:14", "mlb", "14", "Toronto Blue Jays", "Blue Jays", "TOR", "Toronto"),
        SportsTeamDefinition("mlb:20", "mlb", "20", "Washington Nationals", "Nationals", "WSH", "Washington"),
        SportsTeamDefinition("nfl:22", "nfl", "22", "Arizona Cardinals", "Cardinals", "ARI", "Phoenix"),
        SportsTeamDefinition("nfl:1", "nfl", "1", "Atlanta Falcons", "Falcons", "ATL", "Atlanta"),
        SportsTeamDefinition("nfl:33", "nfl", "33", "Baltimore Ravens", "Ravens", "BAL", "Baltimore"),
        SportsTeamDefinition("nfl:2", "nfl", "2", "Buffalo Bills", "Bills", "BUF", "Buffalo"),
        SportsTeamDefinition("nfl:29", "nfl", "29", "Carolina Panthers", "Panthers", "CAR", "Charlotte"),
        SportsTeamDefinition("nfl:3", "nfl", "3", "Chicago Bears", "Bears", "CHI", "Chicago"),
        SportsTeamDefinition("nfl:4", "nfl", "4", "Cincinnati Bengals", "Bengals", "CIN", "Cincinnati"),
        SportsTeamDefinition("nfl:5", "nfl", "5", "Cleveland Browns", "Browns", "CLE", "Cleveland"),
        SportsTeamDefinition("nfl:6", "nfl", "6", "Dallas Cowboys", "Cowboys", "DAL", "Dallas–Fort Worth"),
        SportsTeamDefinition("nfl:7", "nfl", "7", "Denver Broncos", "Broncos", "DEN", "Denver"),
        SportsTeamDefinition("nfl:8", "nfl", "8", "Detroit Lions", "Lions", "DET", "Detroit"),
        SportsTeamDefinition("nfl:9", "nfl", "9", "Green Bay Packers", "Packers", "GB", "Green Bay"),
        SportsTeamDefinition("nfl:34", "nfl", "34", "Houston Texans", "Texans", "HOU", "Houston"),
        SportsTeamDefinition("nfl:11", "nfl", "11", "Indianapolis Colts", "Colts", "IND", "Indianapolis"),
        SportsTeamDefinition("nfl:30", "nfl", "30", "Jacksonville Jaguars", "Jaguars", "JAX", "Jacksonville"),
        SportsTeamDefinition("nfl:12", "nfl", "12", "Kansas City Chiefs", "Chiefs", "KC", "Kansas City"),
        SportsTeamDefinition("nfl:13", "nfl", "13", "Las Vegas Raiders", "Raiders", "LV", "Las Vegas"),
        SportsTeamDefinition("nfl:24", "nfl", "24", "Los Angeles Chargers", "Chargers", "LAC", "Los Angeles"),
        SportsTeamDefinition("nfl:14", "nfl", "14", "Los Angeles Rams", "Rams", "LAR", "Los Angeles"),
        SportsTeamDefinition("nfl:15", "nfl", "15", "Miami Dolphins", "Dolphins", "MIA", "Miami"),
        SportsTeamDefinition("nfl:16", "nfl", "16", "Minnesota Vikings", "Vikings", "MIN", "Minneapolis–Saint Paul"),
        SportsTeamDefinition("nfl:17", "nfl", "17", "New England Patriots", "Patriots", "NE", "Boston"),
        SportsTeamDefinition("nfl:18", "nfl", "18", "New Orleans Saints", "Saints", "NO", "New Orleans"),
        SportsTeamDefinition("nfl:19", "nfl", "19", "New York Giants", "Giants", "NYG", "New York"),
        SportsTeamDefinition("nfl:20", "nfl", "20", "New York Jets", "Jets", "NYJ", "New York"),
        SportsTeamDefinition("nfl:21", "nfl", "21", "Philadelphia Eagles", "Eagles", "PHI", "Philadelphia"),
        SportsTeamDefinition("nfl:23", "nfl", "23", "Pittsburgh Steelers", "Steelers", "PIT", "Pittsburgh"),
        SportsTeamDefinition("nfl:25", "nfl", "25", "San Francisco 49ers", "49ers", "SF", "San Francisco Bay Area"),
        SportsTeamDefinition("nfl:26", "nfl", "26", "Seattle Seahawks", "Seahawks", "SEA", "Seattle"),
        SportsTeamDefinition("nfl:27", "nfl", "27", "Tampa Bay Buccaneers", "Buccaneers", "TB", "Tampa Bay"),
        SportsTeamDefinition("nfl:10", "nfl", "10", "Tennessee Titans", "Titans", "TEN", "Nashville"),
        SportsTeamDefinition("nfl:28", "nfl", "28", "Washington Commanders", "Commanders", "WSH", "Washington"),
    )
    val byKey: Map<String, SportsTeamDefinition> = all.associateBy { it.key }

    private val cityAliases = mapOf(
        "Boston" to listOf("New England", "Foxborough"),
        "Charlotte" to listOf("Carolina"),
        "Dallas–Fort Worth" to listOf("Dallas", "Fort Worth", "Arlington", "Texas"),
        "Denver" to listOf("Colorado"),
        "Indianapolis" to listOf("Indiana"),
        "Los Angeles" to listOf("LA", "Anaheim", "Inglewood"),
        "Minneapolis–Saint Paul" to listOf("Minneapolis", "Saint Paul", "St Paul", "Minnesota", "Twin Cities"),
        "Nashville" to listOf("Tennessee"),
        "New York" to listOf("NY", "NYC", "Brooklyn", "Queens", "Bronx", "East Rutherford"),
        "Phoenix" to listOf("Arizona", "Glendale"),
        "Sacramento" to listOf("West Sacramento"),
        "Salt Lake City" to listOf("Utah"),
        "San Francisco Bay Area" to listOf("SF", "San Francisco", "Bay Area", "Golden State", "Santa Clara"),
        "Tampa Bay" to listOf("Tampa", "St Petersburg", "Saint Petersburg"),
        "Washington" to listOf("DC", "Washington DC"),
    )
    val cityPresets: List<SportsCityPreset> = all.groupBy { it.city }
        .map { (name, teams) -> SportsCityPreset(name, teams, cityAliases[name].orEmpty()) }
        .sortedBy { it.name }

    fun matchingCities(query: String): List<SportsCityPreset> {
        val normalized = normalize(query)
        if (normalized.length < 2) return emptyList()
        return cityPresets.filter { city ->
            (listOf(city.name) + city.aliases).any { matches(normalize(it), normalized) }
        }.take(6)
    }

    fun matchingTeams(query: String, league: String): List<SportsTeamDefinition> {
        val terms = normalize(query).split(' ').filter { it.isNotBlank() }
        return all.filter { team ->
            team.league == league && terms.all { term ->
                matches(normalize(listOf(team.name, team.shortName, team.abbreviation, team.city)
                    .plus(cityAliases[team.city].orEmpty()).joinToString(" ")), term)
            }
        }
    }

    // Short city aliases such as LA should not also match Cleve"la"nd or Dal"la"s.
    private fun matches(value: String, query: String): Boolean =
        if (query.length <= 2) query in value.split(' ') else value.contains(query)

    private fun normalize(value: String): String = value.lowercase(Locale.ROOT)
        .map { if (it.isLetterOrDigit()) it else ' ' }.joinToString("")
        .trim().split(Regex("\\s+")).joinToString(" ")
}
