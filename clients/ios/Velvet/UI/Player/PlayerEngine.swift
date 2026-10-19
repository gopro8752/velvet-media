import Foundation
import SwiftUI
import UIKit
import ObjectiveC
import Darwin
// @preconcurrency: retired players are intentionally handed to a utility queue.
@preconcurrency import VLCKitSPM

/// VLCKit 3.6's stop() only requests an asynchronous native stop. Its queued
/// event/idle-timer blocks can keep the Objective-C wrapper alive, then release
/// its last reference on main. libvlc_media_player_release joins video/input
/// workers; those workers may themselves be waiting for UIKit on main.
///
/// Give the native player one independent reference, owned by an associated
/// object. Objective-C destroys associations *after* VLCMediaPlayer.dealloc has
/// released its native reference. Our extra reference is therefore always the
/// final one, and its potentially blocking release always happens off-main.
/// There is no timer, polling, permanent retention, or dependency on which queue
/// releases VLCKit's last event block.
private final class NativePlayerLifetime: NSObject {
    private typealias NativeRefFunction = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias NativePointerGetter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?

    private struct NativeReference: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        let release: NativeRefFunction
    }

    // These are exported by the pinned MobileVLCKit 3.6 binary. Its public
    // module deliberately excludes the C headers, so resolve the C ABI directly
    // rather than using Swift's underscored symbol/calling-convention features.
    private static let retainNative: NativeRefFunction = function("libvlc_media_player_retain")
    private static let releaseNative: NativeRefFunction = function("libvlc_media_player_release")
    private static var associationKey: UInt8 = 0
    private let native: NativeReference

    private static func function(_ name: String) -> NativeRefFunction {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            preconditionFailure("The bundled VLCKit must export \(name)")
        }
        return unsafeBitCast(symbol, to: NativeRefFunction.self)
    }

    private init(pointer: UnsafeMutableRawPointer) {
        Self.retainNative(pointer)
        native = NativeReference(pointer: pointer, release: Self.releaseNative)
        super.init()
    }

    static func protect(_ player: VLCMediaPlayer) {
        guard objc_getAssociatedObject(player, &associationKey) == nil else { return }
        // This is VLCKit's own LibVLCBridging getter, not an Apple private API.
        let selector = NSSelectorFromString("libVLCMediaPlayer")
        guard let method = class_getInstanceMethod(VLCMediaPlayer.self, selector) else {
            preconditionFailure("The bundled VLCKit must provide its native player bridge")
        }
        let getter = unsafeBitCast(method_getImplementation(method), to: NativePointerGetter.self)
        guard let pointer = getter(player, selector) else {
            preconditionFailure("VLCMediaPlayer must own a native player")
        }
        objc_setAssociatedObject(player, &associationKey, NativePlayerLifetime(pointer: pointer),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    deinit {
        let native = native
        DispatchQueue.global(qos: .utility).async {
            native.release(native.pointer)
        }
    }
}

/// A single embedded track (audio or subtitle) as VLC reports it.
/// `id` is the VLC track id used for selection (NOT a list position).
struct PlayerTrack: Hashable {
    let id: Int
    let name: String
    var codec: String? = nil
    var language: String? = nil
    var channelCount: Int? = nil
    var audioOrdinal: Int? = nil

    /// The bundled MobileVLCKit 3.6 decoder omits TrueHD/MLP. Channel count
    /// itself is not a limitation: supported 7.1 codecs still play normally.
    var needsAudioCompatibility: Bool { ["trhd", "mlp "].contains(codec ?? "") }
    var isAlternateDescription: Bool {
        ["commentary", "audio description", "descriptive", "visually impaired", "visually-impaired"]
            .contains { name.localizedCaseInsensitiveContains($0) }
    }
    static func languageKey(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty, value != "und" else { return nil }
        let aliases = ["en": "eng", "english": "eng", "fr": "fra", "fre": "fra", "french": "fra",
                       "de": "deu", "ger": "deu", "german": "deu", "es": "spa", "spanish": "spa",
                       "it": "ita", "italian": "ita", "ja": "jpn", "japanese": "jpn"]
        return aliases[value] ?? value
    }
    var isEnglish: Bool {
        Self.languageKey(language) == "eng"
            || name.localizedCaseInsensitiveContains("english")
            || name.range(of: #"\beng\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Keep the movie/release intact when it includes a playable version of the
/// same soundtrack. A foreign dub or commentary must not replace the requested
/// language merely because its codec is supported.
enum MobileAudioSelection {
    static func preferred(in tracks: [PlayerTrack], currentId: Int, manualName: String?) -> PlayerTrack? {
        if let manualName,
           let manual = tracks.first(where: { $0.name == manualName })
                ?? tracks.first(where: { $0.name.localizedCaseInsensitiveContains(manualName) }) {
            return manual
        }
        let main = tracks.filter { !$0.isAlternateDescription }
        guard let desired = main.first(where: \.isEnglish)
            ?? main.first(where: { $0.id == currentId }) ?? main.first ?? tracks.first else { return nil }
        guard desired.needsAudioCompatibility else { return desired }
        let sameLanguage = main.filter { candidate in
            if desired.isEnglish { return candidate.isEnglish }
            guard let language = PlayerTrack.languageKey(desired.language) else { return false }
            return PlayerTrack.languageKey(candidate.language) == language
        }
        return sameLanguage.first(where: { !$0.needsAudioCompatibility }) ?? desired
    }
}

/// Thin @MainActor wrapper around VLCMediaPlayer (MobileVLCKit 3.x).
/// Owns the player and the drawable UIView; the view model drives it.
/// VLC delegate callbacks can arrive on arbitrary threads — they hop to the
/// main actor before reaching `onStateChanged` / `onTimeChanged`.
@MainActor
final class PlayerEngine: NSObject, ObservableObject {

    private(set) var player = VLCMediaPlayer()

    /// The drawable host. `PlayerVideoSurface` mounts this in SwiftUI.
    let videoView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }()

    var onStateChanged: (@MainActor (VLCMediaPlayerState) -> Void)?
    var onTimeChanged: (@MainActor () -> Void)?

    private var tornDown = false
    private var nativeAudioIdsBeforeSlave: Set<Int>?
    var hasCompatibleAudio: Bool { nativeAudioIdsBeforeSlave != nil }
    var compatibleAudioTrackIds: Set<Int> {
        guard let native = nativeAudioIdsBeforeSlave else { return [] }
        return Set(audioTracks.map(\.id)).subtracting(native)
    }

    override init() {
        super.init()
        NativePlayerLifetime.protect(player)
        player.delegate = self
        player.drawable = videoView
    }

    // MARK: - Media + playback

    /// Replaces the current media in place (the autoplay-next swap path).
    /// hardwareDecoding == false adds the colon-prefixed per-media option
    /// ":avcodec-hw=none" (VLCMedia.h documents addOption as taking VLC
    /// command-line option strings; per-media options use the ":" prefix).
    func setMedia(url: URL, headers: [String: String], hardwareDecoding: Bool) {
        // Backstop: a late-running view-model task must never restart playback
        // on a torn-down engine (audio with no UI after the screen is gone).
        guard !tornDown else { return }
        replacePlayer()
        nativeAudioIdsBeforeSlave = nil
        let media = VLCMedia(url: url)
        if !hardwareDecoding {
            media.addOption(":avcodec-hw=none")
        }
        // Seek speed + network resilience (verified against libVLC 3.0.x):
        // input-fast-seek — core bool ("Favor speed over precision while
        // seeking"): land on the previous keyframe instead of decoding forward
        // to the exact target frame; that decode is the bulk of multi-second
        // seeks on high-bitrate 4K HEVC.
        media.addOption(":input-fast-seek")
        // network-caching — core int, ms (default 1000): the pts_delay VLC
        // refills after every seek flush before video resumes. 1500 buys WAN
        // jitter headroom for nzbdav at ~0.5s extra post-seek cost; do NOT
        // raise it casually — post-seek latency scales with it. (:http-reconnect
        // deliberately NOT added — the modern http module that serves our
        // streams ignores it; the progress watchdog moves to a fresh input.)
        media.addOption(":network-caching=1500")
        // libVLC 3.x only supports these request headers as per-media options;
        // anything else in StreamOption.headers cannot be applied and is skipped.
        for (key, value) in headers {
            switch key.lowercased() {
            case "user-agent":
                media.addOption(":http-user-agent=\(value)")
            case "referer", "referrer":
                media.addOption(":http-referrer=\(value)")
            default:
                break
            }
        }
        player.media = media
    }

    /// Retire the old input while the next source gets an independent player.
    /// NativePlayerLifetime also protects against queued VLCKit blocks being
    /// the retired wrapper's final owner after this utility closure returns.
    private func replacePlayer() {
        let retired = player
        retired.delegate = nil
        retired.drawable = nil
        player = VLCMediaPlayer()
        NativePlayerLifetime.protect(player)
        player.delegate = self
        player.drawable = videoView
        DispatchQueue.global(qos: .utility).async {
            retired.stop()
            retired.media = nil
        }
    }

    func stopPlayback() {
        guard !tornDown else { return }
        replacePlayer()
        nativeAudioIdsBeforeSlave = nil
    }

    func play() {
        guard !tornDown else { return }
        player.play()
    }

    func pause() { player.pause() }

    var stateNow: VLCMediaPlayerState { player.state }
    var isPlayingNow: Bool { player.isPlaying }

    /// Current position in milliseconds (VLCTime.value is ms).
    var positionMs: Int64 { player.time.value?.int64Value ?? 0 }

    /// Media length in milliseconds; 0 until VLC has determined it.
    var durationMs: Int64 { player.media?.length.value?.int64Value ?? 0 }

    /// Seek via the position fraction — the reliable path for network streams
    /// in VLC 3.x. Falls back to absolute time when the duration is unknown.
    func seek(toMs ms: Int64, durationMs: Int64) {
        if durationMs > 0 {
            let fraction = Double(ms) / Double(durationMs)
            player.position = Float(min(max(fraction, 0.0), 1.0))
        } else {
            player.time = VLCTime(number: NSNumber(value: ms))
        }
    }

    // MARK: - Tracks

    /// Embedded audio tracks. VLC includes a "Disabled" fake entry (id -1) in
    /// both the names and indexes arrays — it is dropped here.
    var audioTracks: [PlayerTrack] {
        let metadata = (player.media?.tracksInformation ?? []).compactMap { $0 as? [String: Any] }
            .filter { ($0[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeAudio }
        return tracks(names: player.audioTrackNames, ids: player.audioTrackIndexes).map { track in
            guard let ordinal = metadata.firstIndex(where: {
                ($0[VLCMediaTracksInformationId] as? NSNumber)?.intValue == track.id
            }) else { return track }
            let info = metadata[ordinal]
            var result = track
            if let fourCC = (info[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value {
                result.codec = String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: fourCC >> ($0 * 8)) }, encoding: .ascii)
            }
            result.language = info[VLCMediaTracksInformationLanguage] as? String
            result.channelCount = (info[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue
            result.audioOrdinal = ordinal
            return result
        }
    }

    var subtitleTracks: [PlayerTrack] {
        tracks(names: player.videoSubTitlesNames, ids: player.videoSubTitlesIndexes)
    }

    var currentAudioTrackId: Int { Int(player.currentAudioTrackIndex) }
    var currentSubtitleTrackId: Int { Int(player.currentVideoSubTitleIndex) }

    func selectAudioTrack(id: Int) {
        player.currentAudioTrackIndex = Int32(id)
    }

    /// VLC's WAV demuxer does not reset packet timestamps on a slave seek in
    /// 3.x. Its FFmpeg demuxer does; explicitly select it so the original video
    /// and converted soundtrack stay on the same timeline after any seek.
    func addCompatibleAudio(url: URL) -> Bool {
        guard !tornDown, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let separator = url.absoluteString.range(of: "://") else { return false }
        let mrl = scheme + "/avformat://" + url.absoluteString[separator.upperBound...]
        guard let slaveURL = URL(string: mrl) else { return false }
        if nativeAudioIdsBeforeSlave == nil { nativeAudioIdsBeforeSlave = Set(audioTracks.map(\.id)) }
        // Register without forcing selection: a user may change tracks while
        // VLC opens this URL. The view model selects only after its generation
        // and playback identity have been checked again.
        return player.addPlaybackSlave(slaveURL, type: .audio, enforce: false) == 0
    }

    /// Pass -1 to turn subtitles off.
    func selectSubtitleTrack(id: Int) {
        player.currentVideoSubTitleIndex = Int32(id)
    }

    private func tracks(names: [Any], ids: [Any]) -> [PlayerTrack] {
        var result: [PlayerTrack] = []
        for (i, rawId) in ids.enumerated() {
            guard let id = (rawId as? NSNumber)?.intValue, id != -1 else { continue }
            let name = (i < names.count ? names[i] as? String : nil) ?? "Track \(i)"
            result.append(PlayerTrack(id: id, name: name))
        }
        return result
    }

    // MARK: - Teardown

    /// Stop playback and detach everything. Idempotent; must run on dismiss.
    /// Detaches delegate/drawable on the main actor, then requests shutdown on
    /// a utility queue. NativePlayerLifetime owns the final native release;
    /// VLCKit's asynchronous stop alone does not complete input teardown.
    /// The tornDown flag already guards late callbacks.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        onStateChanged = nil
        onTimeChanged = nil
        player.delegate = nil
        player.drawable = nil
        let player = self.player
        DispatchQueue.global(qos: .utility).async {
            player.stop()
            player.media = nil
        }
    }
}

// MARK: - VLCMediaPlayerDelegate (callbacks hop to the main actor)

extension PlayerEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        // Capture the state NOW, synchronously: VLCKit 3.x notifications carry
        // no state payload and the player's cached state keeps advancing while
        // events queue — reading it inside the main-actor hop lets two rapid
        // transitions (.ended then .stopped, .error then .stopped) BOTH observe
        // the final state, so handleEnded/handlePlayerError never run.
        let state = (aNotification.object as? VLCMediaPlayer)?.state
        let origin = (aNotification.object as? VLCMediaPlayer).map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
            guard let self, !self.tornDown, origin == ObjectIdentifier(self.player) else { return }
            self.onStateChanged?(state ?? self.player.state)
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let origin = (aNotification.object as? VLCMediaPlayer).map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
            guard let self, !self.tornDown, origin == ObjectIdentifier(self.player) else { return }
            self.onTimeChanged?()
        }
    }
}

/// Hosts the VLC drawable view in SwiftUI. The engine keeps ownership; this
/// representable only mounts/unmounts the same UIView instance.
struct PlayerVideoSurface: UIViewRepresentable {
    let engine: PlayerEngine

    func makeUIView(context: Context) -> UIView {
        engine.videoView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
