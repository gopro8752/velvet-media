import SwiftUI

/// Deliberately generous inset: focus glows remain inside the television's safe area.
enum TVLayout {
    static let edge: CGFloat = 80
    static let railGap: CGFloat = 28
}

struct TVGlassButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        TVGlassButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct TVGlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(VelvetFont.body(24, .semibold))
            .padding(.horizontal, 28).padding(.vertical, 18)
            .foregroundStyle(prominent || focused ? Color.black : VelvetColors.textPrimary)
            .background {
                if prominent || focused {
                    Capsule().fill(.white.opacity(focused ? 1 : 0.92))
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay {
                Capsule().strokeBorder(LinearGradient(
                    colors: [.white.opacity(focused ? 0.85 : 0.24), .white.opacity(0.06), VelvetColors.accent.opacity(0.30)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: VelvetColors.accent.opacity(focused ? 0.22 : 0), radius: 20, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : (focused ? 1.045 : 1))
            .opacity(enabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct TVCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVCardButtonBody(configuration: configuration)
    }
}

private struct TVCardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .padding(9)
            .background(focused ? Color.white.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 23))
            .overlay {
                RoundedRectangle(cornerRadius: 23).strokeBorder(
                    LinearGradient(colors: [.white.opacity(focused ? 0.95 : 0), VelvetColors.accent.opacity(focused ? 0.8 : 0), .white.opacity(focused ? 0.32 : 0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
            }
            .shadow(color: VelvetColors.accent.opacity(focused ? 0.20 : 0), radius: 20, y: 8)
            .scaleEffect(configuration.isPressed ? 0.99 : (focused ? 1.045 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct TVBackdrop: View {
    var url: URL? = nil
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VelvetColors.background
                if let url {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Color.clear }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                } else {
                    RadialGradient(colors: [VelvetColors.accentDeep.opacity(0.24), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: 1000)
                }
                LinearGradient(stops: [.init(color: VelvetColors.background.opacity(0.82), location: 0),
                                       .init(color: VelvetColors.background.opacity(0.25), location: 0.60),
                                       .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: VelvetColors.background.opacity(0.25), location: 0),
                                       .init(color: VelvetColors.background.opacity(0.05), location: 0.35),
                                       .init(color: VelvetColors.background, location: 1)], startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TVArtwork: View {
    let url: URL?
    var symbol = "film"
    var body: some View {
        ZStack {
            VelvetColors.surfaceHighlight
            Image(systemName: symbol).font(.system(size: 40, weight: .light))
                .foregroundStyle(VelvetColors.textTertiary)
            AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                placeholder: { Color.clear }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

struct TVMediaCard: View {
    let item: MediaItem
    var landscape = false
    var subtitle: String? = nil
    var progress: Double? = nil
    var width: CGFloat { landscape ? 340 : 220 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVArtwork(url: landscape ? (item.backdropUrl ?? item.posterUrl) : item.posterUrl,
                      symbol: item.type == .show ? "tv" : "film")
                .frame(width: width, height: landscape ? 191 : 330)
                .overlay(alignment: .bottomLeading) {
                    if let progress {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Color.black.opacity(0.55)
                                VelvetColors.accent.frame(width: proxy.size.width * min(max(progress, 0), 1))
                            }
                        }.frame(height: 5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(item.title).font(VelvetFont.body(23, .semibold))
                .foregroundStyle(VelvetColors.textPrimary).lineLimit(1)
            Text(subtitle ?? [item.year, item.type == .show ? "Series" : "Film"].compactMap { $0 }.joined(separator: " · "))
                .font(VelvetFont.body(18)).foregroundStyle(VelvetColors.textSecondary).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .padding(.bottom, 5)
        .accessibilityElement(children: .combine)
    }
}

struct TVSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(VelvetFont.display(32, .semibold)).foregroundStyle(VelvetColors.textPrimary)
            if let subtitle {
                Text(subtitle).font(VelvetFont.body(20)).foregroundStyle(VelvetColors.textSecondary)
            }
        }
    }
}

struct TVMediaMetadata: View {
    let item: MediaItem
    var extra: String? = nil
    var body: some View {
        HStack(spacing: 18) {
            if let rating = item.rating, rating > 0 {
                Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(VelvetColors.gold)
            }
            if let year = item.year { Text(year) }
            if let runtime = item.runtimeMinutes { Text(DetailsFormat.runtime(runtime)) }
            if let extra { Text(extra) }
        }
        .font(VelvetFont.body(23, .medium)).foregroundStyle(VelvetColors.textSecondary)
    }
}

struct TVTitleArtwork: View {
    let item: MediaItem
    var width: CGFloat = 620
    var height: CGFloat = 150
    var body: some View {
        Group {
            if let url = item.logoUrl {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() }
                    placeholder: { title }
            } else { title }
        }
        .frame(maxWidth: width, minHeight: height, maxHeight: height, alignment: .leading)
    }
    private var title: some View {
        Text(item.title).font(VelvetFont.display(60, .bold))
            .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TVEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: symbol).font(.system(size: 58, weight: .light)).foregroundStyle(VelvetColors.accent)
            Text(title).font(VelvetFont.display(36, .semibold)).foregroundStyle(VelvetColors.textPrimary)
            Text(message).font(VelvetFont.body(24)).foregroundStyle(VelvetColors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 820)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TVPlaybackPresentation: Identifiable {
    let id = UUID()
    let target: PlayTarget
    var queue: HomeCategory? = nil
}
