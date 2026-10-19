import AVFoundation
import SwiftUI

struct LivePlayerView: View {
    @StateObject private var vm: LivePlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controlsVisible = true
    @State private var interaction = Date()
    @State private var picker: PickerKind?
    let channels: [LiveChannel]
    let onSelectChannel: (LiveChannel) -> Void

    private enum PickerKind: String, Identifiable { case channels, audio, subtitles; var id: String { rawValue } }
    private struct HideKey: Equatable {
        let visible: Bool
        let interaction: Date
        let playing: Bool
        let pickerOpen: Bool
    }

    init(channel: LiveChannel, channels: [LiveChannel], client: LiveTVServing,
         hardwareDecoding: Bool, settings: SettingsStore? = nil, onSelectChannel: @escaping (LiveChannel) -> Void) {
        _vm = StateObject(wrappedValue: LivePlayerViewModel(channel: channel, client: client,
                                                          hardwareDecoding: hardwareDecoding, settings: settings))
        self.channels = channels
        self.onSelectChannel = onSelectChannel
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = vm.fairPlayEngine {
                FairPlayLiveVideoSurface(engine: engine)
                    .id(ObjectIdentifier(engine))
                    .ignoresSafeArea()
            } else if let engine = vm.engine {
                PlayerVideoSurface(engine: engine)
                    .id(ObjectIdentifier(engine))
                    .ignoresSafeArea()
            }
            if vm.phase == .playing {
                Button { interaction = Date(); controlsVisible.toggle() } label: {
                    Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controlsVisible ? "Hide live TV controls" : "Show live TV controls")
                .accessibilityIdentifier("live.toggleControls")
            }
            if vm.phase != .playing { status }
            if controlsVisible || vm.phase != .playing { controls }
            if vm.buffering && vm.phase == .playing {
                ProgressView().tint(.white).allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { vm.start() }
        .onDisappear { vm.teardown() }
        .onChange(of: vm.phase) { _, _ in showControls() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { vm.suspend() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            vm.suspend()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began { vm.suspend() }
        }
        .sheet(item: $picker, onDismiss: showControls) { kind in
            switch kind {
            case .channels:
                channelPicker
            case .audio:
                TrackPickerSheet(title: "Audio", options: vm.audioOptions) {
                    vm.selectAudio($0); picker = nil
                }
            case .subtitles:
                TrackPickerSheet(title: "Subtitles", options: vm.subtitleOptions) {
                    vm.selectSubtitle($0); picker = nil
                }
            }
        }
        .task(id: HideKey(visible: controlsVisible, interaction: interaction,
                          playing: vm.phase == .playing, pickerOpen: picker != nil)) {
            guard controlsVisible, vm.phase == .playing, picker == nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 14) {
                PlayerIconButton(systemName: "xmark") { vm.teardown(); dismiss() }
                    .accessibilityLabel("Close live TV")
                    .accessibilityIdentifier("live.close")
                Text(vm.channel.name)
                    .font(VelvetFont.display(19, .semibold))
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("LIVE").font(VelvetFont.body(12, .semibold))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            HStack(spacing: 16) {
                if channels.count > 1 {
                    Button { showControls(); picker = .channels } label: {
                        Label("Channels", systemImage: "list.bullet")
                    }
                    .buttonStyle(PlayerSecondaryButtonStyle())
                    .accessibilityIdentifier("live.chooseChannel")
                }
                Spacer()
                if !vm.audioOptions.isEmpty {
                    PlayerIconButton(systemName: "waveform") { showControls(); picker = .audio }
                        .accessibilityLabel("Audio tracks")
                }
                if !vm.subtitleOptions.isEmpty {
                    PlayerIconButton(systemName: "captions.bubble") { showControls(); picker = .subtitles }
                        .accessibilityLabel("Subtitles")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white)
    }

    private var status: some View {
        VStack(spacing: 14) {
            if vm.phase == .loading { ProgressView().tint(VelvetColors.accent) }
            Text(vm.message)
                .font(VelvetFont.body(16))
                .multilineTextAlignment(.center)
                .foregroundStyle(VelvetColors.textPrimary)
            if vm.phase == .failed || vm.phase == .suspended {
                Button(vm.phase == .suspended ? "Watch live" : "Retry") { vm.watchLive() }
                    .buttonStyle(PlayerPrimaryButtonStyle())
                    .accessibilityIdentifier("live.retry")
            }
        }
        .padding(24)
        .frame(maxWidth: 500)
    }

    private var channelPicker: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(channels) { channel in
                        Button {
                            onSelectChannel(channel)
                            vm.selectChannel(channel)
                            picker = nil
                            showControls()
                        } label: {
                            LiveChannelCard(channel: channel, selected: channel.id == vm.channel.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Watch \(channel.name) live")
                    }
                }
                .padding(16)
            }
            .background(VelvetColors.background)
            .navigationTitle("Channels")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { picker = nil } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func showControls() {
        controlsVisible = true
        interaction = Date()
    }
}
