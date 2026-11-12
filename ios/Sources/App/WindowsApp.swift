// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

@main
struct WindowsOnIPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var store = MachineStore.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var display = DisplayRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(store)
                .environmentObject(downloads)
                .environmentObject(display)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { url in
                    // Files shared via "Open in…", AirDrop or the Files app.
                    if url.isFileURL { store.importFile(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.onBecameActive()
                    case .background: WinIOSBridge.shared.flushDisks()
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HomeView()
            .fullScreenCover(isPresented: $model.showSession) {
                SessionView()
            }
            .sheet(item: $model.activeSafariURL) { item in
                SafariSheet(url: item.url).ignoresSafeArea()
            }
    }
}
