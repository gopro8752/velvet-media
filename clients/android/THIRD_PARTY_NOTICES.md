# Third-party notices

The application's custom repository license does not replace licenses for third-party software, fonts, or runtime service content.

## Bundled fonts

These unmodified fonts are licensed under the SIL Open Font License 1.1. Their notices are included in `app/src/main/assets/licenses/` and packaged in the APK.

| Font | Copyright / source | Notice |
| --- | --- | --- |
| Inter | Copyright 2016 The Inter Project Authors; [Inter v4.0](https://github.com/rsms/inter/tree/v4.0) | [inter-OFL.txt](app/src/main/assets/licenses/inter-OFL.txt) |
| Outfit | Copyright 2021 The Outfit Project Authors; [Outfit](https://github.com/Outfitio/Outfit-Fonts) | [outfit-OFL.txt](app/src/main/assets/licenses/outfit-OFL.txt) |

## Dependencies

Gradle declares and downloads the software dependencies; no dependency source or library binaries are checked into this directory except the Gradle wrapper. Kotlin, AndroidX/Compose/Media3/Room, Coil, OkHttp, and Gradle use Apache 2.0 licensing for their primary projects. A copy of [Apache 2.0](app/src/main/assets/licenses/Apache-2.0.txt) is included. Dependency authors' own notices and any separately licensed components continue to apply. The build preserves the `META-INF/AL2.0` and `META-INF/LGPL2.1` notices supplied by dependency artifacts.

GeckoView is Mozilla's browser runtime. Its Mozilla-covered code uses the [Mozilla Public License 2.0](app/src/main/assets/licenses/MPL-2.0.txt), with additional third-party components under their respective terms. See [Mozilla source](https://hg.mozilla.org/mozilla-central/) and [Mozilla licensing](https://www.mozilla.org/en-US/MPL/). The pinned GeckoView artifact version is in `app/build.gradle.kts`; do not treat the application's license as covering GeckoView. Anyone distributing compiled applications must retain the applicable notices and satisfy the source-availability requirements for the exact browser build and any changes they make.

This file identifies the direct dependency families and checked-in assets. It is not an exhaustive license inventory of every transitive native component. Review the resolved dependency artifacts and their notices before distributing a binary. No prebuilt application is supplied with this source publication.

## Runtime metadata and services

TMDB, ESPN, and configured playback/provider endpoints are separate services. Their data, artwork, marks, availability, and access terms are not licensed by this repository. Obtain your own credentials where needed and retain any attribution their terms require. See [ASSETS.md](ASSETS.md) for the checked-in resource inventory.
