# Velvet for iPhone and iPad

A native SwiftUI client for a self-hosted Velvet backend. The public source contains no shared API key, backend account, signing team, certificate, or provisioning profile.

## Build in Simulator

Requirements: a recent full Xcode installation with an iOS Simulator SDK, XcodeGen, and internet access for Swift Package Manager dependencies. The deployment target is iOS 17.0.

```sh
xcodegen generate
xcodebuild -project Velvet.xcodeproj -scheme Velvet \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Open `Velvet.xcodeproj` in Xcode to choose a Simulator and run the app. The generated project defaults to unsigned builds and has no developer team. For your own physical devices, choose your own bundle identifier and Apple developer team and enable signing in your local Xcode configuration. Keep private signing files out of this repository.

## Connect your services

1. Open Settings and enter your own **TMDB API key**. Discovery, artwork, and search require it; there is no bundled fallback credential. Get a key for your own application from [TMDB](https://developer.themoviedb.org/docs/getting-started).
2. Enter your own **Backend URL**, such as `https://backend.example.com`, and its optional access token. A new installation has no backend selected and sync is initially disabled.
3. Enable sync and select or create your own profile. Backend features, live sources, and AI categories depend on how you configure your server.

Credentials entered in Settings are device-local app preferences. An app built with a credential embedded in code or build settings is not a secret store; do not redistribute such a build. Use HTTPS for connections outside a trusted LAN. No bundled media or live-service subscription is supplied.

## Tests

The `VelvetTests` and `VelvetUITests` targets run through Xcode. Local fixture scripts live in `scripts/`, with startup behavior checks in `Tests/sports-playback-startup.test.mjs`:

```sh
node --test Tests/sports-playback-startup.test.mjs
```

Production catalog smoke tests are optional and skipped unless the local test fixture opts into real sports and `VELVET_SMOKE_BACKEND_URL` points to a backend you explicitly control. All checked-in network examples and fixture identities are synthetic. No test needs an author's home server.

## Distribution

Simulator development needs no Apple account. Physical-device installation and TestFlight distribution require your own Apple developer setup. `scripts/testflight.sh` is an optional helper that requires your own team ID, bundle ID, private export-options plist, and already configured local signing assets; App Store Connect authentication variables are optional. The script does not create certificates or import signing keys. Review the destination in your export plist before running it: that controls export versus upload.

## Assets and dependencies

Inter and Outfit are distributed under the SIL Open Font License; copies are included in `Velvet/Resources/Fonts`. The bundled app icon is Velvet branding. Runtime movie/show artwork comes from configured metadata services and is not included in this repository. VLCKit is resolved through the pinned `VLCKitSPM` dependency; comply with its upstream licenses and notices when distributing a binary. This source package does not include a prebuilt IPA or signing material.
