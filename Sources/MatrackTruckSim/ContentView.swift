import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sim: SimController

    // The cockpit is laid out at a fixed laptop-friendly aspect (≈16:10) and scaled to FIT the window in
    // BOTH dimensions — so it fills a MacBook screen edge-to-edge, grows on external displays, and NEVER
    // clips. The content is compacted to fit this height at ~full size (no heavy shrink). Wider-than-16:10
    // screens (16:9 / ultrawide) get slim, balanced side margins rather than stretched panels.
    private let designSize = CGSize(width: 1800, height: 1120)
    @State private var showDTC = false      // diagnostics live behind a footer menu (low priority right now)
    @State private var showScenario = false // scenarios are a testing tool → tucked behind a footer button, like DTC
    @ObservedObject private var bridge = SimBridge.shared   // LAN link the Fuel App follows

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / designSize.width, geo.size.height / designSize.height)
            ZStack {
                DashboardBackground()            // fills the actual window (unscaled)
                face
                    .frame(width: designSize.width, height: designSize.height)   // lay out at design size
                    .scaleEffect(scale, anchor: .center)                         // fit to the window (grows or shrinks), never clips
                    .frame(width: geo.size.width, height: geo.size.height)       // constrain footprint to the window → centers
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        // maxWidth/Height .infinity makes the GeometryReader report the ACTUAL window size (not the ideal),
        // so the fit math uses real dimensions; idealWidth/Height just sets the default open size.
        .frame(minWidth: 1000, idealWidth: 1560, maxWidth: .infinity,
               minHeight: 660, idealHeight: 980, maxHeight: .infinity)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let renderer = ImageRenderer(content: HaulLogo(size: 256))
            renderer.scale = 2
            if let icon = renderer.nsImage { NSApp.applicationIconImage = icon }
            sim.startBLE()
            if ProcessInfo.processInfo.arguments.contains("dash") {
                sim.skipStartup()                    // jump straight to the live dashboard (static, for screenshots)
            }
            if ProcessInfo.processInfo.arguments.contains("demo") {
                Task { @MainActor in
                    sim.beginStartup()
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await sim.loadRandomRoute()
                    sim.startRouteDrive()
                }
            }
        }
    }

    /// The cluster face + the ignition overlay, laid out at the design size.
    @ViewBuilder
    private var face: some View {
        ZStack {
            clusterFace
            if sim.phase != .live {
                IgnitionView().transition(.opacity).zIndex(30)
            }
            if let g = sim.guidedScenario {
                ZStack {
                    Color.black.opacity(0.58).ignoresSafeArea()
                        .onTapGesture { sim.cancelGuided() }       // tap the dimmed backdrop to dismiss
                    GuidedStepView(scenario: g, step: sim.guidedStep,
                                   onAdvance: { sim.advanceGuided() },
                                   onCancel: { sim.cancelGuided() })
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 44, y: 22)
                }
                .zIndex(60)
            }
        }
        .onChange(of: sim.guidedScenario != nil) { open in if open { showScenario = false; showDTC = false } }
    }

    private var clusterFace: some View {
        let live = sim.phase == .live
        return VStack(spacing: 16) {
            TopRail().panelReveal(live, delay: 0.0)

            HStack(alignment: .top, spacing: 20) {
                // LEFT (controls lane): big speed dial → route → drive.
                VStack(spacing: 14) {
                    SpeedGauge(speed: sim.speedMph, diameter: 286)
                        .padding(.bottom, -34)      // reclaim the empty bottom of the open dial so the gear sits closer
                    GearIndicator()
                    RoutePanel()                    // trip setup reads first, above the drive controls
                    DrivePanel()
                    Spacer(minLength: 0)
                }
                .frame(width: 392)
                .panelReveal(live, delay: 0.08)

                // CENTRE (hero lane): nav → map → telemetry → live packet stream (centre only)
                VStack(spacing: 14) {
                    NavStrip()
                    ClusterMap(sim: sim).frame(maxWidth: .infinity, maxHeight: .infinity)
                    TelemetryDock()
                    PacketConsole().frame(height: 184)
                }
                .frame(maxWidth: .infinity)
                .panelReveal(live, delay: 0.12)

                // RIGHT (status lane): matched tach dial → fuel → connection (fills to the bottom)
                VStack(spacing: 14) {
                    TachGauge(rpm: sim.rpm, diameter: 286)
                    fuelPanel
                    NetworkPanel().frame(maxHeight: .infinity)
                }
                .frame(width: 392)
                .panelReveal(live, delay: 0.16)
            }
            .frame(maxHeight: .infinity)

            footer.panelReveal(live, delay: 0.26)
        }
        .padding(20)
    }

    // FUEL — one panel: cylinder gauges on the left, level sliders on the right ("DUAL TANK").
    private var fuelPanel: some View {
        let t1 = sim.fuelPct < 20 ? Theme.red : Theme.green
        let t2 = sim.fuel2Pct < 20 ? Theme.red : Theme.blue
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "fuelpump.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.green)
                    .frame(width: 23, height: 23)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.green.opacity(0.14)))
                Text("FUEL").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(2).foregroundStyle(Theme.text.opacity(0.92))
                Spacer()
                Text("DUAL TANK").font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .tracking(1.5).foregroundStyle(Theme.dim)
            }
            HStack(spacing: 18) {
                FuelCylinder(value: sim.fuelPct, caption: "F1", tint: t1, width: 46, height: 104)
                FuelCylinder(value: sim.fuel2Pct, caption: "F2", tint: t2, width: 46, height: 104)
                VStack(spacing: 16) {
                    fuelSlider("FUEL 1", value: sim.fuelPct, set: { sim.setFuel($0) }, tint: t1)
                    fuelSlider("FUEL 2", value: sim.fuel2Pct, set: { sim.setFuel2($0) }, tint: t2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .glassPanel()
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.green.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 2).clipShape(Capsule()).padding(.horizontal, 12)
        }
    }

    private func fuelSlider(_ label: String, value: Double, set: @escaping (Double) -> Void, tint: Color) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(label).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(0.5).foregroundStyle(tint)
                Spacer()
                Text("\(Int(value))%").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
            }
            Slider(value: Binding(get: { value }, set: { set($0) }), in: 0...100).tint(tint)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12)).foregroundStyle(sim.statusColor)
            Text("Advertising as ELD-MA · \(sim.streaming ? "streaming" : "waiting for ELD app")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            if bridge.running {
                HStack(spacing: 5) {
                    Image(systemName: "fuelpump.fill").font(.system(size: 10)).foregroundStyle(Theme.green)
                    Text("FUEL LINK \(bridge.linkIP):\(String(bridge.port))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.green)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Theme.green.opacity(0.12)))
                .overlay(Capsule().stroke(Theme.green.opacity(0.4), lineWidth: 1))
                .help("On the phone's Fuel App → Link to sim → enter this address. Phone + this computer must share WiFi (or the phone's hotspot).")
            }
            Spacer()
            Button { showScenario.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "flag.checkered")
                    Text(sim.runningScenario == nil ? "SCENARIO" : "SCENARIO ▸ RUNNING").font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(sim.runningScenario == nil ? Theme.dim : Theme.amber)
            }
            .buttonStyle(.plain).hoverGlow()
            .popover(isPresented: $showScenario, arrowEdge: .bottom) {
                ScenarioPanel().frame(width: 380).padding(14).background(Theme.bg1)
            }
            Button { showDTC.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    Text(sim.faults.isEmpty ? "DTC" : "DTC (\(sim.faults.count))").font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(sim.faults.isEmpty ? Theme.dim : Theme.amber)
            }
            .buttonStyle(.plain).hoverGlow()
            .popover(isPresented: $showDTC, arrowEdge: .bottom) {
                DiagnosticsPanel().frame(width: 360).padding(14).background(Theme.bg1)
            }
            Button { sim.rearmStartup() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise"); Text("REPLAY IGNITION").font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Theme.dim)
            }.buttonStyle(.plain).hoverGlow()
        }
        .frame(height: 24)
    }
}
