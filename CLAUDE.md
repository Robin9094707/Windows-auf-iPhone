# Windows auf iPhone – Hinweise für die Weiterarbeit

Native iOS-App (SwiftUI, Liquid Glass), die Windows 11 ARM64 auf dem iPhone 17 Pro Max ausführt.
Engine (ARM64→ARM64-JIT, MMU, UEFI/ACPI, NVMe, xHCI, HDA, VirtIO-Net) stammt aus
github.com/ammaarreshi/WindowsiOS (GPL-2.0-or-later); die iOS-App ist neu geschrieben.
Der Nutzer spricht Deutsch, hat keinen Mac und sideloadet die IPA (SideStore) + JIT über StikDebug.

## Bauen & Ausliefern
- Es gibt keinen lokalen Mac: **gebaut wird nur in GitHub Actions** (`.github/workflows/build-ipa.yml`).
  - Job `firmware` (ubuntu): `firmware/build_firmware.sh` baut EDK2 ArmVirtQemu mit `firmware/patch_ramfb.py` (gecacht).
  - Job `build` (macos-15, neuestes Xcode 26): `scripts/build_ios_deps.sh` (glib/libffi/libslirp, gecacht) →
    `make ios-lib` → `xcodegen` (`ios/project.yml`) → `xcodebuild` → ad-hoc `codesign` mit Entitlements → IPA.
  - Ergebnis: Release-Tag `latest-build` (`WindowsOnIPhone.ipa`). Erfolg nur, wenn das Log `** BUILD SUCCEEDED **` enthält.
- Nach jedem grünen Build die IPA per REST laden und dem Nutzer schicken
  (`gh api -H "Accept: application/octet-stream" repos/<owner>/<repo>/releases/assets/<id> > dist/WindowsOnIPhone.ipa`).
- Auf Linux lässt sich C-Code mit einem Stub für `TargetConditionals.h` syntaktisch prüfen; Swift/Metal nur über CI.

## Aufbau
- `core/ devices/ host/` – Engine (C). Eigene Ergänzungen:
  - `host/iso2exfat.c` – ISO (UDF/ISO9660/Joliet) → MBR+exFAT-Image (Windows kann ISOs auf NVMe nicht lesen).
    Reserviert 64-KB-Platzhalter (`autounattend.xml`, `sources/autounattend.xml`, `iPhone-Optimieren.cmd`).
    Getestet mit genisoimage/pycdlib-ISOs + `fsck.exfat` + Byte-Vergleich.
  - `devices/acpi.c` – `hv_smbios_set_device` (echte iPhone-Daten für Task-Manager), `hv_fw_set_resolution` (fw_cfg `opt/org.winiphone/resolution`).
  - `devices/winvirt.c` – `hv_winvirt_add_nvme` (3. NVMe = Daten-Laufwerk). `HV_MAX_CPUS` iOS = 6.
  - `devices/nvme.c` – I/O asynchron: Doorbell legt Befehle in einen Ring, 4 Worker-Threads machen Zero-Copy
    `preadv/pwritev` direkt in den Gast-RAM (+ `hv_dma_written`), CQEs/Interrupts postet `hv_nvme_poll` auf CPU 0
    (Board-Tick, Device-Lock). Flush = Zaun. TRIM → `F_PUNCHHOLE` (gibt iPhone-Speicher frei). `HV_NVME_SYNC=1` = alt.
    Unter Linux testbar mit Stubs (siehe Commit „async NVMe“: Test mit TSan).
  - `devices/fb_metal.m` – Streifen-Vergleich, nur geänderte Bereiche hochladen, 120 Hz, bikubischer Shader (Fallback bilinear).
- `ios/Sources/Native` – ObjC-Bridge (`winios_bridge.m`), TXM-JIT/RAM-Reservierung (`winios_jit.c`, RAM-Ziel bis 8 GB).
- `ios/Sources/App` – `AppModel` (Zustand, Start, Makros), `DeviceProfile` (hw.machine → Modell/Chip).
- `ios/Sources/Machine` – `MachineStore` (Dateien, Import, Laufwerke, Bereinigen), `DownloadManager`,
  `UnattendBuilder` (Rufus-artige Optionen + Optimierer-Skript), `WindowsTools` (Zwischenablage-Skripte im Shared-Ordner).
- `ios/Sources/Display` – Metal-Canvas (Touch, Zoom, Langdruck-Menü), externe Displays, `DisplayResolution`.
- `ios/Sources/Input` – Zeiger, Tastatur (DE/US-Layout, Sticky-Keys, Makros), Gamepad, Zwischenablage.
- `ios/JITHelper` – App-Extension (eigener Prozess) = eingebauter „StikDebug“: StikJIT (MPL-2.0, Release 2.0.1,
  per `scripts/fetch_stikjit.sh` nach `ios/Vendor/StikJIT` geholt, nicht eingecheckt) hängt den Debugger über
  LocalDevVPN (10.7.0.1) an die App und führt `henge-jit.js` aus. Gestartet über private `NSExtension`-API
  (`Native/winios_jithelper.m`, wie LiveContainer), Fortschritt per Darwin-Notify-State, Ergebnis per completeRequest.
  Pairing-Datei: `Application Support/JIT/pairingFile.plist` (`Machine/JITPairing.swift`).
- `ios/Sources/UI` – Glas-Oberfläche; `Glass.swift` kapselt iOS-26-Liquid-Glass mit `#if compiler(>=6.2)`-Fallback.

## Wichtige Erkenntnisse / Fallen
- Windows-Setup sieht eine als Festplatte angehängte ISO nicht („Medientreiber fehlt“) → exFAT-Daten-Laufwerk.
- Daten-Laufwerk wird **nur bei Neuinstallation** automatisch erstellt, nie automatisch neu gebaut (Nutzerwunsch).
- Windows nutzt die GOP-Auflösung der Firmware; die Original-Firmware kennt nur 640×480/800×600/1024×768.
- Zustand im `AppModel` nur bei echter Änderung veröffentlichen (sonst schließen sich Menüs/Picker ständig).
- Keine System-`Menu`s im Sitzungsbildschirm – eigenes Glas-Panel verwenden.
- EDK2-Quellen haben CRLF-Zeilenenden (Patch-Skript erhält sie).
- Neue Engine-C-Dateien in `Makefile` (`IOS_C_SRC`) eintragen, Header in `WindowsiOS-Bridging-Header.h`.

- Max. Leistung setzt `HV_QOS=ui` und `HV_WFI_SPIN=30` (µs Warten vor dem Schlafen einer leeren vCPU).
- Session: `isIdleTimerDisabled` (Bildschirmsperre würde die VM einfrieren), Warnung bei Stromsparmodus/Hitze.
- Startbildschirm-Vorschau: Bild nie mit `scaledToFill` direkt im Layout (sprengte die Breite → „rangezoomt“);
  Thumbnail wird in `AppModel.refreshPreview` per ImageIO im Hintergrund geladen. Aurora-Animation pausiert während Windows läuft.

## Offene Punkte / Ideen
- Eingebauter JIT-Helfer auf echter Hardware unbestätigt (Extension-Start via NSExtension, TXM-Skript, ohne WLAN).
- Auf echter Hardware unbestätigt: Auflösungs-Firmware unter Windows, 8-GB-RAM, 6 vCPUs, Zwischenablage-Sync,
  automatische Übernahme der `autounattend.xml` (beim ersten Versuch kam trotzdem die Netzwerk-Seite).
- Netzwerktreiber (NetKVM) braucht ein exFAT-Laufwerk der virtio-win-ISO (Dateien → ISO → „Für Windows lesbar machen“).
