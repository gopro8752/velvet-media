import SwiftUI
import SwiftData

/// Details screen — touch port of the Android DetailsScreen.kt.
/// Pushed via .navigationDestination(for: MediaItem.self) (declared by each
/// tab's NavigationStack). Thin wrapper so the inner view can build its
/// @StateObject VM and @Query predicates from init parameters.
struct DetailsView: View {
    let item: MediaItem
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore

    private var activeProfileId: String { settings.activeProfileId ?? ProfileStore.defaultId }

    var body: some View {
        DetailsScreenView(item: item, container: container, activeProfileId: activeProfileId)
            // Rebuild the profile-scoped @Query when the active profile changes
            // so checkmarks / the Resume label reflect the active profile only.
            .id(activeProfileId)
    }
}

@MainActor
private struct DetailsScreenView: View {
    @StateObject private var vm: DetailsViewModel
    @Environment(\.dismiss) private var dismiss

    // Live SwiftData state — the player and every context-menu action write
    // through PlaybackStore (same main context), so checkmarks, the in-progress
    // underline, and the Play/Resume label all refresh on their own.
    @Query private var progressRows: [WatchProgress]
    @Query private var watchedRows: [WatchedEpisode]
    @Query private var myListRows: [MyListItem]

    @State private var playTarget: PlayTarget?
    /// Context-menu "Details" pushes (card taps use NavigationLink directly).
    @State private var pushedItem: MediaItem?

