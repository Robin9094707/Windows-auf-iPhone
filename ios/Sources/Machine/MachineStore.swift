// SPDX-License-Identifier: GPL-2.0-or-later
// Everything about the files of the Windows machine:
//   Documents/Machines/Win11/windows11.img       – system disk (raw)
//   Documents/Machines/Win11/windows11.hvsparse  – packed disk (unpacked on first start)
//   Documents/Machines/Win11/vars.fd             – UEFI NVRAM (auto-created)
//   Documents/Machines/Win11/code.fd             – optional custom UEFI (bundled one otherwise)
//   Documents/ISOs/*.iso                         – installer / driver media (mountable)
//   Documents/Import/                            – drop anything here in the Files app
//   Documents/Shared/                            – shared with Windows at \\10.0.2.4
import Combine
import Foundation
import UniformTypeIdentifiers

enum WindowsFileKind: String {
    case diskImage, sparseImage, firmware, nvram, iso, unsupported, other

    var title: String {
        switch self {
        case .diskImage: return "Windows-Festplatte"
        case .sparseImage: return "Gepacktes Windows-Image"
        case .firmware: return "UEFI-Firmware"
        case .nvram: return "UEFI-Variablen"
        case .iso: return "ISO-Abbild"
        case .unsupported: return "Nicht unterstützt"
        case .other: return "Datei"
        }
    }

    var icon: String {
        switch self {
        case .diskImage: return "internaldrive.fill"
        case .sparseImage: return "shippingbox.fill"
        case .firmware: return "cpu.fill"
        case .nvram: return "memorychip.fill"
        case .iso: return "opticaldisc.fill"
        case .unsupported: return "exclamationmark.triangle.fill"
        case .other: return "doc.fill"
        }
    }
}

struct MachineFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let kind: WindowsFileKind
    let size: Int64
    let allocated: Int64
    var name: String { url.lastPathComponent }
}

struct ImportJob: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var progress: Double
    var detail: String
}

@MainActor
final class MachineStore: ObservableObject {
    static let shared = MachineStore()

    @Published private(set) var files: [MachineFile] = []
    @Published private(set) var isos: [MachineFile] = []
    @Published private(set) var freeBytes: Int64 = 0
    @Published var jobs: [ImportJob] = []
    @Published var lastMessage: String?
    @Published var lastError: String?

    let fm = FileManager.default
    let documents: URL
    let machineDir: URL
    let isoDir: URL
    let importDir: URL
    let sharedDir: URL

    var diskURL: URL { machineDir.appendingPathComponent("windows11.img") }
    var sparseURL: URL { machineDir.appendingPathComponent("windows11.hvsparse") }
    var varsURL: URL { machineDir.appendingPathComponent("vars.fd") }
    var customFirmwareURL: URL { machineDir.appendingPathComponent("code.fd") }

    /// UEFI firmware shipped inside the app (EDK2 ArmVirtQemu, BSD-2-Clause-Patent).
    var bundledFirmwareURL: URL? {
        Bundle.main.url(forResource: "edk2-aarch64-code", withExtension: "fd", subdirectory: "Firmware")
            ?? Bundle.main.url(forResource: "edk2-aarch64-code", withExtension: "fd")
    }

    var hasFirmware: Bool { fm.fileExists(atPath: customFirmwareURL.path) || bundledFirmwareURL != nil }
    var hasDisk: Bool { fileSize(diskURL) >= (64 << 20) }
    var hasSparse: Bool { fm.fileExists(atPath: sparseURL.path) }
    var hasWindows: Bool { hasDisk || hasSparse }
    /// The disk exists but is (almost) empty: Windows still has to be installed from an ISO.
    var diskLooksBlank: Bool { hasDisk && allocatedSize(diskURL) < (512 << 20) }
    var isReadyToBoot: Bool { hasFirmware && hasWindows }

    private init() {
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        machineDir = documents.appendingPathComponent("Machines/Win11", isDirectory: true)
        isoDir = documents.appendingPathComponent("ISOs", isDirectory: true)
        importDir = documents.appendingPathComponent("Import", isDirectory: true)
        sharedDir = documents.appendingPathComponent("Shared", isDirectory: true)
        for d in [machineDir, isoDir, importDir, sharedDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        writeReadme()
        refresh()
    }

    // MARK: Scanning

    func refresh() {
        sweepImportFolders()
        files = list(machineDir)
        isos = list(isoDir).filter { $0.kind == .iso }
        if let v = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            freeBytes = cap
        }
    }

