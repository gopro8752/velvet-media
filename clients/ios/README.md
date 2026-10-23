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

1. Configure your backend’s TMDB key, then enter its **Backend URL**, such as `https://backend.example.com`, and optional access token in the app’s Settings. Discovery and search use the backend’s metadata service; its TMDB credential stays on the server. Artwork loads from TMDB’s public image CDN.
2. Select or create your own profile. Entering the backend URL enables sync. Backend features, live sources, and AI categories depend on how you configure your server.
3. For standalone discovery without a backend, Settings offers an optional personal **TMDB API key** field. A connected app ignores that local key and never falls back to it if the server is unavailable. Public builds contain no bundled credential.

Credentials entered in Settings are device-local app preferences. An app built with a credential embedded in code or build settings is not a secret store; do not redistribute such a build. Use HTTPS for connections outside a trusted LAN. No bundled media or live-service subscription is supplied.

## Playback recovery and reporting

A configured recovery-enabled backend receives small playback-position heartbeats for each movie or episode, allowing it to verify upcoming bytes, try another provider, and repair the original release before the player reaches missing data. The app uses the same watch identifier for the admin recovery report and reports attempted versus successful source switches, manual versus automatic switches, rebuffering, and seeks. These requests never send provider credentials to a different origin.

Established playback receives bounded retries before changing releases. After 30 seconds of continuously advancing video, the automatic source-switch budget renews without reusing failed releases. Startup still has a short deadline. Repair and alternative playback remain best-effort: a release with insufficient parity or incompatible alternate encoding cannot be guaranteed seamless.

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
