// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import SwiftUI
import UIKit

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class AppModel: ObservableObject {
    // Live engine state
    @Published var isJITLive = false
    @Published var isDebuggerAttached = false
    @Published var isVMRunning = false
    @Published var isUnpacking = false
    @Published var unpackProgress: Double = 0
    @Published var jitStatusText = "JIT wird geprüft …"
    @Published var vmStatusText = "Bereit"
    @Published var fbWidth: UInt32 = 0
    @Published var fbHeight: UInt32 = 0
    @Published var usbKeyboardReady = false
    @Published var usbTabletReady = false

    // UI state
    @Published var showSession = false
    @Published var activeSafariURL: IdentifiableURL?
    @Published var stikDebugMissing = false

    // Settings (persisted)
    @AppStorage("vm.cpus") var cpuCount: Int = 4
    @AppStorage("vm.ramMB") var ramMB: Int = 0
    @AppStorage("vm.network") var networkEnabled: Bool = true
    @AppStorage("vm.sound") var soundEnabled: Bool = true
    @AppStorage("vm.mountedISO") var mountedISO: String = ""
    /// Driver ISO in the extra drive: "" = automatic (virtio-win*.iso), "-" = none.
    @AppStorage("vm.driverISO") var driverISOSetting: String = ""
    @AppStorage("input.longPressMenu") var longPressMenu: Bool = true
    @AppStorage("vm.autostart") var autostart: Bool = true
    @AppStorage("vm.isoBootKeys") var pressKeyForISOBoot: Bool = true
    @AppStorage("input.touchMode") var touchModeRaw: String = TouchMode.direct.rawValue
    @AppStorage("input.layout") var keyboardLayoutRaw: String = WindowsKeyboardLayout.systemDefault.rawValue
    @AppStorage("input.trackpadSpeed") var trackpadSpeed: Double = 1.0
    @AppStorage("ui.landscapeLock") var landscapeLock: Bool = true
    @AppStorage("ui.showStats") var showStats: Bool = false

    var touchMode: TouchMode {
        get { TouchMode(rawValue: touchModeRaw) ?? .direct }
        set { touchModeRaw = newValue.rawValue; objectWillChange.send() }
    }

    var keyboardLayout: WindowsKeyboardLayout {
        get { WindowsKeyboardLayout(rawValue: keyboardLayoutRaw) ?? .german }
        set {
            keyboardLayoutRaw = newValue.rawValue
            KeyboardController.shared.layout = newValue
            objectWillChange.send()
        }
    }

    let store = MachineStore.shared
    private var pollTimer: Timer?
    private var didAutoLaunch = false

    /// The single model instance (set at launch) for sheets that need it.
    static var current: AppModel!

    init() {
        let bridge = WinIOSBridge.shared
        bridge.installTrapGuard()
        bridge.firmwarePath = store.bundledFirmwareURL?.path
        KeyboardController.shared.layout = keyboardLayout
        PointerController.shared.trackpadSpeed = trackpadSpeed
        bridge.onStateChanged = { [weak self] in
            Task { @MainActor in self?.sync() }
        }
        _ = DownloadManager.shared
        ClipboardBridge.shared.start()
        sync()
        AppModel.current = self
        startPolling()
    }

    // MARK: Engine sync

    /// Copies engine state into published properties – but only values that actually
    /// changed, so SwiftUI doesn't re-render (and close open menus/pickers) every tick.
    func sync() {
        let b = WinIOSBridge.shared
        set(\.isJITLive, b.isJITLive)
        set(\.isDebuggerAttached, b.isDebuggerAttached)
        set(\.isVMRunning, b.isVMRunning)
        set(\.isUnpacking, b.isUnpacking)
        set(\.unpackProgress, (b.unpackProgress * 100).rounded() / 100)
        set(\.jitStatusText, Self.localizedJIT(b.jitStatusText, live: b.isJITLive))
        set(\.vmStatusText, b.vmStatusText)
        set(\.fbWidth, b.framebufferWidth)
        set(\.fbHeight, b.framebufferHeight)
        set(\.usbKeyboardReady, b.usbKeyboardReady)
        set(\.usbTabletReady, b.usbTabletReady)
    }

    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }

    static func localizedJIT(_ raw: String, live: Bool) -> String {
        if live { return "JIT aktiv – " + raw.replacingOccurrences(of: "Live ", with: "") }
        if raw.hasPrefix("Waiting for debugger") { return "JIT nicht aktiv" }
        if raw.hasPrefix("Trap guard") || raw.hasPrefix("Not initialized") { return "JIT nicht aktiv" }
        return raw
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let b = WinIOSBridge.shared
        // StikDebug attached → grab the JIT region right away.
        if !b.isJITLive && b.isDebuggerAttached {
            _ = b.tryAcquireJIT(true)
        }
        // OAuth / link bridge from Windows → Safari sheet
        if b.takeGuestOAuthDone(), activeSafariURL != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            activeSafariURL = nil
        }
        if let s = b.takeGuestOpenURL(), let u = URL(string: s) {
            activeSafariURL = IdentifiableURL(url: u)
        }
        sync()
        if autostart && b.isJITLive && !b.isVMRunning && !b.isUnpacking && !didAutoLaunch && store.isReadyToBoot {
            didAutoLaunch = true
            start()
        }
    }

    func onBecameActive() {
        store.refresh()
        tick()
    }

    // MARK: Start / stop

    var mountedISOURL: URL? {
        guard !mountedISO.isEmpty else { return nil }
        let url = store.isoDir.appendingPathComponent(mountedISO)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var driverISOURL: URL? {
        if driverISOSetting == "-" { return nil }
        let name = driverISOSetting.isEmpty ? (store.driverISO?.name ?? "") : driverISOSetting
        guard !name.isEmpty, name != mountedISO else { return nil }
        let url = store.isoDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func applyConfig() {
        let b = WinIOSBridge.shared
        b.configuredCPUCount = Int32(cpuCount)
        b.requestedRamMB = UInt64(max(0, ramMB))
        b.networkEnabled = networkEnabled
        b.soundEnabled = soundEnabled
        b.installerImagePath = mountedISOURL?.path
        b.driverImagePath = driverISOURL?.path
        b.firmwarePath = store.bundledFirmwareURL?.path
    }

    func start() {
        didAutoLaunch = true
        applyConfig()
        let b = WinIOSBridge.shared
        b.prepareAndStart(with: nil)
        sync()
        if b.isVMRunning || b.isUnpacking {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showSession = true
            if mountedISOURL != nil && store.diskLooksBlank && pressKeyForISOBoot {
                pressKeysForCDBoot()
            }
        }
    }

    /// Windows' boot loader asks "Press any key to boot from CD or DVD" – tap Space a few times.
    private func pressKeysForCDBoot() {
        for i in 0..<14 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(i) * 1.2) {
                guard WinIOSBridge.shared.isVMRunning else { return }
                WinIOSBridge.shared.tapKeyHid(HID.space)
            }
        }
    }

    func shutdownGracefully() {
        WinIOSBridge.shared.pressPowerButton()
    }

    func forceStop() {
        WinIOSBridge.shared.flushDisks()
        WinIOSBridge.shared.stopVM()
        sync()
    }

    // MARK: JIT via StikDebug

    func enableJITWithStikDebug() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var urlStr = "stikjit://enable-jit?bundle-id=\(bundleID)&pid=\(getpid())"
        if let scriptURL = Bundle.main.url(forResource: "henge-jit", withExtension: "js"),
           let data = try? Data(contentsOf: scriptURL) {
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            if let enc = b64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlStr += "&script-data=\(enc)"
            }
        }
        guard let url = URL(string: urlStr) else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            if !ok { Task { @MainActor in self?.stikDebugMissing = true } }
        }
    }

    // MARK: Windows setup helpers (typed via virtual keyboard)

    /// Opens a command prompt inside Windows Setup and disables the TPM / Secure Boot / RAM checks.
    func setupBypassRequirements() {
        let cmds = [
            "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f",
            "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f",
            "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f",
            "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f",
            "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f",
            "exit",
        ]
        var steps: [KeyboardController.MacroStep] = [.combo([HID.lShift], HID.f(10)), .wait(2.5)]
        for c in cmds { steps += [.text(c), .key(HID.enter), .wait(0.6)] }
        KeyboardController.shared.run(steps)
    }

    /// Opens a command prompt (Shift+F10) and lists the disks with diskpart.
    func setupListDisks() {
        KeyboardController.shared.run([
            .combo([HID.lShift], HID.f(10)), .wait(2.5),
            .text("diskpart"), .key(HID.enter), .wait(4.0),
            .text("list disk"), .key(HID.enter),
        ])
    }

    /// Wipes disk 0 and converts it to GPT so Windows Setup can use it.
    /// Run inside the diskpart prompt opened by `setupListDisks()`.
    func setupPrepareDisk0() {
        var steps: [KeyboardController.MacroStep] = []
        for c in ["select disk 0", "online disk", "attributes disk clear readonly", "clean", "convert gpt", "list disk", "exit"] {
            steps += [.text(c), .key(HID.enter), .wait(1.5)]
        }
        KeyboardController.shared.run(steps)
    }

    /// Skips the Microsoft account requirement during the out-of-box experience.
    func setupLocalAccount() {
        KeyboardController.shared.run([
            .combo([HID.lShift], HID.f(10)), .wait(2.5),
            .text("start ms-cxh:localonly"), .key(HID.enter),
        ])
    }

    /// Installs the VirtIO network driver (NetKVM) from the driver drive – elevated (UAC prompt).
    func installNetworkDriver() {
        KeyboardController.shared.run([
            .combo([HID.lWin], HID.letter("r")!), .wait(0.8),
            .text(WindowsTools.installNetworkDriverCommand),
            .combo([HID.lCtrl, HID.lShift], HID.enter),
        ])
    }

    /// Installs the clipboard helper inside Windows (needs network).
    func installClipboardSync() {
        openRun(WindowsTools.installClipboardCommand)
    }

    func openRun(_ command: String) {
        KeyboardController.shared.run([
            .combo([HID.lWin], HID.letter("r")!), .wait(0.6),
            .text(command), .key(HID.enter),
        ])
    }
}
