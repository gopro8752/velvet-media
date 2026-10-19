import SwiftUI
import UIKit

/// A full-window player. iPhone and older iPad versions request landscape;
/// iPadOS 26.2+ follows window rotation without entering scaled compatibility mode.
final class LandscapeHostingController<Content: View>: UIHostingController<Content> {
    var onDismissed: (() -> Void)?
    var presentationOrientation: UIInterfaceOrientation = .portrait
    // UIKit may query the mask while UIHostingController first loads its view,
    // before the presentation closure has resolved the containing scene.
    var followsWindowOrientation = OrientationLock.followsWindowOrientation(UIDevice.current.userInterfaceIdiom)

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { followsWindowOrientation ? .all : .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { presentationOrientation }
    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Fires for both the close button (@Environment(\.dismiss)) and an
        // interactive/programmatic dismissal — keep the SwiftUI binding in sync.
        if isBeingDismissed || presentingViewController == nil {
            onDismissed?()
        }
    }
}

extension View {
    /// Presents the player with the platform's playback orientation policy when
    /// `item` is set, and clears `item` when the player dismisses itself.
    func playerPresenter(item: Binding<PlayTarget?>, queue: Binding<HomeCategory?> = .constant(nil)) -> some View {
        modifier(PlayerPresenterModifier(item: item, queue: queue))
    }

    /// Shared presentation shell for players with their own identity and state.
    /// Keeps live channels out of the VOD target/history pipeline.
    func landscapePlayerPresenter<Item: Equatable, PlayerContent: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> PlayerContent
    ) -> some View {
        background(LandscapePlayerBridge(item: item, onDismiss: {}, content: content)
            .frame(width: 0, height: 0))
    }
}

private struct PlayerPresenterModifier: ViewModifier {
    @Binding var item: PlayTarget?
    @Binding var queue: HomeCategory?
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var settings: SettingsStore

    func body(content: Content) -> some View {
        content.background(
            LandscapePlayerBridge(item: $item, onDismiss: { queue = nil }) { target in
                PlayerSessionHost(target: target, queue: queue)
                    .environmentObject(container)
                    .environmentObject(settings)
                    .preferredColorScheme(.dark)
            }
            .frame(width: 0, height: 0)
        )
    }
}

private struct LandscapePlayerBridge<Item: Equatable, PlayerContent: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let onDismiss: () -> Void
    let content: (Item) -> PlayerContent

    func makeUIViewController(context: Context) -> PlayerPresentationAnchor {
        PlayerPresentationAnchor()
    }

    func updateUIViewController(_ host: PlayerPresentationAnchor, context: Context) {
        let coord = context.coordinator
        coord.clearBinding = { finishedTarget in
            guard item == finishedTarget else { return }
            item = nil
            onDismiss()
        }
        host.onReady = { [weak coord] in coord?.pendingPresentation?() }

        if let target = item {
            if coord.presented == nil, coord.pendingTarget != target {
                coord.pendingID = nil
                coord.pendingPresentation = nil
                coord.isPresenting = false
            }
            // Present once; ignore redundant updates while already showing.
            guard coord.presented == nil, !coord.isPresenting else { return }
            coord.isPresenting = true
            let requestID = UUID()
            coord.pendingID = requestID
            coord.pendingTarget = target

            let root = content(target).preferredColorScheme(.dark)
            let vc = LandscapeHostingController(rootView: root)
            vc.modalPresentationStyle = .fullScreen
            vc.view.backgroundColor = .black
            // Resolve only this representable's window (or an attached parent).
            // An unattached tab waits for onReady instead of borrowing an
            // arbitrary foreground scene, which can rotate the wrong iPad window.
            coord.pendingPresentation = { [weak coord, weak host] in
                guard let coord, coord.pendingID == requestID, let host,
                      let window = Self.attachedWindow(of: host), let scene = window.windowScene,
                      let presenter = Self.topViewController(in: window),
                      !presenter.isBeingDismissed, !presenter.isBeingPresented else { return }
                coord.pendingPresentation = nil
                coord.pendingID = nil
                coord.pendingTarget = nil
                let previousOrientation = scene.interfaceOrientation
                let followsWindow = OrientationLock.followsWindowOrientation(scene.traitCollection.userInterfaceIdiom)
                vc.followsWindowOrientation = followsWindow
                vc.presentationOrientation = followsWindow || previousOrientation.isLandscape ? previousOrientation : .landscapeRight
                let sceneID = scene.session.persistentIdentifier
                let orientationToken = OrientationLock.beginPlayback(in: scene)
                coord.restoreOrientation = { [weak window, weak scene] in
                    // Read the held-device orientation before releasing the last
                    // token, which ends device-orientation notifications.
                    let mask = scene.map { OrientationLock.restoredBrowsingOrientation(in: $0, previous: previousOrientation) }
                    OrientationLock.endPlayback(orientationToken, sceneID: sceneID)
                    if let window, let scene, let mask, !OrientationLock.hasPlayback(in: scene) {
                        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                        Self.topViewController(in: window)?.setNeedsUpdateOfSupportedInterfaceOrientations()
                        if !followsWindow { scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in } }
                    }
                }
                vc.onDismissed = { [weak coord, weak vc] in
                    guard let coord, coord.presented === vc else { return }
                    coord.presented = nil
                    coord.isPresenting = false
                    let restore = coord.restoreOrientation
                    coord.restoreOrientation = nil
                    restore?()
                    coord.clearBinding?(target)
                }
                coord.presented = vc
                presenter.present(vc, animated: true) { [weak vc, weak scene] in
                    guard let vc, vc.presentingViewController != nil else { return }
                    vc.setNeedsUpdateOfSupportedInterfaceOrientations()
                    if !followsWindow { scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in } }
                }
            }
            DispatchQueue.main.async { [weak coord] in coord?.pendingPresentation?() }
        } else {
            coord.pendingID = nil
            coord.pendingTarget = nil
            coord.pendingPresentation = nil
            if let presented = coord.presented, !presented.isBeingDismissed {
                // Keep the player mask until UIKit finishes dismissing it.
                presented.dismiss(animated: true)
            } else if coord.presented == nil {
                coord.isPresenting = false
            }
        }
    }

    static func dismantleUIViewController(_ host: PlayerPresentationAnchor, coordinator: Coordinator) {
        host.onReady = nil
        coordinator.pendingID = nil
        coordinator.pendingTarget = nil
        coordinator.pendingPresentation = nil
        coordinator.clearBinding = nil
        let restore = coordinator.restoreOrientation
        coordinator.restoreOrientation = nil
        let presented = coordinator.presented
        coordinator.presented = nil
        coordinator.isPresenting = false
        if let presented, presented.presentingViewController != nil {
            presented.dismiss(animated: false) { restore?() }
        } else {
            restore?()
        }
    }

    private static func attachedWindow(of host: UIViewController) -> UIWindow? {
        var controller: UIViewController? = host
        while let current = controller {
            if let window = current.viewIfLoaded?.window { return window }
            controller = current.parent
        }
        return nil
    }

    private static func topViewController(in window: UIWindow) -> UIViewController? {
        var top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var isPresenting = false
        weak var presented: UIViewController?
        var clearBinding: ((Item) -> Void)?
        var pendingID: UUID?
        var pendingTarget: Item?
        var pendingPresentation: (() -> Void)?
        var restoreOrientation: (() -> Void)?
    }
}

/// Presentation can be requested before SwiftUI attaches a tab's background.
/// Retry when this controller joins its actual window rather than guessing one.
private final class PlayerPresentationAnchor: UIViewController {
    var onReady: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onReady?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.window != nil { onReady?() }
    }
}
