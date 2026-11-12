// SPDX-License-Identifier: GPL-2.0-or-later
// Game controllers (PlayStation / Xbox / MFi) as mouse + keys:
//   left stick → pointer · right stick → scroll · A/✕ → left click · B/○ → right click
//   X/□ → Enter · Y/△ → Windows key · Menu → Esc · D-pad → arrow keys
import Foundation
import GameController
import QuartzCore

final class GamepadInput {
    static let shared = GamepadInput()
    private var timer: Timer?
    private var started = false
    private var scrollAccum: Double = 0

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let c = note.object as? GCController { self?.attach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        pad.buttonA.pressedChangedHandler = { _, _, pressed in PointerController.shared.setHeldButton(1, down: pressed) }
        pad.buttonB.pressedChangedHandler = { _, _, pressed in PointerController.shared.setHeldButton(2, down: pressed) }
        pad.buttonX.pressedChangedHandler = { _, _, pressed in WinIOSBridge.shared.sendKeyHid(HID.enter, down: pressed) }
        pad.buttonY.pressedChangedHandler = { _, _, pressed in if pressed { KeyboardController.shared.tap(HID.lWin) } }
        pad.buttonMenu.pressedChangedHandler = { _, _, pressed in WinIOSBridge.shared.sendKeyHid(HID.escape, down: pressed) }
        pad.dpad.up.pressedChangedHandler = { _, _, p in WinIOSBridge.shared.sendKeyHid(HID.up, down: p) }
        pad.dpad.down.pressedChangedHandler = { _, _, p in WinIOSBridge.shared.sendKeyHid(HID.down, down: p) }
        pad.dpad.left.pressedChangedHandler = { _, _, p in WinIOSBridge.shared.sendKeyHid(HID.left, down: p) }
        pad.dpad.right.pressedChangedHandler = { _, _, p in WinIOSBridge.shared.sendKeyHid(HID.right, down: p) }
        pad.leftShoulder.pressedChangedHandler = { _, _, p in if p { WinIOSBridge.shared.sendAltTab() } }
    }

    private func poll() {
        guard WinIOSBridge.shared.isVMRunning,
              let pad = GCController.controllers().compactMap({ $0.extendedGamepad }).first else { return }
        let lx = Double(pad.leftThumbstick.xAxis.value)
        let ly = Double(pad.leftThumbstick.yAxis.value)
        let mag = hypot(lx, ly)
        if mag > 0.12 {
            let speed = pow(mag, 1.8) * 14.0
            PointerController.shared.moveRelative(dxPoints: CGFloat(lx / mag * speed),
                                                  dyPoints: CGFloat(-ly / mag * speed),
                                                  padWidth: 600, padHeight: 380)
        }
        let ry = Double(pad.rightThumbstick.yAxis.value)
        if abs(ry) > 0.2 {
            scrollAccum += ry * 0.35
            if abs(scrollAccum) >= 1 {
                let steps = Int8(clamping: Int(scrollAccum))
                scrollAccum -= Double(steps)
                PointerController.shared.scroll(steps: steps)
            }
        }
    }
}
