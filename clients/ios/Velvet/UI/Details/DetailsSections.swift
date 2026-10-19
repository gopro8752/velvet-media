import SwiftUI

/// Details screen building blocks — touch port of the Android
/// DetailsSections.kt + the hero/meta/error pieces of DetailsScreen.kt.
/// Everything is prefixed `Details` so names can't collide with other screens.

// MARK: - header

struct DetailsHeaderView: View {
    let details: MediaDetails
    var height: CGFloat = 340
    var contentWidth: CGFloat = 1100
    var expanded = false
    var topInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            logoOrTitle
            if let tagline = details.tagline, !tagline.isEmpty {
                Text(tagline)
                    .font(VelvetFont.body(expanded ? 15 : 13).italic())
                    .foregroundStyle(VelvetColors.textSecondary)
                    .lineLimit(expanded ? 2 : 1)
            }
            DetailsMetaLine(details: details)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, max(0, topInset) + 16)
        .padding(.bottom, 14)
        .frame(maxWidth: contentWidth, alignment: .leading)
        // A minimum lets large text and fallback titles expand the hero instead
        // of being clipped against the screen's top edge or navigation chrome.
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
        .background {
            ZStack {
                // Only the cover-scaled backdrop is clipped. Its overlay cannot
                // inflate the page width or constrain the foreground's height.
                Color.clear
                    .overlay {
                        CardArtwork(url: details.item.backdropUrl ?? details.item.posterUrl)
                    }
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: VelvetColors.background.opacity(0), location: 0.0),
                        .init(color: VelvetColors.background.opacity(0.25), location: 0.55),
                        .init(color: VelvetColors.background, location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                LinearGradient(
                    stops: [
                        .init(color: VelvetColors.background.opacity(0.55), location: 0.0),
                        .init(color: VelvetColors.background.opacity(0.25), location: 0.45),
                        .init(color: VelvetColors.background.opacity(0), location: 0.75),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
        }
    }

    @ViewBuilder
    private var logoOrTitle: some View {
        if let logoUrl = details.item.logoUrl {
            AsyncImage(url: logoUrl,
                       transaction: Transaction(animation: .easeIn(duration: 0.22))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .frame(width: expanded ? 320 : 230,
                               height: expanded ? 90 : 64, alignment: .bottomLeading)
                        .transition(.opacity)
                case .failure:
                    titleText
                default:
                    Color.clear
                        .frame(width: expanded ? 320 : 230, height: expanded ? 90 : 64)
                }
            }
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(details.item.title)
            .font(VelvetFont.display(expanded ? 40 : 30, .bold))
            .foregroundStyle(VelvetColors.textPrimary)
            .lineLimit(2)
    }
}

// MARK: - meta line (cert chip · year · runtime/seasons · ★ · genres)

struct DetailsMetaLine: View {
    let details: MediaDetails

    private enum Entry {
        case certification(String)
        case text(String)
        case rating(Double)
    }

    private var entries: [Entry] {
        var list: [Entry] = []
        if let cert = details.certification, !cert.isEmpty {
            list.append(.certification(cert))
        }
        if let year = details.item.year {
            list.append(.text(year))
        }
        switch details.item.type {
        case .movie:
            if let minutes = details.item.runtimeMinutes, minutes > 0 {
                list.append(.text(DetailsFormat.runtime(minutes)))
            }
        case .show:
            if let label = DetailsFormat.seasonCount(details.seasons) {
                list.append(.text(label))
            }
        }
        if let rating = details.item.rating, rating > 0 {
            list.append(.rating(rating))
        }
        if !details.item.genres.isEmpty {
            list.append(.text(details.item.genres.prefix(3).joined(separator: ", ")))
        }
        return list
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Text("·")
                        .font(VelvetFont.body(12))
                        .foregroundStyle(VelvetColors.textTertiary)
                }
                entryView(entry)
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: Entry) -> some View {
        switch entry {
        case .certification(let cert):
            Text(cert)
                .font(VelvetFont.body(10, .semibold))
                .foregroundStyle(VelvetColors.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(VelvetColors.textTertiary, lineWidth: 1)
                )
        case .text(let text):
            Text(text)
                .font(VelvetFont.body(12))
                .foregroundStyle(VelvetColors.textSecondary)
                .lineLimit(1)
        case .rating(let rating):
            Text("★ " + String(format: "%.1f", rating))
                .font(VelvetFont.body(12, .semibold))
                .foregroundStyle(VelvetColors.gold)
                .lineLimit(1)
        }
    }
}

// MARK: - season chips

