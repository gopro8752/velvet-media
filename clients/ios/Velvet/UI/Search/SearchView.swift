import SwiftUI

/// Search tab — Velvet-styled search field pinned top over an adaptive poster
/// grid. Port of the Android SearchScreen (~/velvet/.../ui/search/SearchScreen.kt):
/// same states (prompt / searching / no results / grid) and the same
/// long-press action set (Details / Play / My List toggle), here as a native
/// context menu.
struct SearchView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var vm = SearchViewModel()

    @State private var playTarget: PlayTarget?
    /// Context-menu "Go to details" pushes through an isPresented destination so
    /// it cannot conflict with the type-based registration the links use.
    @State private var contextDetailsItem: MediaItem?
    @State private var contextDetailsPushed = false

    var body: some View {
        ZStack {
            VelvetColors.background.ignoresSafeArea()
            VStack(spacing: 0) {
                VelvetSearchField(text: $vm.query, onSubmit: vm.commitSearch)
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                content
            }
            .frame(maxWidth: 1200)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: MediaItem.self) { item in
            DetailsView(item: item)
        }
        .navigationDestination(isPresented: $contextDetailsPushed) {
            if let item = contextDetailsItem {
                DetailsView(item: item)
            }
        }
        .playerPresenter(item: $playTarget)
        .task { vm.configure(tmdb: container.tmdb) }
    }

    // MARK: states

    @ViewBuilder
    private var content: some View {
        if vm.trimmedQuery.count < 2 {
            prompt
        } else if vm.results.isEmpty && vm.searching {
            status("Searching…", subtitle: nil)
        } else if vm.results.isEmpty && !vm.resultsFor.isEmpty {
            status("No results for “\(vm.resultsFor)”",
                   subtitle: "Check the spelling or try a different title.")
        } else if vm.results.isEmpty {
            prompt
        } else {
            resultsGrid
        }
    }

    private var resultsGrid: some View {
        GeometryReader { geo in
            // Keep the phone's three columns; wider windows add columns instead
            // of stretching the same three posters across an iPad. The proposal
            // also follows Split View and sheets without consulting device bounds.
            let availableWidth = max(geo.size.width - 32, 0)
            let columnCount = max(3, Int((availableWidth + 12) / 162))
            let columnWidth = max((availableWidth - CGFloat(columnCount - 1) * 12) / CGFloat(columnCount), 0)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columnCount)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(vm.results, id: \.self) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item, width: columnWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextActions(for: item) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// Same action set as the Android long-press sheet. My List membership is
    /// resolved when the menu opens, so the label is correct with no flicker.
    @ViewBuilder
    private func contextActions(for item: MediaItem) -> some View {
        Button {
            contextDetailsItem = item
            contextDetailsPushed = true
        } label: {
            Label("Go to details", systemImage: "info.circle")
        }
        Button {
            // Plain target: shows resolve to the next unwatched episode downstream.
            playTarget = PlayTarget(mediaId: item.id, type: item.type, season: nil, episode: nil)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        if container.playback.isInMyList(mediaId: item.id, typeKey: item.type.rawValue) {
            Button {
                container.playback.toggleMyList(item)
            } label: {
                Label("Remove from My List", systemImage: "minus.circle")
            }
        } else {
            Button {
                container.playback.toggleMyList(item)
            } label: {
                Label("Add to My List", systemImage: "plus.circle")
            }
        }
    }

    /// Idle empty state: invites the user to type.
    private var prompt: some View {
        VStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(VelvetColors.surfaceHighlight)
            Text("Search movies & shows")
                .font(VelvetFont.display(20, .semibold))
                .foregroundStyle(VelvetColors.textSecondary)
                .padding(.top, 14)
            Text("Type at least 2 characters to search")
                .font(VelvetFont.body(13))
                .foregroundStyle(VelvetColors.textTertiary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    /// Centered status text — used for "Searching…" and "No results".
    private func status(_ title: String, subtitle: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(VelvetFont.display(20, .semibold))
                .foregroundStyle(VelvetColors.textSecondary)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(VelvetFont.body(13))
                    .foregroundStyle(VelvetColors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

/// Velvet search input — surfaceElevated rounded field, magnifier icon,
/// near-white caret, custom placeholder. Deliberately NOT `.searchable`:
/// that brings default system chrome that fights the Velvet look.
private struct VelvetSearchField: View {
    @Binding var text: String
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(focused ? VelvetColors.textPrimary : VelvetColors.textTertiary)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("Search movies & shows")
                        .font(VelvetFont.body(16))
                        .foregroundStyle(VelvetColors.textTertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .font(VelvetFont.body(16))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .tint(VelvetColors.textPrimary)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(VelvetColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VelvetColors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(focused ? VelvetColors.accent.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { focused = true }
    }
}
