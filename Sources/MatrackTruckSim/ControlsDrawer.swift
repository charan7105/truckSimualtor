import SwiftUI

/// FLIGHT DECK — the operator surface. Slides in from the right; holds every simulator control so the
/// cluster face stays a clean instrument. All control logic is unchanged from the original dashboard.
struct ControlsDrawer: View {
    @EnvironmentObject var sim: SimController
    @Binding var open: Bool
    @State private var selectedScenarioId = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    driveCard
                    routeCard
                    scenarioCard
                    diagnosticsCard
                    networkCard
                    packetCard
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg2.opacity(0.98))
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Theme.stroke), alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.ice)
            Text("FLIGHT DECK").font(.system(size: 14, weight: .heavy, design: .rounded)).tracking(2).foregroundStyle(Theme.text)
            Spacer()
            StatusPill(text: sim.status, color: sim.statusColor)
            Button { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { open = false } } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.dim)
            }.buttonStyle(.plain).hoverGlow()
        }
        .padding(16)
        .background(Theme.bg0.opacity(0.6))
    }

    // MARK: cards

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).sectionLabel()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var driveCard: some View {
        card("DRIVE") {
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

            Text("QUICK SET · KM/H").sectionLabel()
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

    private var routeCard: some View {
        card("ROUTE · NAVIGATION") {
            HStack(spacing: 6) {
                TextField("From", text: $sim.routeFrom).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dim)
                TextField("To", text: $sim.routeTo).textFieldStyle(.roundedBorder)
            }
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
                Text("\(Int(sim.routeProgress * 100))% · \(sim.routeInfo)")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim).lineLimit(1)
            }
        }
    }

    private var scenarioCard: some View {
        card("SCENARIO") {
            HStack(spacing: 8) {
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
                    NeonButton(title: "STOP", tint: Theme.red) { sim.stopScenario() }.frame(width: 90)
                } else {
                    NeonButton(title: "RUN", tint: Theme.red, filled: true) {
                        if let s = Scenarios.all.first(where: { $0.id == selectedScenarioId }) { sim.runScenario(s) }
                    }.frame(width: 90)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        card("DIAGNOSTICS · DTC") {
            HStack(spacing: 8) {
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
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.red.opacity(0.18)))
                            .overlay(Capsule().stroke(Theme.red.opacity(0.6), lineWidth: 1))
                            .foregroundStyle(Theme.red)
                    }
                    Spacer()
                    NeonButton(title: "CLEAR", icon: "trash", tint: Theme.red) { sim.clearFaults() }.frame(width: 100)
                }
            }
        }
    }

    private var networkCard: some View {
        card("NETWORK EFFECTS") {
            cfgSlider("Packet loss", \.packetLossPct, 0...50, "%", 0)
            cfgSlider("Duplicates", \.duplicatePct, 0...50, "%", 0)
            cfgSlider("Out-of-order", \.outOfOrderPct, 0...50, "%", 0)
            cfgSlider("Pkt interval", \.packetIntervalSec, 0.25...3, "s", 2)
        }
    }

    private var packetCard: some View {
        card("LIVE PACKET STREAM") {
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
                .frame(height: 220)
                .onChange(of: sim.log.count) { _ in
                    if let last = sim.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func cfgSlider(_ label: String, _ kp: WritableKeyPath<SimConfig, Double>,
                           _ range: ClosedRange<Double>, _ unit: String, _ dec: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { sim.config[keyPath: kp] }, set: { sim.config[keyPath: kp] = $0 }), in: range).tint(Theme.ice)
            Text("\(String(format: "%.\(dec)f", sim.config[keyPath: kp]))\(unit)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ice).frame(width: 44, alignment: .trailing)
        }
    }

    private func symbol(_ k: LogLine.Kind) -> String { k == .out ? "→" : (k == .inbound ? "←" : (k == .drop ? "⨯" : "•")) }
    private func color(_ k: LogLine.Kind) -> Color { k == .out ? Theme.ice : (k == .inbound ? Theme.amber : (k == .drop ? Theme.red : Theme.dim)) }
}
