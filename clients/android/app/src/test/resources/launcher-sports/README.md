# Primary-source schedule fixtures

Reduced from ESPN's public scoreboards on 2026-10-15. Only fields consumed by the schedule parser are
retained. These are test resources, not launcher UI data or a production fallback schedule.

- `nba-20261015.json`: https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=20261015&limit=1000
- `mlb-20261015.json`: https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard?dates=20261015&limit=1000
- `nfl-20261015.json`: https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?dates=20261015&limit=1000

The MLB response contains Tampa Bay Rays at Cleveland Guardians, starting 2026-10-15T17:00Z.
The NBA response includes preseason games; the NFL fixture crosses UTC midnight while remaining the
same evening in North America. Tests explicitly supply device zones rather than relying on host settings.
