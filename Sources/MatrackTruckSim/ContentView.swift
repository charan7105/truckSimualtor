import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sim: SimController

    // The cluster is designed at this size; on smaller windows the whole face scales down to fit
    // (looks identical, never clips). On larger windows it fills via its own flexible internals.
    private let designSize = CGSize(width: 1500, height: 1010)

    var body: some View {
        GeometryReader { geo in
            let scale = min(1.0, min(geo.size.width / designSize.width, geo.size.height / designSize.height))
            ZStack {
                DashboardBackground()            // fills the actual window (unscaled)
                face
                    .frame(width: designSize.width, height: designSize.height)   // lay out at design size
                    .scaleEffect(scale, anchor: .center)                         // shrink to fit smaller windows
                    .frame(width: geo.size.width, height: geo.size.height)       // constrain footprint to the window → centers, never clips
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        // maxWidth/Height .infinity makes the GeometryReader report the ACTUAL window size (not the ideal),
        // so the scale-to-fit math uses real dimensions; idealWidth/Height just sets the default open size.
        .frame(minWidth: 1000, idealWidth: 1500, maxWidth: .infinity,
               minHeight: 680, idealHeight: 1010, maxHeight: .infinity)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let renderer = ImageRenderer(content: HaulLogo(size: 256))
            renderer.scale = 2
            if let icon = renderer.nsImage { NSApp.applicationIconImage = icon }
            sim.startBLE()
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
        }
    }

    private var clusterFace: some View {
        let live = sim.phase == .live
        return VStack(spacing: 18) {
            TopRail().panelReveal(live, delay: 0.0)

            // Hero band: speed + drive | nav + map + telemetry | tach + route
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 16) {
                    SpeedGauge(speed: sim.speedMph, diameter: 300)
                    GearIndicator()
                    DrivePanel()
                    Spacer(minLength: 0)
                }
                .frame(width: 384)
                .panelReveal(live, delay: 0.08)

                VStack(spacing: 16) {
                    NavStrip()
                    ClusterMap(sim: sim).frame(maxWidth: .infinity, maxHeight: .infinity)
                    TelemetryDock()
                }
                .frame(maxWidth: .infinity)
                .panelReveal(live, delay: 0.12)

                VStack(spacing: 16) {
                    TachGauge(rpm: sim.rpm, diameter: 300)
                    miniArcs
                    RoutePanel()
                    Spacer(minLength: 0)
                }
                .frame(width: 384)
                .panelReveal(live, delay: 0.08)
            }
            .frame(maxHeight: .infinity)

            // Bottom band: scenario · diagnostics · network · live packet stream
            HStack(alignment: .top, spacing: 16) {
                ScenarioPanel().frame(width: 260)
                DiagnosticsPanel().frame(width: 300)
                NetworkPanel().frame(width: 344)
                PacketConsole()
            }
            .frame(height: 248)
            .panelReveal(live, delay: 0.2)

            footer.panelReveal(live, delay: 0.26)
        }
        .padding(22)
    }

    private var miniArcs: some View {
        VStack(spacing: 14) {
            HStack(spacing: 36) {
                FuelCylinder(value: sim.fuelPct, caption: "FUEL 1", tint: sim.fuelPct < 20 ? Theme.red : Theme.green)
                FuelCylinder(value: sim.fuel2Pct, caption: "FUEL 2", tint: sim.fuel2Pct < 20 ? Theme.red : Theme.blue)
            }
            fuelRow("FUEL 1", value: sim.fuelPct, set: { sim.setFuel($0) }, tint: sim.fuelPct < 20 ? Theme.red : Theme.green)
            fuelRow("FUEL 2", value: sim.fuel2Pct, set: { sim.setFuel2($0) }, tint: sim.fuel2Pct < 20 ? Theme.red : Theme.blue)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .glassPanel()
    }

    private func fuelRow(_ label: String, value: Double, set: @escaping (Double) -> Void, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1)
                .foregroundStyle(Theme.dim).frame(width: 46, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set($0) }), in: 0...100).tint(tint)
            Text("\(Int(value))%").font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint).frame(width: 36, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12)).foregroundStyle(sim.statusColor)
            Text("Advertising as ELD-MA · \(sim.streaming ? "streaming" : "waiting for ELD app")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer()
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
