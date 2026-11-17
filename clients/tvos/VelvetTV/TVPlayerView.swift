import AVFoundation
import SwiftUI

/// A remote-first surface around Velvet's shared playback/recovery pipeline.
struct TVPlayerView: View {
    let target: PlayTarget
    var queuePlayback: CategoryQueuePlayback? = nil
    var queuePrefetch: CategoryQueuePrefetch? = nil
    var onAdvanceQueue: ((CategoryQueueAdvance) -> Void)? = nil
    var onQueueHealthy: (() -> Void)? = nil
    @EnvironmentObject private var container: AppContainer
    @State private var model: PlayerViewModel?

    var body: some View {
        Group {
            if let model {
                TVPlayerScreen(vm: model, onAdvanceQueue: onAdvanceQueue, onQueueHealthy: onQueueHealthy)
            } else {
                ZStack { Color.black; ProgressView() }.ignoresSafeArea()
            }
        }
        .onAppear {
            guard model == nil else { return }
            model = PlayerViewModel(target: target, tmdb: container.tmdb, streamRepo: container.streams,
                settings: container.settings, playback: container.playback, companion: container.companion,
                queuePlayback: queuePlayback, queuePrefetch: queuePrefetch)
        }
        .onDisappear { model?.teardown() }
    }
}

private struct TVPlayerScreen: View {
    @ObservedObject var vm: PlayerViewModel
    let onAdvanceQueue: ((CategoryQueueAdvance) -> Void)?
    let onQueueHealthy: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: String?
    @State private var controls = true
    @State private var interaction = Date()
    @State private var panel: TVPlaybackPanel?

