import SwiftUI
import AppKit
import UniformTypeIdentifiers

// On-screen operator panels (all visible on the cluster — no hidden drawer).
// Each reuses the existing control logic verbatim.

/// A panel on the face. One fill, one hairline — that is the whole treatment.
///
/// It used to carry nine: a gradient fill, a gradient stroke, a glowing tinted bar across the top,
/// a tinted icon in a rounded chip, and a drop shadow. Multiplied by eight panels, every container
/// competed with its own contents, and the per-card `tint` spent colour on decoration — so by the
/// time colour needed to mean something (armed, out of range, changed) it had nothing left to say.
/// `icon` and `tint` are still accepted so call sites read the same, but they no longer draw chrome.
private struct Card<C: View>: View {
    let title: String
    var icon: String = ""
    var tint: Color = Theme.ice
    @ViewBuilder var content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                if !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                }
                Text(title).cardTitle()
                Spacer()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.06), lineWidth: 1))
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
            Text("Quick set · km/h").sectionLabel()
            HStack(spacing: 8) {
                ForEach([0, 60, 90, 110], id: \.self) { v in
                    NeonButton(title: v == 0 ? "STOP" : "\(v)",
                               tint: Theme.ice, filled: presetActive(v)) {
                        sim.setSpeed(Double(v) / 1.60934)
                    }
                }
            }
            // SPEED label + live MODE badge + value all on one line (mode no longer needs its own row)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Speed").sectionLabel()
                Text(modeText.capitalized).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(modeTint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(modeTint.opacity(0.14)))
                Spacer()
                Text("\(Int((sim.speedMph * 1.60934).rounded()))")
                    .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.ice)
                Text("km/h").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.dim)
            }
            Slider(value: Binding(get: { sim.speedMph * 1.60934 },
                                  set: { sim.setSpeed(sim.drivingRoute ? max(8, $0) / 1.60934 : $0 / 1.60934) }),
                   in: 0...130).tint(Theme.ice)

            // Was "SIM SPEED · MAP PACE", which reads as a third speed control sitting under two real
            // ones. It is not a speed: it scales how far the truck travels per tick along the route
            // (see driveDt in step()), while the speed on the wire stays whatever SPEED is set to.
            Text("Fast-forward").sectionLabel()
            HStack(spacing: 6) {
                ForEach([1, 5, 10, 25, 30], id: \.self) { x in
                    NeonButton(title: "\(x)×", tint: Theme.ice, filled: Int(sim.config.routeTimeScale.rounded()) == x) {
                        sim.config.routeTimeScale = Double(x)
                    }
                }
            }
            Text("Covers the route quicker. The speed the app sees stays the same.")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
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
                    NeonButton(title: "DRIVE", icon: "play.fill", tint: Theme.green, prominent: sim.hasRoute) { sim.startRouteDrive() }
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
                        Text(f).font(.system(size: 11, weight: .bold, design: .monospaced))
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

// The right-hand inspector. Four tabs, one per job a tester actually has: watch the link, replay
// the offline backlog, send bad data, set the rig up once.
//
// This replaced a single card that stacked SIGNAL, ESP32, TEST SETUP, RAW EFFECTS and STORED DUMP
// inside a nested ScrollView. Eighteen controls in a card about nine tall: the stored-dump button
// and the packet-effect sliders were below the fold, inside a card that looked finished, so the
// only way to find them was to scroll a view nobody could tell was scrollable.
struct NetworkPanel: View {
    @EnvironmentObject var sim: SimController
    @State private var showSignalInfo = false

