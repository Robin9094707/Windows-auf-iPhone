// SPDX-License-Identifier: GPL-2.0-or-later
// Rufus-style Windows Setup customisation: the app writes an autounattend.xml onto the
// Windows-readable setup drive (root and \sources), which Windows Setup picks up itself.
import Foundation

struct SetupOptions: Equatable {
    var bypassRequirements = true     // TPM 2.0, Secure Boot, RAM, CPU, storage checks
    var localAccount = true           // no Microsoft account needed
    var userName = "Benutzer"
    var password = ""
    var skipPrivacyQuestions = true
    var disableBitLocker = true       // no automatic device encryption (faster disk)
    var regionLikeIPhone = true
    var optimizeWindows = true        // run iPhone-Optimieren.cmd at first sign-in

    static let defaultsKey = "setup.options.v1"

    static func load() -> SetupOptions {
        guard let d = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return SetupOptions() }
        var o = SetupOptions()
        o.bypassRequirements = d["bypass"] as? Bool ?? o.bypassRequirements
        o.localAccount = d["local"] as? Bool ?? o.localAccount
        o.userName = d["user"] as? String ?? o.userName
        o.password = d["pass"] as? String ?? o.password
        o.skipPrivacyQuestions = d["privacy"] as? Bool ?? o.skipPrivacyQuestions
        o.disableBitLocker = d["bitlocker"] as? Bool ?? o.disableBitLocker
        o.regionLikeIPhone = d["region"] as? Bool ?? o.regionLikeIPhone
        o.optimizeWindows = d["optimize"] as? Bool ?? o.optimizeWindows
        return o
    }

    func save() {
        UserDefaults.standard.set([
            "bypass": bypassRequirements, "local": localAccount, "user": userName, "pass": password,
            "privacy": skipPrivacyQuestions, "bitlocker": disableBitLocker, "region": regionLikeIPhone,
            "optimize": optimizeWindows,
        ], forKey: Self.defaultsKey)
    }
}

enum UnattendBuilder {
    /// Fixed size of the placeholder files reserved in the exFAT drive.
    static let slotSize: UInt64 = 65536
    /// Placeholder paths inside the setup drive (root is checked for removable media,
    /// \sources for the installation media itself).
    static let slotPaths = ["autounattend.xml", "sources/autounattend.xml", "iPhone-Optimieren.cmd"]
    static let optimizerName = "iPhone-Optimieren.cmd"

    /// Finds the optimizer on whatever letter the drive got and runs it.
    static let optimizerLauncher =
        "cmd /c for %d in (C D E F G H I J K L M N O P) do @if exist %d:\\iPhone-Optimieren.cmd call %d:\\iPhone-Optimieren.cmd"

