// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: MachineStore
    @EnvironmentObject var display: DisplayRouter
    @Environment(\.dismiss) private var dismiss
    @State private var showPairingPicker = false
    @State private var pairingMessage: String?
    @State private var showJITLog = false

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
                    Toggle("Leistungsmodus: Maximal (Leistungskerne zuerst)", isOn: $model.maxPerformance)
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
                    Toggle("Daten-Laufwerk für Windows (Setup, Treiber, Optimierung)", isOn: $model.dataDriveEnabled)
                } header: {
                    Text("Laufwerke (ISO)")
                } footer: {
                    Text("Das Daten-Laufwerk wird nur bei einer Neuinstallation automatisch erstellt und danach nie wieder von selbst neu gebaut. Unter „Dateien“ kannst du es löschen oder für eine ISO gezielt erstellen. Es erscheint in Windows als zusätzliches Laufwerk (z. B. E:). Darauf liegen die Netzwerktreiber unter NetKVM\\w11\\ARM64.")
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
                    Picker("Auflösung", selection: Binding(get: { model.resolution }, set: { model.resolution = $0 })) {
                        ForEach(DisplayResolution.allCases) { r in Text(r.label()).tag(r) }
                    }
                    Toggle("Windows auf externem Bildschirm zeigen", isOn: $display.preferExternal)
                    Toggle("Querformat sperren", isOn: $model.landscapeLock)
                    Toggle("Leistungsanzeige", isOn: $model.showStats)
                } header: {
                    Text("Anzeige")
                } footer: {
                    Text("Die Auflösung hat genau das Seitenverhältnis deines iPhones – Windows füllt den ganzen Bildschirm, scharf skaliert. Gilt ab dem nächsten Windows-Start. Bei „Nativ“ in Windows die Skalierung auf 200–300 % stellen. Ist beim Start ein externer Bildschirm verbunden, bekommt Windows dessen Auflösung (bis 2560×1440).\n\nPer USB‑C‑auf‑HDMI‑Adapter oder AirPlay (Kontrollzentrum → Bildschirmsynchronisierung). Windows erscheint im Vollbild auf dem Monitor, dein iPhone wird zum Trackpad mit Tastatur.")
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

                Section {
                    LabeledContent("Status", value: model.jitStatusText)
                    if model.builtInJITAvailable {
                        Picker("JIT aktivieren mit", selection: $model.jitMethodRaw) {
                            Text("Automatisch").tag("auto")
                            Text("Integriert (eigener Helfer)").tag("builtin")
                            Text("StikDebug-App").tag("stikdebug")
                        }
                        HStack {
                            Label(model.isPaired ? "Pairing-Datei gekoppelt" : "Keine Pairing-Datei",
                                  systemImage: model.isPaired ? "checkmark.seal.fill" : "link.badge.plus")
                                .foregroundStyle(model.isPaired ? Theme.good : Theme.warn)
                            Spacer()
                            if let d = JITPairing.pairedDate, model.isPaired {
                                Text(d.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                            }
                        }
                        Button(model.isPaired ? "Pairing-Datei ersetzen …" : "Pairing-Datei koppeln …") { showPairingPicker = true }
                        if model.isPaired {
                            Button("JIT jetzt aktivieren (integriert)") { model.enableJITBuiltIn() }
                                .disabled(model.isJITLive || model.builtInJITRunning)
                            Toggle("Beim Öffnen der App automatisch aktivieren", isOn: $model.autoBuiltInJIT)
                            Button("Pairing-Datei entfernen", role: .destructive) {
                                JITPairing.remove(); model.objectWillChange.send()
                            }
                        }
                        if let m = pairingMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
                        if let e = model.builtInJITError { Text(e).font(.footnote).foregroundStyle(Theme.warn) }
                        if !model.builtInJITLog.isEmpty {
                            DisclosureGroup("Protokoll des JIT-Helfers", isExpanded: $showJITLog) {
                                Text(model.builtInJITLog).font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    Button("StikDebug-Skript in „Dateien“ exportieren") {
                        if store.exportJITScript() != nil { pairingMessage = "Skript gespeichert: StikDebug-JIT-Skript.js" }
                    }
                } header: {
                    Text("JIT")
                } footer: {
                    Text("Integriert: Die App bringt ihren eigenen „StikDebug“ mit (StikJIT, MPL-2.0). Einmalig dieselbe Pairing-Datei wie für StikDebug koppeln, dann reicht LocalDevVPN – die StikDebug-App wird nicht mehr gebraucht. Beim ersten Mal lädt der Helfer das Developer Disk Image (Internet nötig), danach bleibt es bis zum Neustart des iPhones eingebunden.\n\nOhne WLAN: mobile Daten an → LocalDevVPN verbinden → Flugmodus an → zurück in die App → JIT aktivieren. Danach kannst du den Flugmodus wieder ausschalten; Windows läuft weiter.")
                }

                Section("Info") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("Engine", value: "WindowsiOS · GPL-2.0-or-later")
                    Link("Quellcode der Engine", destination: URL(string: "https://github.com/ammaarreshi/WindowsiOS")!)
                    Link("StikDebug", destination: URL(string: "https://github.com/StikDebug/StikDebug")!)
                    Link("StikJIT (eingebauter JIT-Helfer, MPL-2.0)", destination: URL(string: "https://github.com/StikDebug/StikJIT")!)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackground())
            .background(DocumentPicker(isPresented: $showPairingPicker) { urls in
                guard let url = urls.first else { return }
                if let err = JITPairing.importFile(url) { pairingMessage = err } else {
                    pairingMessage = "Gekoppelt: \(url.lastPathComponent)"
                    model.builtInJITError = nil
                    model.objectWillChange.send()
                }
            })
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
                        Text("Variante A – integriert (empfohlen)").font(.title3.weight(.semibold))
                        guideStep(1, "LocalDevVPN installieren", "Die kostenlose App „LocalDevVPN“ (App Store) leitet die Verbindung zurück auf dein iPhone. Einmal öffnen und „Verbinden“ tippen.")
                        guideStep(2, "Pairing-Datei koppeln", "Nimm dieselbe Pairing-Datei wie für StikDebug (z. B. aus idevice_pair / iloader am PC, oder aus dem StikDebug-Ordner in „Dateien“). Einstellungen → JIT → „Pairing-Datei koppeln“ – oder die Datei einfach mit dieser App teilen.")
                        guideStep(3, "JIT aktivieren", "Auf „JIT aktivieren“ tippen. Der eingebaute Helfer verbindet sich, bindet beim ersten Mal das Developer Disk Image ein (Internet nötig) und aktiviert JIT – die StikDebug-App wird nicht mehr gebraucht. Optional passiert das automatisch beim Öffnen der App.")

                        Text("Unterwegs ohne WLAN").font(.title3.weight(.semibold)).padding(.top, 6)
                        guideStep(1, "Mobile Daten an, LocalDevVPN verbinden", "WLAN darf aus sein. In LocalDevVPN „Verbinden“ tippen.")
                        guideStep(2, "Flugmodus an", "Im Kontrollzentrum den Flugmodus einschalten (die VPN-Verbindung bleibt). Dann zurück in diese App und JIT aktivieren.")
                        guideStep(3, "Flugmodus wieder aus", "Sobald „JIT aktiv“ angezeigt wird, kannst du den Flugmodus ausschalten – JIT bleibt bis zum Beenden der App aktiv. Klappt es nicht: LocalDevVPN an lassen, nur „Mobile Daten“ aus und erneut versuchen. Hinweis: Auf manchen iOS-Versionen (z. B. 26.4+) hat Apple diesen Trick eingeschränkt – dann ist kurz ein WLAN nötig (ein beliebiges, auch ohne Internet, z. B. ein Hotspot).")

                        Text("Variante B – StikDebug-App").font(.title3.weight(.semibold)).padding(.top, 6)
                        guideStep(1, "StikDebug installieren", "StikDebug über SideStore/AltStore laden und die Pairing-Datei dort einrichten.")
                        guideStep(2, "JIT aktivieren", "Auf „StikDebug“ tippen. StikDebug startet die App mit Debugger und dem passenden JIT-Skript (iOS 26 TXM). Die App erkennt das automatisch.")

                        if model.builtInJITAvailable && model.isPaired {
                            Button { model.enableJITBuiltIn() } label: {
                                Label("JIT jetzt aktivieren (integriert)", systemImage: "bolt.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .glassProminentButton()
                            .controlSize(.large)
                            .disabled(model.isJITLive || model.builtInJITRunning)
                        }
                        Button { model.enableJITWithStikDebug() } label: {
                            Label("Mit StikDebug aktivieren", systemImage: "bolt.badge.automatic.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .glassButton()
                        .controlSize(.large)
                        Button {
                            if let u = URL(string: "localdevvpn://") { UIApplication.shared.open(u) }
                        } label: {
                            Label("LocalDevVPN öffnen", systemImage: "network.badge.shield.half.filled").frame(maxWidth: .infinity)
                        }
                        .glassButton()

                        Button {
                            store.exportJITScript()
                            store.lastMessage = "Skript gespeichert"
                        } label: {
                            Label("JIT-Skript exportieren (für manuelle Zuweisung in StikDebug)", systemImage: "doc.badge.arrow.up").frame(maxWidth: .infinity)
                        }
                        .glassButton()

                        Link(destination: URL(string: "https://github.com/StikDebug/StikDebug")!) {
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
