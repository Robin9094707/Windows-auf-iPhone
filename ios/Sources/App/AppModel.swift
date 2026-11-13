// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import ImageIO
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
    @Published var showSession = false {
        didSet { AuroraClock.shared.set(paused: showSession) }
    }
    @Published var activeSafariURL: IdentifiableURL?
    @Published var stikDebugMissing = false
    /// Small, pre-decoded copy of the last Windows screen for the home screen.
    @Published private(set) var previewImage: UIImage?

    // Settings (persisted)
    @AppStorage("vm.cpus") var cpuCount: Int = 4
    @AppStorage("vm.ramMB") var ramMB: Int = 0
    @AppStorage("vm.network") var networkEnabled: Bool = true
    @AppStorage("vm.sound") var soundEnabled: Bool = true
    @AppStorage("vm.mountedISO") var mountedISO: String = ""
    /// Driver ISO in the extra drive: "" = automatic (virtio-win*.iso), "-" = none.
    @AppStorage("vm.driverISO") var driverISOSetting: String = ""
    @AppStorage("input.longPressMenu") var longPressMenu: Bool = true
    @AppStorage("display.resolution") var resolutionRaw: String = DisplayResolution.sharp.rawValue
    @AppStorage("perf.max") var maxPerformance: Bool = true
    /// Attach a Windows-readable data drive (setup files, drivers, optimizer).
    @AppStorage("vm.dataDrive") var dataDriveEnabled: Bool = true
    @AppStorage("vm.autostart") var autostart: Bool = true
    @AppStorage("vm.isoBootKeys") var pressKeyForISOBoot: Bool = true
    @AppStorage("input.touchMode") var touchModeRaw: String = TouchMode.direct.rawValue
    @AppStorage("input.layout") var keyboardLayoutRaw: String = WindowsKeyboardLayout.systemDefault.rawValue
    @AppStorage("input.trackpadSpeed") var trackpadSpeed: Double = 1.0
    @AppStorage("ui.landscapeLock") var landscapeLock: Bool = true
    @AppStorage("ui.showStats") var showStats: Bool = false
    /// "auto" (built-in helper when paired, otherwise StikDebug), "builtin" or "stikdebug".
    @AppStorage("jit.method") var jitMethodRaw: String = "auto"
    /// Start the built-in JIT helper by itself when the app opens (needs pairing + LocalDevVPN).
    @AppStorage("jit.autoBuiltIn") var autoBuiltInJIT: Bool = true

    // Built-in JIT helper state
    @Published var builtInJITRunning = false
    @Published var builtInJITStage = ""
    @Published var builtInJITError: String?
    @Published var builtInJITLog = ""
    private var didAutoBuiltInJIT = false

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
    private var failedDataDrives: Set<URL> = []
    private var previewDate: Date?
    private var previewLoading = false
    private var tickCount = 0

    /// The single model instance (set at launch) for sheets that need it.
    static var current: AppModel!

    init() {
        let bridge = WinIOSBridge.shared
        bridge.installTrapGuard()
        bridge.firmwarePath = store.bundledFirmwareURL?.path
        // RAM is reserved (ledger-exempt) the moment JIT is acquired.
        bridge.ramReservationMB = UInt64(max(0, ramMB))
        DeviceProfile.current.applyToEngine()
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
        if !live, let m = AppModel.current, m.builtInJITRunning, !m.builtInJITStage.isEmpty { return m.builtInJITStage }
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
            b.ramReservationMB = UInt64(max(0, ramMB))
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
        tickCount &+= 1
        if tickCount % 6 == 1 { refreshPreview() }
        if autostart && b.isJITLive && !b.isVMRunning && !b.isUnpacking && !didAutoLaunch && store.isReadyToBoot {
            didAutoLaunch = true
            start()
        }
    }

    func onBecameActive() {
        store.refresh()
        tick()
        refreshPreview()
        // Built-in JIT: try once per app launch, silently, when everything is set up.
        if autoBuiltInJIT && !didAutoBuiltInJIT && useBuiltInJIT && !WinIOSBridge.shared.isJITLive
            && !WinIOSBridge.shared.isDebuggerAttached {
            didAutoBuiltInJIT = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.enableJITBuiltIn() }
        }
    }

    /// Loads the last screenshot as a downsampled thumbnail in the background – only when
    /// the file changed. Decoding the full-size PNG on the main thread on every redraw
    /// made the home screen stutter.
    func refreshPreview() {
        let url = store.documents.appendingPathComponent("latest_screen.png")
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard date != previewDate, !previewLoading else { return }
        guard date != nil else {
            previewDate = nil
            if previewImage != nil { previewImage = nil }
            return
        }
        previewLoading = true
        DispatchQueue.global(qos: .utility).async {
            let img = Self.thumbnail(url, maxPixel: 1280)
            Task { @MainActor in
                self.previewLoading = false
                self.previewDate = date
                if let img { self.previewImage = img }
            }
        }
    }

    nonisolated static func thumbnail(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
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

    /// The ISO whose files Windows must be able to read right now:
    /// the Windows ISO while installing, otherwise the driver ISO.
    /// Installing Windows right now (setup ISO in the drive, system disk still empty)?
    var isInstalling: Bool { mountedISOURL != nil && (!store.hasDisk || store.diskLooksBlank) }

    /// The ISO whose Windows-readable copy is needed but missing – only while installing.
    /// After installation nothing is ever converted automatically.
    var dataDriveToCreate: URL? {
        guard dataDriveEnabled, isInstalling, let iso = mountedISOURL, !store.hasReadableDrive(for: iso) else { return nil }
        return iso
    }

    /// The converted drive attached as extra NVMe disk (existing drives only).
    var dataDriveImage: URL? {
        guard dataDriveEnabled else { return nil }
        if isInstalling, let iso = mountedISOURL, store.hasReadableDrive(for: iso) {
            return store.readableDriveURL(for: iso)
        }
        for iso in [driverISOURL, mountedISOURL].compactMap({ $0 }) where store.hasReadableDrive(for: iso) {
            return store.readableDriveURL(for: iso)
        }
        return store.drives.first?.url
    }

    var resolution: DisplayResolution {
        get { DisplayResolution(rawValue: resolutionRaw) ?? .sharp }
        set { resolutionRaw = newValue.rawValue; objectWillChange.send() }
    }

    /// The resolution Windows will get at the next start.
    var guestResolution: (UInt32, UInt32) {
        let d = DisplayRouter.shared
        if d.externalConnected && d.preferExternal && d.externalPixelSize.width > 0 {
            return DisplayResolution.external(d.externalPixelSize)
        }
        return resolution.size
    }

    /// Explicitly makes an ISO readable for Windows (e.g. the driver ISO after installation).
    func createDataDrive(for iso: URL) {
        failedDataDrives.remove(iso)
        store.makeReadableDrive(from: iso) { _ in }
    }

    func applyConfig() {
        let b = WinIOSBridge.shared
        b.configuredCPUCount = Int32(cpuCount)
        let res = guestResolution
        b.guestWidth = res.0
        b.guestHeight = res.1
        b.maxPerformance = maxPerformance
        b.requestedRamMB = UInt64(max(0, ramMB))
        b.networkEnabled = networkEnabled
        b.soundEnabled = soundEnabled
        b.installerImagePath = mountedISOURL?.path
        b.driverImagePath = dataDriveImage?.path
        b.firmwarePath = store.bundledFirmwareURL?.path
    }

    func start() {
        didAutoLaunch = true
        // Windows can't read an ISO attached as a disk: give it an exFAT copy first.
        if let src = dataDriveToCreate, !failedDataDrives.contains(src) {
            guard !store.isConverting else { return }
            vmStatusText = "Bereite Laufwerk für Windows vor …"
            store.makeReadableDrive(from: src) { [weak self] ok in
                guard let self else { return }
                if !ok { self.failedDataDrives.insert(src); return }
                self.start()
            }
            return
        }
        // Rufus-style setup options → autounattend.xml (+ optimizer) on the data drive.
        if let drive = dataDriveImage {
            store.writeSetupOptions(SetupOptions.load(), drive: drive)
        }
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

    // MARK: JIT

    var builtInJITAvailable: Bool {
        if #available(iOS 17.4, *) { return WinIOSJITHelper.isAvailable }
        return false
    }

    var isPaired: Bool { JITPairing.isPaired }

    /// Whether the JIT button uses the app's own helper instead of the StikDebug app.
    var useBuiltInJIT: Bool {
        switch jitMethodRaw {
        case "stikdebug": return false
        case "builtin": return builtInJITAvailable
        default: return builtInJITAvailable && isPaired
        }
    }

    /// Main JIT action (home screen button).
    func enableJIT() {
        if useBuiltInJIT {
            if isPaired { enableJITBuiltIn() } else { builtInJITError = "Noch keine Pairing-Datei gekoppelt (Einstellungen → JIT)." }
        } else {
            enableJITWithStikDebug()
        }
    }

    var jitScriptBase64: String? {
        guard let url = Bundle.main.url(forResource: "henge-jit", withExtension: "js"),
              let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }

    /// Built-in "StikDebug": the JIT helper extension attaches the debugger over LocalDevVPN.
    func enableJITBuiltIn() {
        guard !builtInJITRunning, !WinIOSBridge.shared.isJITLive else { return }
        guard let pairing = JITPairing.data else {
            builtInJITError = "Noch keine Pairing-Datei gekoppelt (Einstellungen → JIT)."
            return
        }
        builtInJITRunning = true
        builtInJITError = nil
        builtInJITLog = ""
        builtInJITStage = "JIT-Helfer startet …"
        sync()
        WinIOSJITHelper.enableJIT(withPairing: pairing, scriptBase64: jitScriptBase64, progress: { [weak self] stage, fraction in
            guard let self else { return }
            let pct = Int((fraction * 100).rounded())
            let text: String
            switch stage {
            case 1: text = "Verbinde über LocalDevVPN …"
            case 2: text = "Prüfe Developer Disk Image …"
            case 3: text = "Lade Developer Disk Image (einmalig) … \(pct) %"
            case 4: text = "Binde Developer Disk Image ein … \(pct) %"
            case 5: text = "Prüfe Developer Disk Image …"
            case 6: text = "Starte Debugger …"
            case 7: text = "Debugger verbunden – JIT wird eingerichtet …"
            default: return
            }
            if self.builtInJITStage != text { self.builtInJITStage = text; self.sync() }
            // The helper attached → claim the JIT region right away (answers its breakpoints).
            self.tick()
        }, completion: { [weak self] ok, message, log in
            guard let self else { return }
            self.builtInJITRunning = false
            self.builtInJITLog = log
            self.builtInJITStage = ""
            self.tick()
            if ok || WinIOSBridge.shared.isJITLive {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                self.builtInJITError = Self.friendlyJITError(message)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            self.sync()
        })
    }

    static func friendlyJITError(_ raw: String) -> String {
        let m = raw.lowercased()
        if m.contains("not ready") && (m.contains("timed out") || m.contains("connect") || m.contains("refused") || m.contains("network")) {
            return "iPhone nicht erreichbar. Öffne LocalDevVPN und tippe auf „Verbinden“. Ohne WLAN: mobile Daten an, VPN verbinden, dann Flugmodus an und zurück in diese App."
        }
        if m.contains("pairing") {
            return "Die Pairing-Datei passt nicht (\(raw)). Erzeuge sie neu (z. B. mit idevice_pair) und kopple sie erneut."
        }
        if m.contains("download") {
            return "Developer Disk Image konnte nicht geladen werden – beim ersten Mal ist Internet nötig. (\(raw))"
        }
        return raw
    }

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

    /// Fixes "Ein vom Computer benötigter Medientreiber fehlt": starts Setup from the
    /// Windows-readable copy of the installation media.
    func setupStartFromDataDrive() {
        KeyboardController.shared.run([
            .combo([HID.lShift], HID.f(10)), .wait(2.5),
            .text("for %d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do @if exist %d:\\sources\\install.* (start \"\" %d:\\setup.exe /unattend:%d:\\autounattend.xml & exit)"),
            .key(HID.enter),
        ])
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

    /// Runs iPhone-Optimieren.cmd from the data drive – elevated (confirm the UAC prompt).
    func optimizeWindows() {
        KeyboardController.shared.run([
            .combo([HID.lWin], HID.letter("r")!), .wait(0.8),
            .text(UnattendBuilder.optimizerLauncher),
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
