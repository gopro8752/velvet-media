import SwiftUI
import SwiftData

@main
struct VelvetTVApp: App {
    private let models: ModelContainer
    @StateObject private var container: AppContainer

    init() {
        var inMemory = false
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["VELVET_UI_FIXTURE"],
           let host = URL(string: raw)?.host, ["127.0.0.1", "localhost"].contains(host) { inMemory = true }
        #endif
        let models = try! ModelContainer(for: WatchProgress.self, WatchedEpisode.self,
                                        MyListItem.self, Profile.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        self.models = models
        let container = AppContainer(modelContainer: models)
        #if DEBUG
        // Simulator tests use a loopback fixture, never an author's server or credentials.
        if let raw = ProcessInfo.processInfo.environment["VELVET_UI_FIXTURE"],
           let url = URL(string: raw), ["127.0.0.1", "localhost"].contains(url.host ?? "") {
            container.settings.setBackendUrl(raw)
            container.settings.syncEnabled = false
            container.settings.syncToken = ""
            container.settings.rowOrder = ["popular_now", "trending_shows"]
        }
        #endif
        _container = StateObject(wrappedValue: container)
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(container)
                .environmentObject(container.settings)
                .environmentObject(container.profiles)
                .preferredColorScheme(.dark)
                .tint(VelvetColors.accent)
        }
        .modelContainer(models)
    }
}

struct TVRootView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var profiles: ProfileStore
    @Environment(\.scenePhase) private var phase
    @State private var tab = TVTab.home
    @State private var play: PlayTarget?
    @State private var details: MediaItem?
    @State private var pendingLink: TVDeepLink?
    @State private var handledLaunch = false

    private var needsProfile: Bool {
        settings.profilePickerRequested || (!settings.profileChosenThisLaunch &&
            (settings.activeProfileId == nil || profiles.enabledCount > 1))
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { TVHomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(TVTab.home)
            NavigationStack { TVSearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(TVTab.search)
            NavigationStack { TVLiveTVView() }
                .tabItem { Label("Live TV", systemImage: "tv") }.tag(TVTab.live)
            NavigationStack { TVSportsView() }
                .tabItem { Label("Live Sports", systemImage: "sportscourt") }.tag(TVTab.sports)
            NavigationStack { TVSettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(TVTab.settings)
        }
        .background(VelvetColors.background.ignoresSafeArea())
        .fullScreenCover(isPresented: Binding(get: { needsProfile }, set: { _ in }), onDismiss: drainPendingLink) {
            TVProfilePickerView()
        }
        .fullScreenCover(item: $play) { target in TVPlayerSessionHost(target: target) }
        .fullScreenCover(item: $details) { item in NavigationStack { TVDetailsView(item: item) } }
        .onOpenURL(perform: open)
        .onAppear {
            chooseOnlyProfile()
            container.sync.onAppForegrounded()
            if !handledLaunch {
                handledLaunch = true
                if settings.backendUrl.isEmpty { tab = .settings }
                #if DEBUG
                if let raw = UserDefaults.standard.string(forKey: "VelvetDeepLink"), let url = URL(string: raw) {
                    open(url)
                }
                #endif
            }
        }
        .onChange(of: profiles.enabledCount) { _, _ in chooseOnlyProfile() }
        .onChange(of: phase) { _, value in
            if value == .active { container.sync.onAppForegrounded() }
            else { container.sync.onAppBackgrounded() }
        }
    }

    private func chooseOnlyProfile() {
        guard !settings.profileChosenThisLaunch, !settings.profilePickerRequested,
              profiles.enabledCount == 1, let profile = profiles.profiles.first else { return }
        settings.activeProfileId = profile.id
        settings.profileChosenThisLaunch = true
    }

    private func open(_ url: URL) {
        guard let link = TVDeepLink(url: url) else { return }
        guard !needsProfile else { pendingLink = link; return }
        navigate(link)
    }

    private func drainPendingLink() {
        guard !needsProfile, let link = pendingLink else { return }
        pendingLink = nil
        navigate(link)
    }

    private func navigate(_ link: TVDeepLink) {
        switch link {
        case .tab(let destination): tab = destination
        case .details(let id, let type):
            details = MediaItem(id: id, type: type, title: "", year: nil, posterUrl: nil,
                                backdropUrl: nil, logoUrl: nil, rating: nil, overview: nil,
                                runtimeMinutes: nil, imdbId: nil, rankInRow: nil)
        case .play(let target): play = target
        }
    }
}

enum TVTab: String { case home, search, live, sports, settings }

enum TVDeepLink {
    case tab(TVTab)
    case details(Int, MediaType)
    case play(PlayTarget)

    init?(url: URL) {
        guard url.scheme == "velvet", let host = url.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "tab", let value = parts.first.flatMap(TVTab.init(rawValue:)) {
            self = .tab(value)
            return
        }
        guard parts.count == 2, let type = MediaType(rawValue: parts[0]),
              let id = Int(parts[1]), id > 0 else { return nil }
        if host == "details" { self = .details(id, type); return }
        guard host == "play" else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let season = query.first { $0.name == "s" }?.value.flatMap(Int.init)
        let episode = query.first { $0.name == "e" }?.value.flatMap(Int.init)
        guard season.map({ $0 >= 0 }) ?? true, episode.map({ $0 > 0 }) ?? true else { return nil }
        self = .play(PlayTarget(mediaId: id, type: type, season: season, episode: episode))
    }
}
