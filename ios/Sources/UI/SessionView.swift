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
    @State private var showPanel = false
    @State private var confirmDiskPrep = false


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

            if showPanel {
                // Tap outside closes the panel.
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { showPanel = false }
            }

            VStack(spacing: 10) {
                if controlsVisible { controlBar.transition(.move(edge: .top).combined(with: .opacity)) }
                if showPanel && controlsVisible {
                    actionPanel.transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                }
                if model.showStats && model.isVMRunning { StatsPill() }
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
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showPanel)
        .confirmationDialog("Datenträger 0 löschen und vorbereiten?", isPresented: $confirmDiskPrep, titleVisibility: .visible) {
            Button("Datenträger 0 vorbereiten", role: .destructive) {
                model.setupPrepareDisk0()
                showPanel = false
            }
        } message: {
            Text("Nur nutzen, wenn „list disk“ zeigt, dass Datenträger 0 deine leere Windows-Festplatte (~64 GB) ist. Alles darauf wird gelöscht.")
        }
        .onAppear {
            if model.landscapeLock { OrientationLock.set(.landscape) }
            GamepadInput.shared.start()
            scheduleAutoHide()
        }
        .onDisappear {
            OrientationLock.set(.all)
            keyboardVisible = false
        }
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

                GlassIconButton(systemName: showPanel ? "xmark" : "ellipsis", size: 44, active: showPanel) {
                    showPanel.toggle()
                    hideTask?.cancel()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

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

    // MARK: Action panel (replaces the system dropdown – stays open, big touch targets)

    private var actionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelSection("Funktionstasten") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(1...12, id: \.self) { n in
                            panelKey("F\(n)") { KeyboardController.shared.tap(HID.f(n)) }
                        }
                        panelKey("Esc") { KeyboardController.shared.tap(HID.escape) }
                        panelKey("Tab") { KeyboardController.shared.tap(HID.tab) }
                        panelKey("Entf") { KeyboardController.shared.tap(HID.delete) }
                        panelKey("Enter") { KeyboardController.shared.tap(HID.enter) }
                        panelKey("⊞") { KeyboardController.shared.tap(HID.lWin) }
                        panelKey("Druck") { KeyboardController.shared.tap(HID.printScreen) }
                    }
                }

                panelSection("Tastenkombinationen") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        panelAction("⇧ + F10 (Eingabeaufforderung)", "terminal") { KeyboardController.shared.combo([HID.lShift], HID.f(10)) }
                        panelAction("Strg + Alt + Entf", "lock.shield") { WinIOSBridge.shared.sendCtrlAltDel() }
                        panelAction("Alt + Tab", "rectangle.on.rectangle") { WinIOSBridge.shared.sendAltTab() }
                        panelAction("Alt + F4", "xmark.rectangle") { KeyboardController.shared.combo([HID.lAlt], HID.f(4)) }
                        panelAction("Task-Manager", "chart.bar.xaxis") { KeyboardController.shared.combo([HID.lCtrl, HID.lShift], HID.escape) }
                        panelAction("Explorer", "folder") { KeyboardController.shared.combo([HID.lWin], HID.letter("e")!) }
                        panelAction("Desktop", "menubar.dock.rectangle") { KeyboardController.shared.combo([HID.lWin], HID.letter("d")!) }
                        panelAction("Einstellungen", "gearshape") { KeyboardController.shared.combo([HID.lWin], HID.letter("i")!) }
                        panelAction("Screenshot-Tool", "camera.viewfinder") { KeyboardController.shared.combo([HID.lWin, HID.lShift], HID.letter("s")!) }
                        panelAction("Microsoft Edge", "globe") { model.openRun("msedge") }
                    }
                }

                panelSection("Windows-Installation") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        panelAction("Taste drücken (von ISO booten)", "opticaldisc") { WinIOSBridge.shared.tapKeyHid(HID.space) }
                        panelAction("Anforderungen umgehen (TPM …)", "wand.and.stars") { model.setupBypassRequirements() }
                        panelAction("Festplatten anzeigen (list disk)", "internaldrive") { model.setupListDisks() }
                        panelAction("Datenträger 0 vorbereiten …", "externaldrive.badge.plus", destructive: true, closes: false) { confirmDiskPrep = true }
                        panelAction("Lokales Konto (ohne MS-Konto)", "person.crop.circle.badge.checkmark") { model.setupLocalAccount() }
                    }
                }

                panelSection("Anzeige") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        panelAction("Zoom zurücksetzen", "arrow.up.left.and.down.right.magnifyingglass") { handle.resetZoom(); zoom = 1 }
                        panelAction(model.showStats ? "Leistung ausblenden" : "Leistung anzeigen", "speedometer") { model.showStats.toggle() }
                        if display.externalConnected {
                            panelAction(display.preferExternal ? "Auf iPhone anzeigen" : "Auf Monitor anzeigen", "tv") { display.preferExternal.toggle() }
                        }
                        panelAction("Leiste ausblenden", "eye.slash") { controlsVisible = false }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: 720)
        .frame(maxHeight: 420)
        .glassCard(cornerRadius: 28)
    }

    private func panelSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
            content()
        }
    }

    /// A key that keeps the panel open (press several keys in a row).
    private func panelKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
            action()
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// An action button; closes the panel afterwards so you can see Windows.
    private func panelAction(_ title: String, _ icon: String, destructive: Bool = false, closes: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.6)
            if closes { showPanel = false }
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(destructive ? Theme.bad : Theme.accent)
                    .frame(width: 22)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleControls() {
        controlsVisible.toggle()
        if !controlsVisible { showPanel = false }
        if controlsVisible { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem {
            if model.isVMRunning && model.fbWidth > 0 && !keyboardVisible && !showPanel && !display.isPresentingExternally {
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

/// Live performance pill with its own 1 s timer, so only this small view re-renders.
struct StatsPill: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let b = WinIOSBridge.shared
        HStack(spacing: 12) {
            Label("\(b.framebufferWidth)×\(b.framebufferHeight)", systemImage: "display")
            Label("\(b.availableMemoryMB) MB frei", systemImage: "memorychip")
            Label(SessionView.formatUptime(b.uptimeSeconds), systemImage: "clock")
        }
        .id(now)
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassCapsule(interactive: false)
        .allowsHitTesting(false)
        .onReceive(timer) { now = $0 }
    }
}
