// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

enum HomeSheet: String, Identifiable {
    case files, download, settings, jitGuide, install
    var id: String { rawValue }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MachineStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var display: DisplayRouter
    @State private var sheet: HomeSheet?
    @State private var showPicker = false

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    heroCard
                    GlassGroup(spacing: 14) {
                        VStack(spacing: 14) {
                            jitCard
                            windowsCard
                            if !store.jobs.isEmpty || !downloads.items.isEmpty { activityCard }
                            quickTiles
                        }
                    }
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .refreshable { store.refresh(); model.sync() }
        }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .files: LibraryView()
                case .download: DownloadSheet()
                case .settings: SettingsView()
                case .jitGuide: JITGuideView()
                case .install: InstallSheet()
                }
            }
            .appEnvironment()
        }
        .background(DocumentPicker(isPresented: $showPicker) { urls in store.importFiles(urls) })
        .alert("Hinweis", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.lastError ?? "") }
        .alert("StikDebug nicht gefunden", isPresented: $model.stikDebugMissing) {
            Button("Anleitung") { sheet = .jitGuide }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Installiere StikDebug, um JIT zu aktivieren. Die Anleitung zeigt dir, wie.")
        }
        .onAppear { model.onBecameActive() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Windows")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("11 ARM64 · nativ auf deinem iPhone")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            GlassIconButton(systemName: "gearshape.fill") { sheet = .settings }
        }
        .padding(.top, 8)
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.0, green: 0.36, blue: 0.85), Color(red: 0.0, green: 0.12, blue: 0.40)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if let img = lastScreenshot {
                    Image(uiImage: img).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .opacity(model.isVMRunning ? 1 : 0.55)
                } else {
                    WindowsGlyph().frame(width: 74, height: 74).opacity(0.9)
                }
                if model.isUnpacking {
                    VStack(spacing: 10) {
                        ProgressView(value: model.unpackProgress).tint(.white).frame(width: 200)
                        Text("Windows wird vorbereitet … \(Int(model.unpackProgress * 100)) %")
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 18)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    StatusDot(color: model.isVMRunning ? Theme.good : (model.isJITLive ? Theme.accent : Theme.warn))
                    Text(model.isVMRunning ? "Läuft" : (store.isReadyToBoot ? "Bereit" : "Einrichtung nötig"))
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glassCapsule(interactive: false)
                .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if display.externalConnected {
                    Label(display.externalDescription, systemImage: "tv.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassCapsule(interactive: false)
                        .padding(10)
                }
            }

            Text(primaryStatus)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: primaryIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .glassProminentButton()
            .controlSize(.large)
            .disabled(model.isUnpacking || store.isConverting)
        }
        .padding(16)
        .glassCard(cornerRadius: 32)
    }

    private var lastScreenshot: UIImage? {
        let url = store.documents.appendingPathComponent("latest_screen.png")
        return UIImage(contentsOfFile: url.path)
    }

    private var primaryStatus: String {
        if model.isVMRunning { return model.vmStatusText }
        if !model.isJITLive { return "Schritt 1: Aktiviere JIT mit StikDebug – danach startet Windows mit voller Geschwindigkeit." }
        if !store.hasWindows {
            return store.isos.isEmpty
                ? "Schritt 2: Lade Windows 11 ARM64 herunter oder importiere ein Image."
                : "Schritt 2: Bereite die Installation aus deiner ISO vor."
        }
        return model.vmStatusText
    }

    private var primaryTitle: String {
        if model.isVMRunning { return "Zu Windows wechseln" }
        if !model.isJITLive { return "JIT mit StikDebug aktivieren" }
        if !store.hasWindows { return store.isos.isEmpty ? "Windows herunterladen" : "Installation vorbereiten" }
        return "Windows starten"
    }

    private var primaryIcon: String {
        if model.isVMRunning { return "macwindow" }
        if !model.isJITLive { return "bolt.fill" }
        if !store.hasWindows { return store.isos.isEmpty ? "arrow.down.circle.fill" : "wrench.and.screwdriver.fill" }
        return "play.fill"
    }

    private func primaryAction() {
        if model.isVMRunning { model.showSession = true; return }
        if !model.isJITLive { model.enableJITWithStikDebug(); return }
        if !store.hasWindows { sheet = store.isos.isEmpty ? .download : .install; return }
        model.start()
    }

    // MARK: Cards

    private var jitCard: some View {
        StepCard(number: 1,
                 title: "JIT-Beschleunigung",
                 subtitle: model.jitStatusText,
                 done: model.isJITLive,
                 icon: "bolt.fill") {
            HStack(spacing: 10) {
                Button { model.enableJITWithStikDebug() } label: {
                    Label("StikDebug", systemImage: "bolt.badge.automatic.fill").frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .disabled(model.isJITLive)
                Button { sheet = .jitGuide } label: {
                    Label("Anleitung", systemImage: "questionmark.circle").frame(maxWidth: .infinity)
                }
                .glassButton()
            }
        }
    }

    private var windowsCard: some View {
        StepCard(number: 2,
                 title: "Windows-Image",
                 subtitle: windowsSubtitle,
                 done: store.hasWindows && !store.diskLooksBlank,
                 icon: "internaldrive.fill") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button { sheet = .download } label: {
                        Label("Herunterladen", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    Button { showPicker = true } label: {
                        Label("Importieren", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
                if !store.isos.isEmpty && (!store.hasWindows || store.diskLooksBlank) {
                    Button { sheet = .install } label: {
                        Label("Installation aus ISO", systemImage: "opticaldisc.fill").frame(maxWidth: .infinity)
                    }
                    .glassProminentButton()
                }
            }
        }
    }

    private var windowsSubtitle: String {
        if store.hasDisk {
            let used = store.allocatedSize(store.diskURL).byteString
            return store.diskLooksBlank ? "Leere Festplatte – Windows wird aus der ISO installiert" : "Festplatte bereit · \(used) belegt"
        }
        if store.hasSparse { return "Gepacktes Image – wird beim ersten Start entpackt" }
        if !store.isos.isEmpty { return "\(store.isos.count) ISO gefunden – Installation möglich" }
        return "Noch kein Windows vorhanden"
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Aktivität", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            ForEach(store.jobs) { job in
                ProgressRow(title: job.name, detail: job.detail, progress: job.progress, failed: nil, onCancel: nil)
            }
            ForEach(downloads.items) { item in
                ProgressRow(title: item.name,
                            detail: downloadDetail(item),
                            progress: item.progress,
                            failed: item.failed,
                            onCancel: { item.failed == nil ? downloads.cancel(item) : downloads.dismiss(item) })
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func downloadDetail(_ item: DownloadItem) -> String {
        if let f = item.failed { return "Fehler: \(f)" }
        let speed = item.bytesPerSecond > 0 ? " · \(Int64(item.bytesPerSecond).byteString)/s" : ""
        if item.expected > 0 { return "\(item.received.byteString) von \(item.expected.byteString)\(speed)" }
        return "\(item.received.byteString)\(speed)"
    }

    private var quickTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            QuickTile(icon: "folder.fill", title: "Dateien", subtitle: "\(store.files.count + store.isos.count) Objekte") { sheet = .files }
            QuickTile(icon: "arrow.down.to.line.circle.fill", title: "Downloads", subtitle: downloads.items.isEmpty ? "ISO & Treiber" : "\(downloads.items.count) aktiv") { sheet = .download }
            QuickTile(icon: display.externalConnected ? "tv.fill" : "tv", title: "Bildschirm",
                      subtitle: display.externalConnected ? "Extern verbunden" : "AirPlay / HDMI") { sheet = .settings }
            QuickTile(icon: "internaldrive", title: "Speicher", subtitle: "\(store.freeBytes.byteString) frei") { sheet = .files }
        }
    }

    private var footer: some View {
        Text("Engine: WindowsiOS (GPL-2.0) · ARM64→ARM64 JIT · UEFI EDK2")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, 6)
    }
}

// MARK: Components

struct StepCard<Actions: View>: View {
    let number: Int
    let title: String
    let subtitle: String
    let done: Bool
    let icon: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(done ? Theme.good.opacity(0.25) : Theme.accent.opacity(0.22))
                    Image(systemName: done ? "checkmark" : icon)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(done ? Theme.good : Theme.accent)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(number). \(title)").font(.headline)
                    Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            actions()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct QuickTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 24, interactive: true)
    }
}

struct ProgressRow: View {
    let title: String
    let detail: String
    let progress: Double
    let failed: String?
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            ProgressView(value: min(1, max(0, progress)))
                .tint(failed == nil ? Theme.accent : Theme.bad)
            Text(detail).font(.caption).foregroundStyle(failed == nil ? Color.white.opacity(0.65) : Theme.bad)
        }
    }
}

/// A neutral four-pane window glyph.
struct WindowsGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let g = s * 0.07
            let p = (s - g) / 2
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: p * 0.16, style: .continuous)
                        .fill(Color.white.opacity([0.95, 0.8, 0.8, 0.65][i]))
                        .frame(width: p, height: p)
                        .offset(x: CGFloat(i % 2) * (p + g), y: CGFloat(i / 2) * (p + g))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
