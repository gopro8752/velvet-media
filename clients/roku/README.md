# Velvet for Roku — ALPHA

**This Roku port is alpha software for private developer-mode sideloading.** It is not a Roku Channel Store release, and the source package does not include a signed channel, an installation password, a server account, or any media subscription. Test it on your target hardware before relying on it.

The native BrightScript / SceneGraph client includes profiles, discovery, search, Continue Watching, saved categories, episode queues, player controls, live TV and guide views, sports source selection, and playback reporting. It connects to a backend that you operate or are explicitly permitted to use.

## Build and test

Requirements: Node.js 20 or newer, npm, and `unzip` on your path.

```sh
npm ci
npm test
npm run build
```

The verified sideload package is written to `dist/velvet-roku.zip`; a SHA-256 checksum is generated beside it. Generated packages and dependencies are local build outputs and should not be committed.

## Private sideload setup

1. On your Roku remote, press Home three times, Up twice, then Right, Left, Right, Left, Right to open developer settings. Review Roku's developer agreement, enable the installer, choose a private password, and restart when prompted.
2. Open the Roku's developer installer address in a browser on the same trusted network. Sign in as `rokudev` with the password you chose and upload your locally built ZIP. Sideloading replaces the Roku's single developer app.
3. Open Velvet and enter your own backend URL and its optional token. The app ships with both unset. Use a reachable HTTPS backend for remote households.
4. Choose or create a profile. Voice input depends on the Roku model, remote, OS, and keyboard-field support.

You can alternatively run the local deployment helper after enabling developer mode:

```sh
ROKU_HOST=roku.example.test npm run deploy
```

Replace that documentation hostname with your Roku's actual hostname or IP. The helper verifies developer mode, builds and tests, then prompts for the password without displaying it. For automation, use a private file via `ROKU_PASSWORD_FILE` with mode `600`. Do not place credentials in source or commit configuration containing them. The helper does not enable developer mode for you.

## Current limitations

- Developer-mode sideloading is a per-device setup and supports one developer app at a time. This is not an automatic family-and-friends installation or update service.
- Codec support, audio tracks, subtitle behavior, and seeking depend on Roku hardware and firmware. Some sources need the backend's Roku-compatible audio or video path; not every source format is playable.
- Roku cannot embed arbitrary web players. Live sports requires a playable source and the compatible backend route; availability depends on your backend configuration and source.
- Microphone support uses Roku's system keyboard integration. This is not a custom always-listening assistant, and voice availability varies across devices.
- Visual effects are adapted to SceneGraph. They will not exactly match iOS or Android's rendering.
- Unit/build checks do not replace playback, remote navigation, sleep/wake, and long-session testing on real hardware. The current port remains alpha even when these checks pass.

The backend and your own enabled services supply metadata and playback. No provider account, shared API key, private endpoint, copyrighted title artwork, or media library is bundled.

## Assets and licenses

Inter and Outfit font files include their SIL Open Font License notices in `fonts/`; the build includes these notices in the sideload package. Bundled UI imagery consists of Velvet branding, abstract backgrounds, and controls. Runtime title and cast artwork is loaded from your configured backend. Development dependencies and their license notices are installed by npm; review their licenses before distributing modified tooling or a packaged channel.