    private struct HideKey: Equatable {
        let controls: Bool
        let playing: Bool
        let panel: TVPlaybackPanel?
        let interaction: Date
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if vm.currentStreamUrl != nil {
                PlayerVideoSurface(engine: vm.engine).ignoresSafeArea()
            } else if let url = vm.backdropUrl {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    .ignoresSafeArea().opacity(0.35)
            }
            if vm.phase == .playing {
                if !controls && panel == nil {
                    Button { showControls() } label: { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain).focused($focus, equals: "surface")
                        .accessibilityLabel("Show playback controls")
                        .onMoveCommand { _ in showControls() }
                }
                if controls && panel == nil { transport.transition(.opacity.combined(with: .move(edge: .bottom))) }
                if vm.isBuffering { ProgressView().tint(.white).scaleEffect(1.4).allowsHitTesting(false) }
            } else if panel == nil { status }
            if panel == nil { upNext }
            if vm.failoverNotice {
                VStack {
                    Label("Trying another source", systemImage: "arrow.triangle.2.circlepath")
                        .font(VelvetFont.body(21, .medium)).padding(.horizontal, 24).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }.padding(.top, 50).allowsHitTesting(false)
            }
            if let panel {
                TVPlaybackPanelView(vm: vm, panel: panel, change: { self.panel = $0 }, close: closePanel)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .foregroundStyle(VelvetColors.textPrimary)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: controls)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: panel)
        .onPlayPauseCommand { vm.togglePlayPause(); showControls() }
        .onExitCommand {
            if panel == .audio || panel == .subtitles { panel = .options }
            else if panel != nil { closePanel() }
            else { close() }
        }
        .onChange(of: focus) { _, _ in interaction = Date() }
        .onChange(of: vm.phase) { _, phase in if phase == .playing { showControls() } }
        .onChange(of: panel) { _, value in vm.setSourcePickerOpen(value != nil) }
        .onChange(of: vm.queueAdvanceRequested) { _, reason in
            guard let reason else { return }; vm.teardown(); onAdvanceQueue?(reason)
        }
        .onChange(of: vm.queuePlaybackHealthy) { _, healthy in if healthy { onQueueHealthy?() } }
        .onChange(of: vm.shouldDismiss) { _, value in if value { dismiss() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.onHostStop() }
            if phase == .active { vm.onHostResume() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began { vm.onHostStop() }
        }
        .task(id: HideKey(controls: controls, playing: vm.isPlaying, panel: panel, interaction: interaction)) {
            guard controls, vm.isPlaying, panel == nil else { return }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            controls = false; focus = "surface"
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        if let queue = vm.queuePlayback {
                            Text("\(queue.title) · \(queue.index + 1) of \(queue.count)")
                                .font(VelvetFont.body(20, .medium)).foregroundStyle(VelvetColors.textSecondary)
                        }
                        Text(vm.showTitle).font(VelvetFont.display(36, .semibold)).lineLimit(1)
                        if let label = vm.episodeLabel { Text(label).font(VelvetFont.body(22)).foregroundStyle(VelvetColors.textSecondary) }
                    }
                    Spacer()
                    if vm.skipIntroVisible { action("Skip intro", "forward.end", key: "intro") { vm.skipIntro() } }
                }
                TVPlaybackTimeline(position: vm.positionMs, duration: vm.durationMs) { vm.seekBy($0); interaction = Date() }
                HStack(spacing: 20) {
                    action("Back 10 seconds", "gobackward.10", key: "rewind", iconOnly: true) { vm.seekBy(-10_000) }
                    if vm.hasPrevious { action("Previous episode", "backward.end.fill", key: "previous", iconOnly: true) { vm.playPreviousEpisode() } }
                    action(vm.playbackButtonShowsPause ? "Pause" : "Play", vm.playbackButtonShowsPause ? "pause.fill" : "play.fill", key: "play", iconOnly: true) { vm.togglePlayPause() }
                    if vm.hasNext { action("Next episode", "forward.end.fill", key: "next", iconOnly: true) { vm.playNextEpisode() } }
                    action("Forward 10 seconds", "goforward.10", key: "forward", iconOnly: true) { vm.seekBy(10_000) }
                    Spacer()
                    action("Streams", "rectangle.stack", key: "streams") { panel = .streams }
                    action("Options", "slider.horizontal.3", key: "options") { panel = .options }
                }
            }
            .padding(.horizontal, 72).padding(.top, 100).padding(.bottom, 56)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75), .black.opacity(0.94)], startPoint: .top, endPoint: .bottom))
        }.focusSection()
    }

    private func action(_ title: String, _ icon: String, key: String, iconOnly: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button { interaction = Date(); action() } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 26, weight: .medium))
                if !iconOnly { Text(title).font(VelvetFont.body(22, .semibold)) }
            }.frame(minWidth: iconOnly ? 44 : 0, minHeight: 38)
        }
        .buttonStyle(TVPlaybackButtonStyle()).focused($focus, equals: key)
        .accessibilityLabel(title).accessibilityIdentifier("player.\(key)")
    }

    private var status: some View {
        VStack(spacing: 24) {
            if vm.phase == .loading {
                ProgressView().scaleEffect(1.5).padding(.bottom, 12)
                Text(vm.showTitle.isEmpty ? "Getting your stream ready" : vm.showTitle)
                    .font(VelvetFont.display(36, .semibold))
                if let label = vm.episodeLabel { Text(label).font(VelvetFont.body(24)).foregroundStyle(VelvetColors.textSecondary) }
            } else {
                Text("Playback problem").font(VelvetFont.display(36, .semibold))
                Text(vm.errorMessage ?? "This source could not play.").font(VelvetFont.body(23))
                    .multilineTextAlignment(.center).frame(maxWidth: 1000)
            }
            HStack(spacing: 24) {
                if vm.phase == .error {
                    action("Retry", "arrow.clockwise", key: "retry") { vm.retry() }
                    if vm.canChooseStream { action("Streams", "rectangle.stack", key: "errorStreams") { panel = .streams } }
                    if vm.queuePlayback != nil && vm.hasNext { action("Play next", "forward.end.fill", key: "skip") { vm.playNextEpisode() } }
                }
                action("Back", "chevron.left", key: "back") { close() }
            }
        }.padding(80)
    }

    @ViewBuilder private var upNext: some View {
        switch vm.upNext {
        case .hidden: EmptyView()
        case .countdown(let next, let remaining, _):
            upNextCard(next: next, detail: "Playing in \(remaining) seconds", credits: true)
        case .endChoice(let next):
            upNextCard(next: next, detail: "Up next", credits: false)
        }
    }

    private func upNextCard(next: NextEpisodeUi, detail: String, credits: Bool) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    Text(detail.uppercased()).font(VelvetFont.body(18, .semibold)).tracking(2).foregroundStyle(VelvetColors.accent)
                    Text(next.showTitle ?? vm.showTitle).font(VelvetFont.display(26, .semibold)).lineLimit(1)
                    Text(next.season > 0 ? "S\(next.season) E\(next.episode) · \(next.title)" : next.title)
                        .font(VelvetFont.body(21)).foregroundStyle(VelvetColors.textSecondary).lineLimit(2)
                    HStack(spacing: 20) {
                        action("Play next", "play.fill", key: "upNext") { vm.playNextEpisode() }
                        if credits { action("Watch credits", "film", key: "credits") { vm.watchCredits() } }
                        else { action("Back", "chevron.left", key: "endBack") { close() } }
                    }
                }.padding(30).frame(width: 690, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30))
                    .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.16), lineWidth: 1))
            }
        }.padding(.horizontal, 72).padding(.bottom, controls ? 330 : 60)
    }

    private func showControls() { controls = true; interaction = Date(); focus = "play" }
    private func closePanel() { panel = nil; showControls() }
    private func close() { vm.saveProgressNow(flushSync: true); vm.teardown(); dismiss() }
}

enum TVPlaybackPanel: String, Equatable { case streams, options, audio, subtitles }

