// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Rufus-style switches for Windows Setup (written as autounattend.xml onto the setup drive).
struct SetupOptionsCard: View {
    @State private var o = SetupOptions.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Windows-Setup anpassen (wie Rufus)", systemImage: "wand.and.stars").font(.headline)
            Toggle("Anforderungen entfernen (TPM 2.0, Secure Boot, RAM, CPU)", isOn: $o.bypassRequirements)
            Toggle("Kein Microsoft-Konto – lokales Konto anlegen", isOn: $o.localAccount)
            if o.localAccount {
                TextField("Benutzername", text: $o.userName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .glassCard(cornerRadius: 12)
                SecureField("Passwort (leer = automatisch anmelden)", text: $o.password)
                    .padding(10)
                    .glassCard(cornerRadius: 12)
            }
            Toggle("Datenschutz-Fragen überspringen (alles aus)", isOn: $o.skipPrivacyQuestions)
            Toggle("BitLocker-Verschlüsselung verhindern (schneller)", isOn: $o.disableBitLocker)
            Toggle("Region & Tastatur wie auf dem iPhone", isOn: $o.regionLikeIPhone)
            Toggle("Windows fürs iPhone optimieren (keine Animationen, weniger Hintergrunddienste)", isOn: $o.optimizeWindows)
            Text("Wird beim nächsten Start von Windows-Setup automatisch angewendet.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .tint(Theme.accent)
        .padding(16)
        .glassCard()
        .onChange(of: o) { _, new in new.save() }
    }
}
