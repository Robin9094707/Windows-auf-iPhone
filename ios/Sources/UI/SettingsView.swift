// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MachineStore
    @EnvironmentObject var display: DisplayRouter
    @Environment(\.dismiss) private var dismiss

    private let profile = DeviceProfile.current

    static func gb(_ mb: Int) -> String {
        let v = Double(mb) / 1024
        return v == v.rounded() ? "\(Int(v)) GB" : String(format: "%.1f GB", v).replacingOccurrences(of: ".", with: ",")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Gerät", value: "\(profile.name) · \(profile.chip)")
                    LabeledContent("Reserviert für Windows",
                                   value: WinIOSBridge.shared.reservedGuestRamMB > 0
                                       ? "\(Self.gb(Int(WinIOSBridge.shared.reservedGuestRamMB))) RAM" : "noch nicht (JIT inaktiv)")
                }

                Section {
                    Stepper("Prozessorkerne: \(model.cpuCount) von \(profile.cpuCores)", value: $model.cpuCount, in: 1...min(6, max(1, profile.cpuCores)))
                    Picker("Arbeitsspeicher", selection: $model.ramMB) {
                        Text("Automatisch (\(Self.gb(profile.automaticRamMB)))").tag(0)
                        ForEach(profile.ramChoices, id: \.self) { mb in
                            Text(mb >= 8192 ? "\(Self.gb(mb)) (Maximum)" : Self.gb(mb)).tag(mb)
                        }
                    }
                    Toggle("Netzwerk (Internet)", isOn: $model.networkEnabled)
                    Toggle("Ton & Mikrofon", isOn: $model.soundEnabled)
                    Toggle("Automatisch starten, sobald JIT aktiv ist", isOn: $model.autostart)
                } header: {
                    Text("Virtuelle Maschine")
                } footer: {
                    Text("\(profile.name) mit \(profile.physicalMemoryGB) GB RAM und \(profile.cpuCores) Kernen (\(profile.performanceCores) Leistungskerne). Der RAM wird beim Aktivieren von JIT reserviert – eine Änderung gilt nach dem nächsten JIT-Start (App über StikDebug neu öffnen). 4 Kerne sind am flüssigsten; 6 nutzt zusätzlich die Effizienzkerne.")
                }

                Section {
                    Picker("Eingelegtes ISO", selection: $model.mountedISO) {
                        Text("Keins").tag("")
                        ForEach(store.isos) { iso in Text(iso.name).tag(iso.name) }
                    }
                    Picker("Treiber-Laufwerk", selection: $model.driverISOSetting) {
                        Text("Automatisch (virtio-win)").tag("")
                        Text("Keins").tag("-")
                        ForEach(store.isos) { iso in Text(iso.name).tag(iso.name) }
                    }
                    Toggle("Beim Booten von ISO automatisch Taste drücken", isOn: $model.pressKeyForISOBoot)
                } header: {
                    Text("Laufwerke (ISO)")
                } footer: {
                    Text("Das Treiber-Laufwerk erscheint in Windows als zusätzliches Laufwerk (z. B. E:). Darauf liegen die Netzwerktreiber unter NetKVM\\w11\\ARM64.")
                }

                Section {
                    Picker("Touch-Modus", selection: Binding(get: { model.touchMode }, set: { model.touchMode = $0 })) {
                        ForEach(TouchMode.allCases) { m in Label(m.title, systemImage: m.icon).tag(m) }
                    }
                    VStack(alignment: .leading) {
                        Text("Trackpad-Geschwindigkeit")
                        Slider(value: $model.trackpadSpeed, in: 0.4...2.5, onEditingChanged: { _ in
                            PointerController.shared.trackpadSpeed = model.trackpadSpeed
                        })
                    }
                    Toggle("Langes Drücken: Menü (Einfügen, Kopieren …)", isOn: $model.longPressMenu)
                    Toggle("Zwischenablage automatisch synchronisieren", isOn: Binding(
                        get: { ClipboardBridge.shared.autoSync },
                        set: { ClipboardBridge.shared.autoSync = $0; model.objectWillChange.send() }))
                    Picker("Windows-Tastaturlayout", selection: Binding(get: { model.keyboardLayout }, set: { model.keyboardLayout = $0 })) {
                        ForEach(WindowsKeyboardLayout.allCases) { l in Text(l.title).tag(l) }
                    }
                } header: {
                    Text("Eingabe")
                } footer: {
                    Text("Tippen = Klick · Lange drücken = Menü (Einfügen/Kopieren/Rechtsklick) · Zwei Finger tippen = Rechtsklick · Zwei Finger ziehen = Scrollen · Zoomen mit zwei Fingern · Drei Finger = Menü ein/aus. Maus, Trackpad, Apple Pencil, Bluetooth-Tastaturen und Controller werden unterstützt.")
                }

                Section {
                    HStack {
                        Label("Externer Bildschirm", systemImage: display.externalConnected ? "tv.fill" : "tv")
                        Spacer()
                        Text(display.externalConnected ? display.externalDescription : "nicht verbunden")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Windows auf externem Bildschirm zeigen", isOn: $display.preferExternal)
                    Toggle("Querformat sperren", isOn: $model.landscapeLock)
                    Toggle("Leistungsanzeige", isOn: $model.showStats)
                } header: {
                    Text("Anzeige")
                } footer: {
                    Text("Per USB‑C‑auf‑HDMI‑Adapter oder AirPlay (Kontrollzentrum → Bildschirmsynchronisierung). Windows erscheint im Vollbild auf dem Monitor, dein iPhone wird zum Trackpad mit Tastatur.")
                }

                Section {
                    SetupOptionsCard()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                Section("Windows-Links") {
                    Toggle("Links aus Windows in Safari öffnen (Anmeldungen, Passkeys)", isOn: Binding(
                        get: { WinIOSBridge.shared.useSafariForGuestLinks },
                        set: { WinIOSBridge.shared.useSafariForGuestLinks = $0; model.objectWillChange.send() }))
                }

                Section("JIT") {
                    LabeledContent("Status", value: model.jitStatusText)
                    Button("StikDebug-Skript in „Dateien“ exportieren") {
                        if store.exportJITScript() != nil { store.lastMessage = "Skript gespeichert: StikDebug-JIT-Skript.js" }
                    }
                }

                Section("Info") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("Engine", value: "WindowsiOS · GPL-2.0-or-later")
                    Link("Quellcode der Engine", destination: URL(string: "https://github.com/ammaarreshi/WindowsiOS")!)
                    Link("StikDebug", destination: URL(string: "https://github.com/StephenDev0/StikDebug")!)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackground())
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

struct JITGuideView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MachineStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        guideStep(1, "StikDebug installieren", "Lade StikDebug (über SideStore, AltStore oder TestFlight) und richte die Pairing-Datei einmalig ein – siehe Anleitung auf der StikDebug-Seite.")
                        guideStep(2, "Diese App sideloaden", "Installiere die IPA mit SideStore, AltStore, Sideloadly oder einem Entwicklerzertifikat. Wichtig: Signiert mit Entwickler-Profil, damit „get-task-allow“ erhalten bleibt.")
                        guideStep(3, "JIT aktivieren", "Tippe auf „Mit StikDebug aktivieren“. StikDebug startet die App mit Debugger und dem passenden JIT-Skript (iOS 26 TXM). Die App erkennt das automatisch.")
                        guideStep(4, "Fertig", "Sobald JIT aktiv ist, reserviert die App 384 MB JIT-Speicher und bis zu 4,5 GB RAM für Windows – dann startet Windows automatisch.")

                        Button { model.enableJITWithStikDebug() } label: {
                            Label("Mit StikDebug aktivieren", systemImage: "bolt.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .glassProminentButton()
                        .controlSize(.large)

                        Button {
                            store.exportJITScript()
                            store.lastMessage = "Skript gespeichert"
                        } label: {
                            Label("JIT-Skript exportieren (für manuelle Zuweisung in StikDebug)", systemImage: "doc.badge.arrow.up").frame(maxWidth: .infinity)
                        }
                        .glassButton()

                        Link(destination: URL(string: "https://github.com/StephenDev0/StikDebug")!) {
                            Label("StikDebug auf GitHub", systemImage: "safari").frame(maxWidth: .infinity)
                        }
                        .glassButton()

                        Text("Status: \(model.jitStatusText)")
                            .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(18)
                }
            }
            .navigationTitle("JIT einrichten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }

    private func guideStep(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.headline)
                .frame(width: 34, height: 34)
                .glassCircle(tint: Theme.accent, interactive: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.footnote).foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
