import Foundation
#if os(tvOS)
import AVFoundation
#endif

/// The native VLC 3.x renderer does not establish a Dolby Vision output path.
/// Device AVPlayer capabilities alone must not be mistaken for VLC capability.
/// Filename labels cannot prove a compatible Dolby base layer, so tagged DV
/// requires an alternate release until verified profile metadata is available.
struct TVVideoCompatibility: Equatable {
    let hdr10: Bool
    let hlg: Bool

    func supports(title: String) -> Bool {
        let range = StreamTags.parse(title).first { $0.kind == .hdr }?.label
        switch range {
        case "Dolby Vision": return false
        case "HDR10+", "HDR10", "HDR": return hdr10
        default:
            if title.range(of: #"(?<![a-z0-9])hlg(?![a-z0-9])"#, options: [.regularExpression, .caseInsensitive]) != nil { return hlg }
            return true
        }
    }

    static func isDolbyCodec(_ code: String) -> Bool {
        ["dvhe", "dvh1", "dvav", "dva1"].contains(code.lowercased())
    }

    #if os(tvOS)
    static var connectedDisplay: TVVideoCompatibility {
        // eligibleForHDRPlayback replaces this API in tvOS 26, but collapses all
        // formats into one Boolean. Keep the format-level query for safe HLG/PQ
        // selection on the tvOS 17+ target; it still reports connected displays.
        let modes = AVPlayer.availableHDRModes
        return .init(hdr10: modes.contains(.hdr10), hlg: modes.contains(.hlg))
    }
    #endif
}
