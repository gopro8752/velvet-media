import Foundation

/// A source-provided continuity key. The label is display-only; matching uses its exact key.
struct ReleaseGroup: Codable, Hashable, Identifiable {
    let key: String
    let label: String
    var id: String { key }
}

enum ReleaseGroupBlocks {
    // Keep in parity with Android's ReleaseGroupBlocks.kt. These are known backend
    // fallback tokens, not evidence that every release belongs to the same group.
    private static let unidentifiedVelvetGroups: Set<String> = [
        "", "rls", "unknown", "none", "null", "mkv", "mp4", "avi", "mov", "ts", "m2ts",
        "web", "dl", "hd", "ma", "bluray", "webrip", "hdtv", "remux", "proper", "repack",
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "aac", "ac3", "eac3",
        "dts", "truehd", "atmos", "hdr", "hdr10", "dv", "2160p", "1080p", "720p", "480p",
    ]

    /// Custom addon keys remain opaque, case-sensitive identities. Never derive
    /// a group from the configured source name or guess from a display filename.
    static func group(bingeGroup: String?) -> ReleaseGroup? {
        guard let identifier = bingeGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty, identifier.utf16.count <= 512,
              !identifier.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) })
        else { return nil }
        let label: String
        if identifier.hasPrefix("velvet-") {
            label = String(identifier.dropFirst("velvet-".count))
            guard !unidentifiedVelvetGroups.contains(label.lowercased()) else { return nil }
        } else {
            label = identifier
        }
        return ReleaseGroup(key: identifier, label: label)
    }
}

extension StreamOption {
    func releaseGroupForBlocking() -> ReleaseGroup? {
        ReleaseGroupBlocks.group(bingeGroup: bingeGroup)
    }

    /// The caller supplies only the current show's stored groups.
    func isReleaseGroupBlocked(_ groups: [ReleaseGroup]) -> Bool {
        guard let group = releaseGroupForBlocking() else { return false }
        return groups.contains { $0.key == group.key }
    }
}
