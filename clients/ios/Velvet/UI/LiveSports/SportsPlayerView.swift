import AVFoundation
import OSLog
import SwiftUI
import WebKit

/// Remote sports pages get a private WebKit store, no exposed native bridge,
/// app credentials or permission to escape through native navigation.
@MainActor
final class SportsWebPlayer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var selectedID: String
    @Published private(set) var message: String?
    @Published private(set) var suspended = false
    @Published private(set) var loading = true
    private let streams: [SportsStream]
    private var closed = false
    private var started = false
    private var telemetry: PlaybackTelemetry?
    private var telemetryEvent: SportsEvent?
    private var observedState = "buffering"
    private var observedAt: TimeInterval = 0
    private var hasLoaded = false
    private var startupTask: Task<Void, Never>?
    private var startupFrames: [WKFrameInfo] = []
    // Reuse downloaded player resources only within this player. A fresh store
    // on every Reload/source change needlessly repeats its cold network setup.
    private var websiteDataStore: WKWebsiteDataStore?
    private var loadStartedAt: TimeInterval = 0
    private var embedRecovery: SportsEmbedRecovery?
    private var mainNavigation: WKNavigation?
    private let startupLogger = Logger(subsystem: "tv.velvet.ios", category: "SportsStartup")
#if DEBUG
    private var testInterruptionTask: Task<Void, Never>?
