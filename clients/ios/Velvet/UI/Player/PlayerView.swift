import SwiftUI
import AVFoundation
import UIKit

/// Velvet player — full-screen cover, landscape-locked, VLCKit-backed.
/// Resolves identity + streams, plays, persists progress, and autoplays the
/// next episode inside this same cover (the media swaps in place).
///
/// Contract: `PlayerView(target:)` presented via `.fullScreenCover(item:)`.
struct PlayerView: View {
    let target: PlayTarget
    var queuePlayback: CategoryQueuePlayback? = nil
    var queuePrefetch: CategoryQueuePrefetch? = nil
    var onAdvanceQueue: ((CategoryQueueAdvance) -> Void)? = nil
    var onQueueHealthy: (() -> Void)? = nil

    @EnvironmentObject private var container: AppContainer
    @State private var vm: PlayerViewModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let vm {
                PlayerScreenContent(vm: vm, onAdvanceQueue: onAdvanceQueue, onQueueHealthy: onQueueHealthy)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            if vm == nil {
                vm = PlayerViewModel(
                    target: target,
                    tmdb: container.tmdb,
                    streamRepo: container.streams,
                    settings: container.settings,
                    playback: container.playback,
                    companion: container.companion,
                    queuePlayback: queuePlayback,
                    queuePrefetch: queuePrefetch
                )
            }
        }
        .onDisappear {
            vm?.teardown()
        }
    }
}

// `playerPresenter(item:)` lives in PlayerPresentation.swift (UIKit landscape host).

// MARK: - Screen content (observes the view model)

private struct PlayerScreenContent: View {
    @ObservedObject var vm: PlayerViewModel
    let onAdvanceQueue: ((CategoryQueueAdvance) -> Void)?
    let onQueueHealthy: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var controlsVisible = false
    @State private var interactionStamp = Date()
    private enum Picker: String, Identifiable {
        case streams, options
        var id: String { rawValue }
    }
    @State private var activePicker: Picker?

    private var anyPickerOpen: Bool { activePicker != nil || !vm.tvReceivers.isEmpty }
    private var upNextVisible: Bool { vm.upNext != .hidden }
    private var needsBlockReset: Bool { vm.streams.isEmpty && !vm.blockedGroups.isEmpty }

    private struct AutoHideKey: Equatable {
        let visible: Bool
        let stamp: Date
        let playing: Bool
        let pickerOpen: Bool
    }

    private var playbackSurface: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video surface stays mounted once the first stream is set —
            // overlays draw above it (the autoplay swap reuses it in place).
            if vm.currentStreamUrl != nil {
                PlayerVideoSurface(engine: vm.engine)
                    .ignoresSafeArea()
            }

