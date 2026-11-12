// SPDX-License-Identifier: GPL-2.0-or-later
// Background downloads (keep running when the app is in the background) for
// Windows ISOs, disk images and driver media. Finished files are sorted into
// the machine folders automatically.
import Combine
import Foundation

struct DownloadItem: Identifiable, Equatable {
    let id: Int
    var name: String
    var received: Int64
    var expected: Int64
    var bytesPerSecond: Double
    var failed: String?

    var progress: Double { expected > 0 ? Double(received) / Double(expected) : 0 }
}

/// Well-known downloads offered in the app.
enum DownloadPreset: String, CaseIterable, Identifiable {
    case windowsISO
    case virtioDrivers
    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowsISO: return "Windows 11 ARM64 (ISO, offiziell von Microsoft)"
        case .virtioDrivers: return "VirtIO-Treiber (Netzwerk) – virtio-win.iso"
        }
    }

    var subtitle: String {
        switch self {
        case .windowsISO: return "Öffnet die Microsoft-Downloadseite in der App. Sprache wählen → „Download“ – die ISO landet automatisch in der App."
        case .virtioDrivers: return "Red Hat NetKVM-Treiber für Internet in Windows. ca. 700 MB."
        }
    }

    var pageURL: URL {
        switch self {
        case .windowsISO: return URL(string: "https://www.microsoft.com/de-de/software-download/windows11arm64")!
        case .virtioDrivers: return URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!
        }
    }

    /// Direct downloads skip the in-app browser.
    var isDirect: Bool { self == .virtioDrivers }
}

final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    static let sessionID = "com.windowsaufiphone.downloads"

    @Published private(set) var items: [DownloadItem] = []
    var backgroundCompletionHandler: (() -> Void)?

    private var lastSample: [Int: (Date, Int64)] = [:]
    private var names: [Int: String] = [:]

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        cfg.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        // Reattach to downloads that survived an app restart.
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                for t in tasks where t.state == .running {
                    let name = t.taskDescription ?? t.originalRequest?.url?.lastPathComponent ?? "Download"
                    self.names[t.taskIdentifier] = name
                    self.items.append(DownloadItem(id: t.taskIdentifier, name: name, received: t.countOfBytesReceived,
                                                   expected: t.countOfBytesExpectedToReceive, bytesPerSecond: 0))
                }
            }
        }
    }

    func start(_ url: URL, suggestedName: String? = nil) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        let name = suggestedName ?? Self.fileName(from: url)
        task.taskDescription = name
        names[task.taskIdentifier] = name
        items.append(DownloadItem(id: task.taskIdentifier, name: name, received: 0, expected: 0, bytesPerSecond: 0))
        task.resume()
    }

    func cancel(_ item: DownloadItem) {
        session.getAllTasks { tasks in
            tasks.first { $0.taskIdentifier == item.id }?.cancel()
        }
        items.removeAll { $0.id == item.id }
    }

    func dismiss(_ item: DownloadItem) {
        items.removeAll { $0.id == item.id }
    }

    static func fileName(from url: URL) -> String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? "download.bin" : (last.removingPercentEncoding ?? last)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        let now = Date()
        DispatchQueue.main.async {
            var speed: Double = 0
            if let sample = self.lastSample[id] {
                let dt = now.timeIntervalSince(sample.0)
                if dt < 0.5 { return }
                speed = Double(totalBytesWritten - sample.1) / dt
            }
            self.lastSample[id] = (now, totalBytesWritten)
            if let i = self.items.firstIndex(where: { $0.id == id }) {
                self.items[i].received = totalBytesWritten
                self.items[i].expected = totalBytesExpectedToWrite
                if speed > 0 { self.items[i].bytesPerSecond = speed }
            } else {
                self.items.append(DownloadItem(id: id, name: downloadTask.taskDescription ?? "Download",
                                               received: totalBytesWritten, expected: totalBytesExpectedToWrite, bytesPerSecond: speed))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must move synchronously before returning.
        var name = downloadTask.taskDescription ?? Self.fileName(from: downloadTask.originalRequest?.url ?? location)
        if let suggested = downloadTask.response?.suggestedFilename, !suggested.isEmpty, suggested != "Unknown" {
            if (name as NSString).pathExtension.isEmpty || name == "download.bin" { name = suggested }
        }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let id = downloadTask.taskIdentifier
            DispatchQueue.main.async {
                if let i = self.items.firstIndex(where: { $0.id == id }) { self.items[i].failed = "HTTP \(http.statusCode)" }
            }
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let importDir = docs.appendingPathComponent("Import", isDirectory: true)
        try? FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        let dest = importDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            let id = downloadTask.taskIdentifier
            DispatchQueue.main.async {
                if let i = self.items.firstIndex(where: { $0.id == id }) { self.items[i].failed = error.localizedDescription }
            }
            return
        }
        let id = downloadTask.taskIdentifier
        DispatchQueue.main.async {
            self.items.removeAll { $0.id == id }
            Task { @MainActor in
                MachineStore.shared.refresh()
                MachineStore.shared.lastMessage = "Download abgeschlossen: \(name)"
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled { return }
        DispatchQueue.main.async {
            if let i = self.items.firstIndex(where: { $0.id == id }) {
                self.items[i].failed = error.localizedDescription
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
