// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject var store: MachineStore
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var confirmDelete: MachineFile?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        storageCard
                        section("Windows-Maschine", files: store.files, emptyText: "Noch keine Dateien. Importiere ein Image oder installiere aus einer ISO.")
                        section("ISO-Laufwerke", files: store.isos, emptyText: "Keine ISOs. Lade Windows 11 ARM64 oder Treiber herunter.")
                        firmwareCard
                        howToCard
                    }
                    .padding(18)
                }
                .refreshable { store.refresh() }
            }
            .navigationTitle("Dateien")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showPicker = true } label: { Label("Importieren", systemImage: "plus") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .background(DocumentPicker(isPresented: $showPicker) { urls in store.importFiles(urls) })
            .confirmationDialog("„\(confirmDelete?.name ?? "")“ löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    if let f = confirmDelete {
                        if f.name == model.mountedISO { model.mountedISO = "" }
                        store.delete(f)
                    }
                    confirmDelete = nil
                }
            } message: {
                Text(confirmDelete?.kind == .diskImage ? "Deine Windows-Installation und alle Daten darin gehen verloren." : "Die Datei wird vom iPhone entfernt.")
            }
            .onAppear { store.refresh() }
        }
    }

    private var storageCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "internaldrive.fill").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading) {
                Text("Freier Speicher").font(.headline)
                Text(store.freeBytes.byteString).font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if !store.jobs.isEmpty { ProgressView() }
        }
        .padding(16).glassCard()
    }

    private func section(_ title: String, files: [MachineFile], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if files.isEmpty {
                Text(emptyText).font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(files) { f in
                HStack(spacing: 12) {
                    Image(systemName: f.kind.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(f.kind == .unsupported ? Theme.warn : Theme.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(detail(f)).font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    if f.kind == .iso {
                        Button {
                            model.mountedISO = model.mountedISO == f.name ? "" : f.name
                        } label: {
                            Text(model.mountedISO == f.name ? "Auswerfen" : "Einlegen").font(.caption.weight(.semibold))
                        }
                        .glassButton()
                        .controlSize(.small)
                    }
                    Menu {
                        ShareLink(item: f.url) { Label("Teilen / Exportieren", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { confirmDelete = f } label: { Label("Löschen", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func detail(_ f: MachineFile) -> String {
        var s = "\(f.kind.title) · \(f.size.byteString)"
        if f.kind == .diskImage && f.allocated < f.size { s += " (belegt \(f.allocated.byteString))" }
        if f.kind == .iso && model.mountedISO == f.name { s += " · eingelegt" }
        return s
    }

    private var firmwareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("UEFI-Firmware", systemImage: "cpu").font(.headline)
            Text(store.fm.fileExists(atPath: store.customFirmwareURL.path)
                 ? "Eigene code.fd wird verwendet."
                 : (store.bundledFirmwareURL != nil ? "Integrierte EDK2-Firmware (in der App enthalten)." : "Keine Firmware gefunden – bitte code.fd importieren."))
                .font(.footnote).foregroundStyle(.white.opacity(0.7))
            Button(role: .destructive) { store.resetNVRAM() } label: {
                Label("UEFI-Einstellungen zurücksetzen (vars.fd)", systemImage: "arrow.counterclockwise")
            }
            .glassButton()
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Über die Dateien-App", systemImage: "folder").font(.headline)
            Text("Öffne Dateien → Auf meinem iPhone → Windows → Import und lege Images oder ISOs hinein. Die App sortiert sie automatisch ein. Der Ordner „Shared“ erscheint in Windows unter \\\\10.0.2.4.")
                .font(.footnote).foregroundStyle(.white.opacity(0.7))
            Button {
                if let url = URL(string: "shareddocuments://" + store.documents.path) { UIApplication.shared.open(url) }
            } label: {
                Label("In Dateien-App öffnen", systemImage: "arrow.up.forward.app")
            }
            .glassButton()
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