private struct TVPlaybackPanelView: View {
    @ObservedObject var vm: PlayerViewModel
    @FocusState private var doneFocused: Bool
    let panel: TVPlaybackPanel
    let change: (TVPlaybackPanel) -> Void
    let close: () -> Void
    var title: String {
        switch panel { case .streams: "Choose a stream"; case .options: "Playback options"; case .audio: "Audio"; case .subtitles: "Subtitles" }
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(title).font(VelvetFont.display(36, .semibold))
                    Spacer()
                    Button("Done", action: close).buttonStyle(TVPlaybackButtonStyle()).focused($doneFocused)
                }
                if let error = vm.groupActionError { Text(error).font(VelvetFont.body(20)).foregroundStyle(VelvetColors.gold) }
                ScrollView {
                    LazyVStack(spacing: 18) {
                        switch panel {
                        case .streams:
                            if vm.streams.isEmpty {
                                Text("No unblocked streams are available.").font(VelvetFont.body(23))
                                option("Playback options", "Reset blocked releases", "slider.horizontal.3") { change(.options) }
                            }
                            ForEach(Array(vm.streams.enumerated()), id: \.element.id) { index, stream in
                                option(TVPlaybackFormatting.sourceDescription(stream, index: index),
                                       TVPlaybackFormatting.size(stream.sizeBytes),
                                       stream.url == vm.currentStreamUrl ? "checkmark.circle.fill" : "rectangle.stack") {
                                    vm.switchStream(stream); close()
                                }
                            }
                        case .options:
                            option("Audio", vm.audioOptions.first(where: \.selected)?.label ?? "Not available", "speaker.wave.2") { change(.audio) }
                            option("Subtitles", vm.subtitleOptions.first(where: \.selected)?.label ?? "Off", "captions.bubble") { change(.subtitles) }
                            if vm.canBlockCurrentRelease {
                                option("Block this release", vm.isShow ? "For this show" : "For this movie", "minus.circle") { vm.blockCurrentRelease() }
                            }
                            if vm.hasBlockedReleases {
                                option("Reset blocked releases", vm.isShow ? "For this show" : "For this movie", "arrow.counterclockwise") { vm.resetBlockedReleases() }
                            }
                        case .audio, .subtitles:
                            let tracks = panel == .audio ? vm.audioOptions : vm.subtitleOptions
                            if tracks.isEmpty { Text("No tracks available.").font(VelvetFont.body(23)) }
                            ForEach(tracks) { track in
                                option(track.label, "", track.selected ? "checkmark.circle.fill" : panel == .audio ? "speaker.wave.2" : "captions.bubble") {
                                    if panel == .audio { vm.selectAudioTrack(id: track.index) } else { vm.selectSubtitleTrack(id: track.index) }
                                    change(.options)
                                }
                            }
                        }
                    }.padding(16)
                }.frame(maxHeight: 580)
            }.padding(44).frame(width: 1060)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 34))
                .overlay(RoundedRectangle(cornerRadius: 34).stroke(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        }.focusSection()
        .task(id: panel) {
            // Changing the options page removes its previously focused row.
            // Restore real focus so Menu stays inside this presentation.
            await Task.yield()
            doneFocused = true
        }
    }

    private func option(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Image(systemName: symbol).font(.system(size: 26)).frame(width: 32)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(VelvetFont.body(24, .semibold)).lineLimit(2)
                    if !detail.isEmpty { Text(detail).font(VelvetFont.body(19)).opacity(0.65).lineLimit(2) }
                }
                Spacer()
            }.frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        }.buttonStyle(TVPlaybackButtonStyle())
    }
}

struct TVPlaybackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVPlaybackButtonBody(configuration: configuration)
    }
    private struct TVPlaybackButtonBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label.padding(.horizontal, 22).padding(.vertical, 16)
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? Color.white : Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(focused ? 0.9 : 0.12), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.04 : 1)
                .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 20, y: 6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

struct TVPlaybackTimeline: View {
    let position: Int64
    let duration: Int64
    let seek: (Int64) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button { } label: {
            VStack(spacing: 10) {
                GeometryReader { bounds in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                        Capsule().fill(focused ? Color.white : VelvetColors.accent)
                            .frame(width: bounds.size.width * TVPlaybackFormatting.progress(position: position, duration: duration))
                    }
                }.frame(height: focused ? 9 : 6)
                HStack {
                    Text(TVPlaybackFormatting.time(position))
                    Spacer()
                    if focused { Text("← 10 seconds →").font(VelvetFont.body(17)) }
                    Spacer()
                    Text("−" + TVPlaybackFormatting.time(max(0, duration - position)))
                }.font(VelvetFont.body(20, .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TVPlaybackFormatting.time(position))
            .accessibilityAdjustableAction { direction in
                if direction == .increment { seek(10_000) }
                if direction == .decrement { seek(-10_000) }
            }
            .onMoveCommand { direction in
                if direction == .left { seek(-10_000) }
                if direction == .right { seek(10_000) }
            }
    }
}

enum TVPlaybackFormatting {
    static func progress(position: Int64, duration: Int64) -> Double {
        duration > 0 ? min(1, max(0, Double(position) / Double(duration))) : 0
    }
    static func time(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1_000
        return seconds >= 3_600 ? String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }
    static func sourceDescription(_ stream: StreamOption, index: Int) -> String {
        var tags = StreamTags.parse(stream.title).map(\.label)
        if !StreamTags.parse(stream.title).contains(where: { $0.kind == .resolution }), let quality = stream.quality, !quality.isEmpty {
            tags.insert(quality == "2160p" ? "4K" : quality, at: 0)
        }
        return tags.isEmpty ? "Stream \(index + 1)" : tags.joined(separator: " · ")
    }
    static func size(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
