import SwiftUI
import SwiftData

/// Home — "what do I want to watch", instantly. Hero billboard (~62% screen
/// height, rotating through the featured pool) over Continue Watching, My List,
/// and the user-ordered TMDB discovery rows. A touch-first port of the Android
/// ui/home/HomeScreen.kt.
struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: HomeViewModel?

    /// The namespace whose rails are shown. The migrated "default" until a
    /// profile is selected. Drives the .id() below so the profile-scoped @Query
    /// rebuilds the instant the active profile changes.
    private var activeProfileId: String { settings.activeProfileId ?? ProfileStore.defaultId }

    var body: some View {
        ZStack {
            VelvetColors.background.ignoresSafeArea()
            if let viewModel {
                HomeContent(viewModel: viewModel, activeProfileId: activeProfileId)
                    // Rebuild the @Query (and its captured profile predicate) when
                    // the active profile changes — Continue Watching / My List then
                    // show only the new profile's rows.
                    .id(activeProfileId)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if viewModel == nil {
                viewModel = HomeViewModel(
                    tmdb: container.tmdb,
                    settings: container.settings,
                    playback: container.playback,
                    companion: container.companion
                )
            }
        }
        // Spec §2 (reader side): the user is about to LOOK at Continue Watching —
        // pull the cursor-based delta now and tighten the cadence to 20s while
        // Home is the visible surface. No cursor reset, no full reconcile.
        .onAppear {
            container.sync.setHomeVisible(true)
            container.sync.pullNow()
            viewModel?.onHomeAppear()
        }
        .onDisappear { container.sync.setHomeVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                container.sync.setHomeVisible(true)
                container.sync.pullNow()
                viewModel?.onHomeAppear()
            } else {
                container.sync.setHomeVisible(false)
            }
        }
        .onChange(of: activeProfileId) { _, _ in
            // Different profiles have their own discovery filtering and categories.
            viewModel?.refreshHiddenKeys()
            viewModel?.reloadProfileCategories()
        }
    }
}

private struct HomeContent: View {
    @ObservedObject var viewModel: HomeViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var profiles: ProfileStore

    private let activeProfileId: String

    @Query private var progressRows: [WatchProgress]
    @Query private var myListRows: [MyListItem]

    init(viewModel: HomeViewModel, activeProfileId: String) {
        self.viewModel = viewModel
        self.activeProfileId = activeProfileId
        // Profile-scoped, freshest first — only the active profile's rows.
        _progressRows = Query(
            filter: #Predicate<WatchProgress> { $0.profileId == activeProfileId },
            sort: \WatchProgress.updatedAt, order: .reverse)
        _myListRows = Query(
            filter: #Predicate<MyListItem> { $0.profileId == activeProfileId },
            sort: \MyListItem.addedAt, order: .reverse)
    }

    @State private var playTarget: PlayTarget?
    @State private var detailsItem: MediaItem?
    @State private var scrollOffset: CGFloat = 0
    @State private var categoryPrompt = ""
    @State private var showCategoryComposer = false
    @State private var playbackQueue: HomeCategory?
    @State private var queueLoading = false
    @State private var queueError: String?
    @State private var queueLoadTask: Task<Void, Never>?
    @EnvironmentObject private var container: AppContainer

    private static let scrollSpace = "homeScroll"
    /// The wordmark fades out across the first 160pt of scroll (Android parity).
    private static let wordmarkFadeDistance: CGFloat = 160

    // MARK: Derived local rails

    private var continueWatching: [ContinueWatchingEntry] {
        progressRows.compactMap { ContinueWatchingEntry(progress: $0) }
    }

    private var myListItems: [MediaItem] {
        myListRows.compactMap { HomeViewModel.mediaItem(from: $0) }
    }

    /// Live membership for the hero button label — @Query keeps it current the
    /// instant the user toggles, unlike a one-shot store lookup.
    private var heroInMyList: Bool {
        guard let hero = viewModel.hero else { return false }
        return myListRows.contains {
            $0.mediaId == hero.id && $0.typeKey == hero.type.rawValue
        }
    }

