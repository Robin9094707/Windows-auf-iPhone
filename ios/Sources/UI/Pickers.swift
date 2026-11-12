// SPDX-License-Identifier: GPL-2.0-or-later
// File picker that accepts *every* file type, Safari sheet, and the in-app
// download browser for Microsoft's official Windows 11 ARM64 page.
import SafariServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

extension UIApplication {
    /// The top-most presented view controller of the foreground app window.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// Presents UIDocumentPickerViewController directly from UIKit (more reliable than .fileImporter).
/// All content types are allowed so nothing is greyed out.
final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerCoordinator()
    private var onPick: (([URL]) -> Void)?

    static let allTypes: [UTType] = {
        var types: [UTType] = [.item, .data, .content, .diskImage, .archive, .zip]
        for ext in ["iso", "img", "raw", "hvsparse", "fd", "bin", "vhdx", "qcow2"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    func present(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.allTypes, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        UIApplication.topViewController()?.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick?(urls)
        onPick = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick = nil
    }
}

/// SwiftUI hook: flip `isPresented` to open the picker.
struct DocumentPicker: View {
    @Binding var isPresented: Bool
    let onPick: ([URL]) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isPresented) { _, show in
                guard show else { return }
                isPresented = false
                // Let any closing sheet finish first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    DocumentPickerCoordinator.shared.present(onPick: onPick)
                }
            }
    }
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Theme.accent)
        vc.dismissButtonStyle = .done
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// In-app browser that hands any ISO / image download to the background DownloadManager.
struct DownloadBrowser: UIViewRepresentable {
    let url: URL
    var onDownloadStarted: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDownloadStarted: onDownloadStarted) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .clear
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        let onDownloadStarted: (String) -> Void
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]
        static let downloadExtensions: Set<String> = ["iso", "img", "raw", "hvsparse", "fd", "esd", "zip", "bin"]

        init(onDownloadStarted: @escaping (String) -> Void) { self.onDownloadStarted = onDownloadStarted }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = navigationAction.request.url, Self.downloadExtensions.contains(u.pathExtension.lowercased()) {
                DownloadManager.shared.start(u)
                onDownloadStarted(DownloadManager.fileName(from: u))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let u = navigationResponse.response.url {
                let isAttachment = (navigationResponse.response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") ?? false
                if Self.downloadExtensions.contains(u.pathExtension.lowercased()) || isAttachment || !navigationResponse.canShowMIMEType {
                    DownloadManager.shared.start(u, suggestedName: navigationResponse.response.suggestedFilename)
                    onDownloadStarted(navigationResponse.response.suggestedFilename ?? DownloadManager.fileName(from: u))
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        // Fallback for downloads WebKit insists on handling itself (e.g. blob: / POST).
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("Import", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(suggestedFilename)
            try? FileManager.default.removeItem(at: dest)
            downloadDestinations[ObjectIdentifier(download)] = dest
            onDownloadStarted(suggestedFilename)
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            Task { @MainActor in
                MachineStore.shared.refresh()
                MachineStore.shared.lastMessage = "Download abgeschlossen."
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            Task { @MainActor in MachineStore.shared.lastError = "Download fehlgeschlagen: \(error.localizedDescription)" }
        }
    }
}
