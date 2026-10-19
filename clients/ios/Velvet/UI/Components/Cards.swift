import SwiftUI

/// Velvet card system — the iOS twin of the Android MediaCards.kt.
/// RULE 1 (non-negotiable): every card shows TITLE + YEAR + RATING as text under
/// the artwork, always. Tap = primary action; context menu = secondary actions.
enum CardMetrics {
    static let posterWidth: CGFloat = 112
    static let posterHeight: CGFloat = 168
    static let landscapeWidth: CGFloat = 208
    static let landscapeHeight: CGFloat = 117
    static let corner: CGFloat = 9
}

struct CardArtwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.22))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill().transition(.opacity)
            default:
                VelvetColors.cardPlaceholder
            }
        }
    }
}

/// Title + meta line under a card.
struct CardCaption: View {
    let item: MediaItem
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(VelvetFont.body(13, .semibold))
                .foregroundStyle(VelvetColors.textSecondary)
                .lineLimit(1)
            HStack(spacing: 0) {
                if let year = item.year {
                    Text(year)
                        .font(VelvetFont.body(11))
                        .foregroundStyle(VelvetColors.textTertiary)
                }
                if let rating = item.rating, rating > 0 {
                    if item.year != nil {
                        Text("  ·  ")
                            .font(VelvetFont.body(11))
                            .foregroundStyle(VelvetColors.textTertiary)
                    }
                    Text("★ " + String(format: "%.1f", rating))
                        .font(VelvetFont.body(11))
                        .foregroundStyle(VelvetColors.gold.opacity(0.85))
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.top, 5)
    }
}

struct PosterCard: View {
    let item: MediaItem
    /// Width override so grids can size cards to their actual columns
    /// (Search's 3-up grid); horizontal rows keep the fixed default.
    var width: CGFloat = CardMetrics.posterWidth

    private var height: CGFloat {
        width * CardMetrics.posterHeight / CardMetrics.posterWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardArtwork(url: item.posterUrl)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner))
            CardCaption(item: item, width: width)
        }
    }
}

struct LandscapeCard: View {
    let item: MediaItem
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardArtwork(url: item.backdropUrl ?? item.posterUrl)
                .frame(width: CardMetrics.landscapeWidth, height: CardMetrics.landscapeHeight)
                .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner))
            CardCaption(item: item, width: CardMetrics.landscapeWidth)
        }
    }
}

/// Top 10 card — big accent-violet rank numeral tucked beside the poster.
struct Top10Card: View {
    let item: MediaItem
    let rank: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 1) {
                Text("\(rank)")
                    .font(VelvetFont.display(rank < 10 ? 76 : 58, .bold))
                    .foregroundStyle(VelvetColors.accent.opacity(0.55))
                    .padding(.trailing, 1)
                CardArtwork(url: item.posterUrl)
                    .frame(width: CardMetrics.posterWidth, height: CardMetrics.posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner))
            }
            CardCaption(item: item, width: CardMetrics.posterWidth)
                .padding(.leading, rank < 10 ? 44 : 36)
        }
    }
}

/// Continue Watching — backdrop, green progress bar, caption + resume label.
struct ContinueWatchingCard: View {
    let item: MediaItem
    let progressFraction: Double
    let progressLabel: String      // "S2 E4 · 23m left" or "48m left"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                CardArtwork(url: item.backdropUrl ?? item.posterUrl)
                    .frame(width: CardMetrics.landscapeWidth, height: CardMetrics.landscapeHeight)
                LinearGradient(
                    colors: [.clear, VelvetColors.scrim],
                    startPoint: .center, endPoint: .bottom
                )
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            Rectangle().fill(VelvetColors.trackInactive)
                            Rectangle()
                                .fill(VelvetColors.match)
                                .frame(width: geo.size.width * min(max(progressFraction, 0), 1))
                        }
                        .frame(height: 3)
                    }
                }
            }
            .frame(width: CardMetrics.landscapeWidth, height: CardMetrics.landscapeHeight)
            .clipShape(RoundedRectangle(cornerRadius: CardMetrics.corner))

            VStack(alignment: .leading, spacing: 2) {
                CardCaption(item: item, width: CardMetrics.landscapeWidth)
                Text(progressLabel)
                    .font(VelvetFont.body(11))
                    .foregroundStyle(VelvetColors.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// Section header above a row.
struct RowHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(VelvetFont.display(19, .semibold))
            .foregroundStyle(VelvetColors.textPrimary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
