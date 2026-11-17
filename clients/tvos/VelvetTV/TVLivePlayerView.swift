import AVFoundation
import SwiftUI

struct TVLivePlayerView: View {
    let channel: LiveChannel
    var channels: [LiveChannel] = []
    var client: LiveTVServing? = nil
    var telemetryKind = "live_tv"
    @EnvironmentObject private var container: AppContainer
    @State private var model: LivePlayerViewModel?

    var body: some View {
        Group {
            if let model { TVLivePlayerScreen(vm: model, channels: channels) }
            else { ZStack { Color.black; ProgressView() }.ignoresSafeArea() }
        }
        .onAppear {
            guard model == nil else { return }
            model = LivePlayerViewModel(channel: channel, client: client ?? container.liveTV,
                hardwareDecoding: container.settings.hardwareDecoding, settings: container.settings,
                telemetryKind: telemetryKind)
        }
        .onDisappear { model?.teardown() }
    }
}

private struct TVLivePlayerScreen: View {
    @ObservedObject var vm: LivePlayerViewModel
    let channels: [LiveChannel]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: String?
    @State private var controls = true
    @State private var interaction = Date()
    @State private var picker: Picker?
    private enum Picker: String { case channels, audio, subtitles }
    private struct HideKey: Equatable {
        let controls: Bool
        let playing: Bool
        let picker: Picker?
        let interaction: Date
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = vm.fairPlayEngine {
                FairPlayLiveVideoSurface(engine: engine).id(ObjectIdentifier(engine)).ignoresSafeArea()
            } else if let engine = vm.engine {
                PlayerVideoSurface(engine: engine).id(ObjectIdentifier(engine)).ignoresSafeArea()
            }
            if !controls && picker == nil && vm.phase == .playing {
                Button { showControls() } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain).focused($focus, equals: "surface")
                    .accessibilityLabel("Show live controls").onMoveCommand { _ in showControls() }
            }
            if picker == nil {
                if controls || vm.phase != .playing { transport }
                if vm.phase != .playing { status }
            }
            if vm.buffering && !vm.paused && vm.phase == .playing { ProgressView().scaleEffect(1.4).allowsHitTesting(false) }
            if let picker { options(picker) }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: controls)
        .onAppear { vm.start() }
        .onDisappear { vm.teardown() }
        .onPlayPauseCommand { vm.togglePlayPause(); showControls() }
        .onExitCommand { if picker != nil { picker = nil; showControls() } else { vm.teardown(); dismiss() } }
        .onChange(of: focus) { _, _ in interaction = Date() }
        .onChange(of: vm.phase) { _, _ in showControls() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { vm.suspend() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began { vm.suspend() }
        }
        .task(id: HideKey(controls: controls, playing: vm.phase == .playing && !vm.paused, picker: picker, interaction: interaction)) {
            guard controls, vm.phase == .playing, !vm.paused, picker == nil else { return }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            controls = false; focus = "surface"
        }
    }

    private var transport: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 16) {
                Text(vm.channel.name).font(VelvetFont.display(34, .semibold))
                Spacer()
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text(vm.paused ? "PAUSED" : "LIVE").font(VelvetFont.body(21, .semibold)).tracking(2)
            }.padding(.horizontal, 72).padding(.top, 52).padding(.bottom, 60)
                .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            HStack(spacing: 24) {
                if vm.phase == .playing {
                    button(vm.paused ? "Play" : "Pause", vm.paused ? "play.fill" : "pause.fill", "play") { vm.togglePlayPause() }
                    button("Watch live", "dot.radiowaves.left.and.right", "edge") { vm.watchLive() }
                }
                if channels.count > 1 { button("Channels", "list.bullet", "channels") { picker = .channels } }
                Spacer()
                if !vm.audioOptions.isEmpty { button("Audio", "speaker.wave.2", "audio") { picker = .audio } }
                if !vm.subtitleOptions.isEmpty { button("Subtitles", "captions.bubble", "subtitles") { picker = .subtitles } }
            }.padding(.horizontal, 72).padding(.top, 90).padding(.bottom, 60)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }.focusSection()
    }

    private var status: some View {
        VStack(spacing: 26) {
            if vm.phase == .loading { ProgressView().scaleEffect(1.5) }
            Text(vm.message).font(VelvetFont.body(26)).multilineTextAlignment(.center).frame(maxWidth: 1000)
            HStack(spacing: 26) {
                if vm.phase == .failed || vm.phase == .suspended {
                    button(vm.phase == .suspended ? "Watch live" : "Retry", "arrow.clockwise", "retry") { vm.watchLive() }
                }
                button("Back", "chevron.left", "close") { vm.teardown(); dismiss() }
            }
        }.padding(60)
    }

    private func button(_ text: String, _ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button { interaction = Date(); action() } label: {
            Label(text, systemImage: symbol).font(VelvetFont.body(23, .semibold)).frame(minHeight: 34)
        }.buttonStyle(TVPlaybackButtonStyle()).focused($focus, equals: key)
            .accessibilityIdentifier("live.\(key)")
    }

    private func options(_ picker: Picker) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(picker.rawValue.capitalized).font(VelvetFont.display(34, .semibold))
                    Spacer()
                    Button("Done") { self.picker = nil; showControls() }.buttonStyle(TVPlaybackButtonStyle())
                }
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if picker == .channels {
                            ForEach(channels) { channel in
                                optionRow(channel.name, selected: channel.id == vm.channel.id) {
                                    vm.selectChannel(channel); self.picker = nil; showControls()
                                }
                            }
                        } else {
                            let tracks = picker == .audio ? vm.audioOptions : vm.subtitleOptions
                            ForEach(tracks) { track in
                                optionRow(track.label, selected: track.selected) {
                                    if picker == .audio { vm.selectAudio(track) } else { vm.selectSubtitle(track) }
                                    self.picker = nil; showControls()
                                }
                            }
                        }
                    }.padding(16)
                }.frame(maxHeight: 600)
            }.padding(44).frame(width: 940)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
                .overlay(RoundedRectangle(cornerRadius: 32).stroke(.white.opacity(0.18), lineWidth: 1))
        }.focusSection()
    }
    private func optionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(VelvetFont.body(24, .medium)).lineLimit(2)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill") }
            }.frame(maxWidth: .infinity, minHeight: 50)
        }.buttonStyle(TVPlaybackButtonStyle())
    }
    private func showControls() { controls = true; interaction = Date(); focus = "play" }
}
