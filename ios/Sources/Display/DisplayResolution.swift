// SPDX-License-Identifier: GPL-2.0-or-later
// Windows runs at a resolution with exactly the iPhone's aspect ratio (fills the whole
// screen, no black bars). The patched UEFI firmware reads it at boot.
import UIKit

enum DisplayResolution: String, CaseIterable, Identifiable {
    case native     // every iPhone pixel (sharpest, needs 200–300 % Windows scaling)
    case sharp      // 2/3 of native – crisp and still fluid (default)
    case balanced   // 720p height – fastest, biggest UI
    case classic    // firmware default (800×600), the old behaviour
    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "Nativ (maximal scharf)"
        case .sharp: return "Scharf (empfohlen)"
        case .balanced: return "Flüssig (720p)"
        case .classic: return "Klassisch (800×600)"
        }
    }

    /// iPhone panel in landscape, in pixels.
    static var panel: (Int, Int) {
        let nb = UIScreen.main.nativeBounds.size
        return (Int(max(nb.width, nb.height)), Int(min(nb.width, nb.height)))
    }

    private static func even(_ w: Double, _ h: Double) -> (UInt32, UInt32) {
        (UInt32(Int(w.rounded()) & ~7), UInt32(Int(h.rounded()) & ~1))
    }

    /// Resolution for the iPhone screen (0×0 = firmware default).
    var size: (UInt32, UInt32) {
        let (pw, ph) = Self.panel
        let aspect = Double(pw) / Double(max(1, ph))
        switch self {
        case .native: return Self.even(Double(pw), Double(ph))
        case .sharp: return Self.even(Double(pw) * 2 / 3, Double(ph) * 2 / 3)
        case .balanced: return Self.even(720 * aspect, 720)
        case .classic: return (0, 0)
        }
    }

    func label() -> String {
        let s = size
        return s.0 == 0 ? title : "\(title) – \(s.0)×\(s.1)"
    }

    /// Resolution for an external display (capped at 2560×1440 so Windows stays fluid).
    static func external(_ px: CGSize) -> (UInt32, UInt32) {
        var w = Double(px.width), h = Double(px.height)
        if w < h { swap(&w, &h) }
        let scale = min(1.0, 2560 / w, 1440 / h)
        return even(w * scale, h * scale)
    }
}