struct DetailsSeasonChips: View {
    let seasons: [Season]
    let selectedSeason: Int?
    let onSelect: (Int) -> Void
    let onMarkSeasonWatched: (Season) -> Void
    let onClearSeasonHistory: (Season) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(seasons, id: \.number) { season in
                    chip(season)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ season: Season) -> some View {
        let selected = season.number == selectedSeason
        let trimmed = season.name.trimmingCharacters(in: .whitespaces)
        let label = trimmed.isEmpty ? "Season \(season.number)" : trimmed
        return Button {
            onSelect(season.number)
        } label: {
            Text(label)
                .font(VelvetFont.display(13, .semibold))
                .foregroundStyle(selected ? VelvetColors.background : VelvetColors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(selected ? VelvetColors.accent : VelvetColors.surfaceElevated,
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onMarkSeasonWatched(season)
            } label: {
                Label("Mark season watched", systemImage: "text.badge.checkmark")
            }
            Button(role: .destructive) {
                onClearSeasonHistory(season)
            } label: {
                Label("Clear season history", systemImage: "trash")
            }
        }
    }
}

// MARK: - episode row

struct DetailsEpisodeRow: View {
    let episode: Episode
    let watched: Bool
    /// Non-nil only for the in-progress episode (0..1) — green underline.
    let progressFraction: Double?

    private static let stillWidth: CGFloat = 128
    private static let stillHeight: CGFloat = 72   // 16:9

    private var metaLine: String? {
        var parts: [String] = []
        if let minutes = episode.runtimeMinutes, minutes > 0 {
            parts.append(DetailsFormat.runtime(minutes))
        }
        if let airDate = episode.airDate, !airDate.isEmpty {
            parts.append(DetailsFormat.airDate(airDate))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            still

            VStack(alignment: .leading, spacing: 3) {
                Text("E\(episode.number) · \(episode.title)")
                    .font(VelvetFont.body(14, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .lineLimit(1)
                if let metaLine {
                    Text(metaLine)
                        .font(VelvetFont.body(11))
                        .foregroundStyle(VelvetColors.textTertiary)
                        .lineLimit(1)
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(VelvetFont.body(12))
                        .foregroundStyle(VelvetColors.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if watched {
                Image(systemName: "checkmark.circle.fill")
                    .font(VelvetFont.body(16))
                    .foregroundStyle(VelvetColors.match)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var still: some View {
        ZStack(alignment: .bottomLeading) {
            CardArtwork(url: episode.stillUrl)
                .frame(width: Self.stillWidth, height: Self.stillHeight)
            if let fraction = progressFraction, fraction > 0, fraction < 1 {
                ZStack(alignment: .leading) {
                    Rectangle().fill(VelvetColors.trackInactive)
                    Rectangle()
                        .fill(VelvetColors.match)
                        .frame(width: Self.stillWidth * fraction)
                }
                .frame(width: Self.stillWidth, height: 3)
            }
        }
        .frame(width: Self.stillWidth, height: Self.stillHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Pulsing placeholder row shown while a season's episodes load.
struct DetailsEpisodePlaceholder: View {
    @State private var pulsed = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(VelvetColors.cardPlaceholder)
                .frame(width: 128, height: 72)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(VelvetColors.cardPlaceholder)
                    .frame(maxWidth: 140)
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(VelvetColors.cardPlaceholder)
                    .frame(maxWidth: 90)
                    .frame(height: 9)
                RoundedRectangle(cornerRadius: 4)
                    .fill(VelvetColors.cardPlaceholder)
                    .frame(maxWidth: .infinity)
                    .frame(height: 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .opacity(pulsed ? 1.0 : 0.45)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulsed = true
            }
        }
    }
}

// MARK: - cast

struct DetailsCastRow: View {
    let cast: [CastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RowHeader(title: "Cast")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(cast.prefix(15).enumerated()), id: \.offset) { _, member in
                        DetailsCastCell(member: member)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct DetailsCastCell: View {
    let member: CastMember

    var body: some View {
        VStack(spacing: 6) {
            CardArtwork(url: member.profileUrl)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
            Text(member.name)
                .font(VelvetFont.body(11))
                .foregroundStyle(VelvetColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 72, alignment: .top)
    }
}

// MARK: - error state

struct DetailsErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Something went wrong")
                .font(VelvetFont.display(22, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
            Text(message)
                .font(VelvetFont.body(13))
                .foregroundStyle(VelvetColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 12) {
                Button("Try Again", action: onRetry)
                    .buttonStyle(DetailsActionButtonStyle(prominent: true))
                Button("Go Back", action: onBack)
                    .buttonStyle(DetailsActionButtonStyle())
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 32)
    }
}

// MARK: - button style

/// Capsule action button: prominent (Play) = near-white fill with dark text,
/// secondary (My List / Start Over) = surface-highlight fill.
struct DetailsActionButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VelvetFont.display(14, .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? VelvetColors.background : VelvetColors.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(prominent ? VelvetColors.textPrimary : VelvetColors.surfaceHighlight,
                        in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1.0)
    }
}
