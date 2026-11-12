# Windows auf iPhone

Native iOS‑App, die **Windows 11 ARM64** auf dem iPhone (optimiert für **iPhone 17 Pro Max**) ausführt – mit JIT‑Beschleunigung über **StikDebug**, Liquid‑Glass‑Oberfläche, voller Touch‑Steuerung und **Vollbild auf externen Monitoren** (HDMI über USB‑C oder AirPlay).

Die Emulations‑Engine (ARM64→ARM64‑JIT, 4‑KB‑Software‑MMU, UEFI/ACPI, NVMe, USB, HD‑Audio, VirtIO‑Netzwerk) stammt aus [ammaarreshi/WindowsiOS](https://github.com/ammaarreshi/WindowsiOS) (GPL‑2.0‑or‑later). Die iOS‑App wurde für dieses Repo komplett neu geschrieben.

## Installation (3 Schritte)

1. **IPA laden** – unter [Releases → Neuester Build](../../releases/tag/latest-build) oder in den GitHub Actions (Artefakt `WindowsOnIPhone-ipa`).
2. **Sideloaden** – mit SideStore, AltStore, Sideloadly oder einem Entwicklerzertifikat. Die IPA enthält `get-task-allow`, damit StikDebug sich anhängen darf.
3. **JIT aktivieren** – in der App auf **„JIT mit StikDebug aktivieren“** tippen. StikDebug startet die App mit dem passenden iOS‑26‑TXM‑JIT‑Skript; die App erkennt das automatisch und startet Windows.

## Windows bekommen

Windows ist **nicht** in der App enthalten (Lizenz). Die App hilft dir:

| Weg | So geht's |
|---|---|
| **Download in der App** | „Herunterladen“ → *Windows 11 ARM64 (ISO)* öffnet die offizielle Microsoft‑Seite in der App. Die ISO wird im Hintergrund geladen und automatisch einsortiert. Danach „Installation aus ISO“ – leere Festplatte wird angelegt, Windows wird direkt auf dem iPhone installiert. |
| **Datei‑Auswahl** | „Importieren“ – der Picker erlaubt **alle Dateitypen** (`.img`, `.raw`, `.hvsparse`, `.iso`, `.fd`, …). `.hvsparse` wird direkt beim Import entpackt (kein doppelter Speicher). |
| **Dateien‑App** | *Auf meinem iPhone → Windows → Import* – Dateien hineinlegen, die App sortiert sie beim Öffnen ein. Auch „Öffnen in…“ und AirDrop funktionieren. |
| **Link** | Eigener Direktlink (z. B. NAS) zu einem Image. |

Die UEFI‑Firmware (EDK2 ArmVirtQemu) ist **in der App enthalten**, `vars.fd` wird automatisch erzeugt.

Ordnerstruktur in *Dateien → Windows*:

```
Machines/Win11/windows11.img       Windows-Festplatte (raw)
Machines/Win11/windows11.hvsparse  gepacktes Image (wird beim Start entpackt)
Machines/Win11/vars.fd             UEFI-NVRAM (automatisch)
Machines/Win11/code.fd             optionale eigene Firmware
ISOs/                              Installations- / Treiber-ISOs (in Windows einlegbar)
Import/                            hier einfach Dateien ablegen
Shared/                            in Windows erreichbar unter \\10.0.2.4
```

### Wie bei Rufus
Die App macht die Windows‑ISO beim ersten Start einmalig für Windows lesbar (exFAT‑Laufwerk) und legt eine `autounattend.xml` darauf. In **„Installation aus ISO“** bzw. den Einstellungen wählst du:
- Anforderungen entfernen (TPM 2.0, Secure Boot, RAM, CPU)
- Kein Microsoft‑Konto – lokales Konto mit Benutzername (ohne Passwort = automatische Anmeldung)
- Datenschutzfragen überspringen · BitLocker verhindern · Region & Tastatur wie auf dem iPhone

### Windows‑Setup‑Helfer
Im Menü **⋯** während der Sitzung:
- **Taste drücken** – für „Press any key to boot from CD“ (passiert beim ISO‑Boot auch automatisch).
- **Anforderungen umgehen** – öffnet im Setup die Eingabeaufforderung und setzt die LabConfig‑Schlüssel (TPM, Secure Boot, RAM, CPU, Speicher).
- **Lokales Konto** – überspringt den Microsoft‑Konto‑Zwang in der Ersteinrichtung.
- **Treiber**: Windows braucht für Festplatte, Tastatur, Maus und Ton **keine** zusätzlichen Treiber. Nur fürs **Internet** braucht es NetKVM: in der App *VirtIO‑Treiber* herunterladen – die ISO wird automatisch als **eigenes Treiber‑Laufwerk** eingelegt (zusätzlich zur Windows‑ISO). Nach der Installation: **⋯ → „Netzwerktreiber installieren“** (Admin‑Abfrage mit „Ja“ bestätigen).

### Zwischenablage iPhone ↔ Windows
- **Einfügen**: Lange auf eine Stelle in Windows drücken → **Einfügen** (oder Einfügen-Taste in der Tastenleiste / im ⋯-Panel).
- Ohne Netzwerk wird der Text eingetippt; **mit** Netzwerktreiber: **⋯ → „Zwischenablage‑Sync einrichten“** – danach wird automatisch in beide Richtungen synchronisiert (startet mit Windows).

## Bedienung

| Geste | Aktion |
|---|---|
| Tippen | Linksklick (Doppelklick wird auf denselben Pixel ausgerichtet) |
| Lange drücken / Zwei‑Finger‑Tippen | Rechtsklick |
| Ziehen | Ziehen mit gedrückter Maustaste (Direkt‑Touch) bzw. Zeiger bewegen (Trackpad) |
| Zwei Finger ziehen | Scrollen |
| Zwei Finger spreizen | Zoomen & schwenken |
| Drei Finger tippen | Steuerleiste ein/aus |

- **Tastatur**: iOS‑Tastatur plus Glas‑Tastenleiste (Esc, Tab, Strg, Alt, ⇧, ⊞ als *Sticky‑Keys*, Pfeile, Entf, Pos1, Ende, Bild↑↓, F1–F12). Deutsches **QWERTZ** und US‑Layout werden korrekt übersetzt (inkl. `@ € { } [ ] \ | ~`).
- **Hardware**: Bluetooth‑/USB‑Tastatur, Maus/Trackpad (Hover + Rechtsklick), Apple Pencil, Game‑Controller (linker Stick = Maus, A = Klick, B = Rechtsklick, rechter Stick = Scrollen).
- **Externer Bildschirm**: HDMI‑Adapter anstecken oder AirPlay‑Bildschirmsynchronisierung starten → Windows läuft im Vollbild (seitenrichtig skaliert) auf dem Monitor, das iPhone wird zum **Trackpad mit Maustasten und Tastatur**.
- **Shortcuts im Menü**: Strg+Alt+Entf, Alt+Tab, Task‑Manager, Explorer, Desktop, Einstellungen, Screenshot, Edge.
- 120‑Hz‑ProMotion‑UI, Querformat‑Sperre, Leistungsanzeige.

## Leistung & iPhone‑17‑Pro‑Max‑Ausstattung
- **RAM bis 8 GB**: automatisch 6 GB auf Geräten mit 12 GB (iPhone 17 Pro/Pro Max), wählbar bis 8 GB. Der Speicher wird beim Aktivieren von JIT „ledger‑exempt“ reserviert (zählt nicht gegen das iOS‑App‑Limit); zusätzlich sind `increased-memory-limit` und `extended-virtual-addressing` eingetragen (werden genutzt, wenn deine Signatur sie erlaubt).
- **Bis zu 6 vCPUs** (A19 Pro: 2 Leistungs‑ + 4 Effizienzkerne; 4 sind meist am flüssigsten).
- **Echte Gerätedaten in Windows** (Systeminformationen, Task‑Manager): Modell z. B. „iPhone 17 Pro Max“ (`iPhone18,2`), Prozessor „Apple A19 Pro“ mit Takt, LPDDR5X‑Speicher.
- **Flüssigere Anzeige**: vollständiger Vergleich in 16‑Zeilen‑Streifen, nur geänderte Bereiche werden hochgeladen, Ausgabe mit bis zu 120 Hz (ProMotion).
- **„Windows optimieren“** (⋯‑Panel oder automatisch bei der ersten Anmeldung): Höchstleistung, kein Ruhezustand, keine Animationen/Transparenz, SysMain/Indexer/Telemetrie aus, keine Hintergrund‑Apps, Widgets/Copilot aus, kein BitLocker.

## Einstellungen
CPU‑Kerne (Standard 4, bis 6), RAM (automatisch bzw. bis 8 GB, „ledger‑exempt“ reserviert), Netzwerk, Ton & Mikrofon, eingelegtes ISO, Touch‑Modus, Trackpad‑Tempo, Tastaturlayout, Autostart, externe Anzeige, Links aus Windows in Safari öffnen (für Anmeldungen/Passkeys).

## Selbst bauen

Die IPA wird von [`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml) auf einem macOS‑Runner gebaut:

1. `scripts/build_ios_deps.sh` – kompiliert libffi, glib, libslirp für iOS (gecacht)
2. `make ios-lib` – Engine als `build/ios/libwinvm.a`
3. EDK2‑Firmware holen, `xcodegen` erzeugt das Projekt aus `ios/project.yml`
4. `xcodebuild` (iOS‑26‑SDK für Liquid Glass) → ad‑hoc‑signiert mit `get-task-allow` → `WindowsOnIPhone.ipa`

Lokal (macOS mit Xcode 26):

```bash
brew install meson ninja pkg-config xcodegen
./scripts/build_ios_deps.sh
make ios-lib
cd ios && xcodegen generate && open WindowsOnIPhone.xcodeproj
```

## Struktur

```
core/ devices/ host/   Emulations-Engine (aus WindowsiOS, GPL-2.0-or-later)
ios/Sources/App        App-Einstieg, Zustandsmodell, StikDebug/JIT
ios/Sources/UI         Liquid-Glass-Oberfläche (Home, Sitzung, Dateien, Downloads, Einstellungen)
ios/Sources/Display    Metal-Anzeige, Touch/Zoom, externer Bildschirm (HDMI/AirPlay)
ios/Sources/Input      Zeiger, Tastatur (Layouts, Sticky-Keys, Makros), Gamepad
ios/Sources/Machine    Dateiverwaltung, Import, Downloads
ios/Sources/Native     ObjC/C-Brücke zur Engine, TXM-JIT-Allocator
```

## Lizenz
GPL‑2.0‑or‑later – siehe [LICENSE](LICENSE) und [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Windows ist eine Marke von Microsoft; dieses Projekt ist nicht mit Microsoft verbunden.
