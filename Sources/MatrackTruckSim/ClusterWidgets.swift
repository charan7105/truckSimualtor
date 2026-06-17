import SwiftUI

// MARK: - Top rail (brand · clock/temp · SIMULATOR badge · VIN · status)

struct TopRail: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.ice)
            Text("MATRACK").font(.system(size: 16, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(Theme.text)
            ClockTempWidget()
            Spacer()
            simulatorBadge
            VINChip()
            StatusPill(text: sim.status, color: sim.statusColor)
        }
    }
    private var simulatorBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold))
            Text("SIMULATOR · TEST ONLY").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1)
        }
        .foregroundStyle(Theme.amber)
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(Capsule().fill(Theme.amber.opacity(0.18)))
        .overlay(Capsule().stroke(Theme.amber.opacity(0.5), lineWidth: 1))
    }
}

struct ClockTempWidget: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                Text(timeString(ctx.date))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                Text("· \(sim.ambientTempC)°")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.dim)
            }
        }
    }
    private func timeString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

/// Editable VIN — taps to an inline field bound straight to sim.vin (flows into the LV packet).
struct VINChip: View {
    @EnvironmentObject var sim: SimController
    @State private var editing = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "number").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.dim)
            if editing {
                TextField("VIN", text: $sim.vin)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(width: 170)
                    .focused($focused)
                    .onSubmit { editing = false }
            } else {
                Text(sim.vin.isEmpty ? "SET VIN" : sim.vin)
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Text(sim.vin.count == 17 ? "VALID" : "TEST")
                .font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1)
                .foregroundStyle(sim.vin.count == 17 ? Theme.green : Theme.amber)
            Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(Theme.panel.opacity(0.85)))
        .overlay(Capsule().stroke(editing ? Theme.ice.opacity(0.6) : Theme.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { editing = true; focused = true }
    }
}

// MARK: - Turn-by-turn nav strip

struct NavStrip: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        let active = sim.hasRoute
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ice.opacity(0.14)).frame(width: 44, height: 44)
                Image(systemName: active ? sim.nextTurn.icon : "location.slash")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(active ? Theme.ice : Theme.dim)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(active ? distanceString(sim.routeRemainingMeters) : "No active route")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).contentTransition(.numericText())
                Text(active ? "Continue on route" : "Plan or randomize a route in the Flight Deck")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            if active {
                HStack(spacing: 6) {
                    Image(systemName: "flag.checkered").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.dim)
                    Text("\(sim.routeMilesLeft) mi left").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel.opacity(0.85))
                GeometryReader { geo in
                    Rectangle().fill(Theme.green)
                        .frame(width: geo.size.width * sim.routeProgress, height: 2)
                        .glow(Theme.green, 3)
                }
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke, lineWidth: 1))
        .opacity(active ? 1 : 0.65)
    }
    private func distanceString(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f km", m / 1000) : "\(Int(m)) m"
    }
}

// MARK: - Gear indicator (P R N D)

struct GearIndicator: View {
    @EnvironmentObject var sim: SimController
    @Namespace private var ns
    private let gears = ["P", "R", "N", "D"]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(gears, id: \.self) { g in
                let on = g == sim.gear
                Text(g)
                    .font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(2)
                    .foregroundStyle(on ? Theme.bg0 : Theme.dimmer)
                    .frame(width: 32, height: 28)
                    .background(
                        ZStack {
                            if on {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ice)
                                    .glow(Theme.ice, 8)
                                    .matchedGeometryEffect(id: "gear", in: ns)
                            }
                        }
                    )
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassPanel()
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: sim.gear)
    }
}

// MARK: - Compass rose (floats over the map)

struct CompassRose: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        ZStack {
            Circle().fill(Theme.bg0.opacity(0.7))
            Circle().stroke(Theme.stroke, lineWidth: 1)
            Text("N").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Theme.red)
                .offset(y: -32)
                .rotationEffect(.degrees(-Double(sim.headingDeg)))
                .animation(.easeOut(duration: 0.4), value: sim.headingDeg)
            VStack(spacing: 0) {
                Text("\(sim.headingDeg)°").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text(sim.cardinal).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: 88, height: 88)
    }
}

// MARK: - Telemetry dock (bottom row)

struct TelemetryDock: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        HStack(spacing: 12) {
            MetricTile(icon: "gauge.with.dots.needle.67percent", title: "Odometer", value: fmt(sim.odometerMiles, 0), unit: "mi", tint: Theme.ice)
            MetricTile(icon: "arrow.triangle.swap", title: "Trip", value: fmt(sim.tripMiles, 1), unit: "mi", tint: Theme.blue)
            MetricTile(icon: "clock.fill", title: "Engine Hrs", value: fmt(sim.engineHours, 1), unit: "h", tint: Theme.blue)
            MetricTile(icon: "location.north.fill", title: "Heading", value: "\(sim.headingDeg)", unit: "°", tint: Theme.ice)
            MetricTile(icon: "antenna.radiowaves.left.and.right", title: "Satellites", value: "\(sim.satellites)", tint: sim.satellites >= 4 ? Theme.green : Theme.amber)
            MetricTile(icon: "bonjour", title: "ECM", value: sim.ecmActive ? "ACTIVE" : "OFF", tint: sim.ecmActive ? Theme.green : Theme.dim)
        }
    }
    private func fmt(_ v: Double, _ d: Int) -> String { String(format: "%.\(d)f", v) }
}