    /// Tunes Windows for the iPhone's JIT: fewer background services, no animations/transparency,
    /// max performance power plan, no hibernation file, no BitLocker. Runs elevated.
    static let optimizerScript = #"""
    @echo off
    title Windows auf iPhone - Optimierung
    echo Windows wird fuer das iPhone optimiert ...
    powercfg /setactive SCHEME_MIN >nul 2>&1
    powercfg /h off >nul 2>&1
    powercfg /change monitor-timeout-ac 0 >nul 2>&1
    powercfg /change standby-timeout-ac 0 >nul 2>&1
    for %%s in (SysMain WSearch DiagTrack dmwappushservice MapsBroker WerSvc RetailDemo) do (
      sc stop %%s >nul 2>&1
      sc config %%s start= disabled >nul 2>&1
    )
    reg add "HKCU\Control Panel\Desktop" /v UserPreferencesMask /t REG_BINARY /d 9012038010000000 /f >nul
    reg add "HKCU\Control Panel\Desktop" /v MenuShowDelay /t REG_SZ /d 0 /f >nul
    reg add "HKCU\Control Panel\Desktop\WindowMetrics" /v MinAnimate /t REG_SZ /d 0 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 3 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 0 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewAlphaSelect /t REG_DWORD /d 0 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" /v GlobalUserDisabled /t REG_DWORD /d 1 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f >nul
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f >nul
    reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 0 /f >nul
    reg add "HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f >nul
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f >nul
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v StartupBoostEnabled /t REG_DWORD /d 0 /f >nul
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v BackgroundModeEnabled /t REG_DWORD /d 0 /f >nul
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f >nul
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DODownloadMode /t REG_DWORD /d 0 /f >nul
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f >nul
    manage-bde -off C: >nul 2>&1
    echo.
    echo Fertig! Bitte Windows einmal neu starten.
    if /i "%~1"=="auto" goto :eof
    pause
    """#

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func component(_ name: String, _ body: String) -> String {
        """
            <component name="\(name)" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
        \(body)
            </component>
        """
    }

    private static func runSync(_ cmds: [String], tag: String = "RunSynchronousCommand") -> String {
        var s = "      <RunSynchronous>\n"
        for (i, c) in cmds.enumerated() {
            s += "        <\(tag) wcm:action=\"add\"><Order>\(i + 1)</Order><Path>\(esc(c))</Path></\(tag)>\n"
        }
        return s + "      </RunSynchronous>"
    }

    /// Locales Windows certainly accepts; anything else is left to the user in OOBE.
    private static var windowsLocale: String? {
        let id = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let known = ["de-DE", "de-AT", "de-CH", "en-US", "en-GB", "fr-FR", "it-IT", "es-ES", "nl-NL"]
        return known.first { id.hasPrefix($0) }
    }

    static func xml(_ o: SetupOptions) -> String {
        var passes: [String] = []

        if o.bypassRequirements {
            let keys = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck", "BypassStorageCheck"]
            let cmds = keys.map { "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \($0) /t REG_DWORD /d 1 /f" }
            passes.append("""
              <settings pass="windowsPE">
            \(component("Microsoft-Windows-Setup", runSync(cmds)))
              </settings>
            """)
        }

        var special: [String] = []
        if o.localAccount { special.append("reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f") }
        if o.disableBitLocker { special.append("reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f") }
        if !special.isEmpty {
            passes.append("""
              <settings pass="specialize">
            \(component("Microsoft-Windows-Deployment", runSync(special)))
              </settings>
            """)
        }

        var oobeComponents: [String] = []
        if o.regionLikeIPhone, let loc = windowsLocale {
            oobeComponents.append(component("Microsoft-Windows-International-Core", """
                  <InputLocale>\(loc)</InputLocale>
                  <SystemLocale>\(loc)</SystemLocale>
                  <UserLocale>\(loc)</UserLocale>
            """))
        }
        var shell = ""
        if o.skipPrivacyQuestions || o.localAccount {
            shell += "      <OOBE>\n"
            shell += "        <HideEULAPage>true</HideEULAPage>\n"
            if o.localAccount { shell += "        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>\n" }
            if o.skipPrivacyQuestions { shell += "        <ProtectYourPC>3</ProtectYourPC>\n" }
            shell += "      </OOBE>\n"
        }
        if o.localAccount {
            let name = o.userName.trimmingCharacters(in: .whitespaces).isEmpty ? "Benutzer" : o.userName
            shell += """
                  <UserAccounts>
                    <LocalAccounts>
                      <LocalAccount wcm:action="add">
                        <Name>\(esc(name))</Name>
                        <DisplayName>\(esc(name))</DisplayName>
                        <Group>Administrators</Group>
                        <Password><Value>\(esc(o.password))</Value><PlainText>true</PlainText></Password>
                      </LocalAccount>
                    </LocalAccounts>
                  </UserAccounts>

            """
            if o.password.isEmpty {
                shell += """
                      <AutoLogon>
                        <Enabled>true</Enabled>
                        <LogonCount>1</LogonCount>
                        <Username>\(esc(name))</Username>
                        <Password><Value></Value><PlainText>true</PlainText></Password>
                      </AutoLogon>

                """
            }
        }
        if o.optimizeWindows {
            shell += """
                  <FirstLogonCommands>
                    <SynchronousCommand wcm:action="add">
                      <Order>1</Order>
                      <CommandLine>\(esc(optimizerLauncher)) auto</CommandLine>
                      <Description>Windows fuer das iPhone optimieren</Description>
                    </SynchronousCommand>
                  </FirstLogonCommands>

            """
        }
        if !shell.isEmpty { oobeComponents.append(component("Microsoft-Windows-Shell-Setup", shell)) }
        if !oobeComponents.isEmpty {
            passes.append("  <settings pass=\"oobeSystem\">\n" + oobeComponents.joined(separator: "\n") + "\n  </settings>")
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Erstellt von Windows auf iPhone (wie Rufus) -->
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
        \(passes.joined(separator: "\n"))
        </unattend>

        """
    }

    /// Writes the answer file into the reserved slots of a converted setup drive.
    static func write(_ o: SetupOptions, drive: URL, offsets: [UInt64]) -> Bool {
        func padded(_ text: String) -> Data? {
            var data = Data(text.utf8)
            guard UInt64(data.count) <= slotSize else { return nil }
            data.append(contentsOf: [UInt8](repeating: 0x20, count: Int(slotSize) - data.count))   // pad with spaces
            return data
        }
        guard let xmlData = padded(xml(o)),
              let script = padded(optimizerScript.replacingOccurrences(of: "\n", with: "\r\n") + "\r\nrem ") else { return false }
        guard let h = try? FileHandle(forWritingTo: drive) else { return false }
        defer { try? h.close() }
        var ok = false
        for (i, off) in offsets.enumerated() where off > 0 {
            let data = slotPaths[i].hasSuffix(".cmd") ? script : xmlData
            do {
                try h.seek(toOffset: off)
                try h.write(contentsOf: data)
                ok = true
            } catch { return false }
        }
        try? h.synchronize()
        return ok
    }
}