    var body: some View {
        Card(title: "CONNECTION", icon: "antenna.radiowaves.left.and.right", tint: Theme.blue) {
            VStack(alignment: .leading, spacing: 11) {
                // Link state stays put across every tab — it is the one thing you must be able to
                // see while you are doing something else (dumping, arming a fault, editing the odo).
                liveStatusRow

                Picker("", selection: $sim.inspectorTab) {
                    ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)

                switch sim.inspectorTab {
                case .signal: signalTab
                case .stored: storedTab
                case .faults: FaultPanel(embedded: true)
                case .setup:  setupTab
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Always-visible link state

    private var liveStatusRow: some View {
        HStack(spacing: 8) {
            // Shape as well as colour: red/amber/green alone fails for colour-blind testers.
            Image(systemName: sim.linkDown ? "wifi.slash" : "wifi")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(signalTint)
            Text(signalState).font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(1).foregroundStyle(signalTint)
            Spacer()
            if sim.linkDown {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(outageCountdown).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.amber)
                }
            }
            Button { showSignalInfo.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain).hoverGlow()
            .padding(4).contentShape(Rectangle())      // desktop click targets want >= 24pt
            .popover(isPresented: $showSignalInfo, arrowEdge: .bottom) {
                Text("AUTO continuously sweeps the signal on its own (full ↔ weak ↔ poor) and every few minutes drops fully out of range to mimic a dead zone (tunnel / rural gap) — the app disconnects and auto-reconnects, just like a real drive. It's the default. FULL / POOR set link strength manually (lower = more latency, still connected — real BLE never drops packets on weak signal). DROP forces an immediate disconnect now, then re-advertises after the Back-in-range timer, or press BACK, so the app reconnects.")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.text)
                    .frame(width: 280).fixedSize(horizontal: false, vertical: true).padding(16).background(Theme.bg1)
            }
        }
    }

    // MARK: - Signal

    private var signalTab: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                signalPreset("FULL", 100)
                NeonButton(title: "AUTO", tint: Theme.ice, filled: sim.autoSignal) { sim.setAutoSignal(!sim.autoSignal) }
                signalPreset("POOR", 25)
                NeonButton(title: sim.linkDown ? "BACK" : "DROP", icon: sim.linkDown ? "wifi" : "wifi.slash",
                           tint: Theme.red, filled: sim.linkDown) {
                    if sim.linkDown { sim.resumeLink() } else { sim.autoSignal = false; sim.forceDisconnect(seconds: sim.config.rangeOutageSec) }
                }
            }
            // RSSI only in ESP32 mode — see rssiSlider for why the label follows the transport.
            rssiSlider
            cfgSlider("Back in range after", \.rangeOutageSec, 15...180, "s", 0)
            NeonButton(title: "〰 KEEP DROPPING IN AND OUT", tint: Theme.amber, filled: sim.flickerOn) {
                sim.setFlicker(!sim.flickerOn)
            }
            Text("Puts the phone right at the edge of range, so it keeps losing the tracker and finding it again.")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Stored

    private var storedTab: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("When the phone is not connected, the tracker keeps saving data on its own. It hands the whole lot over the next time the phone connects (the app asks with readstr).")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            cfgSlider("Save one every", \.storedRecordIntervalSec, 0.5...60, "m", 1, scale: 60)

            Divider().overlay(Theme.stroke)

