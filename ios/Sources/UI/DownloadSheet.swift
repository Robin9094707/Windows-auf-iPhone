// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

struct DownloadSheet: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var store: MachineStore
    @Environment(\.dismiss) private var dismiss
    @State private var customURL = ""
    @State private var browserPreset: DownloadPreset?
    @State private var startedName: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(DownloadPreset.allCases) { preset in
                            Button {
                                if preset.isDirect {
                                    downloads.start(preset.pageURL)
                                    startedName = DownloadManager.fileName(from: preset.pageURL)
                                } else {
                                    browserPreset = preset
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: preset == .windowsISO ? "opticaldisc.fill" : "network")
                                        .font(.system(size: 26, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 40)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(preset.title).font(.headline).foregroundStyle(.white)
                                        Text(preset.subtitle).font(.footnote).foregroundStyle(.white.opacity(0.7))
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .glassCard(interactive: true)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Eigenes Image per Link", systemImage: "link").font(.headline)
                            Text("Direkter Link zu einer .img-, .hvsparse- oder .iso-Datei (z. B. von deinem NAS oder Cloud-Speicher).")
                                .font(.footnote).foregroundStyle(.white.opacity(0.7))
                            TextField("https://…/windows11.hvsparse", text: $customURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .padding(12)
                                .glassCard(cornerRadius: 14)
                            Button {
                                if let u = URL(string: customURL.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true {
                                    downloads.start(u)
                                    startedName = DownloadManager.fileName(from: u)
                                    customURL = ""
                                }
                            } label: {
                                Label("Download starten", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                            }
                            .glassProminentButton()
                            .disabled(URL(string: customURL)?.scheme?.hasPrefix("http") != true)
                        }
                        .padding(16)
                        .glassCard()

                        if !downloads.items.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Laufende Downloads", systemImage: "arrow.down.to.line").font(.headline)
                                ForEach(downloads.items) { item in
                                    ProgressRow(title: item.name,
                                                detail: item.failed.map { "Fehler: \($0)" } ?? "\(item.received.byteString) / \(item.expected > 0 ? item.expected.byteString : "?")",
                                                progress: item.progress, failed: item.failed,
                                                onCancel: { item.failed == nil ? downloads.cancel(item) : downloads.dismiss(item) })
                                }
                                Text("Downloads laufen im Hintergrund weiter. Fertige Dateien werden automatisch einsortiert.")
                                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(16)
                            .glassCard()
                        }

                        Text("Hinweis: Windows ist nicht in der App enthalten. Die ISO stammt direkt von Microsoft; für die Nutzung brauchst du eine gültige Windows-Lizenz.")
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 6)
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Windows laden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .sheet(item: $browserPreset) { preset in
                NavigationStack {
                    DownloadBrowser(url: preset.pageURL) { name in
                        startedName = name
                        browserPreset = nil
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Microsoft")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Schließen") { browserPreset = nil } }
                    }
                }
            }
            .alert("Download gestartet", isPresented: Binding(get: { startedName != nil }, set: { if !$0 { startedName = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("„\(startedName ?? "")“ wird im Hintergrund geladen.")
            }
        }
    }
}

struct InstallSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MachineStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedISO: String = ""
    @State private var sizeGB: Double = 64
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Windows wird direkt auf deinem iPhone installiert – wie auf einem PC. Das dauert eine Weile, ist aber nur einmal nötig.")
                            .font(.callout).foregroundStyle(.white.opacity(0.8))

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Installationsmedium", systemImage: "opticaldisc").font(.headline)
                            ForEach(store.isos) { iso in
                                Button { selectedISO = iso.name } label: {
                                    HStack {
                                        Image(systemName: selectedISO == iso.name ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(Theme.accent)
                                        VStack(alignment: .leading) {
                                            Text(iso.name).lineLimit(1)
                                            Text(iso.size.byteString).font(.caption).foregroundStyle(.white.opacity(0.6))
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16).glassCard()

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Festplattengröße: \(Int(sizeGB)) GB", systemImage: "internaldrive").font(.headline)
                            Slider(value: $sizeGB, in: 32...256, step: 8)
                            Text("Belegt nur so viel Speicher, wie Windows tatsächlich nutzt. Frei: \(store.freeBytes.byteString). Empfohlen: mind. 25 GB frei.")
                                .font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        .padding(16).glassCard()

                        SetupOptionsCard()

                        VStack(alignment: .leading, spacing: 8) {
                            Label("So geht's", systemImage: "list.number").font(.headline)
                            Text("1. Start drücken – die App tippt automatisch „Leertaste“, damit von der ISO gebootet wird.")
                            Text("2. Die App macht die ISO einmalig für Windows lesbar (ein paar Minuten).")
                            Text("3. Installation durchlaufen lassen – die Optionen oben werden automatisch angewendet.")
                            Text("4. Danach in den Einstellungen das ISO auswerfen.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(16).glassCard()

                        Button(action: prepare) {
                            Label("Festplatte anlegen & installieren", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .glassProminentButton()
                        .controlSize(.large)
                        .disabled(selectedISO.isEmpty)
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Installation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .onAppear { if selectedISO.isEmpty { selectedISO = store.isos.first(where: { !$0.name.lowercased().contains("virtio") })?.name ?? store.isos.first?.name ?? "" } }
            .alert("Fehler", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func prepare() {
        do {
            if !store.hasDisk || store.diskLooksBlank {
                try store.createBlankDisk(gigabytes: Int(sizeGB))
            }
            model.mountedISO = selectedISO
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if model.isJITLive { model.start() } else { model.enableJITWithStikDebug() }
            }
        } catch {
            self.error = "Festplatte konnte nicht angelegt werden: \(error.localizedDescription)"
        }
    }
}
