import SwiftUI
import SwiftData

/// Dependency container, injected through the environment. Mirrors the Android
/// AppContainer: one instance per app, created in VelvetApp.
@MainActor
final class AppContainer: ObservableObject {
    let settings: SettingsStore
    let tmdb: TmdbRepository
    let streams: StreamRepository
    let playback: PlaybackStore
    let profiles: ProfileStore
    let sync: SyncEngine
    let companion: CompanionApi
    let liveTV: LiveTVClient
    let liveSports: LiveSportsClient

    init(modelContainer: ModelContainer) {
        let settings = SettingsStore()
        self.settings = settings
        self.tmdb = TmdbClient(settings: settings)
        self.streams = StreamClient(settings: settings)
        // Skip-intro + throw-to-TV endpoints on the sync server; inert while
        // sync is off, so it needs no wiring beyond the settings it reads.
        self.companion = CompanionApi(settings: settings)
        self.liveTV = LiveTVClient {
            let source = settings.streamSources.first { $0.enabled }?.baseUrl ?? settings.syncUrl
            return LiveConnection(baseUrl: SettingsStore.normalizeBaseUrl(source),
                                  syncUrl: SettingsStore.normalizeBaseUrl(settings.syncUrl),
                                  token: settings.syncToken)
        }
        self.liveSports = LiveSportsClient {
            let source = settings.streamSources.first { $0.enabled }?.baseUrl ?? settings.syncUrl
            return LiveConnection(baseUrl: SettingsStore.normalizeBaseUrl(source),
                                  syncUrl: SettingsStore.normalizeBaseUrl(settings.syncUrl), token: settings.syncToken)
        }
        let playback = PlaybackStore(container: modelContainer)
        self.playback = playback
        // The active profile flows into every PlaybackStore query/mutation here;
        // switching profiles is a pure re-filter (activeProfileId is read at call
        // time). Falls back to the migrated "default" namespace until selected.
        playback.activeProfileId = { [weak settings] in
            settings?.activeProfileId ?? ProfileStore.defaultId
        }
        let profiles = ProfileStore(container: modelContainer, settings: settings)
        self.profiles = profiles
        let sync = SyncEngine(playback: playback, settings: settings)
        self.sync = sync
        // Wired after construction — the stores hold the engine weakly, so no
        // init needs another to exist first (no init cycle).
        playback.syncEngine = sync
        profiles.syncEngine = sync
        sync.profileStore = profiles
        // First-run: ensure the {id:"default", name:"Me"} profile exists and the
        // active profile is set. Existing watch rows are already tagged "default".
        profiles.ensureFirstRun()
    }
}

@main
struct VelvetApp: App {
    /// iPad browsing follows rotation; iPhone browsing stays portrait. The
    /// player temporarily requests landscape in its own window scene.
    @UIApplicationDelegateAdaptor(VelvetAppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer
    @StateObject private var container: AppContainer

    init() {
        let mc = try! ModelContainer(
            for: WatchProgress.self, WatchedEpisode.self, MyListItem.self, Profile.self)
        modelContainer = mc
        _container = StateObject(wrappedValue: AppContainer(modelContainer: mc))
    }

    var body: some Scene {
        WindowGroup {
            RootGate()
                .environmentObject(container)
                .environmentObject(container.settings)
                .environmentObject(container.profiles)
                .preferredColorScheme(.dark)
                .tint(VelvetColors.accent)
        }
        .modelContainer(modelContainer)
    }
}

/// Root gate: shows the "Who's watching?" picker over the tabs when the gating
/// rule fires, otherwise the tabs directly. Gating rule (spec §33):
/// picker shows when `!profileChosenThisLaunch && (activeProfileId == nil ||
/// enabledProfileCount >= 2)`. Exactly one profile already chosen → straight to
/// Home (auto-select). The picker is a fullScreenCover so it fully owns the
/// screen with no tab chrome leaking.
struct RootGate: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var profiles: ProfileStore

    /// True when the picker should be presented. The launch gating rule (spec
    /// §33), OR an explicit on-demand request from the Home avatar (which must
    /// work even with a single profile).
    private var shouldShowPicker: Bool {
        if settings.profilePickerRequested { return true }
        guard !settings.profileChosenThisLaunch else { return false }
        return settings.activeProfileId == nil || profiles.enabledCount >= 2
    }