            Text("Send saved data now").sectionLabel()
            countSlider
            cfgSlider("Gap between them", \.storedDumpCadenceSec, 0.25...1.5, "s", 2)
            NeonButton(title: isDumping ? "SENDING…" : "SEND SAVED DATA",
                       icon: "tray.and.arrow.down.fill", tint: Theme.blue,
                       filled: isDumping, prominent: true) {
                sim.dumpStoredPackets(count: sim.config.storedDumpCount, cadenceSec: sim.config.storedDumpCadenceSec)
            }
            Text("A small gap can make the phone disconnect — that is the bug this reproduces. 1 second is safe.")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
        }
    }

    // MARK: - Setup (set once, then left alone)

    private var setupTab: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("ESP32 radio").sectionLabel()
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { sim.config.serialPortName }, set: { sim.config.serialPortName = $0 })) {
                    Text("Select port…").tag("")
                    ForEach(sim.availableSerialPorts, id: \.self) { p in
                        Text(portShort(p)).tag(p)
                    }
                }
                .labelsHidden().pickerStyle(.menu).tint(Theme.ice)
                NeonButton(title: "LINK", tint: Theme.ice, filled: sim.config.link == .esp32Serial) {
                    sim.switchTransport(sim.config.link == .esp32Serial ? .ble : .esp32Serial)
                }
                Text(sim.config.link == .esp32Serial ? "\(sim.config.txPowerDbm >= 0 ? "+" : "")\(sim.config.txPowerDbm) dBm" : "n/a (BLE)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ice).fixedSize()
            }

            Divider().overlay(Theme.stroke)

            setupFields

            Divider().overlay(Theme.stroke)

            Text("Message problems").sectionLabel()
            cfgSlider("Send duplicates", \.duplicatePct, 0...50, "%", 0)
            cfgSlider("Send out of order", \.outOfOrderPct, 0...50, "%", 0)
            cfgSlider("Send one message every", \.packetIntervalSec, 0.25...3, "s", 2)
        }
    }
    private var isDumping: Bool { sim.runningDump?.hasPrefix("Stored dump") == true }

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

    // Short tty name for the picker menu (drop the "/dev/cu." prefix so it fits).
    private func portShort(_ path: String) -> String {
        path.replacingOccurrences(of: "/dev/cu.", with: "").replacingOccurrences(of: "/dev/", with: "")
    }

    // RSSI = emulated signal %, which in ESP32 mode drives the board's real BLE TX power.
    /// In ESP32 mode this really is RSSI — it drives the board's BLE TX power, so the phone reads a
    /// different dBm. In BLE mode there is no TX-power API, so the same slider only shapes the emulated
    /// link (latency, and out-of-range at 0). Labelling it "RSSI" there would promise something the
    /// laptop cannot do, so the label follows the transport.
    private var rssiSlider: some View {
        HStack(spacing: 8) {
            Text(sim.config.link == .esp32Serial ? "RSSI" : "Signal")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim).frame(width: 56, alignment: .leading)
            Slider(value: Binding(get: { sim.config.signalPct }, set: { sim.autoSignal = false; sim.setSignal($0) }), in: 0...100).tint(Theme.ice)
            Text("\(Int(sim.config.signalPct.rounded()))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ice).frame(width: 42, alignment: .trailing)
        }
    }

    /// Editable odometer / engine hours: dial the truck to a starting state instead of driving to it.
    /// Both are forward-only while the app is connected — see TrackerPeripheral.setOdometer.
    private var setupFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Starting numbers").sectionLabel()
            numberField("Odometer", value: sim.odometerMiles, unit: "mi", dec: 1) { sim.setOdometer($0) }
            numberField("Engine hours", value: sim.engineHours, unit: "h", dec: 2) { sim.setEngineHours($0) }
            // Must track the same flag the setter gates on (`connected`), or the caption promises
            // "any value" during a watchdog lapse while the app is still attached.
            Text(sim.connected ? "forward only while the app is connected" : "any value — no app connected")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(sim.connected ? Theme.amber : Theme.dim)
        }
    }

    private func numberField(_ label: String, value: Double, unit: String, dec: Int,
                             commit: @escaping (Double) -> Void) -> some View {
        NumberEntry(label: label, value: value, unit: unit, dec: dec, commit: commit)
    }

    /// Same default-visible treatment as cfgSlider — see its doc comment for why it matters.
    private var countSlider: some View {
        let value = sim.config.storedDumpCount
        let fallback = SimConfig.default.storedDumpCount
        let changed = value != fallback
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text("How many records").font(.system(size: 11, design: .rounded))
                    .foregroundStyle(changed ? Theme.amber : Theme.dim)
                    .lineLimit(1).fixedSize()
                Slider(value: Binding(get: { Double(sim.config.storedDumpCount) }, set: { sim.config.storedDumpCount = Int($0) }), in: 0...300)
                    .tint(changed ? Theme.amber : Theme.ice)
                    .frame(minWidth: 60).layoutPriority(1)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(value)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(changed ? Theme.amber : Theme.ice)
                    Text("def \(fallback)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                }.fixedSize()
            }
            if changed {
                Button {
                    sim.config.storedDumpCount = fallback
                    sim.info("How many records back to the default \(fallback)")
                } label: {
                    Text("↺ back to default \(fallback)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.amber)
                }
                // Desktop click targets want >= 24pt; the bare label was about 12pt tall.
                .buttonStyle(.plain)
                .padding(.vertical, 5).contentShape(Rectangle())
                .padding(.leading, 64)
            }
        }
    }

    /// A tunable slider that always shows what the DEFAULT was and offers one click back to it.
    ///
    /// Without this a drawer full of sliders is unreadable after the first session: you cannot tell a
    /// deliberate setting from something you dragged days ago, and a stale value silently changes
    /// what every later test means. The default comes from `SimConfig.default`, so it can never
    /// drift out of step with the real one.
    /// `scale` divides the stored value for display — the record interval lives in seconds but reads
    /// far better as minutes ("30m" rather than "1800s").
    private func cfgSlider(_ label: String, _ kp: WritableKeyPath<SimConfig, Double>,
                           _ range: ClosedRange<Double>, _ unit: String, _ dec: Int,
                           scale: Double = 1) -> some View {
        let value = sim.config[keyPath: kp] / scale
        let fallback = SimConfig.default[keyPath: kp] / scale
        let changed = abs(value - fallback) > 0.0001
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 11, design: .rounded))
                    .foregroundStyle(changed ? Theme.amber : Theme.dim)
                    .lineLimit(1).fixedSize()
                Slider(value: Binding(get: { sim.config[keyPath: kp] / scale },
                                      set: { sim.config[keyPath: kp] = $0 * scale }), in: range)
                    .tint(changed ? Theme.amber : Theme.ice)
                    .frame(minWidth: 60).layoutPriority(1)
                // Value over default, right-aligned: the value stays where the eye already looks and
                // the default sits directly beneath it for comparison, instead of crowding the label.
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(String(format: "%.\(dec)f", value))\(unit)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(changed ? Theme.amber : Theme.ice)
                    Text("def \(String(format: "%.\(dec)f", fallback))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                }.fixedSize()
            }
            // ALWAYS visible, not just once it differs: you need to know what normal looks like
            // BEFORE touching anything, otherwise every slider reads as "probably fine".
            if changed {
                Button {
                    sim.config[keyPath: kp] = fallback * scale
                    sim.info("\(label) back to the default \(String(format: "%.\(dec)f", fallback))\(unit)")
                } label: {
                    Text("↺ back to default \(String(format: "%.\(dec)f", fallback))\(unit)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Theme.amber)
                }
                // Desktop click targets want >= 24pt; the bare label was about 12pt tall.
                .buttonStyle(.plain)
                .padding(.vertical, 5).contentShape(Rectangle())
                .padding(.leading, 64)
            }
        }
    }
}

