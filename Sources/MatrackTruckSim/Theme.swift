import SwiftUI

// MARK: - Design system (premium automotive "virtual cockpit" aesthetic)

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
    static let panel = Color(hex: 0x16181E)
    static let stroke = Color(hex: 0x2A2E37)

    static let red = Color(hex: 0xE2122B)      // signature accent red
    static let ice = Color(hex: 0x6FD3FF)      // cool speed tint
    static let blue = Color(hex: 0x3E7BFA)
    static let green = Color(hex: 0x32D74B)
    static let amber = Color(hex: 0xF5A623)
    static let text = Color(hex: 0xF4F6FA)
    static let dim = Color(hex: 0x868E9C)

    // Back-compat aliases so existing references keep working with the new palette.
    static let cyan = ice
    static let magenta = red

    static let speedArc = [Color(hex: 0x6FD3FF), Color(hex: 0x9FE6FF), Color(hex: 0xE2122B)]
    static let tachArc  = [Color(hex: 0x6FD3FF), Color(hex: 0xF5A623), Color(hex: 0xE2122B)]
}

// MARK: - Clean dark cockpit background

struct DashboardBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bg1, Theme.bg0], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.red.opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Theme.ice.opacity(0.06), .clear],
                           center: .bottom, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Reusable modifiers

struct GlassPanel: ViewModifier {
    var tint: Color = Theme.ice
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.panel.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
    }
}

extension View {
    func glassPanel(_ tint: Color = Theme.ice, radius: CGFloat = 18) -> some View {
        modifier(GlassPanel(tint: tint, radius: radius))
    }
    func glow(_ color: Color, _ radius: CGFloat = 12) -> some View {
        shadow(color: color.opacity(0.7), radius: radius)
    }
    func sectionLabel() -> some View {
        font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .tracking(2.5)
            .foregroundStyle(Theme.dim)
            .textCase(.uppercase)
    }
}
