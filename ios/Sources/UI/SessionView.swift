// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import SwiftUI
import UIKit

struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var display: DisplayRouter
    @StateObject private var keys = StickyKeysObserver()

    @State private var controlsVisible = true
    @State private var keyboardVisible = false
    @State private var rightClickArmed = false
    @State private var zoom: CGFloat = 1
    @State private var showFKeys = false
    @State private var confirmStop = false
    @State private var handle = CanvasHandle()
    @State private var hideTask: DispatchWorkItem?

    private let tick = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            WindowsScreenView(touchMode: model.touchMode,
                              forceTrackpad: display.isPresentingExternally,
                              rightClickArmed: $rightClickArmed,
                              keyboardVisible: $keyboardVisible,
                              handle: handle,
                              onThreeFingerTap: { toggleControls() },
                              onZoomChanged: { z in zoom = z })
                .ignoresSafeArea()

            if display.isPresentingExternally { externalControllerOverlay }
            if model.isVMRunning && model.fbWidth == 0 { bootingOverlay }
            if model.isUnpacking { unpackOverlay }
            if !model.isVMRunning && !model.isUnpacking { stoppedOverlay }

            VStack(spacing: 10) {
                if controlsVisible { controlBar.transition(.move(edge: .top).combined(with: .opacity)) }
                if model.showStats && model.isVMRunning { statsPill }
                Spacer()
                if keyboardVisible { keyBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, keyboardVisible ? 6 : 0)

            if !controlsVisible {
                // Small grabber to bring the controls back.
                VStack {
                    Capsule().fill(.white.opacity(0.35)).frame(width: 60, height: 5)
                        .padding(.vertical, 10).padding(.horizontal, 30)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleControls() }
                    Spacer()
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: controlsVisible)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: keyboardVisible)
        .onAppear {
            if model.landscapeLock { OrientationLock.set(.landscape) }
            GamepadInput.shared.start()
            scheduleAutoHide()
        }
        .onDisappear {
            OrientationLock.set(.all)
            keyboardVisible = false
        }
        .onReceive(tick) { _ in model.sync() }
        .confirmationDialog("Windows beenden?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Herunterfahren (wie Ein/Aus-Taste)") { model.shutdownGracefully() }
            Button("Sofort ausschalten", role: .destructive) { model.forceStop() }
        } message: {
            Text("„Herunterfahren“ beendet Windows sauber. „Sofort ausschalten“ kann ungespeicherte Daten verlieren.")
        }
    }

    // MARK: Control bar

    private var controlBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                GlassIconButton(systemName: "chevron.down", size: 44) { model.showSession = false }

                HStack(spacing: 4) {
                    barButton("keyboard", active: keyboardVisible) { keyboardVisible.toggle() }
                    barButton(model.touchMode.icon, active: model.touchMode == .trackpad) {
                        model.touchMode = model.touchMode == .direct ? .trackpad : .direct
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    barButton("cursorarrow.click.2", active: rightClickArmed) { rightClickArmed.toggle() }
                    barButton("square.grid.2x2.fill") { KeyboardController.shared.tap(HID.lWin) }
                    if zoom > 1.01 {
                        barButton("arrow.down.right.and.arrow.up.left") { handle.resetZoom(); zoom = 1 }
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 44)
                .glassCapsule()

                Menu { moreMenu } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .glassCircle()

                GlassIconButton(systemName: "power", size: 44, tint: Theme.bad.opacity(0.6)) { confirmStop = true }
            }
        }
        .onTapGesture { scheduleAutoHide() }
    }

    private func barButton(_ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleAutoHide()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : .white)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var moreMenu: some View {
        Section("Tastenkombinationen") {
            Button { WinIOSBridge.shared.sendCtrlAltDel() } label: { Label("Strg + Alt + Entf", systemImage: "lock.shield") }
            Button { WinIOSBridge.shared.sendAltTab() } label: { Label("Alt + Tab", systemImage: "rectangle.on.rectangle") }
            Button { KeyboardController.shared.combo([HID.lCtrl, HID.lShift], HID.escape) } label: { Label("Task-Manager", systemImage: "chart.bar.xaxis") }
            Button { KeyboardController.shared.combo([HID.lWin], HID.letter("e")!) } label: { Label("Explorer", systemImage: "folder") }
            Button { KeyboardController.shared.combo([HID.lWin], HID.letter("d")!) } label: { Label("Desktop anzeigen", systemImage: "menubar.dock.rectangle") }
            Button { KeyboardController.shared.combo([HID.lWin], HID.letter("i")!) } label: { Label("Windows-Einstellungen", systemImage: "gearshape") }
            Button { KeyboardController.shared.combo([HID.lWin, HID.lShift], HID.letter("s")!) } label: { Label("Screenshot-Tool", systemImage: "camera.viewfinder") }
            Button { model.openRun("msedge") } label: { Label("Microsoft Edge", systemImage: "globe") }
        }
        Section("Anzeige") {
            Button { handle.resetZoom(); zoom = 1 } label: { Label("Zoom zurücksetzen", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
            Button { showFKeys.toggle(); keyboardVisible = true } label: { Label("F-Tasten", systemImage: "f.cursive") }
            Button { model.showStats.toggle() } label: { Label(model.showStats ? "Leistung ausblenden" : "Leistung anzeigen", systemImage: "speedometer") }
            if display.externalConnected {
                Button { display.preferExternal.toggle() } label: {
                    Label(display.preferExternal ? "Auf iPhone anzeigen" : "Auf externem Bildschirm", systemImage: "tv")
                }
            }
        }
        Section("Windows-Installation") {
            Button { WinIOSBridge.shared.tapKeyHid(HID.space) } label: { Label("Taste drücken (von ISO booten)", systemImage: "opticaldisc") }
            Button { model.setupBypassRequirements() } label: { Label("Setup-Helfer: Anforderungen umgehen", systemImage: "wand.and.stars") }
            Button { model.setupLocalAccount() } label: { Label("Setup-Helfer: Lokales Konto", systemImage: "person.crop.circle.badge.checkmark") }
        }
        Section {
            Button { controlsVisible = false } label: { Label("Leiste ausblenden (3 Finger: einblenden)", systemImage: "eye.slash") }
        }
    }

    private func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem {
            if model.isVMRunning && model.fbWidth > 0 && !keyboardVisible && !display.isPresentingExternally {
                controlsVisible = false
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: task)
    }

    // MARK: Keyboard bar

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyCap("esc") { KeyboardController.shared.tap(HID.escape) }
                keyCap("tab") { KeyboardController.shared.tap(HID.tab) }
                stickyCap("strg", HID.lCtrl)
                stickyCap("alt", HID.lAlt)
                stickyCap("⇧", HID.lShift)
                stickyCap("⊞", HID.lWin)
                keyCap("←") { KeyboardController.shared.tap(HID.left) }
                keyCap("↑") { KeyboardController.shared.tap(HID.up) }
                keyCap("↓") { KeyboardController.shared.tap(HID.down) }
                keyCap("→") { KeyboardController.shared.tap(HID.right) }
                keyCap("entf") { KeyboardController.shared.tap(HID.delete) }
                keyCap("pos1") { KeyboardController.shared.tap(HID.home) }
                keyCap("ende") { KeyboardController.shared.tap(HID.end) }
                keyCap("bild↑") { KeyboardController.shared.tap(HID.pageUp) }
                keyCap("bild↓") { KeyboardController.shared.tap(HID.pageDown) }
                if showFKeys {
                    ForEach(1...12, id: \.self) { n in
                        keyCap("F\(n)") { KeyboardController.shared.tap(HID.f(n)) }
                    }
                } else {
                    keyCap("F1–12") { showFKeys = true }
                }
                keyCap("⌨︎↓") { keyboardVisible = false }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .glassCapsule(interactive: false)
    }

    private func keyCap(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
            action()
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 38, minHeight: 34)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func stickyCap(_ title: String, _ mod: UInt8) -> some View {
        let on = keys.armed.contains(mod)
        return Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
            KeyboardController.shared.toggleSticky(mod)
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(minWidth: 42, minHeight: 34)
                .padding(.horizontal, 4)
                .background(on ? Theme.accent : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Overlays

    private var externalControllerOverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 12) {
                Image(systemName: "tv.and.mediabox.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text("Windows läuft auf dem externen Bildschirm").font(.headline)
                Text("\(display.externalDescription) · Dieses iPhone ist jetzt dein Trackpad.\nTippen = Klick · Zwei Finger = Rechtsklick/Scrollen")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 24)
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    mouseButton("Links", mask: 1)
                    mouseButton("Rechts", mask: 2)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, keyboardVisible ? 70 : 24)
            }
        }
    }

    private func mouseButton(_ title: String, mask: UInt8) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 64)
            .glassCard(cornerRadius: 20, interactive: true)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if PointerController.shared.heldButtons & mask == 0 {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        PointerController.shared.setHeldButton(mask, down: true)
                    }
                }
                .onEnded { _ in PointerController.shared.setHeldButton(mask, down: false) })
    }

    private var bootingOverlay: some View {
        VStack(spacing: 14) {
            WindowsGlyph().frame(width: 64, height: 64)
            ProgressView().tint(.white)
            Text("Windows startet …").font(.headline)
            Text(model.mountedISOURL != nil ? "Wenn „Press any key to boot from CD“ erscheint, tippe auf den Bildschirm-Button ⋯ → „Taste drücken“." : "Der erste Start kann ein paar Minuten dauern.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: 360)
        }
        .padding(24)
        .glassCard(cornerRadius: 30)
        .allowsHitTesting(false)
    }

    private var unpackOverlay: some View {
        VStack(spacing: 12) {
            Text("Windows-Image wird entpackt").font(.headline)
            ProgressView(value: model.unpackProgress).frame(width: 240)
            Text("\(Int(model.unpackProgress * 100)) %").font(.footnote.monospacedDigit())
        }
        .padding(24)
        .glassCard(cornerRadius: 30)
    }

    private var stoppedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "power.circle").font(.system(size: 44)).foregroundStyle(.white.opacity(0.8))
            Text(model.vmStatusText).font(.headline).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { model.start() } label: { Label("Neu starten", systemImage: "arrow.clockwise") }
                    .glassProminentButton()
                Button { model.showSession = false } label: { Label("Zurück", systemImage: "house") }
                    .glassButton()
            }
        }
        .padding(24)
        .glassCard(cornerRadius: 30)
    }

    private var statsPill: some View {
        HStack(spacing: 12) {
            Label("\(model.fbWidth)×\(model.fbHeight)", systemImage: "display")
            Label("\(model.availableMemoryMB) MB frei", systemImage: "memorychip")
            Label(Self.formatUptime(model.uptime), systemImage: "clock")
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassCapsule(interactive: false)
        .allowsHitTesting(false)
    }

    static func formatUptime(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}

/// Publishes sticky-modifier changes from the KeyboardController.
final class StickyKeysObserver: ObservableObject {
    @Published var armed: Set<UInt8> = []
    init() {
        KeyboardController.shared.onStickyChanged = { [weak self] in
            DispatchQueue.main.async { self?.armed = KeyboardController.shared.stickyModifiers }
        }
    }
}
