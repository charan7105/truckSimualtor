import SwiftUI
import AppKit
import UniformTypeIdentifiers

// On-screen operator panels (all visible on the cluster — no hidden drawer).
// Each reuses the existing control logic verbatim.

private struct Card<C: View>: View {
    let title: String
    var icon: String = ""
    var tint: Color = Theme.ice
    @ViewBuilder var content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                if !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                }
                Text(title).sectionLabel()
                Spacer()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel.opacity(0.85))
        )
        .overlay(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 2).clipShape(Capsule()).padding(.horizontal, 14).padding(.top, 0)
        }
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
    }
}

struct DrivePanel: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        Card(title: "DRIVE", icon: "power", tint: Theme.green) {
            HStack(spacing: 10) {
                ToggleChip(title: "ENGINE", icon: "power", isOn: sim.ignitionOn, tint: Theme.green) { sim.setEngine(!sim.ignitionOn) }
                ToggleChip(title: "AUTO", icon: "wand.and.stars", isOn: sim.autoDrive, tint: Theme.red) { sim.setAutoDrive(!sim.autoDrive) }
            }
            HStack {
                Text("MODE").sectionLabel(); Spacer()
                Text(modeText).font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1.5)
                    .foregroundStyle(modeTint)
            }
            Text("QUICK SET · KM/H").sectionLabel()
            HStack(spacing: 8) {
                ForEach([0, 60, 90, 110], id: \.self) { v in
                    NeonButton(title: v == 0 ? "STOP" : "\(v)",
                               tint: v == 0 ? Theme.red : Theme.ice,
                               filled: presetActive(v)) {
                        sim.setSpeed(Double(v) / 1.60934)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("SPEED").sectionLabel(); Spacer()
                Text("\(Int((sim.speedMph * 1.60934).rounded()))")
                    .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.ice)
                Text("km/h").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
            }
            Slider(value: Binding(get: { sim.speedMph * 1.60934 },
                                  set: { sim.setSpeed(sim.drivingRoute ? max(8, $0) / 1.60934 : $0 / 1.60934) }),
                   in: 0...130).tint(Theme.ice)

            HStack {
                Text("SIM SPEED · MAP PACE").sectionLabel(); Spacer()
                Text("how fast the route plays").font(.system(size: 9, design: .rounded)).foregroundStyle(Theme.dim)
            }
            HStack(spacing: 8) {
                ForEach([1, 3, 5, 10], id: \.self) { x in
                    NeonButton(title: "\(x)×", tint: Theme.amber, filled: Int(sim.config.routeTimeScale.rounded()) == x) {
                        sim.config.routeTimeScale = Double(x)
                    }
                }
            }
        }
    }

    private var modeText: String {
        if sim.drivingRoute { return "ROUTE" }
        if sim.autoDrive { return "AUTO CRUISE" }
        return sim.ignitionOn ? "MANUAL" : "PARKED"
    }
    private var modeTint: Color {
        if sim.drivingRoute { return Theme.green }
        if sim.autoDrive { return Theme.red }
        return sim.ignitionOn ? Theme.ice : Theme.dim
    }
    private func presetActive(_ v: Int) -> Bool {
        let kmh = sim.speedMph * 1.60934
        return v == 0 ? sim.speedMph < 0.5 : abs(kmh - Double(v)) < 4
    }
}

struct RoutePanel: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        Card(title: "ROUTE · NAVIGATION", icon: "map.fill", tint: Theme.ice) {
            NavField(placeholder: "From — e.g. Dallas, TX", text: $sim.routeFrom, icon: "smallcircle.filled.circle", tint: Theme.green)
            NavField(placeholder: "To — e.g. Houston, TX", text: $sim.routeTo, icon: "mappin.circle.fill", tint: Theme.red)
            HStack(spacing: 8) {
                NeonButton(title: sim.routeBusy ? "…" : "PLAN", icon: "map", tint: Theme.ice) {
                    Task { await sim.loadRoute(from: sim.routeFrom, to: sim.routeTo) }
                }
                NeonButton(title: "RANDOM", icon: "shuffle", tint: Theme.amber) {
                    Task { await sim.loadRandomRoute() }
                }
            }
            if !sim.routeInfo.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").font(.system(size: 10)).foregroundStyle(Theme.ice)
                    Text(sim.routeInfo).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }
            if sim.drivingRoute {
                NeonButton(title: "STOP", icon: "stop.fill", tint: Theme.red) { sim.stopRouteDrive() }
            } else {
                NeonButton(title: "DRIVE ROUTE", icon: "play.fill", tint: Theme.green, filled: sim.hasRoute) { sim.startRouteDrive() }
            }
            if sim.drivingRoute || sim.routeProgress > 0 {
                SegmentedProgress(progress: sim.routeProgress)
                HStack {
                    Text("\(Int(sim.routeProgress * 100))% complete").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
                    Spacer()
                    Text("\(sim.routeMilesLeft) mi left").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.ice)
                }
            }
        }
    }
}

