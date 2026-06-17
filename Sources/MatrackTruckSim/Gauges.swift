import SwiftUI

// MARK: - Shared 270° dial ring (used by both speed + tach for a twin-gauge cockpit)

private struct GaugeRing: View {
    var frac: Double
    var arc: [Color]
    private let sweep = 0.75            // 270°
    private let startAngle = 135.0

    var body: some View {
        let f = max(0, min(1, frac))
        ZStack {
            // tick marks
            ForEach(0..<28) { i in
                Capsule()
                    .fill(Color.white.opacity(i % 7 == 0 ? 0.30 : 0.10))
                    .frame(width: i % 7 == 0 ? 2.5 : 1.5, height: i % 7 == 0 ? 12 : 7)
                    .offset(y: -116)
                    .rotationEffect(.degrees(startAngle + 270.0 * Double(i) / 27.0))
            }
            // track
            Circle().trim(from: 0, to: sweep)
                .stroke(Color.white.opacity(0.06), style: .init(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
            // value arc
            Circle().trim(from: 0, to: sweep * f)
                .stroke(AngularGradient(gradient: Gradient(colors: arc),
                                        center: .center,
                                        startAngle: .degrees(startAngle),
                                        endAngle: .degrees(startAngle + 270)),
                        style: .init(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
                .animation(.easeOut(duration: 0.4), value: f)
        }
        .frame(width: 232, height: 232)
    }
}

// MARK: - Speedometer (left dial)

struct SpeedGauge: View {
    var speed: Double            // mph (source of truth)
    var maxSpeed: Double = 90    // mph (drives the arc)
    var body: some View {
        let kmh = speed * 1.60934
        ZStack {
            GaugeRing(frac: speed / maxSpeed, arc: Theme.speedArc)
            VStack(spacing: 0) {
                Text("\(Int(kmh.rounded()))")
                    .font(.system(size: 70, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: speed)
                Text("KM/H").font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(6).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 232, height: 232)
    }
}

// MARK: - Tachometer (right dial)

struct TachGauge: View {
    var rpm: Int
    var maxRpm: Double = 3000
    var body: some View {
        ZStack {
            GaugeRing(frac: Double(rpm) / maxRpm, arc: Theme.tachArc)
            VStack(spacing: 0) {
                Text("\(rpm)")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: rpm)
                Text("RPM").font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(6).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 232, height: 232)
    }
}

// MARK: - Small circular ring (fuel, etc.)

struct RingGauge: View {
    var value: Double            // 0–100
    var caption: String
    var tint: Color
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.12), lineWidth: 9)
            Circle().trim(from: 0, to: max(0, min(1, value / 100)))
                .stroke(tint, style: .init(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
            VStack(spacing: 1) {
                Text("\(Int(value.rounded()))").font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(caption).font(.system(size: 8, weight: .semibold, design: .rounded))
                    .tracking(1.5).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 78, height: 78)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                Text(title).sectionLabel()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text).contentTransition(.numericText())
                Text(unit).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
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
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
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
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.12))
            )
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
