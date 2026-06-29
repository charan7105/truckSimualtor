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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                if !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                        .frame(width: 23, height: 23)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
                }
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(2).textCase(.uppercase).foregroundStyle(Theme.text.opacity(0.92))
                Spacer()
            }
            content()
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Theme.glassTop, Theme.glassBot], startPoint: .top, endPoint: .bottom))
        )
        .overlay(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.75), tint.opacity(0.0)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 2).clipShape(Capsule()).padding(.horizontal, 12)
                .shadow(color: tint.opacity(0.5), radius: 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.025)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
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
            // SPEED label + live MODE badge + value all on one line (mode no longer needs its own row)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SPEED").sectionLabel()
                Text(modeText).font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(modeTint)
                Spacer()
                Text("\(Int((sim.speedMph * 1.60934).rounded()))")
                    .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.ice)
                Text("km/h").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
            }
            Slider(value: Binding(get: { sim.speedMph * 1.60934 },
                                  set: { sim.setSpeed(sim.drivingRoute ? max(8, $0) / 1.60934 : $0 / 1.60934) }),
                   in: 0...130).tint(Theme.ice)

            Text("SIM SPEED · MAP PACE").sectionLabel()
            HStack(spacing: 6) {
                ForEach([1, 5, 10, 25, 30], id: \.self) { x in
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
            // From → To on ONE line (with the arrow reading left-to-right), then plan/drive actions paired up.
            HStack(spacing: 7) {
                NavField(placeholder: "From", text: $sim.routeFrom, icon: "smallcircle.filled.circle", tint: Theme.green)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dim)
                NavField(placeholder: "To", text: $sim.routeTo, icon: "mappin.circle.fill", tint: Theme.red)
            }
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
            HStack(spacing: 8) {
                if sim.drivingRoute {
                    NeonButton(title: "STOP", icon: "stop.fill", tint: Theme.red) { sim.stopRouteDrive() }
                } else {
                    NeonButton(title: "DRIVE", icon: "play.fill", tint: Theme.green, filled: sim.hasRoute) { sim.startRouteDrive() }
                }
                if sim.dayDriving {
                    NeonButton(title: "END DAY", icon: "stop.fill", tint: Theme.amber, filled: true) { sim.stopDay() }
                } else {
                    NeonButton(title: "DRIVE MY DAY", icon: "sun.max.fill", tint: Theme.amber) { Task { await sim.driveMyDay() } }
                }
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
    @State private var selectedScenarioId = 4   // Driving highway — a good default demo
    @State private var showSteps = false
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
                    if let s = sel { sim.startGuided(s) }   // opens the centered guided walkthrough overlay
                }
            }
            if let steps = sel?.appSteps, !steps.isEmpty {
                Button { showSteps.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("WHAT & HOW (\(steps.count))").font(.system(size: 11, weight: .bold, design: .rounded))
                        Spacer()
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.amber.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.amber.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain).hoverGlow()
                .popover(isPresented: $showSteps, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(selectedScenarioId). \(sel?.name ?? "")")
                            .font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                        if let ex = sel?.expect, !ex.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("WHAT IT DOES").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(Theme.dim)
                                Text(ex).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider().overlay(Theme.stroke)
                        Label("DO THIS IN THE APP", systemImage: "list.bullet.clipboard")
                            .font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(Theme.amber)
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(i + 1)").font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Theme.amber).frame(width: 18, alignment: .trailing)
                                Text(s).font(.system(size: 13, design: .rounded)).foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider().overlay(Theme.stroke)
                        VStack(alignment: .leading, spacing: 3) {
                            Label("SETUP (ONCE)", systemImage: "dot.radiowaves.left.and.right")
                                .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(Theme.ice)
                            Text("In the ELD app, open the Bluetooth / ELD-device screen, select \"ELD-MA\", and connect. A vehicle must be assigned to the driver first.")
                                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18).frame(width: 360)
                    .background(Theme.bg1)
                }
            }
        }
    }
}

