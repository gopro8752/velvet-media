import SwiftUI

/// Hero billboard — the top ~62% of the Home screen. Full-bleed backdrop with
/// leading + bottom scrims to the background color, TMDB logo art (or display-font
/// title), meta line (gold ★ rating · year · runtime · genres), 2-line overview,
/// and Play / Details / My List buttons. Crossfades when the featured item rotates.
struct HeroBillboard: View {
    let hero: MediaItem?
    let inMyList: Bool
    let height: CGFloat
    var wideLayout = false
    let onPlay: () -> Void
    let onToggleMyList: () -> Void

    private var heroIdentity: String? {
        hero.map { "\($0.type.rawValue):\($0.id)" }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            scrims
            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }

    // MARK: Backdrop

    private var backdropUrl: URL? {
        hero?.backdropUrl ?? hero?.posterUrl
    }

    private var backdrop: some View {
        // Color base adopts the proposed size exactly; the aspect-fill image lives
        // in an overlay so its overflow never inflates the hero's layout frame.
        VelvetColors.background
            .overlay {
                if let url = backdropUrl {
                    CardArtwork(url: url)
                        .id(url.absoluteString)
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeInOut(duration: 0.25), value: backdropUrl)
    }

    private var scrims: some View {
        ZStack {
            // Leading scrim — keeps logo/title legible over bright backdrops.
            LinearGradient(
                stops: [
                    .init(color: VelvetColors.background.opacity(0.75), location: 0.0),
                    .init(color: VelvetColors.background.opacity(0.30), location: 0.32),
                    .init(color: VelvetColors.background.opacity(0.0), location: 0.68),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            // Vertical scrims: a whisper at the top (wordmark legibility), solid at
            // the bottom so the first rows sit on the hero for the overlap look.
            LinearGradient(
                stops: [
                    .init(color: VelvetColors.background.opacity(0.5), location: 0.0),
                    .init(color: VelvetColors.background.opacity(0.0), location: 0.18),
                    .init(color: VelvetColors.background.opacity(0.0), location: 0.5),
                    .init(color: VelvetColors.background.opacity(0.95), location: 0.88),
                    .init(color: VelvetColors.background, location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hero {
                // Text block crossfades on rotation; the buttons live outside the
                // identity swap so they never blink mid-tap.
                textBlock(hero)
                    .id("hero-text-\(heroIdentity ?? "")")
                    .transition(.opacity)
                buttonsRow(hero)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: wideLayout ? 620 : .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: heroIdentity)
    }

    private func textBlock(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            logoOrTitle(item)
            metaLine(item)
                .padding(.top, 10)
            Text(item.overview ?? "")
                .font(VelvetFont.body(wideLayout ? 16 : 14))
                .foregroundStyle(VelvetColors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func logoOrTitle(_ item: MediaItem) -> some View {
        Group {
            if let logoUrl = item.logoUrl {
                AsyncImage(
                    url: logoUrl,
                    transaction: Transaction(animation: .easeIn(duration: 0.22))
                ) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().transition(.opacity)
                    }
                }
                .frame(maxWidth: wideLayout ? 360 : 280,
                       maxHeight: wideLayout ? 104 : 84, alignment: .bottomLeading)
            } else {
                Text(item.title)
                    .font(VelvetFont.display(wideLayout ? 40 : 32, .bold))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: wideLayout ? 108 : 88,
               maxHeight: wideLayout ? 108 : 88, alignment: .bottomLeading)
    }

    /// "★ 8.1  ·  2024  ·  2h 18m  ·  Sci-Fi" — gold star rating, rest in secondary.
    private func metaLine(_ item: MediaItem) -> some View {
        HStack(spacing: 0) {
            let rating = item.rating.flatMap { $0 > 0 ? $0 : nil }
            if let rating {
                Text("★ " + String(format: "%.1f", rating))
                    .font(VelvetFont.body(13, .semibold))
                    .foregroundStyle(VelvetColors.gold)
            }
            let parts = metaParts(item)
            if !parts.isEmpty {
                Text((rating != nil ? "  ·  " : "") + parts.joined(separator: "  ·  "))
                    .font(VelvetFont.body(13, .medium))
                    .foregroundStyle(VelvetColors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func metaParts(_ item: MediaItem) -> [String] {
        var parts: [String] = []
        if let year = item.year, !year.isEmpty {
            parts.append(year)
        }
        if let runtime = item.runtimeMinutes, runtime > 0 {
            parts.append(formatHeroRuntime(runtime))
        }
        parts.append(contentsOf: item.genres.prefix(2))
        return parts
    }

    // MARK: Buttons

    private func buttonsRow(_ item: MediaItem) -> some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Play")
                        .font(VelvetFont.display(15, .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(VelvetColors.background)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(VelvetColors.textPrimary))
            }
            .buttonStyle(.plain)

            NavigationLink(value: item) {
                outlinedLabel(icon: "info.circle", text: "Details")
            }
            .buttonStyle(.plain)

            Button(action: onToggleMyList) {
                outlinedLabel(
                    icon: inMyList ? "checkmark" : "plus",
                    text: inMyList ? "In My List" : "My List"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func outlinedLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(VelvetFont.display(14, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(VelvetColors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(VelvetColors.surface.opacity(0.45)))
        .overlay(Capsule().stroke(VelvetColors.textSecondary.opacity(0.4), lineWidth: 1))
    }
}

/// 138 → "2h 18m", 120 → "2h", 45 → "45m" (exact port of the Android formatter).
private func formatHeroRuntime(_ minutes: Int) -> String {
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}
