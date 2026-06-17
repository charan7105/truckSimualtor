import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sim: SimController

    var body: some View {
        ZStack {
            DashboardBackground()
            clusterFace
            if sim.phase != .live {
                IgnitionView().transition(.opacity).zIndex(30)
            }
        }
        .frame(minWidth: 1500, minHeight: 1010)
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
                DiagnosticsPanel().frame(width: 320)
                NetworkPanel().frame(width: 300)
                PacketConsole()
            }
            .frame(height: 210)
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
