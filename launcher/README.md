# Velour — the companion launcher for Velvet

Velour makes Velvet part of your TV's home screen. It is the recommended companion launcher for a Shield or Android TV: your apps first, Velvet's Continue Watching just below, and today's games within reach. Dark wallpapers, animated glass focus treatments, and quiet typography carry Velvet's visual language through the whole experience. A clock and optional weather sit alongside the profile and settings controls; standby uses a black background behind the moving clock.

[![Velour home with a Today game card, favorite apps, and Velvet Continue Watching](../docs/screenshots/velour-home.png)](../docs/screenshots/velour-home.png)

*Actual Android TV app capture in a 1080p emulator, with staged Continue Watching entries. The game card shows a scheduled matchup; it does not imply a currently available stream.*

## Watch from your home screen

- **Continue Watching opens directly in Velvet.** Select a movie or episode from the current profile's shelf to resume it. The profile button opens Velvet's profile picker, and the launcher refreshes to reflect the selected viewer.
- **Today connects your teams to Live Sports.** Choose favorite NBA, MLB, and NFL teams in launcher settings. Select a game card to open its player in Velvet when Live Sports is configured and a fresh matching event is available. A live, matched game displays a play icon. If no reliable match is available, Velvet opens its sports view with the relevant league and matchup context so you can choose an event.
- **Your apps stay easy to reach.** Launch other TV apps from the same home screen, with consistent focus highlights and remote navigation.

Game schedules come from public scoreboards and can appear even when no playable stream is available. Playback depends on the Live Sports sources configured in Velvet; selecting a future game does not guarantee that its stream has started.

## Connect Velvet and Velour

Install and configure [Velvet for Android TV](../clients/android/README.md), choose a profile there, and install Velour **signed with the same certificate**. This is required for the protected local content provider and launch actions that share profiles, Continue Watching, and game selections. Velour does not bundle or require a second backend URL, backend token, or TMDB key: Velvet owns that connection.

Open Velour as an ordinary TV app to try it, then select it as your device's Home application in the supported Home/default-app settings. Default-launcher selection varies by device. Velour requires Android 9/API 28 or newer. Velvet works standalone, and Velour's app grid and wallpapers work without Velvet; the shared experience is enabled by installing the pair.

## Configuration

Open the top-right **Settings** button to choose wallpaper, location, favorite teams, and other presentation options. A new installation has no saved location or favorite teams. Weather queries use Open-Meteo; team schedules use ESPN's public scoreboard endpoints. These services are independently operated and may change.

## Build

Use JDK 17, Android SDK Platform 35, and the Android command-line tools or Android Studio. Set `ANDROID_HOME`, or create an untracked `local.properties` with `sdk.dir=/path/to/android-sdk`.

```sh
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME=/path/to/android-sdk
./gradlew :app:assembleRelease :app:lintRelease
```

The unsigned output is `app/build/outputs/apk/release/app-release-unsigned.apk`. Align and sign it with your own Android signing key using `zipalign` and `apksigner`; use that same key for Velvet. Keep all signing files and passwords outside the repository. Debug builds (`./gradlew :app:assembleDebug`) use your local Android debug key. There are currently no launcher unit tests; `:app:testDebugUnitTest` reports `NO-SOURCE`.

The source is available under the repository's [custom license](../LICENSE), with its personal/noncommercial use and source-sharing terms. Third-party software and assets retain their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [ASSETS.md](ASSETS.md).
