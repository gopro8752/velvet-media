import UIKit

/// Browsing rotates freely on iPad and stays portrait on iPhone. Older systems
/// restrict only the presenting scene for playback; modern iPad windows rotate.
@MainActor
enum OrientationLock {
    private static var playersByScene: [String: Set<UUID>] = [:]

    static func beginPlayback(in scene: UIWindowScene) -> UUID {
        if playersByScene.isEmpty { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        let token = UUID()
        playersByScene[scene.session.persistentIdentifier, default: []].insert(token)
        return token
    }

    static func endPlayback(_ token: UUID, sceneID: String) {
        guard playersByScene[sceneID]?.remove(token) != nil else { return }
        if playersByScene[sceneID]?.isEmpty == true { playersByScene[sceneID] = nil }
        if playersByScene.isEmpty { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
    }

    static func hasPlayback(in scene: UIWindowScene) -> Bool {
        playersByScene[scene.session.persistentIdentifier]?.isEmpty == false
    }

    /// iPadOS 26.2+ windowing scales orientation-restricted compatibility scenes
    /// into floating windows. Fill the user's window and follow its orientation.
    static func followsWindowOrientation(_ idiom: UIUserInterfaceIdiom) -> Bool {
        if #available(iOS 26.2, *) { return idiom == .pad }
        return false
    }

    static func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        let idiom = window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom
        if followsWindowOrientation(idiom) { return .all }
        if let sceneID = window?.windowScene?.session.persistentIdentifier,
           playersByScene[sceneID]?.isEmpty == false {
            return .landscape
        }
        if idiom == .pad { return .all }
        // UIKit can ask before it has a window. Allow the pending iPhone player
        // transition without choosing an unrelated connected scene.
        if window == nil, !playersByScene.isEmpty { return .allButUpsideDown }
        return .portrait
    }

    static func restoredBrowsingOrientation(in scene: UIWindowScene,
                                           previous: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        guard scene.traitCollection.userInterfaceIdiom == .pad else { return .portrait }
        // Respect how the iPad is now held. When flat/unknown, restore its last
        // browsing orientation instead of always forcing portrait.
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default:
            switch previous {
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: return .all
            }
        }
    }
}

final class VelvetAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationLock.supportedOrientations(for: window) }
    }
}
