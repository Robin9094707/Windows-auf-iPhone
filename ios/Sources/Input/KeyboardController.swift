// SPDX-License-Identifier: GPL-2.0-or-later
// USB HID keyboard (usage page 0x07) – types text into Windows with the correct
// Windows keyboard layout, sticky modifiers, shortcuts and macros.
import Foundation
import UIKit

enum HID {
    static let enter: UInt8 = 0x28
    static let escape: UInt8 = 0x29
    static let backspace: UInt8 = 0x2a
    static let tab: UInt8 = 0x2b
    static let space: UInt8 = 0x2c
    static let printScreen: UInt8 = 0x46
    static let insert: UInt8 = 0x49
    static let home: UInt8 = 0x4a
    static let pageUp: UInt8 = 0x4b
    static let delete: UInt8 = 0x4c
    static let end: UInt8 = 0x4d
    static let pageDown: UInt8 = 0x4e
    static let right: UInt8 = 0x4f
    static let left: UInt8 = 0x50
    static let down: UInt8 = 0x51
    static let up: UInt8 = 0x52
    static func f(_ n: Int) -> UInt8 { UInt8(0x3a + max(0, min(11, n - 1))) }

    static let lCtrl: UInt8 = 0xe0
    static let lShift: UInt8 = 0xe1
    static let lAlt: UInt8 = 0xe2
    static let lWin: UInt8 = 0xe3
    static let rAlt: UInt8 = 0xe6   // AltGr on European layouts

    static func letter(_ c: Character) -> UInt8? {
        guard let a = c.lowercased().first?.asciiValue, a >= 97, a <= 122 else { return nil }
        return UInt8(0x04 + Int(a - 97))
    }
}

enum WindowsKeyboardLayout: String, CaseIterable, Identifiable {
    case german = "de"
    case us = "us"
    var id: String { rawValue }
    var title: String { self == .german ? "Deutsch (QWERTZ)" : "Englisch (US)" }

    static var systemDefault: WindowsKeyboardLayout {
        let lang = Locale.preferredLanguages.first ?? "en"
        return lang.hasPrefix("de") ? .german : .us
    }
}

/// One keystroke: optional modifiers + key usage; `deadKeyFollowUp` sends a space afterwards.
struct KeyStroke {
    var usage: UInt8
    var modifiers: [UInt8] = []
    var deadKeyFollowUp: Bool = false
}

final class KeyboardController {
    static let shared = KeyboardController()

    var layout: WindowsKeyboardLayout = .systemDefault
    /// Sticky modifiers armed from the on-screen key bar; consumed by the next key.
    private(set) var stickyModifiers: Set<UInt8> = []
    var onStickyChanged: (() -> Void)?

    private let queue = DispatchQueue(label: "windows.keyboard.typer", qos: .userInteractive)
    private var bridge: WinIOSBridge { WinIOSBridge.shared }

    private init() {}

    // MARK: Sticky modifiers

    func toggleSticky(_ mod: UInt8) {
        if stickyModifiers.contains(mod) { stickyModifiers.remove(mod) } else { stickyModifiers.insert(mod) }
        onStickyChanged?()
    }

    func isSticky(_ mod: UInt8) -> Bool { stickyModifiers.contains(mod) }

    private func consumeSticky() -> [UInt8] {
        let mods = Array(stickyModifiers).sorted()
        if !mods.isEmpty {
            stickyModifiers.removeAll()
            DispatchQueue.main.async { self.onStickyChanged?() }
        }
        return mods
    }

    // MARK: Keys

    /// Taps a key; applies any armed sticky modifiers.
    func tap(_ usage: UInt8, modifiers: [UInt8] = []) {
        let mods = Array(Set(modifiers + consumeSticky()))
        if mods.isEmpty {
            bridge.tapKeyHid(usage)
        } else {
            bridge.sendKeyCombo(withModifiers: mods.map { NSNumber(value: $0) }, key: usage)
        }
    }

    func combo(_ modifiers: [UInt8], _ usage: UInt8) {
        bridge.sendKeyCombo(withModifiers: modifiers.map { NSNumber(value: $0) }, key: usage)
    }

    func press(_ usage: UInt8, down: Bool) {
        bridge.sendKeyHid(usage, down: down)
    }

    // MARK: Text

    /// Inserts text typed on the iOS keyboard. If sticky modifiers are armed (e.g. Ctrl),
    /// the first character is sent as a shortcut (Ctrl+C …).
    func insertText(_ text: String) {
        let sticky = consumeSticky()
        if !sticky.isEmpty, let ch = text.first, let stroke = strokes(for: ch).first {
            let mods = Array(Set(sticky + stroke.modifiers))
            combo(mods, stroke.usage)
            let rest = String(text.dropFirst())
            if !rest.isEmpty { type(rest) }
            return
        }
        type(text)
    }

