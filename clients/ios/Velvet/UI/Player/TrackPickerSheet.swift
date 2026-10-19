import SwiftUI

/// Subtitle / audio track picker sheet — the touch twin of the Android
/// TrackPickerSheet. Lists VLC track names; the active track is accented with a
/// checkmark; "Off" (index -1) is the first subtitle entry. Selecting applies
/// immediately (the caller closes the sheet).
struct TrackPickerSheet: View {
    let title: String
    let options: [TrackOption]
    let onPick: (TrackOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if options.isEmpty {
                Text("No tracks available.")
                    .font(VelvetFont.body(14))
                    .foregroundStyle(VelvetColors.textSecondary)
                    .padding(.horizontal, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(options) { option in
                            row(option)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(VelvetFont.display(20, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
            let trackCount = options.filter { $0.index >= 0 }.count
            Text(trackCount == 1 ? "1 track" : "\(trackCount) tracks")
                .font(VelvetFont.body(12))
                .foregroundStyle(VelvetColors.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private func row(_ option: TrackOption) -> some View {
        Button {
            onPick(option)
        } label: {
            HStack(spacing: 10) {
                Text(option.label)
                    .font(VelvetFont.body(14, .semibold))
                    .foregroundStyle(option.selected ? VelvetColors.accent : VelvetColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if option.selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(VelvetColors.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 10).fill(VelvetColors.surfaceElevated))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
