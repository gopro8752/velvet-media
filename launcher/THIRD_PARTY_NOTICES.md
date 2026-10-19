# Third-party notices

The application's custom repository license does not replace third-party licenses.

## Bundled fonts

The unmodified fonts below use the SIL Open Font License 1.1. Their copyright and license texts are included in `app/src/main/assets/licenses/` and packaged in the APK.

| Font | Copyright / source | Notice |
| --- | --- | --- |
| Inter | Copyright 2016 The Inter Project Authors; [Inter v4.0](https://github.com/rsms/inter/tree/v4.0) | [inter-OFL.txt](app/src/main/assets/licenses/inter-OFL.txt) |
| Outfit | Copyright 2021 The Outfit Project Authors; [Outfit](https://github.com/Outfitio/Outfit-Fonts) | [outfit-OFL.txt](app/src/main/assets/licenses/outfit-OFL.txt) |
| Space Grotesk | Copyright 2020 The Space Grotesk Project Authors; [Space Grotesk](https://github.com/floriankarsten/space-grotesk) | [spacegrotesk-OFL.txt](app/src/main/assets/licenses/spacegrotesk-OFL.txt) |

## Dependencies

Gradle downloads declared dependencies; this directory does not vendor their source or binaries apart from the Gradle wrapper. The primary Kotlin, AndroidX/Compose, OkHttp, and Gradle projects use Apache 2.0. A copy of [Apache 2.0](app/src/main/assets/licenses/Apache-2.0.txt) is included. Their own copyright notices and licenses for separately bundled components also apply. The build preserves dependency-supplied `META-INF/AL2.0` and `META-INF/LGPL2.1` notices.

This is an inventory of checked-in assets and direct dependency families, not a complete analysis of every resolved transitive dependency. Review dependency notices before distributing a compiled application. No prebuilt application accompanies this source publication.

## Runtime services

Open-Meteo weather/geocoding and ESPN scoreboards are separate services, subject to their own availability and terms. Runtime artwork, app icons, league/team marks, and metadata are not licensed by this repository. The project wallpapers and bundled assets are described in [ASSETS.md](ASSETS.md).