struct ScenarioPanel: View {
    @EnvironmentObject var sim: SimController
    @State private var selectedScenarioId = 5
    var body: some View {
        let sel = Scenarios.all.first { $0.id == selectedScenarioId }
        return Card(title: "SCENARIO", icon: "film.fill", tint: Theme.red) {
            Menu {
                ForEach(Scenarios.all, id: \.id) { s in
                    Button("\(s.id). \(s.name)") { selectedScenarioId = s.id }
                }
            } label: {
                Text("\(selectedScenarioId). \(sel?.name ?? "Pick")")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            }.menuStyle(.borderlessButton)
            if sim.runningScenario != nil {
                NeonButton(title: "STOP", icon: "stop.fill", tint: Theme.red) { sim.stopScenario() }
            } else {
                NeonButton(title: "RUN", icon: "play.fill", tint: Theme.red, filled: true) {
                    if let s = sel { sim.runScenario(s) }
                }
            }
            if let steps = sel?.appSteps, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("DO THIS IN THE APP", systemImage: "list.bullet.clipboard")
                        .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(Theme.amber)
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.amber)
                            Text(s).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.amber.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.amber.opacity(0.3), lineWidth: 1))
            }
        }
    }
}

struct DiagnosticsPanel: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        Card(title: "DIAGNOSTICS · DTC", icon: "wrench.and.screwdriver.fill", tint: Theme.amber) {
            HStack(spacing: 6) {
                ForEach(["P0143", "P0217", "C0035", "U0101"], id: \.self) { code in
                    NeonButton(title: code, tint: Theme.amber, filled: sim.faults.contains(code)) { sim.injectFault(code) }
                }
            }
            if sim.faults.isEmpty {
                Text("No active fault codes").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
            } else {
                HStack(spacing: 6) {
                    ForEach(sim.faults, id: \.self) { f in
                        Text(f).font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.red.opacity(0.18)))
                            .overlay(Capsule().stroke(Theme.red.opacity(0.6), lineWidth: 1))
                            .foregroundStyle(Theme.red)
                    }
                    Spacer()
                    NeonButton(title: "CLEAR", icon: "trash", tint: Theme.red) { sim.clearFaults() }.frame(width: 96)
                }
            }
        }
    }
}

struct NetworkPanel: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        Card(title: "NETWORK EFFECTS", icon: "wifi", tint: Theme.blue) {
            cfgSlider("Loss", \.packetLossPct, 0...50, "%", 0)
            cfgSlider("Dup", \.duplicatePct, 0...50, "%", 0)
            cfgSlider("Reorder", \.outOfOrderPct, 0...50, "%", 0)
            cfgSlider("Interval", \.packetIntervalSec, 0.25...3, "s", 2)
        }
    }
    private func cfgSlider(_ label: String, _ kp: WritableKeyPath<SimConfig, Double>,
                           _ range: ClosedRange<Double>, _ unit: String, _ dec: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim).frame(width: 56, alignment: .leading)
            Slider(value: Binding(get: { sim.config[keyPath: kp] }, set: { sim.config[keyPath: kp] = $0 }), in: range).tint(Theme.ice)
            Text("\(String(format: "%.\(dec)f", sim.config[keyPath: kp]))\(unit)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ice).frame(width: 42, alignment: .trailing)
        }
    }
}

struct PacketConsole: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("LIVE PACKET STREAM").sectionLabel()
                Spacer()
                Text("\(sim.log.count) lines").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                Button { exportLog() } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ice)
                }.buttonStyle(.plain).hoverGlow().help("Export packet log to a file")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(sim.log) { line in
                            HStack(spacing: 8) {
                                Text(line.time).foregroundStyle(Theme.dim)
                                Text(symbol(line.kind)).foregroundStyle(color(line.kind))
                                Text(line.text).foregroundStyle(line.kind == .info ? Theme.dim : Theme.text)
                                Spacer()
                            }
                            .font(.system(size: 11, design: .monospaced)).id(line.id)
                        }
                    }.padding(.vertical, 4)
                }
                .onChange(of: sim.log.count) { _ in
                    if let last = sim.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(Theme.ice)
    }
    private func symbol(_ k: LogLine.Kind) -> String { k == .out ? "→" : (k == .inbound ? "←" : (k == .drop ? "⨯" : "•")) }
    private func color(_ k: LogLine.Kind) -> Color { k == .out ? Theme.ice : (k == .inbound ? Theme.amber : (k == .drop ? Theme.red : Theme.dim)) }

    private func exportLog() {
        let header = "Matrack Truck Sim — packet log\nVIN: \(sim.vin)\nExported: \(Date())\nLines: \(sim.log.count)\n\n"
        let body = sim.log.map { "\($0.time)  \(symbol($0.kind))  \($0.text)" }.joined(separator: "\n")
        let text = header + body
        let panel = NSSavePanel()
        panel.title = "Export Packet Log"
        panel.nameFieldStringValue = "matrack-packets.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
