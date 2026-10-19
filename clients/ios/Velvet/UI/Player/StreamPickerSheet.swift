import SwiftUI

/// A focused source list: format, size, and the source currently playing.
/// Playback preferences live in PlaybackOptionsSheet.
struct StreamPickerSheet: View {
    let streams: [StreamOption]
    let currentUrl: URL?
    let blockedGroupsPresent: Bool
    let onOpenPlaybackOptions: (() -> Void)?
    let onPick: (StreamOption) -> Void
    @Environment(\.dismiss) private var dismiss

    init(streams: [StreamOption], currentUrl: URL?, blockedGroupsPresent: Bool = false,
         onOpenPlaybackOptions: (() -> Void)? = nil, onPick: @escaping (StreamOption) -> Void) {
        self.streams = streams
        self.currentUrl = currentUrl
        self.blockedGroupsPresent = blockedGroupsPresent
        self.onOpenPlaybackOptions = onOpenPlaybackOptions
        self.onPick = onPick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if streams.isEmpty {
                            emptyState
                        }
                        ForEach(streams) { stream in
                            row(stream).id(stream.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .onAppear {
                    if let current = streams.first(where: { $0.url == currentUrl }) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VelvetColors.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose stream")
                    .font(VelvetFont.display(20, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
                Text(streams.count == 1 ? "1 stream available" : "\(streams.count) streams available")
                    .font(VelvetFont.body(12))
                    .foregroundStyle(VelvetColors.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Close") { dismiss() }
                .font(VelvetFont.body(13, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule().fill(VelvetColors.surfaceHighlight))
                .buttonStyle(.plain)
                .accessibilityIdentifier("streamPickerClose")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var emptyState: some View {
        Text(blockedGroupsPresent ? "No unblocked streams available." : "No streams to choose from.")
            .font(VelvetFont.body(14))
            .foregroundStyle(VelvetColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        if blockedGroupsPresent, let onOpenPlaybackOptions {
            Button(action: onOpenPlaybackOptions) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Playback options").font(VelvetFont.body(14, .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(VelvetColors.textPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 10).fill(VelvetColors.surfaceElevated))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("streamPickerPlaybackOptions")
        }
    }

    private func row(_ stream: StreamOption) -> some View {
        let isCurrent = stream.url == currentUrl
        return Button { onPick(stream) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if StreamTagChipRow.buildChips(title: stream.title, quality: stream.quality).isEmpty {
                        Text("Stream")
                            .font(VelvetFont.body(14, .medium))
                            .foregroundStyle(VelvetColors.textSecondary)
                    } else {
                        StreamTagChipRow(title: stream.title, quality: stream.quality)
                    }
                    if let size = formatStreamSize(stream.sizeBytes) {
                        Text(size)
                            .font(VelvetFont.body(11))
                            .foregroundStyle(VelvetColors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VelvetColors.match)
                        .accessibilityLabel("Currently playing")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(VelvetColors.surfaceElevated))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "12.3 GB" / "734 MB" — same thresholds as the Android player.
private func formatStreamSize(_ bytes: Int64?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
}