            // Tap layer: toggles the controls while watching.
            if vm.phase == .playing && !upNextVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        toggleControls()
                    }
            }

            phaseOverlay

            // Skip Intro pill — bottom-trailing, above the controls area. Shown
            // only while the controls are down (they have their own affordances)
            // and no other overlay owns the bottom edge.
            if vm.phase == .playing && vm.skipIntroVisible && !controlsVisible
                && !upNextVisible && !anyPickerOpen {
                SkipIntroPill {
                    vm.skipIntro()
                }
                .transition(.opacity)
            }

            // Non-blocking failover indicator — never intercepts touches, sits
            // above the video and below nothing else that matters (spec §3c).
            if vm.failoverNotice {
                FailoverNotice()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // Throw to TV outcome — same quiet top-pill spot as the failover
            // notice; auto-clears from the view model.
            if let notice = vm.throwToTvNotice {
                ThrowToTvPill(notice: notice)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.failoverNotice)
        .animation(.easeInOut(duration: 0.2), value: vm.skipIntroVisible)
        .animation(.easeInOut(duration: 0.2), value: vm.throwToTvNotice)
    }

    private var streamPicker: some View {
        StreamPickerSheet(streams: vm.streams, currentUrl: vm.currentStreamUrl,
            blockedGroupsPresent: !vm.blockedGroups.isEmpty,
            onOpenPlaybackOptions: { activePicker = .options }) { option in
            activePicker = nil
            vm.switchStream(option)
        }
    }

    private var playbackWithPickers: some View {
        playbackSurface
        .confirmationDialog("Send to TV", isPresented: Binding(
            get: { !vm.tvReceivers.isEmpty },
            set: { if !$0 && !vm.tvReceivers.isEmpty { vm.cancelTvHandoff() } }
        ), titleVisibility: .visible) {
            ForEach(vm.tvReceivers) { receiver in
                Button(receiver.name) { vm.sendToTv(receiver) }
            }
            Button("Cancel", role: .cancel) { vm.cancelTvHandoff() }
        } message: {
            Text("Choose an awake TV with Velvet open.")
        }
        .sheet(item: $activePicker) { picker in
            switch picker {
            case .streams: streamPicker
            case .options: PlaybackOptionsSheet(vm: vm)
            }
        }
    }

    var body: some View {
        playbackWithPickers
        .onChange(of: vm.phase) { _, phase in
            // Show controls briefly when playback starts so the UI is discoverable.
            if phase == .playing { showControls() }
            if activePicker != nil { vm.setSourcePickerOpen(true) }
        }
        .onChange(of: activePicker) { _, picker in vm.setSourcePickerOpen(picker != nil) }
        .onChange(of: upNextVisible) { _, visible in
            // Hide controls while an Up Next overlay is on screen.
            if visible { setControls(false) }
        }
        .onChange(of: anyPickerOpen) { _, open in
            // Closing a picker returns to the controls (the user came from there)
            // and restarts the auto-hide clock.
            if !open && vm.phase == .playing { showControls() }
        }
        .onChange(of: vm.queueAdvanceRequested) { _, reason in
            guard let reason else { return }
            vm.teardown()
            onAdvanceQueue?(reason)
        }
        .onChange(of: vm.queuePlaybackHealthy) { _, healthy in
            if healthy { onQueueHealthy?() }
        }
        .onChange(of: vm.shouldDismiss) { _, should in
            if should { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Pause + persist when the app leaves the foreground.
            if phase == .background { vm.onHostStop() }
            if phase == .active { vm.onHostResume() }
        }
        // Auto-hide 4s after the last interaction, only while actually playing;
        // open pickers pause the clock (same semantics as the Android screen).
        .task(id: AutoHideKey(visible: controlsVisible, stamp: interactionStamp,
                              playing: vm.isPlaying, pickerOpen: anyPickerOpen)) {
            guard controlsVisible, vm.isPlaying, !anyPickerOpen else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            setControls(false)
        }
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch vm.phase {
        case .loading:
            PlayerLoadingOverlay(
                backdropUrl: vm.backdropUrl,
                showTitle: vm.showTitle,
                episodeLabel: vm.episodeLabel,
                onClose: closeAndDismiss
            )
        case .error:
            VStack(spacing: 12) {
            PlayerErrorOverlay(
                backdropUrl: vm.backdropUrl,
                message: vm.errorMessage ?? "Something went wrong.",
                canChooseStream: vm.canChooseStream,
                streamActionLabel: needsBlockReset ? "Playback options" : "Choose stream",
                onRetry: { vm.retry() },
                onChooseStream: { activePicker = needsBlockReset ? .options : .streams },
                onClose: closeAndDismiss
            )
            if vm.queuePlayback != nil && vm.hasNext {
                Button("Skip to next item") { vm.playNextEpisode() }
                    .buttonStyle(PlayerPrimaryButtonStyle())
                    .padding(.bottom, 24)
            }
            }
        case .playing:
            if vm.isBuffering && !controlsVisible && !upNextVisible {
                PlayerSpinner()
            }
            if controlsVisible {
                PlayerControls(
                    vm: vm,
                    onClose: closeAndDismiss,
                    onOpenPlaybackOptions: {
                        activePicker = .options
                        setControls(false)
                    },
                    onOpenStreamPicker: {
                        activePicker = .streams
                        setControls(false)
                    },
                    onInteraction: {
                        interactionStamp = Date()
                    },
                    onBackgroundTap: { setControls(false) }
                )
                .transition(.opacity)
            }
            if upNextVisible && !anyPickerOpen {
                UpNextOverlay(
                    upNext: vm.upNext,
                    fallbackImageUrl: vm.backdropUrl,
                    onPlayNext: {
                        vm.playNextEpisode()
                    },
                    onWatchCredits: {
                        vm.watchCredits()
                    },
                    onBackToDetails: {
                        // Exit path — push the position immediately (spec §2).
                        vm.saveProgressNow(flushSync: true)
                        dismiss()
                    }
                )
            }
        }
    }

    // MARK: helpers

    private func closeAndDismiss() {
        // Exit path — the write the phone → TV hand-off depends on (spec §2).
        vm.saveProgressNow(flushSync: true)
        dismiss()
    }

    private func toggleControls() {
        if controlsVisible {
            setControls(false)
        } else {
            showControls()
        }
    }

    private func showControls() {
        interactionStamp = Date()
        setControls(true)
    }

    private func setControls(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            controlsVisible = visible
        }
    }
}

