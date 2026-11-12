// SPDX-License-Identifier: GPL-2.0-or-later
// iOS <-> Windows clipboard.
//  • With the helper running in Windows (needs network): real two-way sync.
//  • Without it: "Einfügen" types the iPhone clipboard text into Windows.
import Foundation
import UIKit

final class ClipboardBridge {
    static let shared = ClipboardBridge()

    /// Automatic sync on/off (Settings).
    var autoSync: Bool {
        get { UserDefaults.standard.object(forKey: "clip.autoSync") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clip.autoSync") }
    }

    private var timer: Timer?
    private var lastChangeCount = UIPasteboard.general.changeCount
    private var lastFromWindows: String?
    private var lastToWindows: String?

    private init() {}

    /// True while the Windows helper is talking to the app.
    var isHelperActive: Bool {
        let s = WinIOSBridge.shared.clipboardAgentSeenSeconds()
        return s >= 0 && s < 45
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.poll() }
        NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pushIfChanged()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pushIfChanged()
        }
    }

    private func poll() {
        guard WinIOSBridge.shared.isVMRunning else { return }
        // Windows → iPhone
        if let text = WinIOSBridge.shared.takeGuestClipboard(), !text.isEmpty, autoSync {
            lastFromWindows = text
            UIPasteboard.general.string = text
            lastChangeCount = UIPasteboard.general.changeCount
        }
    }

    /// iPhone → Windows when the iOS clipboard changed (copied in another app).
    private func pushIfChanged() {
        let pb = UIPasteboard.general
        guard autoSync, WinIOSBridge.shared.isVMRunning, isHelperActive,
              pb.changeCount != lastChangeCount, pb.hasStrings else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string, text != lastFromWindows, text != lastToWindows else { return }
        sendToWindows(text)
    }

    func sendToWindows(_ text: String) {
        lastToWindows = text
        WinIOSBridge.shared.setHostClipboardForGuest(text)
    }

    /// Pastes text into Windows at the cursor: via the clipboard + Ctrl+V when the helper runs,
    /// otherwise by typing it.
    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if isHelperActive {
            sendToWindows(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                KeyboardController.shared.combo([HID.lCtrl], HID.letter("v")!)
            }
        } else {
            KeyboardController.shared.type(text)
        }
    }

    /// Paste the current iPhone clipboard (asks iOS for permission the first time).
    func pasteFromIPhone() {
        if let text = UIPasteboard.general.string { paste(text) }
    }

    /// Copy in Windows; with the helper running the text lands on the iPhone automatically.
    func copyInWindows(cut: Bool = false) {
        KeyboardController.shared.combo([HID.lCtrl], HID.letter(cut ? "x" : "c")!)
    }
}