    var body: some View {
        RootTabs()
            .fullScreenCover(isPresented: Binding(
                get: { shouldShowPicker },
                set: { _ in }   // dismissal is driven by selecting a profile
            )) {
                ProfilePickerView()
                    .environmentObject(container)
                    .environmentObject(settings)
                    .environmentObject(profiles)
                    .preferredColorScheme(.dark)
            }
            // Auto-select the lone profile deterministically: on the cold-launch
            // appear AND whenever the live count settles to exactly one while none
            // has been chosen this launch (e.g. a second profile was deleted while
            // running). Not dependent on a one-shot onAppear firing.
            .onAppear { autoSelectSingleProfile() }
            .onChange(of: profiles.enabledCount) { _, _ in autoSelectSingleProfile() }
    }

    /// Exactly one profile and not yet chosen → auto-select it and go straight to
    /// Home (the picker never appears in this case). Idempotent and safe to call
    /// from both onAppear and onChange.
    private func autoSelectSingleProfile() {
        guard !settings.profileChosenThisLaunch,
              !settings.profilePickerRequested,
              settings.activeProfileId != nil,
              profiles.enabledCount == 1,
              let only = profiles.profiles.first else { return }
        settings.activeProfileId = only.id
        settings.profileChosenThisLaunch = true
    }
}

/// Bottom tabs: Home, Search, Live TV, Live Sports, Settings. Each owns a NavigationStack;
/// the player presents as a full-screen cover ABOVE everything (PlayerPresenter).
/// Quick-open deep links: velvet://tab/{home|search|settings},
/// velvet://details/{movie|show}/{tmdbId}, velvet://play/{movie|show}/{tmdbId}?s=1&e=2
struct RootTabs: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var deepLinkPlay: PlayTarget?
    @State private var deepLinkDetails: MediaItem?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "play.house.fill") }
                .tag(0)
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)
            NavigationStack { LiveTVView() }
                .tabItem { Label("Live TV", systemImage: "tv.fill") }
                .tag(3)
            NavigationStack { LiveSportsView() }
                .tabItem { Label("Live Sports", systemImage: "sportscourt.fill") }
                .tag(4)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .background(VelvetColors.background)
        .onOpenURL { handle($0) }
        .onAppear {
            // Launch-argument deep link (-VelvetDeepLink velvet://…) — same handling
            // as onOpenURL, used by automated testing where simctl openurl would
            // hit the "Open in Velvet?" confirmation.
            if let raw = UserDefaults.standard.string(forKey: "VelvetDeepLink"),
               let url = URL(string: raw) {
                handle(url)
            }
            // Launch sync (pull + start the 60s ticker). scenePhase may report
            // .active without a change event on cold launch, so hook both;
            // onAppForegrounded is idempotent.
            container.sync.onAppForegrounded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                container.sync.onAppForegrounded()
            } else {
                container.sync.onAppBackgrounded()
            }
        }
        .sheet(item: $deepLinkDetails) { item in
            NavigationStack { DetailsView(item: item) }
                .environmentObject(container)
                .environmentObject(container.settings)
                .preferredColorScheme(.dark)
        }
        .playerPresenter(item: $deepLinkPlay)
    }

    private func handle(_ url: URL) {
        guard url.scheme == "velvet" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "tab":
            switch parts.first {
            case "search": selectedTab = 1
            case "live": selectedTab = 3
            case "sports": selectedTab = 4
            case "settings": selectedTab = 2
            default: selectedTab = 0
            }
        case "details", "play":
            guard parts.count >= 2, let id = Int(parts[1]),
                  let type = MediaType(rawValue: parts[0]) else { return }
            if url.host() == "details" {
                deepLinkDetails = MediaItem(
                    id: id, type: type, title: "", year: nil, posterUrl: nil,
                    backdropUrl: nil, logoUrl: nil, rating: nil, overview: nil,
                    runtimeMinutes: nil, imdbId: nil, rankInRow: nil)
            } else {
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let s = comps?.queryItems?.first(where: { $0.name == "s" })?.value.flatMap(Int.init)
                let e = comps?.queryItems?.first(where: { $0.name == "e" })?.value.flatMap(Int.init)
                deepLinkPlay = PlayTarget(mediaId: id, type: type, season: s, episode: e)
            }
        default:
            break
        }
    }
}
