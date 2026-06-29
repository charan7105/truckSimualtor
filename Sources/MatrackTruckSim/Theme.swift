import SwiftUI

// MARK: - Design system (flagship automotive "virtual cockpit" aesthetic)

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum Theme {
    static let bg0 = Color(hex: 0x08090B)
    static let bg1 = Color(hex: 0x101217)
    static let bg2 = Color(hex: 0x0C0E13)          // drawer / dock mid layer
    static let panel = Color(hex: 0x16181E)
    static let stroke = Color(hex: 0x2A2E37)
    static let glassTop = Color(hex: 0x171A20)     // top-lit glass panel gradient
    static let glassBot = Color(hex: 0x0E1014)

    static let red = Color(hex: 0xE2122B)          // signature accent / redline / fault / STOP
    static let ice = Color(hex: 0x6FD3FF)          // the single cool accent
    static let blue = Color(hex: 0x3E7BFA)
    static let green = Color(hex: 0x32D74B)
    static let amber = Color(hex: 0xF5A623)
    static let text = Color(hex: 0xF4F6FA)
    static let dim = Color(hex: 0x868E9C)
    static let iceDim = Color(hex: 0x2E5A6E)        // empty HUD segment, inactive gear
    static let dimmer = Color(hex: 0x4A515E)        // ghost-tach arc / inactive glyph

    static let redlineBand = Color(hex: 0xE2122B, alpha: 0.9)
    static let glassScrim = Color(hex: 0x08090B, alpha: 0.55)

    // Back-compat aliases
    static let cyan = ice
    static let magenta = red

    // Matched instrument pair: both dials sweep the same cool ice→blue gradient; danger is carried
    // only by the redline band/ticks, so the two gauges read as one engineered cluster.
    static let speedArc = [Color(hex: 0x6FD3FF), Color(hex: 0x3E7BFA)]
    static let tachArc  = [Color(hex: 0x6FD3FF), Color(hex: 0x3E7BFA)]
    static let dialFace = [Color(hex: 0x15181E), Color(hex: 0x0A0B0E)]   // inset gauge face (radial)
}

// MARK: - Clean dark cockpit background

struct DashboardBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bg1, Theme.bg0], startPoint: .top, endPoint: .bottom)
            // a single cool ambient wash from the top — "lit cockpit" room light, no warm cast
            RadialGradient(colors: [Theme.ice.opacity(0.05), .clear],
                           center: .top, startRadius: 0, endRadius: 900)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Reusable modifiers

struct GlassPanel: ViewModifier {
    var tint: Color = Theme.ice
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.glassTop, Theme.glassBot], startPoint: .top, endPoint: .bottom))
            )
            .overlay(   // dual-tone hairline: brighter at the top edge → recedes downward (glassy bevel)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.025)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}

/// Subtle hover lift + ice glow for interactive surfaces.
struct HoverGlow: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? 1.03 : 1.0)
            .shadow(color: Theme.ice.opacity(hover ? 0.28 : 0), radius: hover ? 12 : 0)
            .animation(.easeOut(duration: 0.18), value: hover)
            .onHover { hover = $0 }
    }
}

/// Cinematic power-on reveal: fade + rise + de-blur, staggered by `delay`.
struct PanelReveal: ViewModifier {
    var revealed: Bool
    var delay: Double = 0
    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 16)
            .blur(radius: revealed ? 0 : 6)
            .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(delay), value: revealed)
    }
}

extension View {
    func glassPanel(_ tint: Color = Theme.ice, radius: CGFloat = 18) -> some View {
        modifier(GlassPanel(tint: tint, radius: radius))
    }
    func glow(_ color: Color, _ radius: CGFloat = 12) -> some View {
        shadow(color: color.opacity(0.75), radius: radius)
    }
    func hoverGlow() -> some View { modifier(HoverGlow()) }
    func panelReveal(_ revealed: Bool, delay: Double = 0) -> some View {
        modifier(PanelReveal(revealed: revealed, delay: delay))
    }
    func sectionLabel() -> some View {
        font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .tracking(2.2)
            .foregroundStyle(Theme.dim)
            .textCase(.uppercase)
    }
}

// MARK: - Segmented HUD progress (route)

struct SegmentedProgress: View {
    var progress: Double
    var cells: Int = 24
    var tint: Color = Theme.green
    var body: some View {
        let filled = max(0, min(cells, Int((progress * Double(cells)).rounded())))
        HStack(spacing: 3) {
            ForEach(0..<cells, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < filled ? tint : Theme.iceDim.opacity(0.5))
                    .frame(height: 6)
                    .shadow(color: i < filled ? tint.opacity(0.7) : .clear, radius: 3)
            }
        }
        .animation(.easeOut(duration: 0.3), value: filled)
    }
}
