import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sim: SimController
    @State private var drawerOpen = false

    var body: some View {
        ZStack {
            DashboardBackground()
            clusterFace

            if drawerOpen {
                Theme.glassScrim.ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { drawerOpen = false } }
                    .transition(.opacity).zIndex(15)
                HStack(spacing: 0) {
                    Spacer()
                    ControlsDrawer(open: $drawerOpen).frame(width: 420)
                }
                .transition(.move(edge: .trailing)).zIndex(16)
            }

            if sim.phase != .live {
                IgnitionView().transition(.opacity).zIndex(30)
            }
        }
        .frame(minWidth: 1440, minHeight: 900)
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

    // MARK: - Live cluster face

    private var clusterFace: some View {
        let live = sim.phase == .live
        return VStack(spacing: 14) {
            TopRail().panelReveal(live, delay: 0.00)
            NavStrip().panelReveal(live, delay: 0.05)

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 14) {
                    SpeedGauge(speed: sim.speedMph).panelReveal(live, delay: 0.10)
                    GearIndicator().panelReveal(live, delay: 0.16)
                    Spacer(minLength: 0)
                }
                .frame(width: 360)

                ClusterMap(sim: sim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .panelReveal(live, delay: 0.12)

                VStack(spacing: 14) {
                    TachGauge(rpm: sim.rpm).panelReveal(live, delay: 0.10)
                    miniArcs.panelReveal(live, delay: 0.18)
                    Spacer(minLength: 0)
                }
                .frame(width: 360)
            }
            .frame(maxHeight: .infinity)

            TelemetryDock().panelReveal(live, delay: 0.22)
            footer.panelReveal(live, delay: 0.28)
        }
        .padding(18)
    }

    private var miniArcs: some View {
        HStack(spacing: 24) {
            RingGauge(value: sim.fuelPct, caption: "FUEL", tint: sim.fuelPct < 20 ? Theme.red : Theme.green, diameter: 92)
            RingGauge(value: 64, caption: "DEF", tint: Theme.blue, diameter: 92)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .glassPanel()
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12)).foregroundStyle(sim.statusColor)
            Text(sim.log.last?.text ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer()
            Button { sim.rearmStartup() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.dim)
            }.buttonStyle(.plain).help("Replay ignition").hoverGlow()
            Button { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { drawerOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("FLIGHT DECK").font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Theme.ice)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(Theme.ice.opacity(0.12)))
                .overlay(Capsule().stroke(Theme.ice.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain).keyboardShortcut(".", modifiers: .command).hoverGlow()
        }
        .frame(height: 30)
    }
}
