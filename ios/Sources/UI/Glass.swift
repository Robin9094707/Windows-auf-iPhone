// SPDX-License-Identifier: GPL-2.0-or-later
// Liquid Glass design kit: uses the native iOS 26 glass material when available,
// and falls back to ultra-thin material on older systems / SDKs.
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.24, green: 0.62, blue: 1.0)
    static let accentDeep = Color(red: 0.05, green: 0.33, blue: 0.85)
    static let good = Color(red: 0.25, green: 0.86, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.74, blue: 0.25)
    static let bad = Color(red: 1.0, green: 0.38, blue: 0.38)
}

extension View {
    /// A rounded Liquid Glass card.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 28, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive),
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.legacyGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
        }
        #else
        self.legacyGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
        #endif
    }

    /// A capsule-shaped Liquid Glass surface (pills, toolbars).
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: Capsule())
        } else {
            self.legacyGlass(Capsule(), tint: tint)
        }
        #else
        self.legacyGlass(Capsule(), tint: tint)
        #endif
    }

    /// A circular Liquid Glass surface (round icon buttons).
    @ViewBuilder
    func glassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: Circle())
        } else {
            self.legacyGlass(Circle(), tint: tint)
        }
        #else
        self.legacyGlass(Circle(), tint: tint)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint.opacity(0.55)) }
        if interactive { g = g.interactive() }
        return g
    }
    #endif

    func legacyGlass<S: InsettableShape>(_ shape: S, tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.35), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    /// Prominent glass button style on iOS 26, bordered-prominent otherwise.
    @ViewBuilder
    func glassProminentButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }
}

/// Groups glass shapes so they blend and morph together (iOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// Animated aurora background in Windows blue tones – the canvas behind all glass.
struct AuroraBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.04, blue: 0.10)
            if #available(iOS 18.0, *) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    MeshGradient(width: 3, height: 3,
                                 points: Self.meshPoints(ctx.date.timeIntervalSinceReferenceDate),
                                 colors: Self.meshColors)
                }
            } else {
                LinearGradient(colors: [Color(red: 0.03, green: 0.18, blue: 0.48), Color(red: 0.02, green: 0.05, blue: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Theme.accent.opacity(0.45))
                    .frame(width: 420, height: 420)
                    .blur(radius: 120)
                    .offset(x: animate ? 120 : -120, y: animate ? -80 : 60)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { animate = true }
                    }
            }
        }
        .ignoresSafeArea()
    }

    static func meshPoints(_ t: Double) -> [SIMD2<Float>] {
        let cx = Float(0.5 + 0.18 * sin(t * 0.35))
        let cy = Float(0.5 + 0.14 * cos(t * 0.28))
        var pts: [SIMD2<Float>] = []
        pts.append(SIMD2<Float>(0, 0)); pts.append(SIMD2<Float>(0.5, 0)); pts.append(SIMD2<Float>(1, 0))
        pts.append(SIMD2<Float>(0, 0.5)); pts.append(SIMD2<Float>(cx, cy)); pts.append(SIMD2<Float>(1, 0.5))
        pts.append(SIMD2<Float>(0, 1)); pts.append(SIMD2<Float>(0.5, 1)); pts.append(SIMD2<Float>(1, 1))
        return pts
    }

    static let meshColors: [Color] = [
        Color(red: 0.02, green: 0.07, blue: 0.22), Color(red: 0.03, green: 0.20, blue: 0.52), Color(red: 0.02, green: 0.08, blue: 0.25),
        Color(red: 0.05, green: 0.30, blue: 0.70), Color(red: 0.12, green: 0.55, blue: 0.95), Color(red: 0.25, green: 0.18, blue: 0.62),
        Color(red: 0.01, green: 0.05, blue: 0.16), Color(red: 0.04, green: 0.25, blue: 0.55), Color(red: 0.02, green: 0.06, blue: 0.18),
    ]
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.9), radius: 6)
    }
}

/// Round glass icon button.
struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 46
    var tint: Color? = nil
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : .white)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle(tint: active ? Theme.accent : tint)
    }
}
