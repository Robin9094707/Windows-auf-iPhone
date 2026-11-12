// SPDX-License-Identifier: GPL-2.0-or-later
// External display scene (HDMI via USB-C adapter, or AirPlay screen mirroring):
// shows Windows full screen, aspect-fit, on the TV / monitor.
import SwiftUI
import UIKit

final class ExternalDisplayViewController: UIViewController {
    let canvas = MetalCanvasUIView(frame: .zero)
    private let idleLabel = UILabel()

    override func loadView() {
        canvas.isExternalOutput = true
        canvas.backgroundColor = .black
        view = canvas
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        idleLabel.text = "Windows startet auf dem iPhone …"
        idleLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        idleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        idleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(idleLabel)
        NSLayoutConstraint.activate([
            idleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            idleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        refreshIdleLabel()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.refreshIdleLabel()
        }
    }

    private func refreshIdleLabel() {
        idleLabel.isHidden = WinIOSBridge.shared.isVMRunning
    }

    override var prefersStatusBarHidden: Bool { true }
}

final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let vc = ExternalDisplayViewController()
        window.rootViewController = vc
        window.isHidden = false
        self.window = window
        let screen = windowScene.screen
        let px = CGSize(width: screen.nativeBounds.width, height: screen.nativeBounds.height)
        let desc = "\(Int(px.width))×\(Int(px.height))"
        DispatchQueue.main.async {
            DisplayRouter.shared.registerExternalLayer(vc.canvas.metalLayer, description: desc, pixelSize: px)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        DisplayRouter.shared.registerExternalLayer(nil, description: "")
        window = nil
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// Lets the Windows session lock the interface to landscape.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .all

    static func set(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene, ws.session.role == .windowApplication else { continue }
            if #available(iOS 16.0, *) {
                ws.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { _ in }
                ws.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