    private func list(_ dir: URL) -> [MachineFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { return nil }
            if url.pathExtension == "unpacking" || url.pathExtension == "part" { return nil }
            return MachineFile(url: url, kind: Self.classify(url),
                               size: Int64(v?.fileSize ?? 0),
                               allocated: Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func classify(_ url: URL) -> WindowsFileKind {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        switch ext {
        case "img", "raw", "bin":
            return .diskImage
        case "hvsparse": return .sparseImage
        case "fd", "rom":
            return (name.contains("var") || name.contains("nvram")) ? .nvram : .firmware
        case "iso": return .iso
        case "vhdx", "vhd", "qcow2", "vmdk", "esd", "wim", "utm", "zip":
            return .unsupported
        default: return .other
        }
    }

    /// Moves files that the user dropped via the Files app (Documents root or Import/) into place.
    private func sweepImportFolders() {
        var candidates: [URL] = []
        for dir in [documents, importDir] {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                candidates += items.filter { !$0.hasDirectoryPath && $0.lastPathComponent != "LIESMICH.txt" && $0.lastPathComponent != "boot_status.txt" && !$0.lastPathComponent.hasPrefix("latest_screen") }
            }
        }
        for url in candidates {
            let kind = Self.classify(url)
            guard kind != .other, kind != .unsupported else { continue }
            guard let dest = destination(for: url, kind: kind) else { continue }
            if fm.fileExists(atPath: dest.path) {
                if (kind == .diskImage || kind == .sparseImage) && !diskLooksBlank {
                    lastError = "„\(url.lastPathComponent)“ wurde nicht übernommen: Es gibt bereits eine Windows-Festplatte. Lösche sie zuerst in „Dateien“."
                    continue
                }
                try? fm.removeItem(at: dest)
            }
            try? fm.moveItem(at: url, to: dest)
        }
    }

    func destination(for url: URL, kind: WindowsFileKind) -> URL? {
        switch kind {
        case .diskImage: return diskURL
        case .sparseImage: return sparseURL
        case .firmware: return customFirmwareURL
        case .nvram: return varsURL
        case .iso: return isoDir.appendingPathComponent(url.lastPathComponent)
        case .unsupported, .other: return nil
        }
    }

    // MARK: Import (file picker / "Open in" / AirDrop)

    func importFiles(_ urls: [URL]) {
        for url in urls { importFile(url) }
    }

    func importFile(_ src: URL) {
        let kind = Self.classify(src)
        if kind == .unsupported {
            lastError = "„\(src.lastPathComponent)“ wird nicht direkt unterstützt. Bitte als .img (raw), .hvsparse oder .iso bereitstellen."
            return
        }
        // Unknown extension: decide by size – large files are disk images.
        var effectiveKind = kind
        if kind == .other {
            let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            effectiveKind = size > (512 << 20) ? .diskImage : .other
        }
        guard let dest = destination(for: src, kind: effectiveKind) else {
            // Anything else goes to the Windows shared folder.
            copyWithProgress(src, to: sharedDir.appendingPathComponent(src.lastPathComponent), label: src.lastPathComponent, unpackSparse: false)
            return
        }
        copyWithProgress(src, to: dest, label: src.lastPathComponent, unpackSparse: effectiveKind == .sparseImage)
    }

    private func copyWithProgress(_ src: URL, to dest: URL, label: String, unpackSparse: Bool) {
        let job = ImportJob(name: label, progress: 0, detail: unpackSparse ? "Entpacke …" : "Kopiere …")
        jobs.append(job)
        let jobID = job.id
        let accessing = src.startAccessingSecurityScopedResource()
        let total = Int64((try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let diskDest = diskURL

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var ok = false
            var errorText: String?

            if unpackSparse {
                // Unpack directly from the source: no double storage needed.
                let tmp = diskDest.appendingPathExtension("unpacking")
                try? fm.removeItem(at: tmp)
                let box = ProgressBox { frac in
                    Task { @MainActor in MachineStore.shared.updateJob(jobID, progress: frac) }
                }
                let ctx = Unmanaged.passRetained(box).toOpaque()
                let rc = hv_sparse_unpack(src.path, tmp.path, { done, total, opaque in
                    guard let opaque else { return }
                    let b = Unmanaged<ProgressBox>.fromOpaque(opaque).takeUnretainedValue()
                    b.report(total > 0 ? Double(done) / Double(total) : 0)
                }, ctx)
                Unmanaged<ProgressBox>.fromOpaque(ctx).release()
                if rc == 0 {
                    try? fm.removeItem(at: diskDest)
                    do { try fm.moveItem(at: tmp, to: diskDest); ok = true } catch { errorText = error.localizedDescription }
                } else {
                    try? fm.removeItem(at: tmp)
                    errorText = "Das .hvsparse-Image ist beschädigt oder unvollständig."
                }
            } else {
                let tmp = dest.appendingPathExtension("part")
                try? fm.removeItem(at: tmp)
                // Poll the destination size for progress while copyItem runs (APFS clones are instant).
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
                timer.setEventHandler {
                    let cur = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    if total > 0 {
                        let frac = min(1.0, Double(cur) / Double(total))
                        Task { @MainActor in MachineStore.shared.updateJob(jobID, progress: frac) }
                    }
                }
                timer.resume()
                do {
                    try fm.copyItem(at: src, to: tmp)
                    try? fm.removeItem(at: dest)
                    try fm.moveItem(at: tmp, to: dest)
                    ok = true
                } catch {
                    try? fm.removeItem(at: tmp)
                    errorText = error.localizedDescription
                }
                timer.cancel()
            }
            if accessing { src.stopAccessingSecurityScopedResource() }
            // Clean up the Inbox copy iOS creates for "Open in…"
            if src.path.contains("/Inbox/") { try? fm.removeItem(at: src) }

            Task { @MainActor in
                let store = MachineStore.shared
                store.jobs.removeAll { $0.id == jobID }
                if ok {
                    store.lastMessage = "„\(label)“ importiert."
                } else {
                    store.lastError = "Import von „\(label)“ fehlgeschlagen: \(errorText ?? "unbekannter Fehler")"
                }
                store.refresh()
            }
        }
    }

    func updateJob(_ id: UUID, progress: Double) {
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].progress = progress
            jobs[i].detail = "\(Int(progress * 100)) %"
        }
    }