    /// Home has literally nothing to show: every TMDB row failed and the local
    /// rails are empty. Friendly retry state instead of a silent blank page.
    private var showUnavailable: Bool {
        viewModel.allRowsFailed && progressRows.isEmpty && myListRows.isEmpty
            && viewModel.halloweenCategory == nil && viewModel.generatedCategories.isEmpty
    }

    private var wordmarkOpacity: Double {
        Double(max(0, min(1, 1 + scrollOffset / Self.wordmarkFadeDistance)))
    }

    // MARK: Body

    var body: some View {
        GeometryReader { proxy in
            let screenHeight = proxy.size.height
                + proxy.safeAreaInsets.top
                + proxy.safeAreaInsets.bottom
            let wideLayout = proxy.size.width >= 600
            // Tablet artwork follows the window's width so portrait browsing
            // still leaves room for the rails below the billboard.
            let heroHeight = wideLayout
                ? min(580, max(380, proxy.size.width * 9 / 16), screenHeight * 0.7)
                : screenHeight * 0.62
            ZStack(alignment: .topLeading) {
                if showUnavailable {
                    HomeUnavailableView { viewModel.retryFailedRows() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            HeroBillboard(
                                hero: viewModel.hero,
                                inMyList: heroInMyList,
                                height: heroHeight,
                                wideLayout: wideLayout,
                                onPlay: {
                                    if let hero = viewModel.hero {
                                        playTarget = viewModel.playTarget(for: hero)
                                    }
                                },
                                onToggleMyList: {
                                    if let hero = viewModel.hero {
                                        viewModel.toggleMyList(hero)
                                    }
                                }
                            )
                            rows
                        }
                        .padding(.bottom, 24)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: HomeScrollOffsetKey.self,
                                    value: g.frame(in: .named(Self.scrollSpace)).minY
                                )
                            }
                        )
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .onPreferenceChange(HomeScrollOffsetKey.self) { scrollOffset = $0 }
                    .refreshable { await viewModel.refresh() }
                    .ignoresSafeArea(edges: .top)
                }
                wordmark
            }
        }
        .navigationDestination(for: MediaItem.self) { item in
            DetailsView(item: item)
        }
        .navigationDestination(item: $detailsItem) { item in
            DetailsView(item: item)
        }
        .sheet(isPresented: $showCategoryComposer) {
            categoryComposer
        }
        .overlay {
            if queueLoading {
                ZStack {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Preparing your playlist…")
                            .font(VelvetFont.body(15, .semibold))
                        Button("Cancel") {
                            queueLoadTask?.cancel()
                            queueLoadTask = nil
                            queueLoading = false
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(28)
                    .background(VelvetColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("Couldn't start this category", isPresented: Binding(
            get: { queueError != nil }, set: { if !$0 { queueError = nil } }
        )) { Button("OK") { queueError = nil } } message: { Text(queueError ?? "") }
        .playerPresenter(item: $playTarget, queue: $playbackQueue)
    }

    /// Top bar — profile avatar (re-opens the picker on tap) + "VELVET" wordmark,
    /// fading together as you scroll. Only the avatar takes hits.
    private var wordmark: some View {
        HStack(spacing: 10) {
            Button {
                // Re-open "Who's watching?" on demand (spec §38) — forces the
                // picker even with a single profile, unlike the launch gate.
                settings.profilePickerRequested = true
            } label: {
                ProfileAvatar(profile: profiles.activeProfile, diameter: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch profile")

            Text("VELVET")
                .font(VelvetFont.display(18, .bold))
                .tracking(5)
                .foregroundStyle(VelvetColors.textPrimary)
                .allowsHitTesting(false)
        }
        .padding(.leading, 16)
        .padding(.top, 8)
        .opacity(wordmarkOpacity)
    }

    // MARK: Rows

    @ViewBuilder
    private var rows: some View {
        if !continueWatching.isEmpty {
            ContinueWatchingRow(
                entries: continueWatching,
                onResume: { playTarget = $0 }
            ) { entry in
                continueWatchingMenu(for: entry)
            }
        }
        if !myListItems.isEmpty {
            HomeRow(title: "My List", style: .poster, state: .loaded(myListItems)) { item in
                myListMenu(for: item)
            }
        }
        if let category = viewModel.halloweenCategory(for: activeProfileId) {
            categoryRow(category)
        } else if PersonalHalloweenCategory.isVisible(profile: activeProfileId), viewModel.halloweenLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading Monstober & Nick Halloween…")
                    .font(VelvetFont.body(13))
            }
            .padding(16)
        }
        ForEach(viewModel.generatedCategories) { category in
            categoryRow(category, removable: true)
        }
        Button {
            viewModel.categoryError = nil
            showCategoryComposer = true
        } label: {
            Label("Make a category", systemImage: "sparkles")
                .font(VelvetFont.body(14, .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(VelvetColors.cardPlaceholder, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        ForEach(viewModel.tmdbRows) { spec in
            HomeRow(
                title: spec.title,
                style: spec.style,
                state: viewModel.rowStates[spec.id] ?? .loading
            ) { item in
                standardMenu(for: item)
            }
        }
    }

    private func categoryRow(_ category: HomeCategory, removable: Bool = false) -> some View {
        HomeCategoryRow(category: category, onPlay: { entry in
            guard viewModel.canPlayCategory(category) else { return }
            playbackQueue = nil
            playTarget = categoryTarget(entry)
        }, onPlayAll: {
            startCategory(category, shuffle: false)
        }, onShuffle: {
            startCategory(category, shuffle: true)
        }) { entry in
            Button {
                guard viewModel.canPlayCategory(category) else { return }
                playTarget = categoryTarget(entry)
            } label: { Label("Play", systemImage: "play.fill") }
            Button { detailsItem = entry.item } label: {
                Label(entry.type == .show ? "Go to show" : "Go to movie", systemImage: "info.circle")
            }
            Button { viewModel.toggleMyList(entry.item) } label: {
                Label(viewModel.isInMyList(entry.item) ? "Remove from My List" : "Add to My List",
                      systemImage: "plus")
            }
            if removable {
                Button(role: .destructive) { viewModel.removeCategory(category.id) } label: {
                    Label("Remove category", systemImage: "trash")
                }
            }
        }
    }

    private func startCategory(_ category: HomeCategory, shuffle: Bool) {
        guard !queueLoading, viewModel.canPlayCategory(category) else { return }
        let profile = settings.activeProfileId
        queueLoading = true
        queueLoadTask = Task { @MainActor in
            defer {
                if !Task.isCancelled { queueLoading = false; queueLoadTask = nil }
            }
            do {
                let queue = try await container.companion.categoryQueue(category, shuffle: shuffle)
                guard !Task.isCancelled, settings.activeProfileId == profile,
                      let first = queue.items.first else { return }
                playbackQueue = queue
                playTarget = first.target
            } catch {
                if !Task.isCancelled { queueError = error.localizedDescription }
            }
        }
    }

    private func categoryTarget(_ entry: HomeCategoryItem) -> PlayTarget {
        entry.season == nil ? viewModel.playTarget(for: entry.item) : entry.target
    }

    private var categoryComposer: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("What are you in the mood for?")
                    .font(VelvetFont.display(23, .semibold))
                Text("Try “Cartoon Network shows,” “Disney Halloween episodes,” or “Star Wars movies in story order.” Years are optional. Type or use your keyboard’s microphone.")
                    .font(VelvetFont.body(15))
                    .foregroundStyle(VelvetColors.textSecondary)
                TextField("Describe your category", text: $categoryPrompt, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(VelvetColors.cardPlaceholder, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(viewModel.isGeneratingCategory)
                if let error = viewModel.categoryError {
                    Text(error).font(VelvetFont.body(14)).foregroundStyle(.orange)
                }
                if viewModel.isGeneratingCategory {
                    HStack { ProgressView(); Text("Building your category…") }
                } else {
                    Button("Create category") { viewModel.createCategory(prompt: categoryPrompt) }
                        .buttonStyle(.borderedProminent)
                        .disabled(categoryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || categoryPrompt.count > 500)
                }
                Spacer()
            }
            .padding(24)
            .background(VelvetColors.background)
            .navigationTitle("Make a category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showCategoryComposer = false } } }
            .onChange(of: viewModel.isGeneratingCategory) { wasGenerating, isGenerating in
                if wasGenerating && !isGenerating && viewModel.categoryError == nil {
                    categoryPrompt = ""
                    showCategoryComposer = false
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Context menus — exact Android long-press action sets

    /// CW show: Resume / Start episode over / Go to show / Remove from Continue
    /// Watching / Clear watch progress / My List toggle. Movie variant drops Clear
    /// and says "Start over" / "Go to movie".
    @ViewBuilder
    private func continueWatchingMenu(for entry: ContinueWatchingEntry) -> some View {
        let item = entry.item
        let isShow = item.type == .show
        Button {
            playTarget = entry.target
        } label: {
            Label("Resume", systemImage: "play.fill")
        }
        Button {
            playTarget = viewModel.startOver(entry)
        } label: {
            Label(isShow ? "Start episode over" : "Start over",
                  systemImage: "arrow.counterclockwise")
        }
        Button {
            detailsItem = item
        } label: {
            Label(isShow ? "Go to show" : "Go to movie", systemImage: "info.circle")
        }
        Button(role: .destructive) {
            viewModel.removeFromContinueWatching(item)
        } label: {
            Label("Remove from Continue Watching", systemImage: "xmark.circle")
        }
        if isShow {
            Button(role: .destructive) {
                viewModel.clearAllProgress(item)
            } label: {
                Label("Clear watch progress", systemImage: "trash")
            }
        }
        myListToggleButton(for: item)
    }

    /// My List rail: Go to details / Play / Remove from My List (destructive).
    @ViewBuilder
    private func myListMenu(for item: MediaItem) -> some View {
        goToDetailsButton(for: item)
        playButton(for: item)
        Button(role: .destructive) {
            viewModel.removeFromMyList(item)
        } label: {
            Label("Remove from My List", systemImage: "trash")
        }
    }

    /// Ordinary row cards: Go to details / Play / My List toggle.
    @ViewBuilder
    private func standardMenu(for item: MediaItem) -> some View {
        goToDetailsButton(for: item)
        playButton(for: item)
        myListToggleButton(for: item)
    }

    private func goToDetailsButton(for item: MediaItem) -> some View {
        Button {
            detailsItem = item
        } label: {
            Label("Go to details", systemImage: "info.circle")
        }
    }

    /// Plain target: shows resolve to the next unwatched episode downstream.
    private func playButton(for item: MediaItem) -> some View {
        Button {
            playTarget = PlayTarget(mediaId: item.id, type: item.type, season: nil, episode: nil)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
    }

    /// Membership is resolved when the menu opens, so the label is final — no flicker.
    @ViewBuilder
    private func myListToggleButton(for item: MediaItem) -> some View {
        if viewModel.isInMyList(item) {
            Button {
                viewModel.toggleMyList(item)
            } label: {
                Label("Remove from My List", systemImage: "minus")
            }
        } else {
            Button {
                viewModel.toggleMyList(item)
            } label: {
                Label("Add to My List", systemImage: "plus")
            }
        }
    }
}

/// Full-screen friendly failure state: every TMDB row failed and there is no
/// local data to fall back on (rule 3: never dead-end).
private struct HomeUnavailableView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Can't reach TMDB right now")
                .font(VelvetFont.display(21, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
            Text("Check your connection, then try again.")
                .font(VelvetFont.body(14))
                .foregroundStyle(VelvetColors.textSecondary)
                .padding(.top, 8)
            Button(action: onRetry) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Retry")
                        .font(VelvetFont.display(15, .semibold))
                }
                .foregroundStyle(VelvetColors.textPrimary)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Capsule().fill(VelvetColors.accentDeep))
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
}

private struct HomeScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
