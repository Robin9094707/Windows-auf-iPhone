// SPDX-License-Identifier: GPL-2.0-or-later
// Small helper scripts the app hands to Windows through the shared folder
// (http://10.0.2.4/iPhone-Tools/…). They need the VirtIO network driver.
import Foundation

enum WindowsTools {
    static let folderName = "iPhone-Tools"
    static let baseURL = "http://10.0.2.4/iPhone-Tools"

    /// Writes (and refreshes) the helper scripts into Shared/iPhone-Tools.
    static func install(into sharedDir: URL) {
        let dir = sharedDir.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files: [String: String] = [
            "ClipboardSync.ps1": clipboardSync,
            "Install-ClipboardSync.ps1": installClipboardSync,
            "LIESMICH.txt": readme,
        ]
        for (name, text) in files {
            // Windows PowerShell 5.1 wants CRLF; keep scripts pure ASCII.
            let crlf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            try? crlf.data(using: .ascii, allowLossyConversion: true)?.write(to: dir.appendingPathComponent(name))
        }
    }

    /// Runs inside Windows (hidden). Long-polls the iPhone clipboard and pushes Windows' clipboard back.
    static let clipboardSync = #"""
    # iPhone <-> Windows clipboard sync (Windows auf iPhone)
    $mutex = New-Object System.Threading.Mutex($false, 'iPhoneClipboardSync')
    if (-not $mutex.WaitOne(0)) { exit }
    Add-Type -AssemblyName System.Net.Http
    Add-Type -AssemblyName System.Windows.Forms
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(40)
    $base = 'http://10.0.2.4/.henge/clipboard'
    $seq = 0
    $last = ''
    try { $last = [System.Windows.Forms.Clipboard]::GetText() } catch {}
    $pull = $null
    while ($true) {
        try {
            if ($pull -eq $null) { $pull = $client.GetAsync($base + '?since=' + $seq) }
            if ($pull.IsCompleted) {
                if (-not $pull.IsFaulted -and -not $pull.IsCanceled) {
                    $resp = $pull.Result
                    $vals = $null
                    if ($resp.Headers.TryGetValues('X-Henge-Seq', [ref]$vals)) { $seq = [int64]($vals | Select-Object -First 1) }
                    if ([int]$resp.StatusCode -eq 200) {
                        $bytes = $resp.Content.ReadAsByteArrayAsync().Result
                        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                        if ($text.Length -gt 0 -and $text -ne $last) {
                            [System.Windows.Forms.Clipboard]::SetText($text)
                            $last = $text
                        }
                    }
                } else { Start-Sleep -Seconds 2 }
                $pull = $null
            }
            $cur = ''
            try { $cur = [System.Windows.Forms.Clipboard]::GetText() } catch {}
            if ($cur.Length -gt 0 -and $cur -ne $last) {
                $last = $cur
                $body = New-Object System.Net.Http.StringContent($cur, [System.Text.Encoding]::UTF8, 'text/plain')
                [void]$client.PutAsync($base, $body).Wait(5000)
            }
        } catch { Start-Sleep -Seconds 2; $pull = $null }
        Start-Sleep -Milliseconds 500
    }
    """#

    /// Copies the sync script to %APPDATA%, adds it to Autostart and starts it now.
    static let installClipboardSync = #"""
    $dir = Join-Path $env:APPDATA 'iPhoneClipboard'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script = Join-Path $dir 'ClipboardSync.ps1'
    Invoke-WebRequest -UseBasicParsing 'http://10.0.2.4/iPhone-Tools/ClipboardSync.ps1' -OutFile $script
    $psArgs = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'
    $startup = [Environment]::GetFolderPath('Startup')
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut((Join-Path $startup 'iPhone Zwischenablage.lnk'))
    $lnk.TargetPath = (Join-Path $PSHOME 'powershell.exe')
    $lnk.Arguments = $psArgs
    $lnk.WindowStyle = 7
    $lnk.Save()
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $psArgs -WindowStyle Hidden
    Write-Host 'Zwischenablage iPhone <-> Windows ist aktiv (startet automatisch mit Windows).'
    Start-Sleep -Seconds 3
    """#

    static let readme = """
    Windows auf iPhone - Hilfsprogramme
    ===================================

    Zwischenablage synchronisieren:
      In der App: Menue ... -> "Zwischenablage-Sync in Windows einrichten".
      Oder manuell in Windows (Win+R):
      powershell -ep bypass -c "iex (iwr -UseB http://10.0.2.4/iPhone-Tools/Install-ClipboardSync.ps1).Content"

    Voraussetzung: Netzwerktreiber (NetKVM aus virtio-win.iso) ist installiert.
    """

    // MARK: Commands typed into Windows' Run dialog (Win+R)

    /// Installs the clipboard helper (needs network).
    static let installClipboardCommand =
        "powershell -NoProfile -ExecutionPolicy Bypass -Command \"iex (iwr -UseBasicParsing \(baseURL)/Install-ClipboardSync.ps1).Content\""

    /// Installs the NetKVM network driver from the mounted virtio-win drive (run elevated).
    static let installNetworkDriverCommand =
        "powershell -NoProfile -ExecutionPolicy Bypass -Command \"Get-PSDrive -PSProvider FileSystem | ForEach-Object { $p = $_.Root + 'NetKVM\\w11\\ARM64'; if (Test-Path $p) { pnputil /add-driver ($p + '\\*.inf') /install } }; pause\""
}
