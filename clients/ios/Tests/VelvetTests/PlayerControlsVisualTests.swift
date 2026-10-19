import XCTest
import SwiftUI
import SwiftData
import UIKit
import AVFoundation
@testable import Velvet

private struct VisualPlayerMetadata: TmdbRepository {
    var allRows: [RowSpec] { [] }
    func rowItems(rowId: String, page: Int) async -> [MediaItem] { [] }
    func search(query: String) async -> [MediaItem] { [] }
    func episodes(showId: Int, season: Int) async -> [Episode] {
        (1...3).map { Episode(season: 1, number: $0, title: "Episode \($0)", runtimeMinutes: 2) }
    }
    func details(id: Int, type: MediaType) async throws -> MediaDetails {
        MediaDetails(item: MediaItem(id: id, type: type, title: "Local player fixture", imdbId: "visual-fixture"),
                     seasons: [Season(number: 1, name: "Season 1", episodeCount: 3, posterUrl: nil)])
    }
}

private struct VisualPlayerStreams: StreamRepository {
    let options: [StreamOption]
    func streams(imdbId: String, type: MediaType, season: Int?, episode: Int?) async -> [StreamOption] { options }
    func sortStreams(_ streams: [StreamOption], preferredQuality: String) -> [StreamOption] { streams }
    func autoPick(_ streams: [StreamOption], preferredQuality: String, previousBingeGroup: String?) -> StreamOption? { streams.first }
    func probeStreams(_ streams: [StreamOption], limit: Int) async -> [StreamOption] {
        XCTFail("Visual fixture must not perform startup probes")
        return streams
    }
}

@MainActor private final class VisualPickerState: ObservableObject {
    let streams: [StreamOption]
    @Published var allBlocked = false
    @Published var presented = false
    @Published var didOpenOptions = false
    init(streams: [StreamOption]) { self.streams = streams }
}

private struct VisualPickerHost: View {
    @ObservedObject var state: VisualPickerState
    var body: some View {
        Color.black.ignoresSafeArea()
            .sheet(isPresented: $state.presented) {
                StreamPickerSheet(streams: state.allBlocked ? [] : Array(state.streams.dropFirst()),
                    currentUrl: state.streams[1].url, blockedGroupsPresent: true,
                    onOpenPlaybackOptions: { state.didOpenOptions = true },
                    onPick: { _ in })
            }
    }
}

private struct VisualOptionsHost: View {
    @ObservedObject var model: PlayerViewModel
    @State private var presented = false
    var body: some View {
        Color.black.ignoresSafeArea()
            .sheet(isPresented: $presented) { PlaybackOptionsSheet(vm: model) }
            .task { presented = true }
    }
}

/// Component screenshots rendered by the simulator's UIKit/SwiftUI stack.
/// All media and metadata are fixtures, settings use a disposable suite, and
/// history is an in-memory store. No production AppContainer is constructed.
@MainActor final class PlayerControlsVisualTests: XCTestCase {
    private var window: UIWindow?
    private var scene: UIWindowScene?
    private var originalKeyWindow: UIWindow?
    private var originalOrientation: UIInterfaceOrientation = .portrait
    private var orientationToken: UUID?
    private var model: PlayerViewModel?
    private var suite: String?
    private var ownsAudioSession = false

    override func setUp() async throws {
        continueAfterFailure = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        self.scene = scene
        originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        originalOrientation = scene.interfaceOrientation
        orientationToken = OrientationLock.beginPlayback(in: scene)
        let window = UIWindow(windowScene: scene)
        self.window = window
    }

