import SwiftUI

/// One titled home row. Loading shows pulsing placeholder cards; loaded renders
/// the style-appropriate cards from UI/Components/Cards.swift; failed (or loaded
/// empty) collapses silently — header included. Card tap pushes Details via
/// NavigationLink(value:); the context menu comes from the caller so each rail
/// gets its exact Android action set.
struct HomeRow<Menu: View>: View {
    let title: String
    let style: RowStyle
    let state: RowState
    @ViewBuilder let menu: (MediaItem) -> Menu

    var body: some View {
        switch state {
        case .loading:
            section { HomeRowPlaceholder(style: style) }
        case .loaded(let items) where !items.isEmpty:
            section { cardsRow(items) }
        default:
            EmptyView()
        }
    }

    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(title: title)
            content()
        }
        .padding(.top, 22)
    }

    private func cardsRow(_ items: [MediaItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: style == .top10 ? 16 : 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    NavigationLink(value: pair.element) {
                        card(for: pair.element, index: pair.offset)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(pair.element) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func card(for item: MediaItem, index: Int) -> some View {
        switch style {
        case .poster:
            PosterCard(item: item)
        case .landscape:
            LandscapeCard(item: item)
        case .top10:
            Top10Card(item: item, rank: item.rankInRow ?? (index + 1))
        }
    }
}

/// Continue Watching rail — tap resumes playback DIRECTLY (no Details detour),
/// the context menu carries the full Android long-press action set.
struct ContinueWatchingRow<Menu: View>: View {
    let entries: [ContinueWatchingEntry]
    let onResume: (PlayTarget) -> Void
    @ViewBuilder let menu: (ContinueWatchingEntry) -> Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeader(title: "Continue Watching")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(entries) { entry in
                        Button {
                            onResume(entry.target)
                        } label: {
                            ContinueWatchingCard(
                                item: entry.item,
                                progressFraction: entry.progressFraction,
                                progressLabel: entry.label
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(entry) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 22)
    }
}

/// Pulsing placeholder cards while a row loads: cardPlaceholder rounded rects
/// (artwork + caption bars) breathing between 45% and 100% opacity. Mirrors the
/// loaded geometry — Top 10 includes the rank gutter — so rows land in place.
private struct HomeRowPlaceholder: View {
    let style: RowStyle
    @State private var pulse = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: style == .top10 ? 16 : 12) {
                ForEach(0..<6, id: \.self) { _ in
                    placeholderCard
                }
            }
            .padding(.horizontal, 16)
        }
        .disabled(true)
        .opacity(pulse ? 1.0 : 0.45)
        .animation(.linear(duration: 0.75).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }

    private var cardWidth: CGFloat {
        style == .landscape ? CardMetrics.landscapeWidth : CardMetrics.posterWidth
    }

    private var cardHeight: CGFloat {
        style == .landscape ? CardMetrics.landscapeHeight : CardMetrics.posterHeight
    }

    private var placeholderCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 1) {
                if style == .top10 {
                    // Stand-in for the big rank numeral beside the poster.
                    RoundedRectangle(cornerRadius: CardMetrics.corner)
                        .fill(VelvetColors.cardPlaceholder.opacity(0.5))
                        .frame(width: 42, height: 64)
                        .padding(.trailing, 1)
                }
                RoundedRectangle(cornerRadius: CardMetrics.corner)
                    .fill(VelvetColors.cardPlaceholder)
                    .frame(width: cardWidth, height: cardHeight)
            }
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(VelvetColors.cardPlaceholder.opacity(0.8))
                    .frame(width: cardWidth * 0.7, height: 10)
                RoundedRectangle(cornerRadius: 4)
                    .fill(VelvetColors.cardPlaceholder.opacity(0.8))
                    .frame(width: cardWidth * 0.4, height: 9)
            }
            .padding(.top, 8)
            .padding(.leading, style == .top10 ? 44 : 0)
        }
    }
}

/// Episode collections keep show identity for library actions and explicit
/// episode identity for playback. Already-watched episodes remain browsable.
struct HomeCategoryRow<Menu: View>: View {
    let category: HomeCategory
    let onPlay: (HomeCategoryItem) -> Void
    let onPlayAll: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder let menu: (HomeCategoryItem) -> Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RowHeader(title: category.title)
            }
            HStack(spacing: 10) {
                Button(action: onPlayAll) { Label("Play all", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Button(action: onShuffle) { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(.bordered)
            }
            .font(VelvetFont.body(13, .semibold))
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(category.items) { entry in
                        Button { onPlay(entry) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                ZStack(alignment: .bottomTrailing) {
                                    CardArtwork(url: entry.stillUrl ?? entry.backdropUrl ?? entry.posterUrl)
                                        .frame(width: CardMetrics.landscapeWidth, height: CardMetrics.landscapeHeight)
                                        .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner))
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 27))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 3)
                                        .padding(8)
                                }
                                CardCaption(item: entry.item, width: CardMetrics.landscapeWidth)
                                if let label = entry.episodeLabel {
                                    Text(label)
                                        .font(VelvetFont.body(12))
                                        .foregroundStyle(VelvetColors.textTertiary)
                                        .lineLimit(2)
                                        .frame(width: CardMetrics.landscapeWidth, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(entry.title)\(entry.episodeLabel.map { ", " + $0 } ?? "")")
                        .contextMenu { menu(entry) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 22)
    }
}
