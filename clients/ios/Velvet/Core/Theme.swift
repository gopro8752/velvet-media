import SwiftUI

/// Velvet palette — identical hex values to the Android app (ui/theme/Color.kt).
/// Dark cinematic: near-black blue base, iris-violet accent, gold ratings,
/// match-green progress.
enum VelvetColors {
    static let background = Color(hex: 0x0A0C12)
    static let surface = Color(hex: 0x11141C)
    static let surfaceElevated = Color(hex: 0x181C26)
    static let surfaceHighlight = Color(hex: 0x222736)

    static let textPrimary = Color(hex: 0xF2F4F8)
    static let textSecondary = Color(hex: 0x9BA3B4)
    static let textTertiary = Color(hex: 0x5F6878)

    static let accent = Color(hex: 0x8B7CF6)
    static let accentDeep = Color(hex: 0x5B47D6)
    static let gold = Color(hex: 0xF5C76B)
    static let match = Color(hex: 0x46D369)
    static let danger = Color(hex: 0xE0506A)

    static let cardPlaceholder = Color(hex: 0x161A24)

    // Overlay chrome drawn ON TOP of artwork/video — semantic entries so
    // component code never hardcodes .black/.white (a palette change must not
    // strand them). Values match the previous literals exactly.
    /// Bottom scrim over card artwork keeping progress bars/labels legible.
    static let scrim = Color.black.opacity(0.55)
    /// Inactive (unfilled) part of thin progress tracks over artwork.
    static let trackInactive = Color.white.opacity(0.25)
    /// Unfilled track of the Up Next countdown ring.
    static let ringTrack = Color.white.opacity(0.18)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

/// Outfit (display: titles, headers, buttons) + Inter (body, captions, meta) —
/// the same variable TTFs the Android app bundles. `.weight(...)` applies to
/// custom fonts on iOS 16+.
enum VelvetFont {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom("Outfit", size: size).weight(weight)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size).weight(weight)
    }
}
