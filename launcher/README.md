# Velour for Android TV

Velour is a remote-first home launcher for Android TV. It combines an app grid, animated glass focus treatments, dark wallpapers, a clock, optional weather and favorite-team cards, and Velvet's Continue Watching row. Its standby view uses a black background behind the moving clock.

The launcher can run as an ordinary TV app before you select it as your device's Home application. It requires Android 9/API 28 or newer. Default-launcher selection varies by device; choose Velour in the device's supported Home/default-app settings when available.

## Configuration

Open the top-right **Settings** button to choose wallpaper, location, favorite teams, and other presentation options. A new installation has no saved location or favorite teams. Weather queries use Open-Meteo; team schedules use ESPN's public scoreboard endpoints. These services are independently operated and may change.

Install and configure [Velvet for Android TV](../clients/android/README.md) for profiles, Continue Watching, and playback shortcuts. Velour reads these through a local Android content provider; it does not bundle a backend URL, backend token, or TMDB key. Velvet and Velour **must be signed with the same certificate** because this integration uses Android's signature-level permission. The app grid and wallpapers work without Velvet.

## Build

Use JDK 17, Android SDK Platform 35, and the Android command-line tools or Android Studio. Set `ANDROID_HOME`, or create an untracked `local.properties` with `sdk.dir=/path/to/android-sdk`.

```sh
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME=/path/to/android-sdk
./gradlew :app:assembleRelease :app:lintRelease
```

The unsigned output is `app/build/outputs/apk/release/app-release-unsigned.apk`. Align and sign it with your own Android signing key using `zipalign` and `apksigner`; use that same key for Velvet. Keep all signing files and passwords outside the repository. Debug builds (`./gradlew :app:assembleDebug`) use your local Android debug key. There are currently no launcher unit tests; `:app:testDebugUnitTest` reports `NO-SOURCE`.

The source is available under the repository's [custom license](../LICENSE), with its personal/noncommercial use and source-sharing terms. Third-party software and assets retain their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [ASSETS.md](ASSETS.md).
