# Velvet for Android TV

Velvet is a remote-first media client built with Kotlin, Compose for TV, Media3, and GeckoView. It supports profiles, Continue Watching, lists, episode navigation, source and track selection, category queues, shuffle, playback handoff, and optional backend-powered live TV, sports, and AI categories.

This repository contains the client software, not a media library, provider subscription, API credential, or hosted backend. Configure services you are entitled to use. See the [repository setup](../../README.md) for the other components.

## First launch

Open **Settings** from the dock. Configure:

1. **TMDB → API key**: your own TMDB v3 API key for catalog metadata. The public build has no embedded key. The home catalog will be empty until this is configured; Settings remains available.
2. **Backend → Backend URL**: the base URL of your Velvet backend, for example `https://backend.example.com`. This also configures its stream-source and sync endpoints.
3. **Backend → Token (optional)**: the backend's bearer token, if your server requires one. Use HTTPS for a backend reached over the internet.

Live TV, sports, AI categories, cross-device sync, and reporting depend on the matching backend capabilities and configuration. Configure upstream credentials on your own server. Neither the client nor this source distribution grants access to any third-party service.

The playback reporter sends title/profile/device information and measured playing/buffering time to the **configured Velvet backend**. It uses an app-install identifier and the backend token, sends asynchronously, and does not report media URLs or upstream credentials. Clearing the backend configuration disables reporting. See the server documentation before sharing a deployment with other people.

## Build

Use JDK 17 and the Android command-line tools or Android Studio. Install Android SDK Platform 37.2 and the build tools requested by Gradle. Set `ANDROID_HOME` to your SDK directory, or create an untracked `local.properties` containing `sdk.dir=/path/to/android-sdk`.

```sh
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME=/path/to/android-sdk
./gradlew :app:testDebugUnitTest :app:assembleRelease :app:lintRelease
node --test tests/sports-startup.test.cjs
```

Gradle downloads its pinned toolchain dependencies from the configured upstream repositories. The client supports Android 8.0/API 26 or newer. Release builds produce **unsigned** APKs for `arm64-v8a`, `armeabi-v7a`, and `x86_64` under `app/build/outputs/apk/release/`. Choose the ABI supported by your device.

Sign and align release APKs using your own Android signing key and the Android SDK's `zipalign`/`apksigner` tools. Keep signing material and passwords outside the repository. Debug builds (`./gradlew :app:assembleDebug`) use your local Android debug key. No release signing key or publisher credentials are included.

To use [Velour](../../launcher/README.md), sign **both applications with the same certificate**. Velvet protects its launcher data provider and launch entry point with a signature permission. Independently signed copies cannot read that data. An existing installation signed with a different key cannot be updated by your build; use your own test device or app identifier while developing.

## Source layout

| Directory | Purpose |
| --- | --- |
| `app/src/main/java/tv/velvet/data` | Catalog, backend, sync, profiles, telemetry, and launcher integration |
| `app/src/main/java/tv/velvet/ui` | TV navigation, browsing, settings, native and browser players |
| `app/src/main/assets/sports-startup` | Browser playback-start coordination |
| `app/src/test` | Unit tests and reduced metadata fixtures |
| `tests` | Browser startup logic tests |

The source is available under the repository's [custom license](../../LICENSE). It permits personal, noncommercial use subject to its terms; it is not an MIT/Apache license for the application. Third-party code and assets retain their own terms, described in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