    init(item: MediaItem, container: AppContainer, activeProfileId: String) {
        _vm = StateObject(wrappedValue: DetailsViewModel(
            item: item, tmdb: container.tmdb, playback: container.playback,
            streams: container.streams, settings: container.settings))
        let mediaId = item.id
        let typeKey = item.type.rawValue
        let pid = activeProfileId
        _progressRows = Query(filter: #Predicate<WatchProgress> {
            $0.mediaId == mediaId && $0.typeKey == typeKey && $0.profileId == pid
        })
        _watchedRows = Query(filter: #Predicate<WatchedEpisode> {
            $0.mediaId == mediaId && $0.profileId == pid
        })
        _myListRows = Query(filter: #Predicate<MyListItem> {
            $0.mediaId == mediaId && $0.typeKey == typeKey && $0.profileId == pid
        })
    }

    // MARK: - derived live state

    private var progress: WatchProgress? { progressRows.first }

    private var watchedSet: Set<DetailsViewModel.EpisodeKey> {
        Set(watchedRows.map { DetailsViewModel.EpisodeKey(season: $0.season, episode: $0.episode) })
    }

    private var inMyList: Bool { !myListRows.isEmpty }

    // MARK: - body

    var body: some View {
        ZStack {
            VelvetColors.background.ignoresSafeArea()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await vm.loadIfNeeded() }
        .playerPresenter(item: $playTarget)
        .navigationDestination(item: $pushedItem) { pushed in
            DetailsView(item: pushed)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading {
            ProgressView()
                .controlSize(.large)
                .tint(VelvetColors.accent)
        } else if let message = vm.errorMessage {
            DetailsErrorView(
                message: message,
                onRetry: { Task { await vm.load() } },
                onBack: { dismiss() }
            )
        } else if let details = vm.details {
            loadedContent(details)
        }
    }

    private func loadedContent(_ details: MediaDetails) -> some View {
        let play = DetailsViewModel.resolvePlayState(
            details: details, progress: progress, watched: watchedSet)
        return GeometryReader { geometry in
            let contentWidth = min(geometry.size.width, 1100)
            let expanded = geometry.size.width >= 600
            let heroHeight: CGFloat = expanded
                ? min(480, max(340, geometry.size.width * 0.45), max(300, geometry.size.height * 0.65))
                : 340
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailsHeaderView(details: details, height: heroHeight,
                                      contentWidth: contentWidth, expanded: expanded,
                                      topInset: geometry.safeAreaInsets.top)

                    VStack(alignment: .leading, spacing: 0) {
                        actionButtons(play)
                            .padding(.top, 14)

                        if let overview = details.item.overview, !overview.isEmpty {
                            Text(overview)
                                .font(VelvetFont.body(expanded ? 15 : 13))
                                .foregroundStyle(VelvetColors.textSecondary)
                                .lineLimit(expanded ? 4 : 3)
                                .frame(maxWidth: 760, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                        }

                        if details.item.type == .show,
                           details.seasons.contains(where: { $0.number >= 1 }) {
                            seasonsSection(details, twoColumns: contentWidth >= 960)
                        }

                        if !details.cast.isEmpty {
                            DetailsCastRow(cast: details.cast)
                                .padding(.top, 28)
                        }

                        if !details.similar.isEmpty {
                            similarSection(details)
                                .padding(.top, 28)
                        }
                    }
                    .frame(maxWidth: contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            // Extend the artwork, while the header reserves this reader's
            // original safe area for its title and metadata.
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - action buttons

    private func actionButtons(_ play: DetailsViewModel.PlayState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    playTarget = play.target
                } label: {
                    Label(play.label, systemImage: "play.fill")
                }
                .buttonStyle(DetailsActionButtonStyle(prominent: true))

                Button {
                    vm.toggleMyList()
                } label: {
                    Label(inMyList ? "In List" : "My List",
                          systemImage: inMyList ? "checkmark" : "plus")
                }
                .buttonStyle(DetailsActionButtonStyle())

                if play.showStartOver {
                    Button {
                        playTarget = vm.startOverTarget()
                    } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(DetailsActionButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - seasons + episodes

    @ViewBuilder
    private func seasonsSection(_ details: MediaDetails, twoColumns: Bool) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: twoColumns ? 2 : 1)
        DetailsSeasonChips(
            seasons: details.seasons.filter { $0.number >= 1 },
            selectedSeason: vm.selectedSeason,
            onSelect: { vm.selectSeason($0) },
            onMarkSeasonWatched: { vm.markSeasonWatched($0.number) },
            onClearSeasonHistory: { vm.clearSeasonHistory($0.number) }
        )
        .padding(.top, 22)

        if vm.episodesLoading {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<4, id: \.self) { _ in
                    DetailsEpisodePlaceholder()
                }
            }
            .padding(.top, 12)
        } else if vm.episodes.isEmpty, vm.selectedSeason != nil {
            Text("No episodes found for this season.")
                .font(VelvetFont.body(13))
                .foregroundStyle(VelvetColors.textTertiary)
                .padding(.horizontal, 16)
                .padding(.top, 18)
        } else {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(vm.episodes, id: \.self) { episode in
                    episodeRow(episode, details: details)
                }
            }
            .padding(.top, 12)
        }
    }

    private func episodeRow(_ episode: Episode, details: MediaDetails) -> some View {
        let watched = watchedSet.contains(
            DetailsViewModel.EpisodeKey(season: episode.season, episode: episode.number))
        let isInProgress: Bool = {
            guard let p = progress, let s = p.season, let e = p.episode else { return false }
            return s == episode.season && e == episode.number
        }()
        let target = PlayTarget(
            mediaId: details.item.id, type: .show,
            season: episode.season, episode: episode.number)

        return Button {
            playTarget = target
        } label: {
            DetailsEpisodeRow(
                episode: episode,
                watched: watched,
                progressFraction: progressFraction(for: episode)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                playTarget = target
            } label: {
                Label("Play this episode", systemImage: "play.fill")
            }

            if watched {
                Button {
                    vm.unmarkEpisodeWatched(episode)
                } label: {
                    Label("Mark unwatched", systemImage: "minus.circle")
                }
            } else {
                Button {
                    vm.markEpisodeWatched(episode)
                } label: {
                    Label("Mark watched", systemImage: "checkmark.circle")
                }
            }

            Button {
                vm.markWatchedUpTo(episode)
            } label: {
                Label("Mark all up to here watched", systemImage: "text.badge.checkmark")
            }

            // Only the episode that owns the saved resume position can clear it.
            if isInProgress {
                Button(role: .destructive) {
                    vm.clearEpisodeProgress()
                } label: {
                    Label("Clear episode progress", systemImage: "trash")
                }
            }
        }
    }

    /// Green partial-progress underline fraction for the in-progress episode.
    private func progressFraction(for episode: Episode) -> Double? {
        guard let p = progress,
              p.season == episode.season, p.episode == episode.number,
              p.durationMs > 0, p.positionMs > 0 else { return nil }
        return min(max(Double(p.positionMs) / Double(p.durationMs), 0), 1)
    }

    // MARK: - more like this

    private func similarSection(_ details: MediaDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RowHeader(title: "More Like This")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(details.similar) { similar in
                        NavigationLink(value: similar) {
                            PosterCard(item: similar)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                pushedItem = similar
                            } label: {
                                // "Go to details" — matches Android's similar-card
                                // sheet and the Home menus.
                                Label("Go to details", systemImage: "info.circle")
                            }
                            Button {
                                // No season/episode: the player resolves next
                                // unwatched / S1 E1.
                                playTarget = PlayTarget(
                                    mediaId: similar.id, type: similar.type,
                                    season: nil, episode: nil)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            if vm.isInMyList(similar) {
                                Button {
                                    vm.toggleMyList(for: similar)
                                } label: {
                                    Label("Remove from My List", systemImage: "minus.circle")
                                }
                            } else {
                                Button {
                                    vm.toggleMyList(for: similar)
                                } label: {
                                    Label("Add to My List", systemImage: "plus.circle")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
