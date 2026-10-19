import SwiftUI

/// Custom playback controls overlaid on the video — the touch twin of the
/// Android PlayerControls.kt. Bottom-anchored: title block, scrubber with
/// seek-on-release, then the buttons row. Close (X) sits top-leading.
/// Tapping the gradient background hides the controls (the caller toggles).
struct PlayerControls: View {
    @ObservedObject var vm: PlayerViewModel
    let onClose: () -> Void
    let onOpenPlaybackOptions: () -> Void
    let onOpenStreamPicker: () -> Void
    let onInteraction: () -> Void
    let onBackgroundTap: () -> Void

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.88), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { onBackgroundTap() }

            VStack(spacing: 0) {
                HStack {
                    PlayerIconButton(systemName: "xmark", action: onClose)
                    Spacer()
                }
                Spacer()
                titleBlock
                scrubBlock
                    .padding(.top, 10)
                buttonsRow
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    // MARK: title

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let queue = vm.queuePlayback {
                Text("\(queue.title) · \(queue.index + 1) of \(queue.count)")
                    .font(VelvetFont.body(11, .semibold))
                    .foregroundStyle(VelvetColors.accent)
                    .lineLimit(1)
            }
            if let episodeLabel = vm.episodeLabel {
                Text(vm.showTitle)
                    .font(VelvetFont.body(13, .medium))
                    .foregroundStyle(VelvetColors.textSecondary)
                    .lineLimit(1)
                Text(episodeLabel)
                    .font(VelvetFont.display(18, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .lineLimit(1)
            } else {
                Text(vm.showTitle)
                    .font(VelvetFont.display(18, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: scrubber

    private var shownPositionMs: Int64 {
        if isScrubbing && vm.durationMs > 0 {
            return Int64(scrubFraction * Double(vm.durationMs))
        }
        return vm.positionMs
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: {
                if isScrubbing { return scrubFraction }
                guard vm.durationMs > 0 else { return 0 }
                return min(max(Double(vm.positionMs) / Double(vm.durationMs), 0), 1)
            },
            set: { scrubFraction = $0 }
        )
    }

    /// "Ends 11:42 PM" — the wall clock when playback finishes from here.
    /// timeStyle .short respects the device's 12/24h preference; recomputed as
    /// the position ticks (and previews the new end time while scrubbing).
    private static let endsAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var endsAtSuffix: String {
        guard vm.durationMs > 0 else { return "" }
        let ends = Date().addingTimeInterval(Double(vm.durationMs - shownPositionMs) / 1000)
        return " · Ends " + Self.endsAtFormatter.string(from: ends)
    }

    // NOTE: unlike the Android scrubber there is no buffered-position track —
    // ExoPlayer exposes bufferedMs, libVLC 3.x exposes no buffered position
    // (only a transient buffering percentage). Accepted platform limitation.
    private var scrubBlock: some View {
        VStack(spacing: 0) {
            HStack {
                Text(playerTimeString(shownPositionMs))
                    .font(VelvetFont.body(12, .medium))
                    .foregroundStyle(isScrubbing ? VelvetColors.accent : VelvetColors.textSecondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("player.position")
                Spacer()
                Text(playerTimeString(vm.durationMs) + endsAtSuffix)
                    .font(VelvetFont.body(12, .medium))
                    .foregroundStyle(VelvetColors.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: sliderBinding, in: 0...1) { editing in
                onInteraction()
                if editing {
                    isScrubbing = true
                } else {
                    if vm.durationMs > 0 {
                        vm.seek(toMs: Int64(scrubFraction * Double(vm.durationMs)))
                    }
                    isScrubbing = false
                }
            }
            .tint(VelvetColors.accent)
            .disabled(vm.durationMs <= 0)
        }
    }

    // MARK: buttons

    private var buttonsRow: some View {
        HStack(spacing: 12) {
            // Equal-width side groups keep Play centered as tracks and TV
            // availability change. Playback adjustments live in one menu.
            HStack {
                PlayerIconButton(
                    systemName: "arrow.counterclockwise",
                    tint: vm.replayActive ? VelvetColors.accent : VelvetColors.textPrimary
                ) {
                    onInteraction()
                    vm.replayWithSubtitles()
                }
                .accessibilityLabel("Replay with subtitles")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            transportControls
                .fixedSize()

            HStack(spacing: 8) {
                PlayerIconButton(systemName: "play.rectangle.on.rectangle") {
                    onInteraction()
                    onOpenStreamPicker()
                }
                .accessibilityLabel("Streams")
                .accessibilityIdentifier("player.streams")
                PlayerIconButton(systemName: "slider.horizontal.3") {
                    onInteraction()
                    onOpenPlaybackOptions()
                }
                .accessibilityLabel("Playback options")
                .accessibilityIdentifier("player.options")
                if vm.canThrowToTv {
                    PlayerIconButton(systemName: "tv", disabled: vm.handoffInProgress) {
                        onInteraction()
                        vm.throwToTv()
                    }
                    .accessibilityLabel("Send to TV")
                    .accessibilityIdentifier("player.sendToTv")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            PlayerIconButton(systemName: "gobackward.10") {
                onInteraction()
                vm.seekBy(-10_000)
            }
            .accessibilityLabel("Back 10 seconds")
            if vm.isShow || vm.queuePlayback != nil {
                PlayerIconButton(systemName: "backward.end.fill", disabled: !vm.hasPrevious) {
                    onInteraction()
                    vm.playPreviousEpisode()
                }
                .accessibilityLabel(vm.queuePlayback == nil ? "Previous episode" : "Previous item")
                .accessibilityIdentifier("player.previous")
            }
            PlayerIconButton(
                systemName: vm.playbackButtonShowsPause ? "pause.fill" : "play.fill",
                size: 56,
                iconSize: 22
            ) {
                onInteraction()
                vm.togglePlayPause()
            }
            .accessibilityLabel(vm.playbackButtonShowsPause ? "Pause" : "Play")
            .accessibilityIdentifier("player.playPause")
            if vm.isShow || vm.queuePlayback != nil {
                PlayerIconButton(systemName: "forward.end.fill", disabled: !vm.hasNext) {
                    onInteraction()
                    vm.playNextEpisode()
                }
                .accessibilityLabel(vm.queuePlayback == nil ? "Next episode" : "Next item")
                .accessibilityIdentifier("player.next")
            }
            PlayerIconButton(systemName: "goforward.10") {
                onInteraction()
                vm.seekBy(10_000)
            }
            .accessibilityLabel("Forward 10 seconds")
        }
    }

}

// MARK: - Shared player building blocks

/// Circular icon button matching the Android ControlIconButton styling.
struct PlayerIconButton: View {
    var systemName: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 17
    var tint: Color = VelvetColors.textPrimary
    var disabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(disabled ? VelvetColors.textTertiary : tint)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(VelvetColors.textPrimary.opacity(disabled ? 0.05 : 0.12))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Accent-filled capsule (the Android velvetButtonColors twin).
struct PlayerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VelvetFont.display(14, .semibold))
            .foregroundStyle(VelvetColors.background)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(VelvetColors.accent))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Outlined capsule (the Android velvetOutlinedButtonBorder twin).
struct PlayerSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VelvetFont.display(14, .semibold))
            .foregroundStyle(VelvetColors.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Capsule().strokeBorder(VelvetColors.textPrimary.opacity(0.35), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// "1:23:45" / "23:45" / "0:00" — same formatting as the Android player.
private func playerTimeString(_ ms: Int64) -> String {
    if ms <= 0 { return "0:00" }
    let totalSecs = ms / 1000
    let h = totalSecs / 3600
    let m = (totalSecs % 3600) / 60
    let s = totalSecs % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}