#endif

    init(streams: [SportsStream], selectedID: String, settings: SettingsStore? = nil, event: SportsEvent? = nil) {
        self.streams = streams
        self.selectedID = selectedID
        super.init()
        if let settings { telemetry = PlaybackTelemetry(settings: settings) }
        telemetryEvent = event
    }

    func start() {
        guard !started else { return }
        started = true
        if let event = telemetryEvent {
            telemetry?.start(kind: "live_sports", mediaId: event.id, title: event.title) { [weak self] in
                guard let self else { return .init(state: "ended") }
                let state = self.suspended ? "paused" : self.message != nil ? "error" :
                    self.observedState == "playing" && ProcessInfo.processInfo.systemUptime - self.observedAt > 2 ? "buffering" : self.observedState
                return .init(state: state)
            }
        }
        load(selectedID)
    }

    func load(_ id: String) {
        load(id, dnsRetry: false)
    }

    private func load(_ id: String, dnsRetry: Bool) {
        guard !closed, let stream = streams.first(where: { $0.selectionID == id }),
              SportsEmbedPolicy.accepts(stream.embedUrl) else { return }
        if !dnsRetry {
            embedRecovery = SportsEmbedRecovery(stream.embedUrl)
            loadStartedAt = ProcessInfo.processInfo.systemUptime
        }
        guard let embedURL = embedRecovery?.currentURL, SportsEmbedPolicy.accepts(embedURL) else { return }
        if hasLoaded && !dnsRetry { telemetry?.sourceSwitch() }
        hasLoaded = true
        observedState = "buffering"
        telemetry?.observe(force: true)
        detach()
        selectedID = id
        suspended = false
        loading = true
        message = nil
        let configuration = WKWebViewConfiguration()
        let store = websiteDataStore ?? .nonPersistent()
        websiteDataStore = store
        configuration.websiteDataStore = store
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(SportsPlaybackStateHandler(owner: self),
            contentWorld: SportsPlaybackStartup.world, name: SportsPlaybackStartup.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(source: SportsPlaybackStartup.makeScript(for: embedURL),
            injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: SportsPlaybackStartup.world))

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.allowsLinkPreview = false
        web.accessibilityIdentifier = "sports.webPlayer"
        webView = web
        startupPhase("browser-created")
        let remainingSeconds = max(0, 50 - (ProcessInfo.processInfo.systemUptime - loadStartedAt))
        startupTask = Task { [weak self, weak web] in
            try? await Task.sleep(nanoseconds: UInt64(remainingSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, let web, web === self.webView, self.loading else { return }
            self.stopStartup()
            self.loading = false
            self.message = "This stream hasn't started. Retry or choose another stream."
            self.telemetry?.error()
        }

        // Load only the selected public embed. Keeping its document first-party
        // lets WebKit use the provider's own HLS/service-worker startup path.
        // Native delegates still reject escapes, windows, forms and downloads.
        // Reload must still fetch a fresh embed/session; only its reusable
        // resources can benefit from the current player's in-memory store.
        mainNavigation = web.load(URLRequest(url: embedURL, cachePolicy: .reloadIgnoringLocalCacheData))
        startupPhase("document-requested")
        UIApplication.shared.isIdleTimerDisabled = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func suspend() {
        guard !closed, !suspended else { return }
        suspended = true
        telemetry?.observe(force: true)
        detach()
        message = "Playback stopped while the app was away. Reopen the stream when you're ready."
    }

    func close() {
        guard !closed else { return }
        telemetry?.end()
        closed = true
        detach()
        websiteDataStore = nil
    }

    func usePlayerControls() {
        guard !closed, !suspended, webView != nil else { return }
        stopStartup()
        loading = false
        message = nil
    }

    private func detach() {
        stopStartup()
#if DEBUG
        testInterruptionTask?.cancel()
        testInterruptionTask = nil
#endif
        if let web = webView {
            web.configuration.userContentController.removeScriptMessageHandler(
                forName: SportsPlaybackStartup.handlerName, contentWorld: SportsPlaybackStartup.world)
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.stopLoading()
            web.loadHTMLString("", baseURL: nil)
            web.removeFromSuperview()
        }
        webView = nil
        mainNavigation = nil
        loading = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func receivePlaybackState(_ state: WKScriptMessage) {
        guard let web = state.webView, web === webView, !closed, !suspended,
              state.name == SportsPlaybackStartup.handlerName, state.frameInfo.isMainFrame,
              let stream = streams.first(where: { $0.selectionID == selectedID }),
              let embedURL = embedRecovery?.currentURL,
              SportsPlaybackStartup.accepts(frameURL: state.frameInfo.request.url, for: embedURL),
              let payload = state.body as? [String: String], payload.count == 1,
              let value = payload["state"], ["ready", "media-source", "media-metadata", "playing", "paused", "buffering", "ended"].contains(value) else { return }
        if value == "media-source" || value == "media-metadata" {
            startupPhase(value)
            return
        }
        if value != "ready" {
#if DEBUG
            if observedState != value { print("[SportsDiagnostics] observed state=\(value)") }
#endif
            observedState = value
            observedAt = ProcessInfo.processInfo.systemUptime
            telemetry?.observe()
        }
        if value == "ready" {
            if loading, startupFrames.count < 16 {
                startupPhase("helper-ready")
                startupFrames.append(state.frameInfo)
                let remaining = max(0, Int((49 - (ProcessInfo.processInfo.systemUptime - loadStartedAt)) * 1000))
                web.evaluateJavaScript(SportsPlaybackStartup.beginScript(remainingMilliseconds: remaining), in: state.frameInfo,
                    in: SportsPlaybackStartup.world, completionHandler: nil)
            }
            else { web.evaluateJavaScript(SportsPlaybackStartup.cancelScript, in: state.frameInfo,
                                          in: SportsPlaybackStartup.world, completionHandler: nil) }
        } else if value == "playing" && loading {
            startupPhase("first-video")
            // A decoded picture and advancing time, not a page load or ad-click,
            // ends startup permanently so later Pause remains the user's choice.
            stopStartup()
            loading = false
            message = nil
#if DEBUG
            if stream.embedUrl.host == "127.0.0.1",
               ProcessInfo.processInfo.arguments.contains("-VelvetTestAudioInterruption") {
                testInterruptionTask = Task { [weak self, weak web] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled, let self, let web, web === self.webView,
                          UIApplication.shared.applicationState == .active else { return }
                    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                        object: AVAudioSession.sharedInstance(),
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
                    print("[SportsDiagnostics] fixture foreground interruption delivered")
                }
            }
#endif
        }
    }

    private func stopStartup() {
        startupTask?.cancel()
        startupTask = nil
        if let web = webView {
            for frame in startupFrames {
                web.evaluateJavaScript(SportsPlaybackStartup.cancelScript, in: frame,
                    in: SportsPlaybackStartup.world, completionHandler: nil)
            }
        }
        startupFrames.removeAll()
    }

    private func startupPhase(_ name: String) {
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - loadStartedAt) * 1000)
        // Fixed phase names and elapsed time only; no page URLs or provider tokens.
        startupLogger.info("Startup phase=\(name, privacy: .public) elapsedMs=\(elapsed, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView, !closed else { return }
        startupPhase("document-committed")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, !closed else { return }
        startupPhase("document-loaded")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard webView === self.webView, !closed, !action.shouldPerformDownload,
              action.navigationType != .formSubmitted, action.navigationType != .formResubmitted,
              let frame = action.targetFrame, let url = action.request.url,
              url.user == nil, url.password == nil else { decisionHandler(.cancel); return }
        if frame.isMainFrame {
            let selectedURL = embedRecovery?.currentURL
            decisionHandler(url == selectedURL && action.navigationType == .other ? .allow : .cancel)
        } else {
            // Subframes can load the provider's nested players. Native policy
            // above denies forms/downloads, and all main-frame escapes are denied.
            let allowed = url.scheme == "https" || url.absoluteString == "about:blank"
                || SportsEmbedPolicy.accepts(url)
            decisionHandler(allowed ? .allow : .cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(webView === self.webView && response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error: error, allowsDNSRetry: navigation != nil && navigation === mainNavigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error: error)
    }
    private func failed(_ web: WKWebView, error: Error, allowsDNSRetry: Bool = false) {
        guard web === webView, (error as NSError).code != NSURLErrorCancelled else { return }
        let failure = error as NSError
        let failedURL = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (failure.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        let dnsFailure = allowsDNSRetry && failure.domain == NSURLErrorDomain &&
            [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(failure.code)
        let remaining = Int((50 - (ProcessInfo.processInfo.systemUptime - loadStartedAt)) * 1000)
        if !closed, !suspended, embedRecovery?.retryDNSFailure(failedURL: failedURL, isDNSFailure: dnsFailure,
            playbackStarted: !loading, remainingMilliseconds: remaining) != nil {
            startupPhase("dns-mirror-retry")
            load(selectedID, dnsRetry: true)
            return
        }
        stopStartup()
        loading = false
        message = "Couldn't load this player. Try another stream or retry."
        telemetry?.error()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        detach()
        message = "The player stopped. Try another stream or retry."
        telemetry?.error()
    }

    // Never hand remote links off to Safari, apps, download managers or native UI.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

struct SportsPlayerView: View {
    let target: SportsPlayTarget
    @StateObject private var player: SportsWebPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(target: SportsPlayTarget, settings: SettingsStore? = nil) {
        self.target = target
        _player = StateObject(wrappedValue: SportsWebPlayer(streams: target.streams, selectedID: target.selectedID, settings: settings, event: target.event))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                PlayerIconButton(systemName: "xmark") { player.close(); dismiss() }
                    .accessibilityLabel("Close sports player").accessibilityIdentifier("sports.close")
                Text(target.event.title).font(VelvetFont.display(17, .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button { player.load(player.selectedID) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload stream").accessibilityIdentifier("sports.reload")
                Menu {
                    ForEach(target.streams, id: \.selectionID) { stream in
                        Button { player.load(stream.selectionID) } label: {
                            if stream.selectionID == player.selectedID { Label(stream.label, systemImage: "checkmark") }
                            else { Text(stream.label) }
                        }
                    }
                } label: { Label("Streams", systemImage: "list.bullet") }
                .accessibilityIdentifier("sports.switchStream")
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            ZStack {
                if let web = player.webView { SportsWebSurface(web: web).id(ObjectIdentifier(web)) }
                if player.loading {
                    Color.black.overlay {
                        ProgressView("Starting stream…").tint(.white)
                            .accessibilityIdentifier("sports.starting")
                    }
                }
                if let message = player.message {
                    VStack(spacing: 14) {
                        Text(message).multilineTextAlignment(.center)
                        Button(player.suspended ? "Open stream" : "Retry") { player.load(player.selectedID) }
                            .buttonStyle(PlayerPrimaryButtonStyle()).accessibilityIdentifier("sports.retry")
                        if !player.suspended, player.webView != nil {
                            Button("Use player controls") { player.usePlayerControls() }
                                .accessibilityIdentifier("sports.manualPlay")
                        }
                    }.padding(24).frame(maxWidth: 500).background(.black.opacity(0.92))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("If playback fails, choose another stream or reload. Stream availability can change.")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.vertical, 5)
        }
        .background(.black).foregroundStyle(.white)
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear { player.start() }
        .onDisappear { player.close() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {

                // UIKit app state is authoritative for background cleanup in
                // this separate hosting controller.
                if UIApplication.shared.applicationState == .background { player.suspend() }
            }
        }
        // This view is presented by a separate UIKit hosting controller; app
        // notifications also cover hosts without a propagated SwiftUI scenePhase.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in

            player.suspend()
        }

    }
}

private struct SportsWebSurface: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ view: WKWebView, context: Context) { }
}