    override func tearDown() async throws {
        model?.teardown()
        model = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            ownsAudioSession = false
        }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        if let scene, let orientationToken {
            OrientationLock.endPlayback(orientationToken, sceneID: scene.session.persistentIdentifier)
            originalKeyWindow?.makeKeyAndVisible()
            originalKeyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            let mask: UIInterfaceOrientationMask = originalOrientation.isLandscape ? .landscape : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        orientationToken = nil
        originalKeyWindow = nil
        scene = nil
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    private func host<Content: View>(_ content: Content) async throws {
        let scene = try XCTUnwrap(scene)
        let window = try XCTUnwrap(window)
        let controller = LandscapeHostingController(rootView: content.preferredColorScheme(.dark))
        controller.followsWindowOrientation = false
        controller.presentationOrientation = .landscapeRight
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        let deadline = Date().addingTimeInterval(5)
        while !(scene.interfaceOrientation.isLandscape && window.bounds.width > window.bounds.height), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(scene.interfaceOrientation.isLandscape, "Capture must use real landscape window geometry")
        XCTAssertGreaterThan(window.bounds.width, window.bounds.height)
        window.layoutIfNeeded()
    }

    private func capture(_ name: String) async throws {
        let window = try XCTUnwrap(window)
        // Allow presentation/layout animations to finish before drawing the
        // actual window, including the system sheet and its clipping bounds.
        try await Task.sleep(nanoseconds: 600_000_000)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(window.bounds.width, window.bounds.height)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func streams(token: String) -> [StreamOption] {
        ["a", "b", "c"].map { source in
            var parts = URLComponents(string: "http://127.0.0.1:18885/stream/\(source)")!
            parts.queryItems = [.init(name: "case", value: token), .init(name: "episode", value: "2")]
            return StreamOption(url: parts.url!, title: "Local.Player.Fixture.S01E02.1080p.WEB-DL.H264-QA\(source.uppercased())",
                                quality: "1080p", sizeBytes: 1_800_000_000, sourceName: "Local generated fixture",
                                bingeGroup: "velvet-QA\(source.uppercased())", headers: [:])
        }
    }

    private func fixtureModel() async throws -> PlayerViewModel {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18885/health")!)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              String(data: data, encoding: .utf8)?.contains("playback-recovery") == true else {
            throw XCTSkip("Run scripts/playback-recovery-fixture.py before the controls capture")
        }
        let token = UUID().uuidString
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        ownsAudioSession = true
        suite = "tv.velvet.tests.visual." + token
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite!)!)
        settings.syncEnabled = false
        settings.syncUrl = "http://127.0.0.1:18885"
        settings.syncToken = ""
        settings.autoplayNext = false
        settings.hardwareDecoding = false
        settings.activeProfileId = "visual-fixture"
        let options = streams(token: token)
        let blocked = try XCTUnwrap(options.first?.releaseGroupForBlocking())
        XCTAssertTrue(settings.blockReleaseGroup(imdbId: "visual-fixture", group: blocked))
        let container = try ModelContainer(for: WatchProgress.self, WatchedEpisode.self, MyListItem.self, Profile.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let playback = PlaybackStore(container: container)
        playback.activeProfileId = { "visual-fixture" }
        let model = PlayerViewModel(target: .init(mediaId: 999996, type: .show, season: 1, episode: 2),
                                    tmdb: VisualPlayerMetadata(), streamRepo: VisualPlayerStreams(options: options),
                                    settings: settings, playback: playback, companion: CompanionApi(settings: settings))
        self.model = model
        return model
    }

    private func waitForPlayback(_ model: PlayerViewModel) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !(model.engine.positionMs > 250 && model.hasPrevious && model.hasNext), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.hasPrevious && model.hasNext)
        XCTAssertGreaterThan(model.engine.positionMs, 250)
        model.pause()
    }

    func testLandscapeIPhonePreviousAndNextControls() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone landscape control layout")
        let model = try await fixtureModel()
        try await host(ZStack {
            Color.black.ignoresSafeArea()
            PlayerVideoSurface(engine: model.engine).ignoresSafeArea()
            PlayerControls(vm: model, onClose: {}, onOpenPlaybackOptions: {},
                           onOpenStreamPicker: {}, onInteraction: {}, onBackgroundTap: {})
        })
        try await waitForPlayback(model)
        try await capture("Player controls — iPhone landscape — Previous and Next")

    }

    func testLandscapeStreamPickerActiveBlockedAndAllBlocked() async throws {
        let state = VisualPickerState(streams: streams(token: UUID().uuidString))
        try await host(VisualPickerHost(state: state))
        state.presented = true
        let deadline = Date().addingTimeInterval(5)
        while window?.rootViewController?.presentedViewController == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(window?.rootViewController?.presentedViewController, "Capture the actual presented source sheet")
        try await capture("Stream picker — active source — format and size only")
        state.allBlocked = true
        try await capture("Stream picker — all blocked — playback options remain reachable")
    }

    func testLandscapePlaybackOptionsRoot() async throws {
        let model = try await fixtureModel()
        // Attach VLC to a real view before presenting the sheet, so track
        // choices reflect the generated clip rather than invented model state.
        try await host(ZStack {
            PlayerVideoSurface(engine: model.engine).ignoresSafeArea()
            Color.clear
        })
        try await waitForPlayback(model)
        try await host(VisualOptionsHost(model: model))
        let deadline = Date().addingTimeInterval(5)
        while window?.rootViewController?.presentedViewController == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(window?.rootViewController?.presentedViewController)
        try await capture("Playback options — audio, subtitles and per-show release controls")
    }
}
