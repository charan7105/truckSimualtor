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
        .frame(minWidth: 1480, minHeight: 940)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
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
        return VStack(spacing: 12) {
            TopRail().panelReveal(live, delay: 0.0)

            // Hero band: speed + drive | nav + map + telemetry | tach + route
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 12) {
                    SpeedGauge(speed: sim.speedMph, diameter: 270)
                    GearIndicator()
                    DrivePanel()
                    Spacer(minLength: 0)
                }
                .frame(width: 360)
                .panelReveal(live, delay: 0.08)

                VStack(spacing: 12) {
                    NavStrip()
                    ClusterMap(sim: sim).frame(maxWidth: .infinity, maxHeight: .infinity)
                    TelemetryDock()
                }
                .frame(maxWidth: .infinity)
                .panelReveal(live, delay: 0.12)

                VStack(spacing: 12) {
                    TachGauge(rpm: sim.rpm, diameter: 270)
                    miniArcs
                    RoutePanel()
                    Spacer(minLength: 0)
                }
                .frame(width: 360)
                .panelReveal(live, delay: 0.08)
            }
            .frame(maxHeight: .infinity)

            // Bottom band: scenario · diagnostics · network · live packet stream
            HStack(alignment: .top, spacing: 12) {
                ScenarioPanel().frame(width: 250)
                DiagnosticsPanel().frame(width: 300)
                NetworkPanel().frame(width: 280)
                PacketConsole()
            }
            .frame(height: 200)
            .panelReveal(live, delay: 0.2)

            footer.panelReveal(live, delay: 0.26)
        }
        .padding(16)
    }

    private var miniArcs: some View {
        HStack(spacing: 22) {
            RingGauge(value: sim.fuelPct, caption: "FUEL", tint: sim.fuelPct < 20 ? Theme.red : Theme.green, diameter: 76)
            RingGauge(value: 64, caption: "DEF", tint: Theme.blue, diameter: 76)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassPanel()
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
