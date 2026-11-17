import SwiftUI
import SwiftData

struct TVDetailsView: View {
    let item: MediaItem
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TVDetailsContent(item: item, container: container,
                         profileID: settings.activeProfileId ?? ProfileStore.defaultId)
            .id("\(item.type.rawValue):\(item.id):\(settings.activeProfileId ?? ProfileStore.defaultId)")
    }
}

private struct TVDetailsContent: View {
    @StateObject private var vm: DetailsViewModel
    @Query private var progressRows: [WatchProgress]
    @Query private var watchedRows: [WatchedEpisode]
    @Query private var listRows: [MyListItem]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedDescription = false
    @State private var presentation: TVPlaybackPresentation?

    init(item: MediaItem, container: AppContainer, profileID: String) {
        _vm = StateObject(wrappedValue: DetailsViewModel(item: item, tmdb: container.tmdb,
            playback: container.playback, streams: container.streams, settings: container.settings))
        let mediaID = item.id
        let type = item.type.rawValue
        _progressRows = Query(filter: #Predicate<WatchProgress> {
            $0.mediaId == mediaID && $0.typeKey == type && $0.profileId == profileID
        })
        _watchedRows = Query(filter: #Predicate<WatchedEpisode> {
            $0.mediaId == mediaID && $0.profileId == profileID
        })
        _listRows = Query(filter: #Predicate<MyListItem> {
            $0.mediaId == mediaID && $0.typeKey == type && $0.profileId == profileID
        })
    }

    private var watched: Set<DetailsViewModel.EpisodeKey> {
        Set(watchedRows.map { DetailsViewModel.EpisodeKey(season: $0.season, episode: $0.episode) })
    }

    var body: some View {
        ZStack {
            VelvetColors.background.ignoresSafeArea()
            if let details = vm.details { loaded(details) }
            else if let error = vm.errorMessage {
                VStack(spacing: 30) {
                    TVEmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load this title", message: error)
                        .frame(height: 320)
                    HStack(spacing: 25) {
                        Button("Try again") { Task { await vm.load() } }.buttonStyle(TVGlassButtonStyle(prominent: true))
                        Button("Back") { dismiss() }.buttonStyle(TVGlassButtonStyle())
                    }
                }
            } else { ProgressView().controlSize(.large).tint(VelvetColors.accent) }
        }
        .toolbar(.hidden, for: .tabBar)
        .task { await vm.loadIfNeeded() }
        .navigationDestination(for: MediaItem.self) { TVDetailsView(item: $0) }
        .fullScreenCover(item: $presentation) { TVPlayerSessionHost(target: $0.target, queue: $0.queue) }
    }

    private func loaded(_ details: MediaDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 42) {
                header(details)
                if details.item.type == .show && !details.seasons.isEmpty { episodes(details) }
                if !details.cast.isEmpty { cast(details.cast) }
                if !details.similar.isEmpty { similar(details.similar) }
            }.padding(.bottom, 130)
        }
        .scrollIndicators(.hidden).scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
    }

    private func header(_ details: MediaDetails) -> some View {
        let play = DetailsViewModel.resolvePlayState(details: details, progress: progressRows.first, watched: watched)
        return VStack(alignment: .leading, spacing: 26) {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(TVGlassButtonStyle()).accessibilityIdentifier("details.back")
            Spacer().frame(height: 24)
            TVTitleArtwork(item: details.item, width: 680, height: 155)
            TVMediaMetadata(item: details.item,
                            extra: [details.certification, DetailsFormat.seasonCount(details.seasons)].compactMap { $0 }.joined(separator: " · "))
            if !details.item.genres.isEmpty {
                Text(details.item.genres.prefix(3).joined(separator: " · "))
                    .font(VelvetFont.body(22)).foregroundStyle(VelvetColors.textSecondary)
            }
            if let description = details.item.overview, !description.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expandedDescription.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(description).font(VelvetFont.body(25)).lineSpacing(5)
                            .foregroundStyle(VelvetColors.textPrimary.opacity(0.92))
                            .lineLimit(expandedDescription ? nil : 5)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(expandedDescription ? "Show less" : "Read more", systemImage: expandedDescription ? "chevron.up" : "chevron.down")
                            .font(VelvetFont.body(18, .semibold)).foregroundStyle(VelvetColors.textSecondary)
                    }.frame(maxWidth: 920, alignment: .leading)
                }
                .buttonStyle(TVCardButtonStyle())
                .padding(.leading, -9)
                .accessibilityLabel(description)
                .accessibilityHint(expandedDescription ? "Select to collapse description" : "Select to read full description")
                .accessibilityIdentifier("details.description")
                .accessibilityValue(expandedDescription ? "Expanded" : "Collapsed")
            }
            HStack(spacing: 24) {
                if details.digitallyAvailable {
                    Button { presentation = TVPlaybackPresentation(target: play.target) } label: {
                        Label(play.label, systemImage: "play.fill")
                    }.buttonStyle(TVGlassButtonStyle(prominent: true)).accessibilityIdentifier("details.play")
                } else {
                    Label("Not available to stream yet", systemImage: "calendar")
                        .font(VelvetFont.body(24)).foregroundStyle(VelvetColors.textSecondary)
                }
                Button { vm.toggleMyList() } label: {
                    Label(listRows.isEmpty ? "Add to My List" : "In My List", systemImage: listRows.isEmpty ? "plus" : "checkmark")
                }.buttonStyle(TVGlassButtonStyle())
                if play.showStartOver {
                    Button { presentation = TVPlaybackPresentation(target: vm.startOverTarget()) } label: {
                        Label("Start over", systemImage: "arrow.counterclockwise")
                    }.buttonStyle(TVGlassButtonStyle())
                }
            }.padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TVLayout.edge).padding(.top, 42).padding(.bottom, 20)
        .background(alignment: .top) { TVBackdrop(url: details.item.backdropUrl).frame(height: 880) }
    }

    private func episodes(_ details: MediaDetails) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: "Episodes").padding(.horizontal, TVLayout.edge)
            ScrollView(.horizontal) {
                HStack(spacing: 22) {
                    ForEach(details.seasons, id: \.number) { season in
                        Button { vm.selectSeason(season.number) } label: {
                            HStack(spacing: 12) {
                                if vm.selectedSeason == season.number { Image(systemName: "checkmark") }
                                Text(season.name)
                            }
                        }
                        .buttonStyle(TVGlassButtonStyle(prominent: vm.selectedSeason == season.number))
                        .contextMenu {
                            Button("Mark season watched", systemImage: "checkmark") { vm.markSeasonWatched(season.number) }
                            Button("Clear season history", systemImage: "arrow.counterclockwise") { vm.clearSeasonHistory(season.number) }
                        }
                    }
                }.padding(.horizontal, TVLayout.edge).padding(.vertical, 15)
            }.scrollIndicators(.hidden).scrollClipDisabled().focusSection()
            if vm.episodesLoading {
                ProgressView().frame(height: 230).frame(maxWidth: .infinity)
            } else if vm.episodes.isEmpty {
                Text("Episodes aren't available right now.")
                    .font(VelvetFont.body(24)).foregroundStyle(VelvetColors.textSecondary)
                    .padding(.horizontal, TVLayout.edge).padding(.vertical, 35)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: TVLayout.railGap) {
                        ForEach(vm.episodes, id: \.number) { episode in episodeCard(episode) }
                    }.padding(.horizontal, TVLayout.edge - 9).padding(.vertical, 20)
                }.scrollIndicators(.hidden).scrollClipDisabled().focusSection()
            }
        }
    }

    private func episodeCard(_ episode: Episode) -> some View {
        let isWatched = episode.coveredEpisodes.allSatisfy {
            watched.contains(DetailsViewModel.EpisodeKey(season: $0.season, episode: $0.episode))
        }
        return Button {
            presentation = TVPlaybackPresentation(target: PlayTarget(mediaId: vm.item.id, type: .show,
                                                                      season: episode.season, episode: episode.number))
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                TVArtwork(url: episode.stillUrl ?? vm.details?.item.backdropUrl)
                    .frame(width: 360, height: 203)
                    .overlay(alignment: .topTrailing) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 28))
                                .foregroundStyle(.white, VelvetColors.accent).padding(12)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text("\(episode.number). \(episode.title)").font(VelvetFont.body(23, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary).lineLimit(2).frame(height: 58, alignment: .top)
                HStack(spacing: 12) {
                    if let runtime = episode.runtimeMinutes { Text(DetailsFormat.runtime(runtime)) }
                    if isWatched { Text("Watched") }
                }.font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textSecondary)
                Text(episode.overview ?? "").font(VelvetFont.body(19)).foregroundStyle(VelvetColors.textSecondary)
                    .lineLimit(2).frame(height: 50, alignment: .top)
            }.frame(width: 360, alignment: .leading).padding(.bottom, 6)
        }
        .buttonStyle(TVCardButtonStyle())
        .contextMenu {
            Button(isWatched ? "Mark unwatched" : "Mark watched", systemImage: "checkmark") {
                if isWatched { vm.unmarkEpisodeWatched(episode) } else { vm.markEpisodeWatched(episode) }
            }
            Button("Mark all up to here watched", systemImage: "checkmark.circle") { vm.markWatchedUpTo(episode) }
            if let progress = progressRows.first,
               episode.covers(season: progress.season ?? -1, episode: progress.episode ?? -1) {
                Button("Clear resume position", systemImage: "arrow.counterclockwise") { vm.clearEpisodeProgress() }
            }
        }
    }

    private func cast(_ members: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSectionHeader(title: "Cast").padding(.horizontal, TVLayout.edge)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 30) {
                    ForEach(members, id: \.self) { member in TVCastPortrait(member: member) }
                }.padding(.horizontal, TVLayout.edge).padding(.vertical, 22)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }.focusSection()
    }

    private func similar(_ items: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSectionHeader(title: "More Like This").padding(.horizontal, TVLayout.edge)
            ScrollView(.horizontal) {
                HStack(spacing: TVLayout.railGap) {
                    ForEach(items, id: \.self) { item in
                        NavigationLink(value: item) { TVMediaCard(item: item) }
                            .buttonStyle(TVCardButtonStyle())
                            .contextMenu {
                                Button(vm.isInMyList(item) ? "Remove from My List" : "Add to My List", systemImage: "plus") {
                                    vm.toggleMyList(for: item)
                                }
                            }
                    }
                }.padding(.horizontal, TVLayout.edge - 9).padding(.vertical, 24)
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }.focusSection()
    }
}

private struct TVCastPortrait: View {
    let member: CastMember
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 15) {
            TVArtwork(url: member.profileUrl, symbol: "person.fill")
                .frame(width: 156, height: 156).clipShape(Circle())
                .overlay { Circle().strokeBorder(focused ? .white : .white.opacity(0.1), lineWidth: focused ? 3 : 1) }
            Text(member.name).font(VelvetFont.body(22, .semibold)).foregroundStyle(VelvetColors.textPrimary).lineLimit(2)
            Text(member.role ?? "").font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textSecondary).lineLimit(2)
        }.frame(width: 185).multilineTextAlignment(.center)
            .padding(10).focusable().focused($focused)
            .scaleEffect(focused ? 1.06 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
            .accessibilityElement(children: .combine)
    }
}
