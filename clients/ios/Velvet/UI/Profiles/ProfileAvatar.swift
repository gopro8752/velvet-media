import SwiftUI

/// Circular profile avatar (iOS form per the spec): a disc filled with the
/// profile's color carrying the name's first initial in TextPrimary. No image
/// upload in v1. A nil profile renders a neutral placeholder disc.
struct ProfileAvatar: View {
    let profile: Profile?
    var diameter: CGFloat = 84
    /// Optional white focus/selection ring (the picker's selected tile).
    var selected: Bool = false

    private var fill: Color {
        if let profile { return Color(hex: profile.color.profileColorHex) }
        return VelvetColors.surfaceHighlight
    }

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(
                Text(profile?.initial ?? "?")
                    .font(VelvetFont.display(diameter * 0.42, .semibold))
                    .foregroundStyle(VelvetColors.textPrimary)
            )
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .strokeBorder(VelvetColors.textPrimary,
                                  lineWidth: selected ? max(2, diameter * 0.035) : 0)
            )
            .overlay(
                // Subtle hairline so dark avatars don't vanish into the background.
                Circle().strokeBorder(VelvetColors.textPrimary.opacity(0.06), lineWidth: 0.5)
            )
    }
}
