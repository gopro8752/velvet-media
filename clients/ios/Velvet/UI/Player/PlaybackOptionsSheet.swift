import SwiftUI

/// One touch sheet for playback preferences. Nested track choices return here;
/// release identities remain implementation details rather than interface labels.
struct PlaybackOptionsSheet: View {
    @ObservedObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .root

    private enum Page: Equatable {
        case root, audio, subtitles
        var title: String {
            switch self {
            case .root: return "Playback options"
            case .audio: return "Audio"
            case .subtitles: return "Subtitles"
            }
        }
    }

    private var blockableStream: StreamOption? {
        guard vm.isShow, let stream = vm.playingStream,
              stream.releaseGroupForBlocking() != nil,
              !stream.isReleaseGroupBlocked(vm.blockedGroups) else { return nil }
        return stream
    }

    private var audioSelection: String {
        vm.audioOptions.first(where: \.selected)?.label ?? (vm.audioOptions.isEmpty ? "Not available" : "Default")
    }

    private var subtitleSelection: String {
        vm.subtitleOptions.first(where: \.selected)?.label ?? vm.subtitleLabel ?? "Off"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let error = vm.groupActionError, !error.isEmpty {
                        Text(error)
                            .font(VelvetFont.body(12))
                            .foregroundStyle(VelvetColors.gold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)
                    }
                    switch page {
                    case .root: rootOptions
                    case .audio: trackList(vm.audioOptions, isAudio: true)
                    case .subtitles: trackList(vm.subtitleOptions, isAudio: false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VelvetColors.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if page != .root {
                Button { page = .root } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(VelvetColors.surfaceHighlight))
                }
                .buttonStyle(.plain)
                .foregroundStyle(VelvetColors.textPrimary)
                .accessibilityLabel("Back to playback options")
                .accessibilityIdentifier("playbackOptionsBack")
            }
            Text(page.title)
                .font(VelvetFont.display(20, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Close") { dismiss() }
                .font(VelvetFont.body(13, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule().fill(VelvetColors.surfaceHighlight))
                .buttonStyle(.plain)
                .accessibilityIdentifier("playbackOptionsClose")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var rootOptions: some View {
        option("Audio", detail: audioSelection, symbol: "speaker.wave.2", navigates: true) { page = .audio }
            .accessibilityIdentifier("playbackOptionsAudio")
        option("Subtitles", detail: subtitleSelection, symbol: "captions.bubble", navigates: true) { page = .subtitles }
            .accessibilityIdentifier("playbackOptionsSubtitles")
        if let stream = blockableStream {
            option("Block this release", detail: "For this show only", symbol: "minus.circle") {
                vm.blockReleaseGroup(stream)
            }
            .accessibilityIdentifier("playbackOptionsBlockRelease")
            .padding(.top, 8)
        }
        if vm.isShow && !vm.blockedGroups.isEmpty {
            option("Reset blocked releases", detail: "For this show only", symbol: "arrow.counterclockwise") {
                // Capture identities first: each synchronous mutation publishes a
                // new list and must not change the collection being iterated.
                let keys = vm.blockedGroups.map(\.key)
                for key in keys { vm.unblockReleaseGroup(key) }
            }
            .accessibilityIdentifier("playbackOptionsResetReleases")
        }
    }

    private func option(_ title: String, detail: String, symbol: String,
                        navigates: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(VelvetColors.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(VelvetFont.body(14, .medium)).foregroundStyle(VelvetColors.textPrimary)
                    Text(detail).font(VelvetFont.body(12)).foregroundStyle(VelvetColors.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if navigates {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VelvetColors.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(VelvetColors.surfaceElevated))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func trackList(_ tracks: [TrackOption], isAudio: Bool) -> some View {
        if tracks.isEmpty {
            Text(isAudio ? "No audio tracks available." : "No subtitle tracks available.")
                .font(VelvetFont.body(14))
                .foregroundStyle(VelvetColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        }
        ForEach(tracks) { track in
            Button {
                if isAudio { vm.selectAudioTrack(id: track.index) }
                else { vm.selectSubtitleTrack(id: track.index) }
                page = .root
            } label: {
                HStack(spacing: 12) {
                    Text(track.label)
                        .font(VelvetFont.body(14, .medium))
                        .foregroundStyle(track.selected ? VelvetColors.accent : VelvetColors.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if track.selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(VelvetColors.accent)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(VelvetColors.surfaceElevated))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(track.selected ? .isSelected : [])
        }
    }
}
