import SwiftUI
import Foundation

// MARK: - Shared dial ring (thick gradient arc, numbered ticks, inner dial-face)

private struct GaugeRing: View {
    var frac: Double
    var arc: [Color]
    var diameter: CGFloat = 232
    var labels: [(Double, String)] = []     // (fraction 0…1, text) for numbered ticks
    var showRedlineBand: Bool = false
    var redlineStart: Double = 0.82
    var showCometTip: Bool = false
    var tipColor: Color = Theme.ice
    var arcOpacity: Double = 1.0

    private let sweep = 0.78
    private let startAngle = 144.0
    @State private var breathe = false

    var body: some View {
        let f = max(0, min(1, frac))
        let lw = diameter * 0.072
        let s = diameter / 232.0
        let tickR = diameter / 2 - lw - 4 * s
        let labelR = diameter / 2 - lw - 20 * s
        let innerD = diameter - lw * 2 - 18 * s
        ZStack {
            // tick marks (fine)
            ForEach(0..<37) { i in
                Capsule()
                    .fill(Color.white.opacity(i % 6 == 0 ? 0.32 : 0.10))
                    .frame(width: i % 6 == 0 ? 2.5 : 1.5, height: (i % 6 == 0 ? 11 : 6) * s)
                    .offset(y: -tickR)
                    .rotationEffect(.degrees(startAngle + sweep * 360 * Double(i) / 36.0))
            }
            // numbered tick labels (upright, trig-placed)
            ForEach(labels.indices, id: \.self) { k in
                let a = (startAngle + sweep * 360 * labels[k].0) * .pi / 180
                Text(labels[k].1)
                    .font(.system(size: diameter * 0.040, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.dim)
                    .offset(x: labelR * sin(a), y: -labelR * cos(a))
            }
            // track
            Circle().trim(from: 0, to: sweep)
                .stroke(Color.white.opacity(0.06), style: .init(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
            // redline danger band
            if showRedlineBand {
                Circle().trim(from: sweep * redlineStart, to: sweep)
                    .stroke(Theme.redlineBand, style: .init(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
            }
            // value arc (thick gradient)
            Circle().trim(from: 0, to: sweep * f)
                .stroke(AngularGradient(gradient: Gradient(colors: arc),
                                        center: .center,
                                        startAngle: .degrees(startAngle),
                                        endAngle: .degrees(startAngle + sweep * 360)),
                        style: .init(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
                .opacity(arcOpacity)
                .shadow(color: (arc.last ?? Theme.ice).opacity(arcOpacity * 0.5), radius: 8)
                .animation(.easeOut(duration: 0.4), value: f)
                .animation(.easeOut(duration: 0.3), value: arcOpacity)
            // inner dial-face
            Circle().fill(Theme.bg0.opacity(0.55)).frame(width: innerD, height: innerD)
            Circle().stroke(Theme.stroke, lineWidth: 1).frame(width: innerD, height: innerD)
            // comet tip
            if showCometTip && f > 0.001 {
                Circle().fill(tipColor)
                    .frame(width: lw * 0.6, height: lw * 0.6)
                    .glow(tipColor, breathe ? 14 : 7)
                    .offset(y: -tickR)
                    .rotationEffect(.degrees(startAngle + sweep * 360 * f))
                    .animation(.easeOut(duration: 0.4), value: f)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathe = true }
                    }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Speedometer (left, focal)

struct SpeedGauge: View {
    var speed: Double                              // mph (source of truth)
    var maxKmh: Double = 200                        // full dial == 200 km/h
    var diameter: CGFloat = 300
    private let labels: [(Double, String)] = [(0, "0"), (0.2, "40"), (0.4, "80"), (0.6, "120"), (0.8, "160"), (1.0, "200")]
    var body: some View {
        let kmh = speed * 1.60934
        ZStack {
            GaugeRing(frac: kmh / maxKmh, arc: Theme.speedArc, diameter: diameter,
                      labels: labels, showCometTip: true, tipColor: Theme.ice)
            VStack(spacing: -2) {
                Text("\(Int(kmh.rounded()))")
                    .font(.system(size: diameter * 0.26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: speed)
                Text("KM/H").font(.system(size: diameter * 0.045, weight: .bold, design: .rounded))
                    .tracking(6).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Tachometer (right, ghost → wakes red at redline)

struct TachGauge: View {
    var rpm: Int
    var maxRpm: Double = 3000
    var diameter: CGFloat = 300
    private let labels: [(Double, String)] = [(0, "0"), (0.333, "1"), (0.667, "2"), (1.0, "3")]
    var body: some View {
        let frac = Double(rpm) / maxRpm
        let hot = frac > 0.82
        ZStack {
            GaugeRing(frac: frac,
                      arc: hot ? Theme.tachArc : [Theme.dimmer, Theme.dimmer],
                      diameter: diameter,
                      labels: labels,
                      showRedlineBand: true,
                      arcOpacity: hot ? 1.0 : 0.6)
            VStack(spacing: -2) {
                Text("\(rpm)")
                    .font(.system(size: diameter * 0.19, weight: .bold, design: .rounded))
                    .foregroundStyle(hot ? Theme.red : Theme.text)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: rpm)
                Text("× RPM").font(.system(size: diameter * 0.045, weight: .bold, design: .rounded))
                    .tracking(5).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: (hot ? Theme.red : .clear).opacity(0.7), radius: 14)
        .animation(.easeOut(duration: 0.3), value: hot)
    }
}

// MARK: - Small circular ring (fuel / DEF)

struct RingGauge: View {
    var value: Double            // 0–100
    var caption: String
    var tint: Color
    var diameter: CGFloat = 78
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.12), lineWidth: diameter * 0.115)
            Circle().trim(from: 0, to: max(0, min(1, value / 100)))
                .stroke(tint, style: .init(lineWidth: diameter * 0.115, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
            VStack(spacing: 1) {
                Text("\(Int(value.rounded()))").font(.system(size: diameter * 0.28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(caption).font(.system(size: diameter * 0.10, weight: .semibold, design: .rounded))
                    .tracking(1.5).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Telemetry tile

struct MetricTile: View {
    var icon: String
    var title: String
    var value: String
    var unit: String = ""
    var tint: Color = Theme.ice
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1)
                    .foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text).contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(unit).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 18)
        .glassPanel(tint)
    }
}

// MARK: - Connection status pill (pulsing)

struct StatusPill: View {
    var text: String
    var color: Color
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
                .glow(color, pulse ? 8 : 2)
                .scaleEffect(pulse ? 1.25 : 0.9)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            Text(text).font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .onAppear { pulse = true }
    }
}

// MARK: - Button

struct NeonButton: View {
    var title: String
    var icon: String? = nil
    var tint: Color = Theme.ice
    var filled: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(filled ? Theme.bg0 : tint)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.12))
            )
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .hoverGlow()
    }
}
