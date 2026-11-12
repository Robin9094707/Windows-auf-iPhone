// SPDX-License-Identifier: GPL-2.0-or-later
// Absolute USB tablet pointer driven by touch, trackpad gestures, mice and Apple Pencil.
import QuartzCore
import UIKit

final class PointerController {
    static let shared = PointerController()

    var cursorX: Double = 0.5
    var cursorY: Double = 0.5
    /// Trackpad speed multiplier (Settings).
    var trackpadSpeed: Double = 1.0
    private(set) var heldButtons: UInt8 = 0

    private var lastTapTime: CFTimeInterval = 0
    private var lastTapX: Double = 0.5
    private var lastTapY: Double = 0.5

    private init() {}

    private func send(_ x: Double, _ y: Double, _ buttons: UInt8, wheel: Int8 = 0) {
        WinIOSBridge.shared.sendTabletNormalizedX(x, y: y, buttons: buttons, wheel: wheel)
    }

    func moveAbsolute(x: Double, y: Double, extraButtons: UInt8 = 0) {
        cursorX = min(1.0, max(0.0, x))
        cursorY = min(1.0, max(0.0, y))
        send(cursorX, cursorY, heldButtons | extraButtons)
    }

    /// Laptop-style trackpad ballistics: precise when slow, brisk on flicks.
    func moveRelative(dxPoints: CGFloat, dyPoints: CGFloat, padWidth: CGFloat, padHeight: CGFloat, extraButtons: UInt8 = 0) {
        let dist = hypot(Double(dxPoints), Double(dyPoints))
        let gain = min(2.6, 0.9 + dist * 0.06) * trackpadSpeed
        let refW = Double(max(260.0, padWidth))
        let refH = Double(max(160.0, padHeight))
        cursorX = min(1.0, max(0.0, cursorX + (Double(dxPoints) / refW) * gain))
        cursorY = min(1.0, max(0.0, cursorY + (Double(dyPoints) / refH) * gain))
        send(cursorX, cursorY, heldButtons | extraButtons)
    }

    func setHeldButton(_ mask: UInt8, down: Bool) {
        if down { heldButtons |= mask } else { heldButtons &= ~mask }
        send(cursorX, cursorY, heldButtons)
    }

    func releaseAll() {
        heldButtons = 0
        send(cursorX, cursorY, 0)
    }

    func scroll(steps: Int8) {
        guard steps != 0 else { return }
        send(cursorX, cursorY, heldButtons, wheel: steps)
    }

    /// Direct touch tap with double-click snapping (Win32 needs both clicks on the same pixel)
    /// and hover-before-press sequencing so XAML hover states engage.
    func directTapAt(x: Double, y: Double, buttonMask: UInt8) {
        let now = CACurrentMediaTime()
        let dist = hypot(x - lastTapX, y - lastTapY)
        if now - lastTapTime < 0.42 && dist < 0.045 {
            cursorX = lastTapX
            cursorY = lastTapY
        } else {
            cursorX = min(1.0, max(0.0, x))
            cursorY = min(1.0, max(0.0, y))
            lastTapX = cursorX
            lastTapY = cursorY
        }
        lastTapTime = now
        let tx = cursorX, ty = cursorY
        send(tx, ty, heldButtons)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.014) { [weak self] in
            guard let self else { return }
            self.send(tx, ty, self.heldButtons | buttonMask)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
                guard let self else { return }
                self.send(tx, ty, self.heldButtons)
            }
        }
    }

    func clickAtCurrent(buttonMask: UInt8) {
        let tx = cursorX, ty = cursorY
        send(tx, ty, heldButtons | buttonMask)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.send(tx, ty, self.heldButtons)
        }
    }

    func doubleClickAtCurrent() {
        clickAtCurrent(buttonMask: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.clickAtCurrent(buttonMask: 1)
        }
    }
}
