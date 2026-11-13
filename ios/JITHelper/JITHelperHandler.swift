// SPDX-License-Identifier: GPL-2.0-or-later
// Built-in JIT helper ("eigener StikDebug"): a tiny app extension that runs in its own
// process and attaches the debugger to the Windows app over LocalDevVPN (10.7.0.1), using
// StikJIT (MPL-2.0, github.com/StikDebug/StikJIT, compiled into this target).
// A process cannot debug itself (it would freeze), hence the separate extension process.
//
// Input  (NSExtensionItem.userInfo): pid, pairing (Data), script (base64 String), force (Bool)
// Output (completeRequest items):    ok (Bool), message (String), log (String)
// Progress: Darwin notification state on "<host bundle id>.jithelper.progress"
//           value = stage * 1000 + permille.
import Foundation
import notify

@objc(JITHelperHandler)
final class JITHelperHandler: NSObject, NSExtensionRequestHandling {
    private static let queue = DispatchQueue(label: "windowsaufiphone.jithelper")
    private var logLines: [String] = []
    private var notifyToken: Int32 = -1
    private var notifyName = "com.windowsaufiphone.app.jithelper.progress"

    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        let pid = (info["pid"] as? NSNumber)?.int32Value ?? 0
        let pairing = info["pairing"] as? Data
        let script = info["script"] as? String
        let force = (info["force"] as? NSNumber)?.boolValue ?? true
        if let name = info["notify"] as? String { notifyName = name }
        notify_register_check(notifyName, &notifyToken)

        Self.queue.async {
            let result = self.run(pid: pid, pairing: pairing, script: script, force: force)
            let item = NSExtensionItem()
            item.userInfo = ["ok": result.ok, "message": result.message,
                             "log": self.logLines.suffix(40).joined(separator: "\n")]
            self.report(stage: result.ok ? 9 : 10, fraction: 1)
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private func report(stage: Int, fraction: Double) {
        guard notifyToken >= 0 else { return }
        let value = UInt64(stage * 1000 + Int(max(0, min(1, fraction)) * 999))
        notify_set_state(notifyToken, value)
        notify_post(notifyName)
    }

    private func log(_ s: String) {
        logLines.append(s)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        NSLog("[JITHelper] %@", s)
    }

    private func run(pid: Int32, pairing: Data?, script: String?, force: Bool) -> (ok: Bool, message: String) {
        guard pid > 0 else { return (false, "Keine Prozess-ID erhalten.") }
        guard let pairing, !pairing.isEmpty else { return (false, "Keine Pairing-Datei gekoppelt.") }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
        do { try pairing.write(to: tmp, options: .atomic) } catch {
            return (false, "Pairing-Datei konnte nicht geschrieben werden: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tmp) }

        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("StikJIT")
        try? fm.createDirectory(at: library.appendingPathComponent("DDI"), withIntermediateDirectories: true)
        let paths = DDIPaths.default(in: library)
        let jsScript: StikJIT.Script = script.map { .customBase64($0) } ?? .universal

        report(stage: 1, fraction: 0)
        do {
            try StikJIT.enableJIT(
                targetPID: pid,
                pairingFile: tmp,
                ddiPaths: paths,
                configuration: StikJIT.Configuration(connectionTimeout: 6),
                script: jsScript,
                forceScript: force,
                preparationProgress: { [weak self] stage in
                    guard let self else { return }
                    switch stage {
                    case .checkingReachability: self.report(stage: 1, fraction: 0); self.log("Verbinde über LocalDevVPN …")
                    case .checkingDDI: self.report(stage: 2, fraction: 0); self.log("Prüfe Developer Disk Image …")
                    case .downloadingDDI(let f, let status): self.report(stage: 3, fraction: f); self.log(status)
                    case .mountingDDI(let f): self.report(stage: 4, fraction: f)
                    case .verifyingDDI: self.report(stage: 5, fraction: 0)
                    case .ready: self.report(stage: 6, fraction: 0); self.log("Gerät bereit")
                    }
                },
                progress: { [weak self] line in
                    self?.report(stage: 7, fraction: 0)
                    self?.log(line)
                })
            return (true, "JIT aktiviert")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log(msg)
            return (false, msg)
        }
    }
}
