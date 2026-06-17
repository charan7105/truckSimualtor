import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sim: SimController
    @State private var selectedScenarioId = 5

    var body: some View {
        ZStack {
            DashboardBackground()
            VStack(spacing: 14) {
                header
                HStack(alignment: .top, spacing: 16) {
                    // LEFT: speedometer + drive controls
                    VStack(spacing: 14) {
                        SpeedGauge(speed: sim.speedMph)
                        driveControls
                    }
                    .frame(width: 320)

                    // CENTER: telemetry strip on top, navigation map below
                    VStack(spacing: 12) {
                        telemetryStrip
                        MapPanel().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity)

                    // RIGHT: tachometer + vehicle/diagnostics
                    VStack(spacing: 14) {
                        TachGauge(rpm: sim.rpm)
                        rightPanel
                    }
                    .frame(width: 320)
                }
                packetConsole.frame(height: 116)
            }
            .padding(18)
        }
        .frame(minWidth: 1440, minHeight: 880)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            sim.startBLE()
            if ProcessInfo.processInfo.arguments.contains("demo") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await sim.loadRandomRoute()
                    sim.startRouteDrive()
                }
            }
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("MATRACK TRUCK SIM").font(.system(size: 19, weight: .heavy, design: .rounded)).tracking(2).foregroundStyle(Theme.text)
                Text("Virtual cockpit · J1939 / MT").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.dim)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold))
                Text("SIMULATOR · TEST ONLY").font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1)
            }
            .foregroundStyle(Theme.amber)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.amber.opacity(0.14)))
            .overlay(Capsule().stroke(Theme.amber.opacity(0.5), lineWidth: 1))
            StatusPill(text: sim.status, color: sim.statusColor)
        }
    }

    // MARK: Drive controls (left, under speedometer)
    private var driveControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { sim.ignitionOn }, set: { sim.setEngine($0) })) {
                    Label("ENGINE", systemImage: "power").font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .toggleStyle(.switch).tint(Theme.green)
                Spacer()
                Toggle(isOn: Binding(get: { sim.autoDrive }, set: { sim.setAutoDrive($0) })) {
                    Label("AUTO", systemImage: "wand.and.stars").font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .toggleStyle(.switch).tint(Theme.red)
            }
            .foregroundStyle(Theme.text)

            HStack(spacing: 8) {
                ForEach([0, 60, 90, 110], id: \.self) { v in   // km/h presets
                    NeonButton(title: v == 0 ? "STOP" : "\(v)", tint: v == 0 ? Theme.red : Theme.ice) { sim.setSpeed(Double(v) / 1.60934) }
                }
            }

            VStack(spacing: 6) {
                HStack { Text("SPEED").sectionLabel(); Spacer(); Text("\(Int((sim.speedMph * 1.60934).rounded())) km/h").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ice) }
                Slider(value: Binding(get: { sim.speedMph * 1.60934 }, set: { sim.setSpeed($0 / 1.60934) }), in: 0...130).tint(Theme.ice)
            }

            Divider().overlay(Theme.stroke)

            Text("SCENARIO").sectionLabel()
            HStack(spacing: 8) {
                Menu {
                    ForEach(Scenarios.all, id: \.id) { s in
                        Button("\(s.id). \(s.name)") { selectedScenarioId = s.id }
                    }
                } label: {
                    let name = Scenarios.all.first { $0.id == selectedScenarioId }?.name ?? "Pick"
                    Text("\(selectedScenarioId). \(name)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                if sim.runningScenario != nil {
                    NeonButton(title: "STOP", tint: Theme.red) { sim.stopScenario() }.frame(width: 84)
                } else {
                    NeonButton(title: "RUN", tint: Theme.red, filled: true) {
                        if let s = Scenarios.all.first(where: { $0.id == selectedScenarioId }) { sim.runScenario(s) }
                    }.frame(width: 84)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }

    // MARK: Telemetry strip (center, under map)
    private var telemetryStrip: some View {
        HStack(spacing: 12) {
            MetricTile(icon: "gauge.with.dots.needle.67percent", title: "Odometer", value: fmt(sim.odometerMiles, 0), unit: "mi", tint: Theme.ice)
            MetricTile(icon: "clock.fill", title: "Engine Hrs", value: fmt(sim.engineHours, 1), unit: "h", tint: Theme.blue)
            MetricTile(icon: "location.north.fill", title: "Heading", value: "\(sim.headingDeg)", unit: "°", tint: Theme.ice)
            MetricTile(icon: "antenna.radiowaves.left.and.right", title: "Satellites", value: "\(sim.satellites)", tint: Theme.green)
            MetricTile(icon: "bonjour", title: "ECM", value: sim.ecmActive ? "ACTIVE" : "OFF", tint: sim.ecmActive ? Theme.green : Theme.dim)
        }
    }

    // MARK: Right panel — vehicle + fuel + diagnostics + network
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("VEHICLE").sectionLabel()
                    Text(sim.vin).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(sim.firmware).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                RingGauge(value: sim.fuelPct, caption: "FUEL", tint: sim.fuelPct < 20 ? Theme.red : Theme.green)
            }

            Divider().overlay(Theme.stroke)

            HStack { Text("DIAGNOSTICS · DTC").sectionLabel(); Spacer()
                if !sim.faults.isEmpty { NeonButton(title: "CLEAR", icon: "trash", tint: Theme.red) { sim.clearFaults() }.frame(width: 92) } }
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
                }
            }

            Divider().overlay(Theme.stroke)

            Text("NETWORK EFFECTS").sectionLabel()
            cfgSlider("Packet loss", \.packetLossPct, 0...50, "%", 0)
            cfgSlider("Duplicates", \.duplicatePct, 0...50, "%", 0)
            cfgSlider("Out-of-order", \.outOfOrderPct, 0...50, "%", 0)
            cfgSlider("Pkt interval", \.packetIntervalSec, 0.25...3, "s", 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel()
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

    // MARK: Packet console
    private var packetConsole: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LIVE PACKET STREAM").sectionLabel()
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
                            .font(.system(size: 11, design: .monospaced))
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: sim.log.count) { _ in
                    if let last = sim.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassPanel()
    }

    // helpers
    private func fmt(_ v: Double, _ d: Int) -> String { String(format: "%.\(d)f", v) }
    private func symbol(_ k: LogLine.Kind) -> String { k == .out ? "→" : (k == .inbound ? "←" : (k == .drop ? "⨯" : "•")) }
    private func color(_ k: LogLine.Kind) -> Color { k == .out ? Theme.ice : (k == .inbound ? Theme.amber : (k == .drop ? Theme.red : Theme.dim)) }
}
