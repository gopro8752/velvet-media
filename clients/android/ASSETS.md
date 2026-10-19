# Asset inventory

| Asset | Origin and terms |
| --- | --- |
| `app/src/main/res/font/inter.ttf` | Unmodified Inter font, version 4.001; SIL Open Font License 1.1 |
| `app/src/main/res/font/outfit.ttf` | Unmodified Outfit font, version 1.100; SIL Open Font License 1.1 |
| App icon and TV banner XML/vector resources | Project-authored geometric artwork; repository license |
| `app/src/main/assets/sports-startup` | Project-authored browser startup code; repository license |

The exact font license and copyright notices ship under `app/src/main/assets/licenses/`. Font filenames may describe use rather than upstream family naming; inspect `app/src/main/res/font/` for the complete packaged set.

Movie/show artwork is fetched at runtime from the configured metadata service. No entertainment posters, screenshots, logos, or video are bundled as application assets. Material icons are provided by AndroidX under its Apache 2.0 terms.

`app/src/test/resources/launcher-sports/` contains small, reduced ESPN scoreboard fixtures used only by tests. Its README records the public source endpoints and retained fields. These are factual parser fixtures, not bundled app content or a grant of rights to ESPN branding or media.
