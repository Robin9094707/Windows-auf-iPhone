// SPDX-License-Identifier: GPL-2.0-or-later
// Routes the Windows framebuffer to the iPhone screen or to an external display
// (HDMI / USB-C / AirPlay). With an external display the iPhone becomes a
// trackpad + keyboard controller.
import Combine
import QuartzCore
import UIKit

final class DisplayRouter: ObservableObject {
    static let shared = DisplayRouter()

    @Published private(set) var externalConnected = false
    @Published private(set) var externalDescription = ""
    @Published private(set) var externalPixelSize: CGSize = .zero
    @Published var preferExternal: Bool = UserDefaults.standard.object(forKey: "display.preferExternal") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(preferExternal, forKey: "display.preferExternal")
            rebind()
        }
    }

    private weak var phoneLayer: CAMetalLayer?
    private weak var externalLayer: CAMetalLayer?

    /// True while Windows is shown on the external display.
    var isPresentingExternally: Bool { externalConnected && preferExternal && externalLayer != nil }

    private init() {}

    func registerPhoneLayer(_ layer: CAMetalLayer?) {
        phoneLayer = layer
        rebind()
    }

    func registerExternalLayer(_ layer: CAMetalLayer?, description: String, pixelSize: CGSize = .zero) {
        externalLayer = layer
        externalPixelSize = layer != nil ? pixelSize : .zero
        externalConnected = layer != nil
        externalDescription = layer != nil ? description : ""
        rebind()
        if layer != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func rebind() {
        let target: CAMetalLayer? = isPresentingExternally ? externalLayer : phoneLayer
        WinIOSBridge.shared.bindMetalLayer(target)
        objectWillChange.send()
    }
}
