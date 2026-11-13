// SPDX-License-Identifier: GPL-2.0-or-later
// Pairing file for the built-in JIT helper (the same file StikDebug uses, e.g. made with
// idevice_pair / iloader). Stored privately in Application Support – never shown in "Dateien".
import Foundation

enum JITPairing {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JIT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("pairingFile.plist") }

    static var isPaired: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    static var data: Data? { try? Data(contentsOf: fileURL) }

    static var pairedDate: Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static let fileExtensions: Set<String> = ["plist", "mobiledevicepairing", "rppairing", "pairing"]

    /// A pairing file is a small property list (XML or binary) with a dictionary at the root.
    static func looksLikePairing(_ data: Data) -> Bool {
        guard data.count > 64, data.count < 1 << 20,
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return false }
        let keys = Set(dict.keys.map { $0.lowercased() })
        let hints = ["hostid", "hostcertificate", "deviceidentifier", "systembuid", "wifimacaddress",
                     "public_key", "private_key", "identifier", "remote_unlock_host_key", "alt_irk", "rppairing"]
        return hints.contains { h in keys.contains { $0.contains(h) } } || dict.count >= 3
    }

    static func isCandidate(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
            || url.lastPathComponent.lowercased().contains("pairing")
    }

    /// Imports the file; returns an error text or nil on success.
    @discardableResult
    static func importFile(_ src: URL) -> String? {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: src) else { return "Die Datei konnte nicht gelesen werden." }
        guard looksLikePairing(data) else {
            return "„\(src.lastPathComponent)“ ist keine Pairing-Datei. Nimm dieselbe Datei wie für StikDebug (…pairing….plist)."
        }
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return nil
        } catch {
            return "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    static func remove() { try? FileManager.default.removeItem(at: fileURL) }
}
