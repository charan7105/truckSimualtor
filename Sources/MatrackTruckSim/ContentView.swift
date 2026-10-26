import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sim: SimController

    // The cockpit is laid out at a fixed laptop-friendly aspect (≈16:10) and scaled to FIT the window in
    // BOTH dimensions — so it fills a MacBook screen edge-to-edge, grows on external displays, and NEVER
    // clips. The content is compacted to fit this height at ~full size (no heavy shrink). Wider-than-16:10
    // screens (16:9 / ultrawide) get slim, balanced side margins rather than stretched panels.
    private let designSize = CGSize(width: 1800, height: 1120)
    /// User zoom on top of the fit-to-window scale. macOS has no Dynamic Type, so scaling the whole
    /// face under the operator's control is the only honest answer to "the text is too small" — at
    /// the old 1000pt minimum width the 10pt labels were rendering at 5.6pt. View ▸ Zoom In (⌘+).
    @AppStorage("uiZoom") private var uiZoom: Double = 1.0
    @State private var showDTC = false
    @State private var linkCopied = false   // brief ✓ feedback after tapping the FUEL LINK pill to copy the address
    @ObservedObject private var bridge = SimBridge.shared   // LAN link the Fuel App follows

    var body: some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / designSize.width, geo.size.height / designSize.height)
            let scale = fit * uiZoom
            let w = designSize.width * scale, h = designSize.height * scale
            ZStack {
                DashboardBackground()            // fills the actual window (unscaled)
                if uiZoom <= 1 {
                    // Unzoomed: fit and centre, exactly as before. No ScrollView in this path —
                    // inside one the face is measured at its pre-scale 1800x1120, so the window
                    // shows a crop of an oversized canvas instead of the whole fitted cockpit.
                    face
                        .frame(width: designSize.width, height: designSize.height)   // lay out at design size
                        .scaleEffect(scale, anchor: .center)                         // fit to the window, never clips
                        .frame(width: geo.size.width, height: geo.size.height)       // constrain footprint → centers
                } else {
                    // Zoomed past fit the face is bigger than the window, so it has to scroll —
                    // clipping it would silently cut off controls.
                    ScrollView([.horizontal, .vertical]) {
                        face
                            .frame(width: designSize.width, height: designSize.height)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: w, height: h)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        // maxWidth/Height .infinity makes the GeometryReader report the ACTUAL window size (not the ideal),
        // so the fit math uses real dimensions; idealWidth/Height just sets the default open size.
        // The minimum was 1000x660, which forced a 0.56 fit scale and rendered the smallest labels at
        // 5.6pt. 1280x820 holds the scale at 0.71 or better, so nothing drops under ~8pt unzoomed.
        .frame(minWidth: 1280, idealWidth: 1560, maxWidth: .infinity,
               minHeight: 820, idealHeight: 980, maxHeight: .infinity)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let renderer = ImageRenderer(content: HaulLogo(size: 256))
            renderer.scale = 2
            if let icon = renderer.nsImage { NSApp.applicationIconImage = icon }
            sim.startBLE()
            // Fuel-app link: point the LAN position feed at THIS instance — the one the window drives.
            // Wiring it in SimController.init can capture a non-driven copy (SwiftUI may build SimController()
            // more than once), which freezes /pos at the parked start; re-point it to the live sim here.
            SimBridge.shared.position = { [weak sim] in
                guard let sim else { return (0, 0, 0, 0, "") }
                return (sim.currentLat, sim.currentLon, sim.headingDeg, sim.speedMph,
                        sim.routeFrom.isEmpty ? "Free drive" : "\(sim.routeFrom) → \(sim.routeTo)")
            }
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
            if sim.showLowFuel {
                ZStack {
                    Color.black.opacity(0.62).ignoresSafeArea()
                        .onTapGesture { sim.dismissLowFuel() }       // tap the backdrop to dismiss
                    lowFuelCard
                        .shadow(color: .black.opacity(0.6), radius: 44, y: 22)
                }
                .zIndex(65)
            }
        }
    }

    // Low-fuel prompt: the drain is the hook that pushes the tester into the Matrack Fuel App, then lets
    // them "refuel at the station" (¼/½/¾/Full → both tanks). Also the way to un-stall an empty truck.
    private var lowFuelCard: some View {
        let empty = sim.fuelPct <= 0 && sim.fuel2Pct <= 0
        return VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: empty ? "fuelpump.slash.fill" : "fuelpump.fill")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.red)
                Text(empty ? "OUT OF FUEL" : "LOW FUEL · \(Int(sim.fuelPct))%")
                    .font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Spacer()
            }
            Text(empty
                 ? "The truck has stopped — both tanks are empty. Fill up to keep driving."
                 : "Fuel is running low. Time to find a station.")
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text.opacity(0.9))
            VStack(alignment: .leading, spacing: 7) {
                lowFuelStep("1", "Open the Matrack Fuel App on your phone.")
                lowFuelStep("2", "Don't have it? Get it from truck-simualtor.vercel.app.")
                lowFuelStep("3", "Link it to this simulator — you'll see your current location.")
                lowFuelStep("4", "Find a nearby station, then fill up:")
            }
            HStack(spacing: 9) {
                ForEach([("¼", 25.0), ("½", 50.0), ("¾", 75.0), ("Full", 100.0)], id: \.0) { label, pct in
                    Button { sim.refuel(toPct: pct) } label: {
                        Text(label).font(.system(size: 15, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.green.opacity(0.18)))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.green.opacity(0.5), lineWidth: 1))
                            .foregroundStyle(Theme.green)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Later") { sim.dismissLowFuel() }
                .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.dim).frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 452)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.red.opacity(0.5), lineWidth: 1))
    }

    private func lowFuelStep(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Theme.green)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.green.opacity(0.16)))
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text.opacity(0.85))
            Spacer(minLength: 0)
        }
    }

    private var clusterFace: some View {
        let live = sim.phase == .live
        return VStack(spacing: 16) {
            TopRail().panelReveal(live, delay: 0.0)
            NextStep().panelReveal(live, delay: 0.04)

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
            HStack(spacing: 7) {
                Image(systemName: "fuelpump.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
                Text("FUEL").cardTitle()
                Spacer()
                Text("Dual tank").sectionLabel()
            }
            HStack(spacing: 18) {
                FuelCylinder(value: sim.fuelPct, caption: "F1", tint: t1, width: 46, height: 104)
                FuelCylinder(value: sim.fuel2Pct, caption: "F2", tint: t2, width: 46, height: 104)
                VStack(spacing: 16) {
                    fuelSlider("Fuel 1", value: sim.fuelPct, set: { sim.setFuel($0) }, tint: t1)
                    fuelSlider("Fuel 2", value: sim.fuel2Pct, set: { sim.setFuel2($0) }, tint: t2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassPanel()
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
                // Tap the pill to copy just the IP — that's all the Fuel App needs (Link to sim → paste).
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bridge.linkIP, forType: .string)
                    linkCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { linkCopied = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "fuelpump.fill").font(.system(size: 10)).foregroundStyle(Theme.green)
                        Text("FUEL LINK \(bridge.linkIP)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.green)
                        Image(systemName: linkCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green.opacity(0.8))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.green.opacity(0.12)))
                    .overlay(Capsule().stroke(Theme.green.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Tap to copy the address, then paste it into the phone's Fuel App → Link to sim. Phone + this computer must share WiFi (or the phone's hotspot).")
            }
            Spacer()
            footerButton("DTC", sim.faults.isEmpty ? "DTC" : "DTC (\(sim.faults.count))",
                         icon: "wrench.and.screwdriver.fill",
                         tint: sim.faults.isEmpty ? Theme.dim : Theme.amber) { showDTC.toggle() }
                .popover(isPresented: $showDTC, arrowEdge: .bottom) {
                    DiagnosticsPanel().frame(width: 360).padding(14).background(Theme.bg1)
                }
            // Jumps to the inspector's Bad data tab rather than opening a popover copy of it.
            // Two live copies of the same panel meant a fault armed in one left the other showing
            // "wire is clean", and the popover hid the link state you need while faults are running.
            // faultRevision is read so the badge repaints the moment a fault is armed, not on the
            // next telemetry tick — see TrackerPeripheral.faultRevision.
            footerButton("BADDATA\(sim.faultRevision)",
                         sim.faultsArmed ? "BAD DATA ▸ SENDING" : "BAD DATA",
                         icon: "exclamationmark.triangle.fill",
                         tint: sim.faultsArmed ? Theme.red : Theme.dim) { sim.inspectorTab = .faults }
                .help("Opens the Bad data tab in the CONNECTION panel.")
            footerButton("REPLAY", "REPLAY IGNITION", icon: "arrow.clockwise", tint: Theme.dim) {
                sim.rearmStartup()
            }
        }
        .frame(height: 30)
    }

    /// Footer controls used to be bare 11pt text with no border and a ~14pt hit area — they did not
    /// read as buttons at all, and the desktop guidance is a >= 24pt target. Same chrome as every
    /// other control on the face, so they look clickable because they are.
    private func footerButton(_ id: String, _ title: String, icon: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverGlow().id(id)
    }
}