/// Step-by-step guided walkthrough for a scenario: shows one instruction at a time and, on the
/// "Tap RUN" step, fires the real sim action (which for the disconnect/UDP scenarios drops the link,
/// records the drive, and dumps it on the app's reconnect — so the tester knows exactly what to do
/// in the app at each moment).
struct GuidedStepView: View {
    let scenario: Scenario
    let step: Int
    let onAdvance: () -> Void
    let onCancel: () -> Void
    var body: some View {
        let steps = scenario.appSteps
        let isLast = step + 1 >= steps.count
        let isRun = steps[step].uppercased().contains("RUN")
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("GUIDED RUN", systemImage: "list.number")
                    .font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1.2).foregroundStyle(Theme.amber)
                Spacer()
                Text("Step \(step + 1) of \(steps.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            Text("\(scenario.id). \(scenario.name)")
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.ice)
            Text(steps[step])
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule().fill(i <= step ? Theme.amber : Theme.stroke)
                        .frame(width: i == step ? 22 : 9, height: 6)
                }
            }
            HStack {
                Button(action: onCancel) {
                    Text("Cancel").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
                }.buttonStyle(.plain)
                Spacer()
                NeonButton(title: isLast ? "Done" : (isRun ? "Run it" : "Next"),
                           icon: isLast ? "checkmark" : (isRun ? "play.fill" : "arrow.right"),
                           tint: isRun ? Theme.red : Theme.ice, filled: true) { onAdvance() }
                    .frame(width: 170)
            }
        }
        .padding(26).frame(width: 440)
        .background(Theme.bg1)
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
    @State private var showSignalInfo = false
    var body: some View {
        Card(title: "CONNECTION · SIGNAL", icon: "antenna.radiowaves.left.and.right", tint: Theme.blue) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {

                    // F1 — signal / out-of-range: one clean row of presets
                    HStack(spacing: 8) {
                        Image(systemName: sim.linkDown ? "wifi.slash" : "wifi").font(.system(size: 12, weight: .bold)).foregroundStyle(signalTint)
                        Text("SIGNAL").sectionLabel()
                        Spacer()
                        Text(signalState).font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(signalTint)
                        Button { showSignalInfo.toggle() } label: {
                            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.dim)
                        }
                        .buttonStyle(.plain).hoverGlow()
                        .popover(isPresented: $showSignalInfo, arrowEdge: .bottom) {
                            Text("AUTO continuously sweeps the signal on its own (full ↔ weak ↔ poor) and every few minutes drops fully out of range to mimic a dead zone (tunnel / rural gap) — the app disconnects and auto-reconnects, just like a real drive. It's the default. FULL / POOR set link strength manually (lower = more latency, still connected — real BLE never drops packets on weak signal). DROP forces an immediate disconnect now, then re-advertises after the Auto-return timer, or press BACK, so the app reconnects.")
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.text)
                                .frame(width: 280).fixedSize(horizontal: false, vertical: true).padding(16).background(Theme.bg1)
                        }
                    }
                    HStack(spacing: 6) {
                        signalPreset("FULL", 100)
                        NeonButton(title: "AUTO", tint: Theme.ice, filled: sim.autoSignal) { sim.setAutoSignal(!sim.autoSignal) }
                        signalPreset("POOR", 25)
                        NeonButton(title: sim.linkDown ? "BACK" : "DROP", icon: sim.linkDown ? "wifi" : "wifi.slash",
                                   tint: Theme.red, filled: sim.linkDown) {
                            if sim.linkDown { sim.resumeLink() } else { sim.autoSignal = false; sim.forceDisconnect(seconds: sim.config.rangeOutageSec) }
                        }
                    }
                    if sim.linkDown {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(Theme.amber)
                                Text(outageCountdown).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.amber)
                                Spacer()
                            }
                        }
                    }
                    cfgSlider("Auto-return", \.rangeOutageSec, 15...180, "s", 0)

                    Divider().overlay(Theme.stroke)

                    // Raw transport effects (advanced). Weak signal adds latency (driven by SIGNAL / AUTO), not loss.
                    Text("RAW EFFECTS").sectionLabel()
                    cfgSlider("Dup", \.duplicatePct, 0...50, "%", 0)
                    cfgSlider("Reorder", \.outOfOrderPct, 0...50, "%", 0)
                    cfgSlider("Interval", \.packetIntervalSec, 0.25...3, "s", 2)

                    Divider().overlay(Theme.stroke)

                    // F2 — stored-packet dump (reproduce the fast-dump disconnect)
                    HStack {
                        Text("STORED DUMP").sectionLabel(); Spacer()
                        Text("\(sim.config.storedDumpCount) pkts").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                    countSlider
                    cfgSlider("Cadence", \.storedDumpCadenceSec, 0.25...1.5, "s", 2)
                    NeonButton(title: isDumping ? "DUMPING…" : "DUMP STORED",
                               icon: "tray.and.arrow.down.fill", tint: Theme.blue, filled: isDumping) {
                        sim.dumpStoredPackets(count: sim.config.storedDumpCount, cadenceSec: sim.config.storedDumpCadenceSec)
                    }
                    Text("≈500ms reproduces the disconnect · 1s is safe.")
                        .font(.system(size: 9, design: .rounded)).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    private var isDumping: Bool { sim.runningScenario?.hasPrefix("Stored dump") == true }

    private var signalTint: Color {
        if sim.linkDown || sim.config.signalPct < 20 { return Theme.red }
        if sim.config.signalPct < 50 { return Theme.amber }
        return Theme.green
    }

    private var signalState: String {
        if sim.linkDown { return "OUT OF RANGE" }
        let p = Int(sim.config.signalPct.rounded())
        if p >= 80 { return "FULL · \(p)%" }
        if p >= 40 { return "WEAK · \(p)%" }
        return "POOR · \(p)%"
    }

    private var outageCountdown: String {
        guard let ends = sim.dropEndsAt else { return "out of range" }
        let r = Int(ceil(ends.timeIntervalSinceNow))
        return r > 0 ? "back in range in \(r)s" : "reconnecting…"
    }

    private func signalPreset(_ title: String, _ pct: Double) -> some View {
        // Uniform neutral style so the row reads as one control; only the active level is highlighted.
        // (The colour meaning lives in the FULL/WEAK/POOR state label above.)
        let active = !sim.linkDown && !sim.autoSignal && Int(sim.config.signalPct.rounded()) == Int(pct)
        return NeonButton(title: title, tint: Theme.ice, filled: active) { sim.autoSignal = false; sim.setSignal(pct) }
    }

    private var countSlider: some View {
        HStack(spacing: 8) {
            Text("Count").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim).frame(width: 56, alignment: .leading)
            Slider(value: Binding(get: { Double(sim.config.storedDumpCount) }, set: { sim.config.storedDumpCount = Int($0) }), in: 0...300).tint(Theme.ice)
            Text("\(sim.config.storedDumpCount)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ice).frame(width: 42, alignment: .trailing)
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
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sim.log) { line in
                            HStack(spacing: 8) {
                                Text(line.time).foregroundStyle(Theme.dim).monospacedDigit()
                                Text(symbol(line.kind)).foregroundStyle(color(line.kind))
                                Text(line.text).foregroundStyle(line.kind == .info ? Theme.text.opacity(0.62) : Theme.text.opacity(0.9))
                                Spacer()
                            }
                            .font(.system(size: 12, design: .monospaced)).id(line.id)
                        }
                    }.padding(.vertical, 4).padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                             .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
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