    // MARK: Fresh installation

    /// Creates an empty (sparse) NVMe disk for installing Windows from an ISO.
    func createBlankDisk(gigabytes: Int) throws {
        let bytes = off_t(gigabytes) * 1024 * 1024 * 1024
        let path = diskURL.path
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        if ftruncate(fd, bytes) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // Fresh install also needs a fresh NVRAM.
        try? fm.removeItem(at: varsURL)
        refresh()
    }

    // MARK: Management

    func delete(_ file: MachineFile) {
        do {
            try fm.removeItem(at: file.url)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func resetNVRAM() {
        try? fm.removeItem(at: varsURL)
        refresh()
    }

    func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func allocatedSize(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? 0)
    }

    /// Exports the StikDebug JIT script so it can be assigned manually in StikDebug.
    @discardableResult
    func exportJITScript() -> URL? {
        guard let src = Bundle.main.url(forResource: "henge-jit", withExtension: "js") else { return nil }
        let dest = documents.appendingPathComponent("StikDebug-JIT-Skript.js")
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: src, to: dest)
        return dest
    }

    private func writeReadme() {
        let url = documents.appendingPathComponent("LIESMICH.txt")
        guard !fm.fileExists(atPath: url.path) else { return }
        let text = """
        Windows auf iPhone – Dateien
        ============================

        Lege Dateien einfach in den Ordner „Import“ (oder direkt hier hinein).
        Die App sortiert sie beim nächsten Öffnen automatisch ein:

          *.img / *.raw      → Windows-Festplatte (Machines/Win11/windows11.img)
          *.hvsparse         → gepacktes Image, wird beim Start entpackt
          *.iso              → ISOs/ (als Laufwerk in Windows einlegbar)
          code.fd / vars.fd  → eigene UEFI-Firmware / NVRAM (optional)

        Der Ordner „Shared“ ist in Windows unter \\\\10.0.2.4 erreichbar.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Bridges the C progress callback to Swift.
final class ProgressBox {
    private let handler: (Double) -> Void
    private var last: CFAbsoluteTime = 0
    init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
    func report(_ frac: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        if frac < 1.0 && now - last < 0.2 { return }
        last = now
        handler(frac)
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
