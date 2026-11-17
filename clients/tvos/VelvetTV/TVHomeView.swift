import SwiftUI
import SwiftData

struct TVHomeView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm: HomeViewModel?
    private var profileID: String { settings.activeProfileId ?? ProfileStore.defaultId }

    var body: some View {
        ZStack {
            VelvetColors.background.ignoresSafeArea()
            if let vm { TVHomeContent(vm: vm, profileID: profileID).id(profileID) }
            else { ProgressView().tint(VelvetColors.accent) }
        }
        .task(id: TVServiceConfiguration(settings)) {
            vm = HomeViewModel(tmdb: container.tmdb, settings: settings,
                               playback: container.playback, companion: container.companion)
        }
        .onAppear {
            container.sync.setHomeVisible(true)
            container.sync.pullNow()
            vm?.onHomeAppear()
        }
        .onDisappear { container.sync.setHomeVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            container.sync.setHomeVisible(phase == .active)
            if phase == .active { container.sync.pullNow(); vm?.onHomeAppear() }
        }
        .onChange(of: profileID) { _, _ in vm?.refreshHiddenKeys(); vm?.reloadProfileCategories() }
    }
}

private struct TVHomeContent: View {
    @ObservedObject var vm: HomeViewModel
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore
    @Query private var progressRows: [WatchProgress]
    @Query private var listRows: [MyListItem]
    @State private var presentation: TVPlaybackPresentation?
    @State private var detailsItem: MediaItem?
    @State private var showComposer = false
    @State private var deleteCategory: HomeCategory?
    @State private var queueTask: Task<Void, Never>?
    @State private var queueLoading = false
    @State private var queueError: String?