struct PacketConsole: View {
    @EnvironmentObject var sim: SimController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Live messages").sectionLabel()
                Spacer()
                Text("\(sim.log.count) lines").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
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

// MARK: - Fault injection panel
//
// Deliberately grouped by WHAT THE TESTER WILL SEE ON THE PHONE, not by protocol field. Four of the
// faults people ask for are silently ignored by the ELD app; hiding that would have testers demoing
// a button and waiting for an alert that cannot come. So the sections are labelled by outcome and
// the ignored ones are collapsed by default — present, but never mistaken for a warning.
struct FaultPanel: View {
    /// `true` when shown as a tab inside the inspector Card, which already draws the chrome and
    /// constrains the height — so drop the standalone popover's own frame and let it fill the tab.
    var embedded = false
    @EnvironmentObject var sim: SimController
    @State private var showIgnored = false
    @State private var customVin = "00000000000000000"
    @State private var macCase: MACCase = .blank

    /// The device-ID cases worth testing, named by what SHOULD HAPPEN rather than by their bytes.
    enum MACCase: String, CaseIterable, Identifiable {
        case good, filler, lower, tooShort, blank, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .good:     return "Correct ID — phone should accept"
            case .filler:   return "Short ID with filler — phone should reject"
            case .lower:    return "Small letters — phone should reject"
            case .tooShort: return "Too short — phone should reject"
            case .blank:    return "Blank — phone should reject"
            case .custom:   return "My own value"
            }
        }
        /// `nil` for `.custom`, which keeps whatever is typed in the box.
        var value: String? {
            switch self {
            case .good:     return "87CB6819AFFF"
            case .filler:   return "87CB6819A\u{FF}\u{FF}\u{FF}"   // 9 hex + three 0xFF filler bytes
            case .lower:    return "87cb6819afff"
            case .tooShort: return "87CB6819A"
            case .blank:    return ""
            case .custom:   return nil
            }
        }
        var help: String {
            switch self {
            case .good:     return "A normal device ID. The phone should connect with no complaint."
            case .filler:   return "The real tracker case: the ID is 9 characters and the rest is filler. The phone should refuse it."
            case .lower:    return "Right characters, wrong case. The phone only accepts capitals, so it should refuse it."
            case .tooShort: return "Only 9 characters. The phone needs exactly 12, so it should refuse it."
            case .blank:    return "No ID at all. This is what the simulator sends by default."
            case .custom:   return "Type any value in the box above to try it."
            }
        }
    }

    private var armedSummary: String {
        var parts = sim.activeFaults.map { "\($0.name) = \($0.value)" }
        if sim.config.timeSkewSec != 0 { parts.insert("clock \(sim.config.timeSkewSec > 0 ? "+" : "")\(Int(sim.config.timeSkewSec / 60)) min", at: 0) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        // Reading faultRevision is what ties this view to arm/clear events — see its doc comment.
        let _ = sim.faultRevision
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !embedded { header }      // the tab shows the arm state in its own summary row
                if embedded { embeddedHeader } else { EmptyView() }
                legend
                warns
                Divider().overlay(Theme.stroke)
                macSection
                Divider().overlay(Theme.stroke)
                noWarning
                Divider().overlay(Theme.stroke)
                ignoredSection
            }
            .padding(.trailing, embedded ? 4 : 0)   // breathing room beside the scroll indicator
        }
        .frame(maxHeight: embedded ? .infinity : 560)
    }

    /// Inside the inspector the Card title and the live link row are already overhead, so the tab
    /// leads with the only thing that changes — whether the wire is clean — plus the way back to it.
    private var embeddedHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sim.faultsArmed ? "SENDING BAD DATA ON PURPOSE: \(armedSummary)" : "Nothing bad is being sent — the phone is getting good data.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(sim.faultsArmed ? Theme.red : Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if sim.faultsArmed {
                NeonButton(title: "Stop sending bad data", tint: Theme.red, filled: true) { sim.clearAllFaults() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                Text("SEND BAD DATA ON PURPOSE")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            }
            Text(sim.faultsArmed ? "SENDING BAD DATA ON PURPOSE: \(armedSummary)" : "Nothing bad is being sent — the phone is getting good data.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(sim.faultsArmed ? Theme.red : Theme.dim)
            NeonButton(title: "RESET TO CLEAN DATA", tint: Theme.red, filled: sim.faultsArmed) {
                sim.clearAllFaults()
            }
        }
    }

    private var legend: some View {
        Text("⚠ phone warns     ◐ bad data, no warning     ∅ phone ignores it")
            .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
    }

    // Ordered fastest-to-fire first, so a demo runs straight down the list.
    private var warns: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("⚠ The phone shows a warning").sectionLabel()

            faultToggle(title: "Engine computer stops answering", on: sim.activeFaults.contains { $0.field == 12 },
                        subtitle: "Tells the phone the engine computer stopped answering while the key is on.",
                        look: "Phone: Data Diagnostic 2 within about 3 seconds.") {
                sim.setWireOverride(field: 12, value: sim.activeFaults.contains { $0.field == 12 } ? nil : "0")
            }

            faultToggle(title: "Clock is 30 minutes wrong", on: sim.config.timeSkewSec != 0,
                        subtitle: "Stamps every packet with a time that is wrong by half an hour.",
                        look: "Phone: red bar reading Malfunction(T) after about 20 seconds. One good packet clears it.") {
                sim.config.timeSkewSec = sim.config.timeSkewSec == 0 ? 1800 : 0
            }

            faultToggle(title: "No odometer or engine hours", on: sim.activeFaults.contains { $0.field == 4 && $0.value == "0" },
                        subtitle: "Sends odometer 0 and engine hours 0, like a tracker with no ECU data.",
                        look: "Phone: change duty status while this is on → Data Diagnostic 3. Nothing happens until you change status.") {
                let armed = sim.activeFaults.contains { $0.field == 4 && $0.value == "0" }
                sim.setWireOverride(field: 4, value: armed ? nil : "0")
                sim.setWireOverride(field: 5, value: armed ? nil : "0")
            }

            faultToggle(title: "GPS drops out now and then, only while moving",
                        on: sim.activeFaults.contains { $0.field == 8 },
                        subtitle: "Randomly drops the GPS fix on about a fifth of packets, and only above 5 mph.",
                        look: "Phone: nothing quickly. The app's positioning check never fires — see the audit doc.") {
                sim.setWireOverride(field: 8, value: sim.activeFaults.contains { $0.field == 8 } ? nil : "0",
                                    probability: 0.2, requiresMotion: true)
            }
        }
    }

    private var noWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("◐ Wrong data, but no warning").sectionLabel()

            faultButton(title: "Odometer jumps up by 58,000 miles",
                        subtitle: "One jump to a different ECU odometer series.",
                        look: "Phone: Logs → today → the Driving event's odometer jumps and stays. No warning at all.") {
                sim.setWireOverride(field: 4, value: "5000000")
            }

            faultToggle(title: "Odometer stops moving", on: sim.activeFaults.contains { $0.field == 4 && $0.value == SimConfig.odometerUnavailableSentinel },
                        subtitle: "Sends the tracker's \"odometer not available\" value.",
                        look: "Phone: keeps showing the LAST odometer as if it were live. Nothing changes on screen — that is the finding.") {
                let armed = sim.activeFaults.contains { $0.field == 4 && $0.value == SimConfig.odometerUnavailableSentinel }
                sim.setWireOverride(field: 4, value: armed ? nil : SimConfig.odometerUnavailableSentinel)
            }

            faultToggle(title: "Two different odometer readings", on: sim.odoAlternating,
                        subtitle: "The ECU reports two different odometers about 3,700 miles apart, flipping every packet.",
                        look: "Phone: Help → Bluetooth → BLE Values, the odometer visibly flips. No warning — this is the finding.") {
                sim.setOdoAlternating(!sim.odoAlternating)
            }

            faultToggle(title: "Wrong time now and then",
                        on: sim.activeFaults.contains { $0.field == 10 },
                        subtitle: "Scatters an impossible time through the stream instead of corrupting every packet.",
                        look: "Phone: intermittent, so watch the event list rather than expecting a banner.") {
                sim.setWireOverride(field: 10, value: sim.activeFaults.contains { $0.field == 10 } ? nil : "999999",
                                    probability: 0.2)
            }

            faultToggle(title: "Odometer goes missing now and then",
                        on: sim.activeFaults.contains { $0.field == 4 && $0.value == SimConfig.odometerUnavailableSentinel && $0.probability < 1 },
                        subtitle: "Scatters the tracker's \"odometer not available\" value through the stream.",
                        look: "Phone: nothing live. Only a stored dump carries it into the FMCSA file.") {
                let armed = sim.activeFaults.contains { $0.field == 4 && $0.probability < 1 }
                sim.setWireOverride(field: 4, value: armed ? nil : SimConfig.odometerUnavailableSentinel,
                                    probability: 0.2)
            }

            faultButton(title: "Truck powers on and off 10 times",
                        subtitle: "Ten power-up/shutdown pairs, two per second.",
                        look: "Phone: speaks \"Vehicle Power up\" each time and re-shows the popups. It never raises Power Compliance — no code in the app can.") {
                sim.powerCycleBurst()
            }
        }
    }

    private var ignoredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { showIgnored.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showIgnored ? "chevron.down" : "chevron.right").font(.system(size: 10))
                    Text("∅ Show the ones the phone ignores").font(.system(size: 11, weight: .bold, design: .rounded))
                }.foregroundStyle(Theme.dim)
            }.buttonStyle(.plain)

            if showIgnored {
                Text("The phone does nothing at all with these. Send them to PROVE it ignores them — do not wait for a warning.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)

                HStack(spacing: 6) {
                    TextField("VIN", text: $customVin)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                    NeonButton(title: "Send this VIN", tint: Theme.dim, filled: false) {
                        sim.vin = customVin
                        sim.sendVINNow()
                    }
                }
                Text("All zeros and a 6-character VIN behave identically. Only visible in Troubleshoot → Run Diagnostic Check.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)

                HStack(spacing: 6) {
                    NeonButton(title: "ALL ZEROS", tint: Theme.dim, filled: false) { customVin = "00000000000000000" }
                    NeonButton(title: "LAST 6 ONLY", tint: Theme.dim, filled: false) { customVin = "292058" }
                }


                faultToggle(title: "Wrong date now and then",
                            on: sim.activeFaults.contains { $0.field == 11 },
                            subtitle: "A tracker that lost its clock reports 01-01-00.",
                            look: "Phone: nothing. Both the MT and PT parsers rewrite the packet date to phone time.") {
                    sim.setWireOverride(field: 11, value: sim.activeFaults.contains { $0.field == 11 } ? nil : "010100",
                                        probability: 0.2)
                }

                faultButton(title: "Saved data dated in the future (2030)",
                            subtitle: "Dumps stored packets all stamped 1 Jan 2030.",
                            look: "Phone: each one should be SKIPPED, not recorded. Check Troubleshoot → support dump; the audit rows read \"Stored packet skipped: packet time ... is N days from now\".") {
                    sim.dumpStoredPackets(count: 5, cadenceSec: 1.0,
                                          options: .init(stampedAt: SimConfig.futureStoredPacketDate),
                                          label: "Stored dump · future dated")
                }

                faultButton(title: "Same saved data sent twice",
                            subtitle: "Each stored packet sent twice, back to back, in one dump.",
                            look: "Phone: the second copy of each pair should be dropped — it only compares against the packet immediately before it.") {
                    sim.dumpStoredPackets(count: 5, cadenceSec: 1.0,
                                          options: .init(repeatEachPacket: true),
                                          label: "Stored dump · duplicated")
                }

                faultButton(title: "Send the same saved data again after reconnect",
                            subtitle: "Sends the previous dump again, byte for byte. Disconnect and reconnect first.",
                            look: "Phone: whether it de-dups across a connection. Run a dump, drop the link, reconnect, then press this.") {
                    sim.repeatLastStoredDump(cadenceSec: 1.0)
                }

                faultButton(title: "Send one broken message",
                            subtitle: "One packet that is not valid at all.",
                            look: "Phone: should reject it and carry on. A crash or a stalled stream is the bug.") {
                    sim.sendMalformedPacket()
                }

                faultButton(title: "Change where the odometer comes from",
                            subtitle: "The xO packet that tells the app the odometer source changed.",
                            look: "Phone: nothing at all. It parses this into a variable with no readers and posts a notification with no observers.") {
                    sim.sendOdoSourcePacket(virtual: true)
                }
            }
        }
    }

    /// Device MAC — field 8 of the LV packet, which the app validates with `^[0-9A-F]{12}$`
    /// (check added app-side 2026-10-29).
    ///
    /// Written for someone who does not know what a MAC is. The first version of this was five
    /// buttons reading 0xFF PAD / lowercase / SHORT / EMPTY / VALID — every one of them described
    /// the BYTES rather than the test, so you had to already know the answer to pick the right one.
    /// Now it is one plain-English list that names the expected outcome, a field you can actually
    /// see, and one button.
    private var macSection: some View {
        let ok = SimController.macPassesAppCheck(sim.deviceMAC)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Device ID sent to the phone").sectionLabel()

            Picker("", selection: $macCase) {
                ForEach(MACCase.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).tint(Theme.ice)
            .onChange(of: macCase) { newCase in
                if let v = newCase.value { sim.deviceMAC = v }
            }

            // A real, visible box — the old one was borderless, so an empty MAC looked like no
            // control at all until you happened to click where the text would have been.
            HStack(spacing: 8) {
                TextField("", text: $sim.deviceMAC)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                    .overlay(alignment: .leading) {
                        if sim.deviceMAC.isEmpty {
                            Text("(blank — nothing is sent)")
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.dim)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: sim.deviceMAC) { _ in macCase = .custom }
                Text(ok ? "phone accepts" : "phone rejects")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(ok ? Theme.green : Theme.amber).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bg0.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.stroke, lineWidth: 1))

            NeonButton(title: "SEND TO PHONE NOW", icon: "arrow.up.circle.fill",
                       tint: Theme.blue, prominent: true) { sim.sendMACNow() }

            Text(macCase.help)
                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text("The phone reads this when it connects, so pick it BEFORE connecting. Use the button if the phone is already connected.")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Row builders

    private func faultToggle(title: String, on: Bool, subtitle: String, look: String,
                             action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            NeonButton(title: on ? "\(title)  ● ON" : title, tint: on ? Theme.red : Theme.ice, filled: on, action: action)
            Text(subtitle).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.text.opacity(0.75))
            Text(look).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
        }
    }

    private func faultButton(title: String, subtitle: String, look: String,
                             action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            NeonButton(title: title, tint: Theme.amber, filled: false, action: action)
            Text(subtitle).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.text.opacity(0.75))
            Text(look).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
        }
    }
}