    /// Types text sequentially with reliable timing (also used by macros).
    func type(_ text: String, perKeyDelay: TimeInterval = 0.028, completion: (() -> Void)? = nil) {
        let all = text.flatMap { strokes(for: $0) }
        queue.async { [bridge] in
            for s in all {
                for m in s.modifiers { bridge.sendKeyHid(m, down: true) }
                if !s.modifiers.isEmpty { Thread.sleep(forTimeInterval: 0.008) }
                bridge.sendKeyHid(s.usage, down: true)
                Thread.sleep(forTimeInterval: perKeyDelay * 0.5)
                bridge.sendKeyHid(s.usage, down: false)
                for m in s.modifiers.reversed() { bridge.sendKeyHid(m, down: false) }
                if s.deadKeyFollowUp {
                    Thread.sleep(forTimeInterval: perKeyDelay * 0.5)
                    bridge.sendKeyHid(HID.space, down: true)
                    Thread.sleep(forTimeInterval: perKeyDelay * 0.5)
                    bridge.sendKeyHid(HID.space, down: false)
                }
                Thread.sleep(forTimeInterval: perKeyDelay * 0.5)
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Runs a sequence of steps (combos, text, waits) in order.
    enum MacroStep {
        case combo([UInt8], UInt8)
        case key(UInt8)
        case text(String)
        case wait(TimeInterval)
    }

    func run(_ steps: [MacroStep]) {
        queue.async { [bridge] in
            for step in steps {
                switch step {
                case .combo(let mods, let key):
                    for m in mods { bridge.sendKeyHid(m, down: true) }
                    Thread.sleep(forTimeInterval: 0.02)
                    bridge.sendKeyHid(key, down: true)
                    Thread.sleep(forTimeInterval: 0.04)
                    bridge.sendKeyHid(key, down: false)
                    Thread.sleep(forTimeInterval: 0.02)
                    for m in mods.reversed() { bridge.sendKeyHid(m, down: false) }
                    Thread.sleep(forTimeInterval: 0.05)
                case .key(let key):
                    bridge.sendKeyHid(key, down: true)
                    Thread.sleep(forTimeInterval: 0.04)
                    bridge.sendKeyHid(key, down: false)
                    Thread.sleep(forTimeInterval: 0.05)
                case .text(let text):
                    let strokes = text.flatMap { self.strokes(for: $0) }
                    for s in strokes {
                        for m in s.modifiers { bridge.sendKeyHid(m, down: true) }
                        bridge.sendKeyHid(s.usage, down: true)
                        Thread.sleep(forTimeInterval: 0.016)
                        bridge.sendKeyHid(s.usage, down: false)
                        for m in s.modifiers.reversed() { bridge.sendKeyHid(m, down: false) }
                        if s.deadKeyFollowUp {
                            bridge.sendKeyHid(HID.space, down: true)
                            Thread.sleep(forTimeInterval: 0.016)
                            bridge.sendKeyHid(HID.space, down: false)
                        }
                        Thread.sleep(forTimeInterval: 0.016)
                    }
                case .wait(let t):
                    Thread.sleep(forTimeInterval: t)
                }
            }
        }
    }

    // MARK: Character → HID mapping

    func strokes(for ch: Character) -> [KeyStroke] {
        switch ch {
        case "\n", "\r": return [KeyStroke(usage: HID.enter)]
        case "\t": return [KeyStroke(usage: HID.tab)]
        case " ": return [KeyStroke(usage: HID.space)]
        default: break
        }
        if let l = HID.letter(ch), ch.isASCII {
            var usage = l
            if layout == .german {
                if usage == 0x1c { usage = 0x1d } else if usage == 0x1d { usage = 0x1c } // y <-> z
            }
            return [KeyStroke(usage: usage, modifiers: ch.isUppercase ? [HID.lShift] : [])]
        }
        if let a = ch.asciiValue, a >= 48, a <= 57 {
            return [KeyStroke(usage: a == 48 ? 0x27 : UInt8(0x1e + Int(a - 49)))]
        }
        let table = layout == .german ? Self.germanSymbols : Self.usSymbols
        if let s = table[ch] { return [s] }
        // Smart punctuation from the iOS keyboard → plain ASCII
        switch ch {
        case "“", "”", "„": return strokes(for: "\"")
        case "‘", "’", "‚": return strokes(for: "'")
        case "–", "—": return strokes(for: "-")
        case "…": return strokes(for: ".") + strokes(for: ".") + strokes(for: ".")
        default: return []
        }
    }

    private static let S = HID.lShift
    private static let G = HID.rAlt

    static let usSymbols: [Character: KeyStroke] = [
        "!": KeyStroke(usage: 0x1e, modifiers: [S]), "@": KeyStroke(usage: 0x1f, modifiers: [S]),
        "#": KeyStroke(usage: 0x20, modifiers: [S]), "$": KeyStroke(usage: 0x21, modifiers: [S]),
        "%": KeyStroke(usage: 0x22, modifiers: [S]), "^": KeyStroke(usage: 0x23, modifiers: [S]),
        "&": KeyStroke(usage: 0x24, modifiers: [S]), "*": KeyStroke(usage: 0x25, modifiers: [S]),
        "(": KeyStroke(usage: 0x26, modifiers: [S]), ")": KeyStroke(usage: 0x27, modifiers: [S]),
        "-": KeyStroke(usage: 0x2d), "_": KeyStroke(usage: 0x2d, modifiers: [S]),
        "=": KeyStroke(usage: 0x2e), "+": KeyStroke(usage: 0x2e, modifiers: [S]),
        "[": KeyStroke(usage: 0x2f), "{": KeyStroke(usage: 0x2f, modifiers: [S]),
        "]": KeyStroke(usage: 0x30), "}": KeyStroke(usage: 0x30, modifiers: [S]),
        "\\": KeyStroke(usage: 0x31), "|": KeyStroke(usage: 0x31, modifiers: [S]),
        ";": KeyStroke(usage: 0x33), ":": KeyStroke(usage: 0x33, modifiers: [S]),
        "'": KeyStroke(usage: 0x34), "\"": KeyStroke(usage: 0x34, modifiers: [S]),
        "`": KeyStroke(usage: 0x35), "~": KeyStroke(usage: 0x35, modifiers: [S]),
        ",": KeyStroke(usage: 0x36), "<": KeyStroke(usage: 0x36, modifiers: [S]),
        ".": KeyStroke(usage: 0x37), ">": KeyStroke(usage: 0x37, modifiers: [S]),
        "/": KeyStroke(usage: 0x38), "?": KeyStroke(usage: 0x38, modifiers: [S]),
    ]

    static let germanSymbols: [Character: KeyStroke] = [
        "!": KeyStroke(usage: 0x1e, modifiers: [S]), "\"": KeyStroke(usage: 0x1f, modifiers: [S]),
        "§": KeyStroke(usage: 0x20, modifiers: [S]), "$": KeyStroke(usage: 0x21, modifiers: [S]),
        "%": KeyStroke(usage: 0x22, modifiers: [S]), "&": KeyStroke(usage: 0x23, modifiers: [S]),
        "/": KeyStroke(usage: 0x24, modifiers: [S]), "(": KeyStroke(usage: 0x25, modifiers: [S]),
        ")": KeyStroke(usage: 0x26, modifiers: [S]), "=": KeyStroke(usage: 0x27, modifiers: [S]),
        "{": KeyStroke(usage: 0x24, modifiers: [G]), "[": KeyStroke(usage: 0x25, modifiers: [G]),
        "]": KeyStroke(usage: 0x26, modifiers: [G]), "}": KeyStroke(usage: 0x27, modifiers: [G]),
        "ß": KeyStroke(usage: 0x2d), "?": KeyStroke(usage: 0x2d, modifiers: [S]),
        "\\": KeyStroke(usage: 0x2d, modifiers: [G]),
        "`": KeyStroke(usage: 0x2e, modifiers: [S], deadKeyFollowUp: true),
        "ü": KeyStroke(usage: 0x2f), "Ü": KeyStroke(usage: 0x2f, modifiers: [S]),
        "+": KeyStroke(usage: 0x30), "*": KeyStroke(usage: 0x30, modifiers: [S]),
        "~": KeyStroke(usage: 0x30, modifiers: [G]),
        "#": KeyStroke(usage: 0x32), "'": KeyStroke(usage: 0x32, modifiers: [S]),
        "ö": KeyStroke(usage: 0x33), "Ö": KeyStroke(usage: 0x33, modifiers: [S]),
        "ä": KeyStroke(usage: 0x34), "Ä": KeyStroke(usage: 0x34, modifiers: [S]),
        "^": KeyStroke(usage: 0x35, deadKeyFollowUp: true), "°": KeyStroke(usage: 0x35, modifiers: [S]),
        ",": KeyStroke(usage: 0x36), ";": KeyStroke(usage: 0x36, modifiers: [S]),
        ".": KeyStroke(usage: 0x37), ":": KeyStroke(usage: 0x37, modifiers: [S]),
        "-": KeyStroke(usage: 0x38), "_": KeyStroke(usage: 0x38, modifiers: [S]),
        "<": KeyStroke(usage: 0x64), ">": KeyStroke(usage: 0x64, modifiers: [S]),
        "|": KeyStroke(usage: 0x64, modifiers: [G]),
        "@": KeyStroke(usage: 0x14, modifiers: [G]), "€": KeyStroke(usage: 0x08, modifiers: [G]),
        "²": KeyStroke(usage: 0x1f, modifiers: [G]), "³": KeyStroke(usage: 0x20, modifiers: [G]),
        "µ": KeyStroke(usage: 0x10, modifiers: [G]),
    ]
}