    init(vm: HomeViewModel, profileID: String) {
        self.vm = vm
        _progressRows = Query(filter: #Predicate<WatchProgress> { $0.profileId == profileID },
                              sort: \WatchProgress.updatedAt, order: .reverse)
        _listRows = Query(filter: #Predicate<MyListItem> { $0.profileId == profileID },
                          sort: \MyListItem.addedAt, order: .reverse)
    }
    private var continuing: [ContinueWatchingEntry] { progressRows.compactMap(ContinueWatchingEntry.init) }
    private var list: [MediaItem] { listRows.compactMap(HomeViewModel.mediaItem) }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 34) {
                if !vm.allRowsFailed || !continuing.isEmpty || !list.isEmpty || !vm.generatedCategories.isEmpty {
                    hero
                }
                if !continuing.isEmpty { continueRail }
                if !list.isEmpty { mediaRail("My List", items: list) }
                ForEach(vm.generatedCategories) { category in categoryRail(category) }
                ForEach(vm.tmdbRows) { row in
                    if case let .loaded(items) = vm.rowStates[row.id], !items.isEmpty {
                        mediaRail(row.title, items: items, landscape: row.style == .landscape)
                    }
                }
                if vm.allRowsFailed {
                    VStack(spacing: 22) {
                        TVEmptyState(symbol: "wifi.exclamationmark", title: "The catalog couldn't load",
                                     message: "Check your backend connection in Settings, then try again.")
                        Button("Try again") { vm.retryFailedRows() }.buttonStyle(TVGlassButtonStyle())
                    }.frame(height: 330).padding(.horizontal, TVLayout.edge)
                }
            }
            .padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .navigationDestination(for: MediaItem.self) { TVDetailsView(item: $0) }
        .navigationDestination(item: $detailsItem) { TVDetailsView(item: $0) }
        .fullScreenCover(item: $presentation) { entry in
            TVPlayerSessionHost(target: entry.target, queue: entry.queue)
        }
        .sheet(isPresented: $showComposer) { TVCreateCategoryView(vm: vm) }
        .confirmationDialog("Delete this category?", isPresented: Binding(
            get: { deleteCategory != nil }, set: { if !$0 { deleteCategory = nil } }
        ), titleVisibility: .visible) {
            Button("Delete category", role: .destructive) {
                if let category = deleteCategory { vm.removeCategory(category.id) }
                deleteCategory = nil
            }
            Button("Cancel", role: .cancel) { deleteCategory = nil }
        } message: { Text("This removes the category from your profile.") }
        .alert("Couldn't start this category", isPresented: Binding(
            get: { queueError != nil }, set: { if !$0 { queueError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(queueError ?? "") }
        .overlay { if queueLoading { queueOverlay } }
        .onDisappear { queueTask?.cancel(); queueTask = nil; queueLoading = false }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            TVBackdrop(url: vm.hero?.backdropUrl)
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("VELVET").font(VelvetFont.display(24, .semibold)).tracking(7)
                        .foregroundStyle(.white.opacity(0.84))
                    Spacer()
                    Button { showComposer = true } label: {
                        Label("Create category", systemImage: "plus")
                    }.buttonStyle(TVGlassButtonStyle()).accessibilityIdentifier("home.createCategory")
                }.focusSection()
                Spacer(minLength: 28)
                if let item = vm.hero {
                    TVTitleArtwork(item: item, height: 120)
                    TVMediaMetadata(item: item)
                    if let overview = item.overview {
                        Text(overview).font(VelvetFont.body(24))
                            .foregroundStyle(VelvetColors.textPrimary.opacity(0.88))
                            .lineLimit(2).frame(maxWidth: 840, alignment: .leading)
                    }
                    HStack(spacing: 22) {
                        Button { presentation = TVPlaybackPresentation(target: vm.playTarget(for: item)) } label: {
                            Label("Play", systemImage: "play.fill")
                        }.buttonStyle(TVGlassButtonStyle(prominent: true))
                        NavigationLink(value: item) { Label("Details", systemImage: "info.circle") }
                            .buttonStyle(TVGlassButtonStyle()).accessibilityIdentifier("home.heroDetails")
                        Button { vm.toggleMyList(item) } label: {
                            Label(heroSaved(item) ? "In My List" : "My List", systemImage: heroSaved(item) ? "checkmark" : "plus")
                        }.buttonStyle(TVGlassButtonStyle())
                    }.padding(.top, 3)
                } else {
                    Text("A world worth watching.").font(VelvetFont.display(55, .semibold))
                    Text("Your favorites, together.").font(VelvetFont.body(27)).foregroundStyle(VelvetColors.textSecondary)
                }
            }
            .padding(.horizontal, TVLayout.edge)
            .padding(.top, 16).padding(.bottom, 32)
        }
        .frame(height: 640)
    }

    private func heroSaved(_ item: MediaItem) -> Bool {
        listRows.contains { $0.mediaId == item.id && $0.typeKey == item.type.rawValue }
    }

    private var continueRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSectionHeader(title: "Continue Watching").padding(.horizontal, TVLayout.edge)
            ScrollView(.horizontal) {
                HStack(spacing: TVLayout.railGap) {
                    ForEach(continuing) { entry in
                        Button { presentation = TVPlaybackPresentation(target: entry.target) } label: {
                            TVMediaCard(item: entry.item, landscape: true, subtitle: entry.label, progress: entry.progressFraction)
                        }
                        .buttonStyle(TVCardButtonStyle())
                        .contextMenu {
                            Button("Details", systemImage: "info.circle") { detailsItem = entry.item }
                            Button("Start over", systemImage: "arrow.counterclockwise") {
                                presentation = TVPlaybackPresentation(target: vm.startOver(entry))
                            }
                            Button("Remove from Continue Watching", systemImage: "xmark", role: .destructive) {
                                vm.removeFromContinueWatching(entry.item)
                            }
                        }
                    }
                }.padding(.horizontal, TVLayout.edge - 9).padding(.vertical, 20)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }.focusSection()
    }

    private func mediaRail(_ title: String, items: [MediaItem], landscape: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TVSectionHeader(title: title).padding(.horizontal, TVLayout.edge)
            ScrollView(.horizontal) {
                HStack(spacing: TVLayout.railGap) {
                    ForEach(items, id: \.self) { item in
                        NavigationLink(value: item) { TVMediaCard(item: item, landscape: landscape) }
                            .buttonStyle(TVCardButtonStyle())
                            .accessibilityIdentifier("home.card.\(item.type.rawValue).\(item.id)")
                            .contextMenu {
                                Button("Play", systemImage: "play.fill") {
                                    presentation = TVPlaybackPresentation(target: vm.playTarget(for: item))
                                }
                                Button(vm.isInMyList(item) ? "Remove from My List" : "Add to My List", systemImage: "plus") {
                                    vm.toggleMyList(item)
                                }
                            }
                    }
                }.padding(.horizontal, TVLayout.edge - 9).padding(.vertical, 20)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }.focusSection()
    }

    private func categoryRail(_ category: HomeCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 22) {
                TVSectionHeader(title: category.title)
                Spacer()
                Button { start(category, shuffle: false) } label: { Label("Play all", systemImage: "play.fill") }
                    .buttonStyle(TVGlassButtonStyle())
                Button { start(category, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(TVGlassButtonStyle())
                Button { deleteCategory = category } label: { Image(systemName: "trash") }
                    .buttonStyle(TVGlassButtonStyle()).accessibilityLabel("Delete \(category.title)")
            }.padding(.horizontal, TVLayout.edge).focusSection()
            ScrollView(.horizontal) {
                HStack(spacing: TVLayout.railGap) {
                    ForEach(category.items) { entry in
                        Button {
                            presentation = TVPlaybackPresentation(target: entry.season == nil ? vm.playTarget(for: entry.item) : entry.target)
                        } label: {
                            TVMediaCard(item: categoryArtwork(entry), landscape: true,
                                        subtitle: entry.episodeLabel ?? entry.year)
                        }.buttonStyle(TVCardButtonStyle())
                        .contextMenu {
                            Button("Details", systemImage: "info.circle") { detailsItem = entry.item }
                            Button(vm.isInMyList(entry.item) ? "Remove from My List" : "Add to My List", systemImage: "plus") {
                                vm.toggleMyList(entry.item)
                            }
                        }
                    }
                }.padding(.horizontal, TVLayout.edge - 9).padding(.vertical, 20)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }.focusSection()
    }

    private func categoryArtwork(_ entry: HomeCategoryItem) -> MediaItem {
        var item = entry.item
        item.backdropUrl = entry.stillUrl ?? entry.backdropUrl
        return item
    }

    private var queueOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 28) {
                ProgressView().controlSize(.large)
                Text("Preparing your playlist…").font(VelvetFont.display(32))
                Button("Cancel") { queueTask?.cancel(); queueTask = nil; queueLoading = false }
                    .buttonStyle(TVGlassButtonStyle())
            }.padding(60).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 36))
        }
    }

    private func start(_ category: HomeCategory, shuffle: Bool) {
        guard !queueLoading, vm.canPlayCategory(category) else { return }
        let profile = settings.activeProfileId
        queueLoading = true
        queueTask = Task { @MainActor in
            defer { if !Task.isCancelled { queueLoading = false; queueTask = nil } }
            do {
                let queue = try await container.companion.categoryQueue(category, shuffle: shuffle)
                guard !Task.isCancelled, settings.activeProfileId == profile else { return }
                guard let first = queue.items.first else { queueError = "No playable items were found in this category."; return }
                presentation = TVPlaybackPresentation(target: first.target, queue: queue)
            } catch {
                if !Task.isCancelled { queueError = error.localizedDescription }
            }
        }
    }
}
