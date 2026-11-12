// SPDX-License-Identifier: GPL-2.0-or-later
// The Windows screen: a CAMetalLayer-backed view that turns touches, trackpad
// gestures, mice, Apple Pencil and hardware keyboards into USB HID input.
import Metal
import QuartzCore
import SwiftUI
import UIKit

enum TouchMode: String, CaseIterable, Identifiable {
    case direct
    case trackpad
    var id: String { rawValue }
    var title: String { self == .direct ? "Direkt-Touch" : "Trackpad" }
    var icon: String { self == .direct ? "hand.point.up.left.fill" : "rectangle.and.hand.point.up.left.fill" }
}

final class MetalCanvasUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// `true` for the view living on an external display (output only).
    var isExternalOutput = false
    var touchMode: TouchMode = .direct
    /// Forces trackpad behaviour (e.g. while Windows is shown on an external display).
    var forceTrackpad = false
    var rightClickArmed = false
    var onRightClickConsumed: (() -> Void)?
    var onThreeFingerTap: (() -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?

    private var effectiveTrackpad: Bool { forceTrackpad || touchMode == .trackpad }
    private var activeDragButtons: UInt8 = 0
    private var panLastPoint: CGPoint = .zero
    private var scrollAccum: CGFloat = 0
    private var dragArmedByDoubleTap = false
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)

    // Pinch-zoom state (applied as a transform on the canvas)
    private(set) var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var pinchStartZoom: CGFloat = 1
    private var pinchStartPan: CGPoint = .zero
    private var pinchStartCentroid: CGPoint = .zero
    private var isPinching = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resizeAspect
        updateDrawableScale()
    }

    func installGestures() {
        guard !isExternalOutput, gestureRecognizers?.isEmpty ?? true else { return }

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        addGestureRecognizer(threeFingerTap)

        let dragPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        dragPan.minimumNumberOfTouches = 1
        dragPan.maximumNumberOfTouches = 1
        dragPan.delegate = self
        addGestureRecognizer(dragPan)

        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        scrollPan.allowedScrollTypesMask = .all
        scrollPan.delegate = self
        addGestureRecognizer(scrollPan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 12
        addGestureRecognizer(longPress)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch + two-finger scroll run together; we arbitrate inside the handlers.
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) ||
            (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableScale()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableScale()
    }

    private func updateDrawableScale() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if !isExternalOutput, let winBounds = window?.bounds.size, winBounds.width > 0 {
            WinIOSBridge.shared.updateScreenSize(winBounds, scale: scale)
        }
    }

    // MARK: Zoom

    func resetZoom(animated: Bool = true) {
        zoom = 1
        pan = .zero
        applyTransform(animated: animated)
        onZoomChanged?(zoom)
    }

    private func applyTransform(animated: Bool) {
        let t = CGAffineTransform(translationX: pan.x, y: pan.y).scaledBy(x: zoom, y: zoom)
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) { self.transform = t }
        } else {
            transform = t
        }
    }

    private func clampPan() {
        let maxX = bounds.width * (zoom - 1) / 2
        let maxY = bounds.height * (zoom - 1) / 2
        pan.x = min(maxX, max(-maxX, pan.x))
        pan.y = min(maxY, max(-maxY, pan.y))
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        guard let container = superview else { return }
        let centroid = gr.location(in: container)
        switch gr.state {
        case .began:
            isPinching = true
            pinchStartZoom = zoom
            pinchStartPan = pan
            pinchStartCentroid = centroid
        case .changed:
            zoom = min(4.0, max(1.0, pinchStartZoom * gr.scale))
            pan = CGPoint(x: pinchStartPan.x + (centroid.x - pinchStartCentroid.x),
                          y: pinchStartPan.y + (centroid.y - pinchStartCentroid.y))
            clampPan()
            applyTransform(animated: false)
        case .ended, .cancelled, .failed:
            isPinching = false
            if zoom < 1.08 { resetZoom() } else { onZoomChanged?(zoom) }
        default: break
        }
    }

    // MARK: Coordinate mapping (aspect-fit framebuffer inside the view)

    private func normalizedPoint(for pt: CGPoint) -> (Double, Double) {
        let bw = max(1.0, bounds.width), bh = max(1.0, bounds.height)
        let fbW = Double(WinIOSBridge.shared.framebufferWidth)
        let fbH = Double(WinIOSBridge.shared.framebufferHeight)
        var rect = bounds
        if fbW > 0 && fbH > 0 {
            let viewAspect = Double(bw / bh), fbAspect = fbW / fbH
            if viewAspect > fbAspect {
                let w = CGFloat(Double(bh) * fbAspect)
                rect = CGRect(x: (bw - w) * 0.5, y: 0, width: w, height: bh)
            } else {
                let h = CGFloat(Double(bw) / fbAspect)
                rect = CGRect(x: 0, y: (bh - h) * 0.5, width: bw, height: h)
            }
        }
        let nx = min(1.0, max(0.0, Double((pt.x - rect.minX) / max(1.0, rect.width))))
        let ny = min(1.0, max(0.0, Double((pt.y - rect.minY) / max(1.0, rect.height))))
        return (nx, ny)
    }

    private func consumeRightClickArm() -> UInt8 {
        if rightClickArmed {
            rightClickArmed = false
            onRightClickConsumed?()
            return 2
        }
        return 1
    }

    // MARK: Gestures

    @objc private func handleSingleTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        tapHaptic.impactOccurred(intensity: 0.45)
        let mask = consumeRightClickArm()
        if effectiveTrackpad {
            PointerController.shared.clickAtCurrent(buttonMask: mask)
        } else {
            let (nx, ny) = normalizedPoint(for: gr.location(in: self))
            PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: mask)
        }
    }

    @objc private func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.6)
        if !effectiveTrackpad {
            let (nx, ny) = normalizedPoint(for: gr.location(in: self))
            PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 2)
        } else {
            PointerController.shared.clickAtCurrent(buttonMask: 2)
        }
    }

    @objc private func handleThreeFingerTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onThreeFingerTap?()
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if effectiveTrackpad {
            PointerController.shared.clickAtCurrent(buttonMask: 2)
        } else {
            let (nx, ny) = normalizedPoint(for: gr.location(in: self))
            PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 2)
        }
    }

    @objc private func handleOneFingerPan(_ gr: UIPanGestureRecognizer) {
        let loc = gr.location(in: self)
        switch gr.state {
        case .began:
            panLastPoint = loc
            if !effectiveTrackpad {
                let (nx, ny) = normalizedPoint(for: loc)
                activeDragButtons = consumeRightClickArm()
                PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: activeDragButtons)
            } else if rightClickArmed {
                // Armed "drag" in trackpad mode: hold left button while moving
                rightClickArmed = false
                onRightClickConsumed?()
                activeDragButtons = 1
            }
        case .changed:
            if effectiveTrackpad {
                // Movement in view coordinates is scaled by zoom; undo it for consistent speed
                let dx = (loc.x - panLastPoint.x) * zoom
                let dy = (loc.y - panLastPoint.y) * zoom
                panLastPoint = loc
                PointerController.shared.moveRelative(dxPoints: dx, dyPoints: dy,
                                                      padWidth: bounds.width, padHeight: bounds.height,
                                                      extraButtons: activeDragButtons)
            } else {
                let (nx, ny) = normalizedPoint(for: loc)
                PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: activeDragButtons)
            }
        case .ended, .cancelled, .failed:
            if activeDragButtons != 0 {
                activeDragButtons = 0
                PointerController.shared.moveAbsolute(x: PointerController.shared.cursorX,
                                                      y: PointerController.shared.cursorY, extraButtons: 0)
            }
        default: break
        }
    }

    @objc private func handleTwoFingerScroll(_ gr: UIPanGestureRecognizer) {
        if isPinching && zoom > 1.01 { return }
        let trans = gr.translation(in: self)
        if gr.state == .began {
            scrollAccum = 0
        } else if gr.state == .changed {
            let delta = trans.y - scrollAccum
            if abs(delta) >= 10 {
                let steps = Int(delta / 10)
                scrollAccum += CGFloat(steps) * 10
                PointerController.shared.scroll(steps: Int8(clamping: max(-8, min(8, steps))))
            }
        }
    }

    @objc private func handleHover(_ gr: UIHoverGestureRecognizer) {
        // Mouse / trackpad / Apple Pencil hover moves the pointer absolutely.
        let (nx, ny) = normalizedPoint(for: gr.location(in: self))
        PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: activeDragButtons)
    }

    // Physical mouse buttons (secondary click)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let e = event, e.buttonMask.contains(.secondary), let t = touches.first {
            let (nx, ny) = normalizedPoint(for: t.location(in: self))
            PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 2)
            return
        }
        super.touchesBegan(touches, with: event)
    }

    // MARK: Keyboard (software + hardware)

    override var canBecomeFirstResponder: Bool { !isExternalOutput }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        KeyboardController.shared.insertText(text)
    }

    func deleteBackward() {
        KeyboardController.shared.tap(HID.backspace)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                let code = key.keyCode.rawValue
                if code >= 0x04 && code <= 0xe7 {
                    WinIOSBridge.shared.sendKeyHid(UInt8(code), down: true)
                    handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                let code = key.keyCode.rawValue
                if code >= 0x04 && code <= 0xe7 {
                    WinIOSBridge.shared.sendKeyHid(UInt8(code), down: false)
                    handled = true
                }
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}

/// Holder so SwiftUI controls (toolbar) can talk to the live canvas.
final class CanvasHandle {
    weak var view: MetalCanvasUIView?
    func resetZoom() { view?.resetZoom() }
}

/// The interactive iPhone canvas.
struct WindowsScreenView: UIViewRepresentable {
    var touchMode: TouchMode
    var forceTrackpad: Bool
    @Binding var rightClickArmed: Bool
    @Binding var keyboardVisible: Bool
    var handle: CanvasHandle
    var onThreeFingerTap: () -> Void
    var onZoomChanged: (CGFloat) -> Void = { _ in }

    func makeUIView(context: Context) -> MetalCanvasUIView {
        let view = MetalCanvasUIView(frame: .zero)
        view.installGestures()
        handle.view = view
        DisplayRouter.shared.registerPhoneLayer(view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MetalCanvasUIView, context: Context) {
        handle.view = uiView
        uiView.touchMode = touchMode
        uiView.forceTrackpad = forceTrackpad
        uiView.rightClickArmed = rightClickArmed
        uiView.onThreeFingerTap = onThreeFingerTap
        uiView.onZoomChanged = onZoomChanged
        uiView.onRightClickConsumed = { DispatchQueue.main.async { rightClickArmed = false } }
        if keyboardVisible && !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !keyboardVisible && uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: MetalCanvasUIView, coordinator: ()) {
        DisplayRouter.shared.registerPhoneLayer(nil)
    }
}
