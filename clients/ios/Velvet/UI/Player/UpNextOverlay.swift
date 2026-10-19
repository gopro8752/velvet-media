import SwiftUI

/// Bottom-trailing Up Next card — the touch twin of the Android UpNextOverlay.
/// Two flavors:
///  - `.countdown`: still + "Up Next · S2 E5" + draining ring; Play now / Watch credits.
///  - `.endChoice`: shown at ENDED when autoplay was cancelled or disabled;
///    Play next / Back to details, no countdown.
struct UpNextOverlay: View {
    let upNext: UpNextUi
    let fallbackImageUrl: URL?
    let onPlayNext: () -> Void
    let onWatchCredits: () -> Void
    let onBackToDetails: () -> Void

    private var model: (next: NextEpisodeUi, countdown: (secondsLeft: Int, totalSeconds: Int)?)? {
        switch upNext {
        case .hidden:
            return nil
        case let .countdown(next, secondsLeft, totalSeconds):
            return (next, (secondsLeft, totalSeconds))
        case let .endChoice(next):
            return (next, nil)
        }
    }

    var body: some View {
        if let model {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    card(next: model.next, countdown: model.countdown)
                }
            }
            .padding(.trailing, 24)
            .padding(.bottom, 18)
        }
    }

    private func card(next: NextEpisodeUi,
                      countdown: (secondsLeft: Int, totalSeconds: Int)?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                CardArtwork(url: next.stillUrl ?? fallbackImageUrl)
                    .frame(width: 280, height: 130)
                    .clipped()
                // Still-to-card blend over the bottom half, like the Android scrim.
                LinearGradient(
                    colors: [.clear, VelvetColors.surfaceElevated.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: 280, height: 65)
            }
            .frame(width: 280, height: 130)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(next.season > 0 ? "Up Next · S\(next.season) E\(next.episode)" : "Up Next")
                        .font(VelvetFont.body(12, .semibold))
                        .foregroundStyle(VelvetColors.accent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let countdown {
                        PlayerCountdownRing(
                            secondsLeft: countdown.secondsLeft,
                            totalSeconds: countdown.totalSeconds
                        )
                    }
                }
                if let showTitle = next.showTitle {
                    Text(showTitle)
                        .font(VelvetFont.body(13, .semibold))
                        .foregroundStyle(VelvetColors.textSecondary)
                        .lineLimit(1)
                }
                Text(next.title.isEmpty ? "Episode \(next.episode)" : next.title)
                    .font(VelvetFont.display(15, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 10) {
                    Button(countdown != nil ? "Play now" : "Play next", action: onPlayNext)
                        .buttonStyle(PlayerPrimaryButtonStyle())
                    if countdown != nil {
                        Button("Watch credits", action: onWatchCredits)
                            .buttonStyle(PlayerSecondaryButtonStyle())
                    } else {
                        Button("Back to details", action: onBackToDetails)
                            .buttonStyle(PlayerSecondaryButtonStyle())
                    }
                }
                .padding(.top, 8)
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(VelvetColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }
}

/// Small ring that drains as the countdown ticks, seconds number in the middle.
struct PlayerCountdownRing: View {
    let secondsLeft: Int
    let totalSeconds: Int

    var body: some View {
        let fraction = totalSeconds > 0
            ? min(max(Double(secondsLeft) / Double(totalSeconds), 0), 1)
            : 0
        ZStack {
            Circle()
                .stroke(VelvetColors.ringTrack, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(VelvetColors.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(secondsLeft)")
                .font(VelvetFont.body(11, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
                .monospacedDigit()
        }
        .frame(width: 28, height: 28)
        .animation(.linear(duration: 1), value: fraction)
    }
}