// MARK: - Loading / error overlays

/// Dimmed backdrop shared by the loading and error states.
private struct PlayerBackdrop: View {
    let url: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                CardArtwork(url: url)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(0.65)
                Color.black.opacity(0.6)
            }
        }
        .ignoresSafeArea()
    }
}

/// "Trying another source…" — a small pill at the top of the player while a
/// dead stream is swapped for the next healthy candidate in place. Deliberately
/// tiny and non-modal: playback is still happening behind it.
private struct FailoverNotice: View {
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(VelvetColors.textSecondary)
                    .scaleEffect(0.7)
                Text("Trying another source…")
                    .font(VelvetFont.body(13, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(VelvetColors.surfaceElevated.opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }
}

/// Tappable "Skip Intro" pill, bottom-trailing while playback is inside a known
/// intro (marker from the velvet-sync /segments endpoint). Accent-tinted — the
/// one pill that IS the control, unlike the informational notices above.
private struct SkipIntroPill: View {
    let action: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button(action: action) {
                    Text("Skip Intro")
                        .font(VelvetFont.body(13, .semibold))
                        .foregroundStyle(VelvetColors.background)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(VelvetColors.accent))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 24)
        .padding(.bottom, 44)
    }
}

/// Pending/acknowledged TV handoff status, above the playing video.
private struct ThrowToTvPill: View {
    let notice: ThrowToTvNotice

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: notice.isSuccess ? "checkmark.circle.fill" : (notice.isPending ? "tv" : "wifi.exclamationmark"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(notice.isSuccess ? VelvetColors.accent : VelvetColors.textSecondary)
                Text(notice.message)
                    .font(VelvetFont.body(13, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(VelvetColors.surfaceElevated.opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }
}

private struct PlayerSpinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(VelvetColors.accent)
            .scaleEffect(1.6)
    }
}

private struct PlayerLoadingOverlay: View {
    let backdropUrl: URL?
    let showTitle: String
    let episodeLabel: String?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            PlayerBackdrop(url: backdropUrl)
            VStack(spacing: 0) {
                if !showTitle.isEmpty {
                    Text(showTitle)
                        .font(VelvetFont.display(24, .semibold))
                        .foregroundStyle(VelvetColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let episodeLabel {
                        Text(episodeLabel)
                            .font(VelvetFont.body(15))
                            .foregroundStyle(VelvetColors.textSecondary)
                            .lineLimit(1)
                            .padding(.top, 4)
                    }
                    Spacer().frame(height: 28)
                }
                PlayerSpinner()
                Text("Finding the best stream…")
                    .font(VelvetFont.body(15))
                    .foregroundStyle(VelvetColors.textSecondary)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 48)
        }
        .overlay(alignment: .topLeading) {
            PlayerIconButton(systemName: "xmark", action: onClose)
                .padding(.leading, 16)
                .padding(.top, 8)
        }
    }
}

private struct PlayerErrorOverlay: View {
    let backdropUrl: URL?
    let message: String
    let canChooseStream: Bool
    let streamActionLabel: String
    let onRetry: () -> Void
    let onChooseStream: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            PlayerBackdrop(url: backdropUrl)
            VStack(spacing: 0) {
                Text("Playback problem")
                    .font(VelvetFont.display(24, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
                Text(message)
                    .font(VelvetFont.body(14))
                    .foregroundStyle(VelvetColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                HStack(spacing: 14) {
                    Button("Retry", action: onRetry)
                        .buttonStyle(PlayerPrimaryButtonStyle())
                    if canChooseStream {
                        Button(streamActionLabel, action: onChooseStream)
                            .buttonStyle(PlayerSecondaryButtonStyle())
                    }
                    Button("Close", action: onClose)
                        .buttonStyle(PlayerSecondaryButtonStyle())
                }
                .padding(.top, 26)
            }
            .padding(.horizontal, 64)
        }
        .overlay(alignment: .topLeading) {
            PlayerIconButton(systemName: "xmark", action: onClose)
                .padding(.leading, 16)
                .padding(.top, 8)
        }
    }
}
