import SwiftUI

// On-screen operator panels (all visible on the cluster — no hidden drawer).
// Each reuses the existing control logic verbatim.

private struct Card<C: View>: View {
    let title: String
    @ViewBuilder var content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).sectionLabel()
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}

struct DrivePanel: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        Card(title: "DRIVE") {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { sim.ignitionOn }, set: { sim.setEngine($0) })) {
                    Label("ENGINE", systemImage: "power").font(.system(size: 12, weight: .bold, design: .rounded))
                }.toggleStyle(.switch).tint(Theme.green)
                Spacer()
                Toggle(isOn: Binding(get: { sim.autoDrive }, set: { sim.setAutoDrive($0) })) {
                    Label("AUTO", systemImage: "wand.and.stars").font(.system(size: 12, weight: .bold, design: .rounded))
                }.toggleStyle(.switch).tint(Theme.red)
            }
            .foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                ForEach([0, 60, 90, 110], id: \.self) { v in
                    NeonButton(title: v == 0 ? "STOP" : "\(v)", tint: v == 0 ? Theme.red : Theme.ice) {
                        sim.setSpeed(Double(v) / 1.60934)
                    }
                }
            }
            HStack {
                Text("SPEED").sectionLabel(); Spacer()
                Text("\(Int((sim.speedMph * 1.60934).rounded())) km/h")
                    .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ice)
            }
            Slider(value: Binding(get: { sim.speedMph * 1.60934 },
                                  set: { sim.setSpeed(sim.drivingRoute ? max(8, $0) / 1.60934 : $0 / 1.60934) }),
                   in: 0...130).tint(Theme.ice)
        }
    }
}

struct RoutePanel: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        Card(title: "ROUTE · NAVIGATION") {
            TextField("From — e.g. Dallas, TX", text: $sim.routeFrom).textFieldStyle(.roundedBorder)
            TextField("To — e.g. Houston, TX", text: $sim.routeTo).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                NeonButton(title: sim.routeBusy ? "…" : "PLAN", icon: "map", tint: Theme.ice) {
                    Task { await sim.loadRoute(from: sim.routeFrom, to: sim.routeTo) }
                }
                NeonButton(title: "RANDOM", icon: "shuffle", tint: Theme.amber) {
                    Task { await sim.loadRandomRoute() }
                }
            }
            if sim.drivingRoute {
                NeonButton(title: "STOP", icon: "stop.fill", tint: Theme.red) { sim.stopRouteDrive() }
            } else {
                NeonButton(title: "DRIVE ROUTE", icon: "play.fill", tint: Theme.green, filled: sim.hasRoute) { sim.startRouteDrive() }
            }
            if sim.drivingRoute || sim.routeProgress > 0 {
                SegmentedProgress(progress: sim.routeProgress)
                Text("\(Int(sim.routeProgress * 100))% complete").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
            }
        }
    }
}

struct ScenarioPanel: View {
    @EnvironmentObject var sim: SimController
    @State private var selectedScenarioId = 5
    var body: some View {
        Card(title: "SCENARIO") {
            Menu {
                ForEach(Scenarios.all, id: \.id) { s in
                    Button("\(s.id). \(s.name)") { selectedScenarioId = s.id }
                }
            } label: {
                let name = Scenarios.all.first { $0.id == selectedScenarioId }?.name ?? "Pick"
                Text("\(selectedScenarioId). \(name)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            }.menuStyle(.borderlessButton)
            if sim.runningScenario != nil {
                NeonButton(title: "STOP", icon: "stop.fill", tint: Theme.red) { sim.stopScenario() }
            } else {
                NeonButton(title: "RUN", icon: "play.fill", tint: Theme.red, filled: true) {
                    if let s = Scenarios.all.first(where: { $0.id == selectedScenarioId }) { sim.runScenario(s) }
                }
            }
        }
    }
}

struct DiagnosticsPanel: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        Card(title: "DIAGNOSTICS · DTC") {
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
        Card(title: "NETWORK EFFECTS") {
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
            HStack {
                Text("LIVE PACKET STREAM").sectionLabel()
                Spacer()
                Text("\(sim.log.count) lines").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
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
}
