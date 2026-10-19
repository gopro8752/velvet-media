import SwiftUI

/// Compact wrapping row of pretty release tags for a stream-picker tile — the
/// touch twin of the Android `StreamTagChipRow`.
///
/// Give it the raw `StreamOption.title` and its `quality`; it parses, folds the
/// old quality badge into the RESOLUTION chip, and wraps chips onto multiple
/// short lines. RESOLUTION and HDR chips are accent-emphasized; the rest are
/// neutral surface chips. If nothing parses and no `quality` is known, it falls
/// back to a two-line trimmed title so the tile is never blank.
struct StreamTagChipRow: View {
    let title: String
    let quality: String?

    var body: some View {
        let chips = Self.buildChips(title: title, quality: quality)
        if chips.isEmpty {
            Text(Self.trimmedTitle(title))
                .font(VelvetFont.body(14, .semibold))
                .foregroundStyle(VelvetColors.textPrimary)
                .lineLimit(2)
        } else {
            FlowLayout(hSpacing: 6, vSpacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, tag in
                    TagChip(tag: tag)
                }
            }
        }
    }

    /// Parsed tags, with the quality badge folded in as a RESOLUTION chip when
    /// the title carried no resolution but `StreamOption.quality` is known.
    static func buildChips(title: String, quality: String?) -> [ReleaseTag] {
        let tags = StreamTags.parse(title)
        let hasResolution = tags.contains { $0.kind == .resolution }
        if hasResolution { return tags }
        guard let quality, !quality.isEmpty,
              let label = qualityToResolutionLabel(quality) else { return tags }
        return [ReleaseTag(label: label, kind: .resolution)] + tags
    }

    /// Mirror of the parser's RESOLUTION mapping, for the StreamOption.quality field.
    static func qualityToResolutionLabel(_ quality: String) -> String? {
        switch quality.lowercased() {
        case "2160p", "4k", "uhd": return "4K"
        case "1080p", "fhd": return "1080p"
        case "720p": return "720p"
        case "480p": return "480p"
        default: return quality.uppercased()
        }
    }

    /// Fallback shown only when nothing parses: drop a trailing container extension.
    static func trimmedTitle(_ title: String) -> String {
        let exts: Set<String> = ["mkv", "mp4", "avi", "ts", "m2ts", "mov", "wmv"]
        if let dot = title.lastIndex(of: "."), dot != title.startIndex {
            let ext = title[title.index(after: dot)...].lowercased()
            if ext.count >= 1 && ext.count <= 4 && exts.contains(ext) {
                return String(title[..<dot])
            }
        }
        return title
    }
}

private struct TagChip: View {
    let tag: ReleaseTag

    var body: some View {
        Text(tag.label)
            .font(VelvetFont.body(11, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(background))
    }

    private var emphasized: Bool { tag.kind == .resolution || tag.kind == .hdr }

    private var background: Color {
        switch tag.kind {
        case .resolution: return VelvetColors.accentDeep.opacity(0.35)
        case .hdr: return VelvetColors.accent.opacity(0.30)
        default: return VelvetColors.surfaceHighlight
        }
    }

    private var foreground: Color {
        emphasized ? VelvetColors.textPrimary : VelvetColors.textSecondary
    }
}

/// Minimal wrap layout (iOS 16+ `Layout`): lays chips left-to-right, wrapping to
/// the next line when the next chip would overflow the proposed width.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + vSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - hSpacing)
        }
        let width = proposal.width ?? widest
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + vSpacing
                x = 0
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
