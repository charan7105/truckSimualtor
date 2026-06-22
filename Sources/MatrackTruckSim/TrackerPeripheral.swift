import Foundation
import CoreBluetooth
import CoreLocation
import SwiftUI

// The simulator core: a BLE peripheral that impersonates a legacy Matrack "MT" tracker,
// exposed as an ObservableObject so the SwiftUI control panel can drive + observe it.

/// Power-on state machine for the cinematic ignition sequence.
enum ClusterPhase { case cold, igniting, sweep, settle, live }

struct LogLine: Identifiable {
    enum Kind { case out, inbound, info, drop }
    let id = UUID()
    let time: String
    let text: String
    let kind: Kind
}

final class SimController: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    // Connection / status
    @Published var status = "Starting…"
    @Published var statusColor = Theme.dim
    @Published var connected = false
    @Published var streaming = false
    @Published var linkDown = false                 // F1: emulated out-of-range (we go silent; the app times out)
    @Published var dropEndsAt: Date?                // F1: when the outage auto-recovers (for the UI countdown)
    @Published var phase: ClusterPhase = .cold      // ignition power-on state

    // Live telemetry (mirrored from EngineState each tick)
    @Published var ignitionOn = false
    @Published var autoDrive = false
    @Published var speedMph = 0.0
    @Published var rpm = 0
    @Published var odometerMiles = 25_000.0
    @Published var engineHours = 4_352.5
    @Published var fuelPct = 78.0
    @Published var fuel2Pct = 60.0
    @Published var satellites = 11
    @Published var headingDeg = 103
    @Published var ecmActive = true
    // Read directly by the map's render loop — deliberately NOT @Published so position updates
    // don't re-render the whole dashboard every tick (which starved the map and caused stutter).
    var currentLat = 37.78687
    var currentLon = -121.977687

    // Identity / diagnostics
    @Published var vin = "" { didSet { device.vin = vin } }   // editable; flows into the LV/VIN packet
    @Published var firmware = ""
    @Published var faults: [String] = []
    @Published var log: [LogLine] = []

    // Config (everything tunable)
    @Published var config = SimConfig.default

    // Route driving
    @Published var drivingRoute = false
    @Published var dayDriving = false               // F3: DRIVE MY DAY (distinct from a plain ROUTE drive)
    @Published var routeInfo = ""
    @Published var routeProgress = 0.0
    @Published var routeCoords: [CLLocationCoordinate2D] = []
    @Published var routeBusy = false
    @Published var routeFrom = ""
    @Published var routeTo = ""
    @Published var routeVersion = 0          // bumps only when a new route is loaded (drives map redraw)

    let route = RouteEngine()

    var advertisedName: String { config.advertisedName }

    private var manager: CBPeripheralManager!
    private var dataChar: CBMutableCharacteristic!
    private var commandChar: CBMutableCharacteristic!
    private let engine = EngineState()
    private var device = DeviceInfo()
    private var tick: Timer?
    private var pending: [Data] = []
    private var lastIgnitionSent: Bool?
    private var heldPacket: String?            // for out-of-order injection
    private var lastWatchdog = Date()          // app sends $wdg every ~20s; a real tracker stops streaming if it stops
    private let bootOdometerMiles = SimConfig.default.startOdometerMiles   // for trip distance
    private let uiTickSec = 0.2                // smooth sim/UI clock (decoupled from packet cadence)
    private var sinceLastPacket = 0.0
    private var autoSpeedCountdown = 0.0       // AUTO: seconds until the next random target-speed change
    private var dropTimer: Timer?             // F1: out-of-range outage timer
    private var nextViolationAtMeters = 0.0   // F3: distance-triggered violation scheduler
    private var violationHoldSec = 0.0        // F3: remaining seconds of the active violation
    private var violationIsIdle = false       // F3: alternate speeding ↔ idle

    override init() {
        super.init()
        applyConfigToEngine()
        vin = device.vin
        firmware = "\(device.mcuFW) · BLE \(device.bleFW)"
    }

    func startBLE() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // MARK: - Cluster-derived display helpers (computed from existing state)
    var ambientTempC: Int { 22 }
    var tripMiles: Double { max(0, odometerMiles - bootOdometerMiles) }
    var routeRemainingMeters: Double { max(0, route.totalMeters * (1 - routeProgress)) }
    var routeMilesLeft: Int { Int((route.totalMiles * (1 - routeProgress)).rounded()) }
    var hasRoute: Bool { routeCoords.count >= 2 }
    var gear: String { !ignitionOn ? "P" : (speedMph > 0.5 ? "D" : "N") }
    var cardinal: String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int(((Double(headingDeg) + 22.5) / 45).rounded(.down))
        return dirs[((i % 8) + 8) % 8]
    }
    /// Next-turn icon + signed bearing delta, from a look-ahead along the route.
    var nextTurn: (icon: String, deltaDeg: Int) {
        guard route.hasRoute else { return ("location.slash", 0) }
        let t = route.traveledMeters
        let h1 = route.positionAt(t).headingDeg
        let h2 = route.positionAt(min(route.totalMeters, t + 400)).headingDeg
        var d = h2 - h1
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        let icon: String
        if abs(d) > 150 { icon = "arrow.uturn.up" }
        else if d > 25 { icon = "arrow.turn.up.right" }
        else if d < -25 { icon = "arrow.turn.up.left" }
        else { icon = "arrow.up" }
        return (icon, d)
    }

    // MARK: - Ignition power-on sequence (visual only; BLE keeps running)
    func beginStartup() {
        guard phase == .cold else { return }
        setEngine(true)                                   // real telemetry spins up "under the curtain"
        withAnimation(.easeIn(duration: 0.3)) { phase = .igniting }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeOut(duration: 0.6)) { phase = .sweep }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.4)) { phase = .settle }
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.45)) { phase = .live }
        }
    }
    func skipStartup() { withAnimation(.easeOut(duration: 0.3)) { phase = .live } }
    func rearmStartup() { withAnimation(.easeIn(duration: 0.3)) { phase = .cold } }

    private func applyConfigToEngine() {
        engine.odometerMiles = config.startOdometerMiles
        engine.engineHours = config.startEngineHours
        engine.fuelLevelPct = config.startFuelPct
        engine.idleRpmConfig = config.idleRpm
        engine.rpmPerMphConfig = config.rpmPerMph
        engine.fuelBurnPctPerMile = config.fuelBurnPctPerMile
        mirror()
    }

    // MARK: - Manual controls
    func setEngine(_ on: Bool) {
        if runningScenario != nil { stopScenario() }
        autoDrive = false; drivingRoute = false; dayDriving = false
        engine.ignitionOn = on
        if !on { engine.speedMph = 0 }
        ensureClock(); mirror(); info("engine \(on ? "ON" : "OFF")")
    }

    func setSpeed(_ mph: Double) {
        if runningScenario != nil { stopScenario() }
        dayDriving = false                          // a manual speed set ends DRIVE MY DAY automation
        if drivingRoute {
            if mph <= 0 { stopRouteDrive(); return }    // STOP pauses (keeps position)
            autoDrive = false                           // manual speed override; keep driving
            config.targetSpeedMph = mph; ensureClock(); return
        }
        autoDrive = false
        if mph > 0 { engine.ignitionOn = true }
        engine.speedMph = mph
        ensureClock(); mirror()
    }

    /// AUTO = automatic (cruise) speed control. It does NOT reset position or load a new route —
    /// it takes over speed on the *current* drive and gradually settles to a cruising speed.
    func setAutoDrive(_ on: Bool) {
        if runningScenario != nil { stopScenario() }
        dayDriving = false                          // AUTO cruise takes over from DRIVE MY DAY automation
        autoDrive = on
        if on {
            engine.ignitionOn = true
            autoSpeedCountdown = 0                                  // pick a fresh auto speed immediately
            if route.hasRoute {
                if !drivingRoute { beginDrive() }                  // continue the current route, no reset
            } else if !routeBusy {                                 // no route yet → grab one (skip if a load is already in flight)
                Task { @MainActor in
                    await self.loadRandomRoute()
                    guard self.autoDrive, self.route.hasRoute else { return }
                    self.beginDrive()
                }
            }
            ensureClock()
        } else {
            config.targetSpeedMph = 65                              // restore a sane manual default after auto
        }
        mirror()
        info("auto speed \(on ? "on" : "off")")
    }
    func injectFault(_ code: String) { if !device.dtcCodes.contains(code) { device.dtcCodes.append(code) }; faults = device.dtcCodes; info("fault \(code) armed (app sees it on next readdtc)") }
    func clearFaults() { device.dtcCodes = []; faults = []; info("faults cleared") }
    func setFuel(_ pct: Double) { engine.fuelLevelPct = max(0, min(100, pct)); mirror() }
    func setFuel2(_ pct: Double) { engine.fuelLevel2Pct = max(0, min(100, pct)); mirror() }
    func sendVINNow() { sendReliable(MTPacket.version(device)) }

    // MARK: - F1: signal strength + out-of-range emulation
    /// Signal 100→0. Above 0 it ramps packet loss (weak signal); at 0 it goes out of range (drops the link).
    /// macOS has no TX-power API, so this is emulated: loss reuses the existing emitNow() gate, and
    /// "out of range" = going silent so the *app* times out (~75s) → disconnects → auto-reconnects.
    private var preDropSignalPct: Double = 100          // signal level to restore after a transient outage
    func setSignal(_ pct: Double) {
        config.signalPct = pct
        config.packetLossPct = max(0, 100 - pct)        // reuse the emitNow() loss gate
        if pct <= 0 { if !linkDown { dropLink(seconds: config.rangeOutageSec) } }   // idempotent: a slider drag to 0 arms once
        else if linkDown { resumeLink() }
    }

    /// EMULATED out-of-range: suppress telemetry for `seconds`. We never stop advertising (the app
    /// reconnects by scanning, so it must stay discoverable). After ~75s of silence the app disconnects
    /// and auto-reconnects on its own — exactly the real out-of-range round-trip.
    func dropLink(seconds: Double) {
        preDropSignalPct = config.signalPct >= 1 ? config.signalPct : 100   // remember weak level to restore on return
        linkDown = true
        config.signalPct = 0
        status = "OUT OF RANGE — silent \(Int(seconds))s"; statusColor = Theme.red
        info("📵 out of range: telemetry suppressed for \(Int(seconds))s (≥80s ⇒ app disconnect+reconnect; <75s ⇒ stall demo)")
        dropEndsAt = Date().addingTimeInterval(max(1, seconds))
        dropTimer?.invalidate()
        dropTimer = Timer.scheduledTimer(withTimeInterval: max(1, seconds), repeats: false) { [weak self] _ in self?.resumeLink() }
    }

    /// Back in range: resume telemetry. Restores the streaming status only if the app is still connected;
    /// if the silence already made the app disconnect, the next readdata re-arms streaming normally.
    func resumeLink() {
        dropTimer?.invalidate(); dropTimer = nil; dropEndsAt = nil
        linkDown = false
        if config.signalPct < 1 { config.signalPct = preDropSignalPct }    // restore the pre-drop weak level (or 100)
        config.packetLossPct = max(0, 100 - config.signalPct)
        info("📶 back in range — telemetry resumes")
        if connected && streaming { status = "Connected · streaming"; statusColor = Theme.green }
        else if connected { status = "iPhone connected"; statusColor = Theme.green }
    }

    // MARK: - Route driving (from → to)
    @MainActor
    func loadRoute(from: String, to: String) async {
        routeBusy = true; defer { routeBusy = false }
        do {
            let pts = try await Directions.route(from: from, to: to)
            route.setRoute(pts)
            routeCoords = pts
            drivingRoute = false            // freshly planned route returns to overview; press DRIVE to go
            routeVersion += 1
            routeInfo = "\(from) → \(to) · \(String(format: "%.0f", route.totalMiles)) mi"
            routeProgress = 0
            info("route loaded: \(routeInfo)")
        } catch {
            info("route error: \(error.localizedDescription)")    // keep prior route shown; surface error in log only
        }
    }

    /// Pick a random real city pair and load a drivable route between them.
    @MainActor
    func loadRandomRoute() async {
        let pairs: [(String, String)] = [
            ("Dallas, TX", "Houston, TX"),
            ("Los Angeles, CA", "San Diego, CA"),
            ("Chicago, IL", "Milwaukee, WI"),
            ("Phoenix, AZ", "Tucson, AZ"),
            ("Atlanta, GA", "Macon, GA"),
            ("Denver, CO", "Colorado Springs, CO"),
            ("Seattle, WA", "Portland, OR"),
            ("Miami, FL", "Orlando, FL"),
            ("New York, NY", "Philadelphia, PA"),
            ("San Francisco, CA", "Sacramento, CA"),
        ]
        let pick = pairs.randomElement() ?? ("Dallas, TX", "Houston, TX")
        routeFrom = pick.0; routeTo = pick.1
        await loadRoute(from: pick.0, to: pick.1)
    }

    func startRouteDrive() { beginDrive() }     // DRIVE ROUTE button

    /// Start/continue driving the loaded route from the current position (no reset), so toggling
    /// speed/auto/stop never teleports back to the start. Only a finished route restarts.
    private func beginDrive() {
        guard route.hasRoute else { info("load a route first"); return }
        if runningScenario != nil { stopScenario() }
        if route.progressFraction >= 0.999 { route.reset() }   // re-drive a finished route from the start
        drivingRoute = true
        engine.ignitionOn = true
        routeProgress = route.progressFraction
        let p = route.positionAt(route.traveledMeters)
        engine.latitude = p.coord.latitude; engine.longitude = p.coord.longitude; engine.headingDeg = p.headingDeg
        ensureClock()
        mirror()
        info("driving route…")
    }

    func stopRouteDrive() { drivingRoute = false; dayDriving = false; engine.speedMph = 0; mirror(); info("route drive stopped") }

    // MARK: - F3: DRIVE MY DAY (one-click full-day, state-crossing, with event violations)
    /// Curated long interstate pairs so the day crosses a state line (IFTA is per-jurisdiction mileage).
    private let dayRoutes: [(String, String)] = [
        ("Dallas, TX", "Oklahoma City, OK"),
        ("Atlanta, GA", "Nashville, TN"),
        ("Phoenix, AZ", "Las Vegas, NV"),
        ("Chicago, IL", "Indianapolis, IN"),
        ("Portland, OR", "Seattle, WA"),
        ("Kansas City, MO", "Omaha, NE"),
    ]

    /// One click: load a long state-crossing route and drive it end-to-end at 30×, with baked-in
    /// speeding + idle EVENT violations — a full day of IFTA per-jurisdiction mileage in ~10 min.
    /// HONEST LIMIT: the app's 11/14/70h HOS *hour* clocks run on real wall-clock and CANNOT be
    /// compressed — use 1× + a long route for genuine HOS exhaustion. This produces mileage + events.
    @MainActor
    func driveMyDay() async {
        let pick = dayRoutes.randomElement() ?? ("Dallas, TX", "Oklahoma City, OK")
        routeFrom = pick.0; routeTo = pick.1
        await loadRoute(from: pick.0, to: pick.1)
        guard route.hasRoute else { info("DRIVE MY DAY: route load failed (check network)"); return }
        config.routeTimeScale = 30
        autoDrive = false                                   // steady cruise → deterministic IFTA mileage
        config.targetSpeedMph = config.dayCruiseMph
        nextViolationAtMeters = config.violationEveryMiles / 0.000621371
        violationHoldSec = 0; violationIsIdle = false
        dayDriving = true
        beginDrive()
        info("▶ DRIVE MY DAY — \(pick.0) → \(pick.1) at 30× with auto speeding/idle events")
    }

    func stopDay() { dayDriving = false; stopRouteDrive() }

    /// F3 event scheduler — alternates a speeding spike and an idle stop every `violationEveryMiles`,
    /// distance-triggered so it fires identically at any timescale. Holds are real-time so the LP
    /// stream (sampled ~1/s) actually records each event.
    private func runDayViolations(dt: Double) {
        if violationHoldSec > 0 {
            violationHoldSec -= dt
            if violationHoldSec <= 0 { config.targetSpeedMph = config.dayCruiseMph }   // resume cruise
            return
        }
        guard route.traveledMeters >= nextViolationAtMeters else { return }
        let atMi = Int(route.totalMiles * route.progressFraction)
        if violationIsIdle {
            config.targetSpeedMph = 0; violationHoldSec = config.idleStopSec            // idle stop, ignition stays on
            info("⚠︎ DRIVE MY DAY: idle stop ~\(Int(config.idleStopSec))s at \(atMi) mi")
        } else {
            config.targetSpeedMph = config.speedingViolationMph; violationHoldSec = 6   // speeding spike
            info("⚠︎ DRIVE MY DAY: speeding \(Int(config.speedingViolationMph)) mph at \(atMi) mi")
        }
        violationIsIdle.toggle()
        nextViolationAtMeters += config.violationEveryMiles / 0.000621371
    }

    // MARK: - Live scenario playback (plays a scenario's exact packet sequence over BLE)
    private var scenarioTimer: Timer?
    private var scenarioQueue: [Emitted] = []
    @Published var runningScenario: String?

    func runScenario(_ s: Scenario) {
        autoDrive = false; drivingRoute = false; dayDriving = false   // step() pauses normal emission while a scenario runs
        scenarioQueue = ScenarioRunner.run(s, config: config)
        runningScenario = s.name
        info("▶ scenario '\(s.name)' — \(scenarioQueue.count) packets (effects baked in)")
        scenarioTimer?.invalidate()
        scenarioTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, config.packetIntervalSec), repeats: true) { [weak self] _ in
            self?.popScenario()
        }
    }

    func stopScenario() {
        scenarioTimer?.invalidate(); scenarioQueue.removeAll(); runningScenario = nil; info("scenario stopped")
    }

    /// F2: replay N stored 'S' packets at a configurable cadence to reproduce Harshith's fast-dump
    /// disconnect (≈0.5s breaks the app; 1.0s completes cleanly). The SIM never fails — it reproduces
    /// the STIMULUS for the app to react to. Reuses the scenario playback path with its own cadence timer.
    func dumpStoredPackets(count: Int, cadenceSec: Double, stopDrive: Bool = true) {
        if stopDrive { autoDrive = false; drivingRoute = false; dayDriving = false }   // app-issued readstr keeps the drive (resumes when queue drains)
        scenarioQueue = ScenarioRunner.storedDump(count: count, config: config)
        runningScenario = "Stored dump (\(count) @ \(Int(cadenceSec * 1000))ms)"
        info("▶ stored dump — \(count) packets @ \(Int(cadenceSec * 1000))ms cadence (≈500ms repros the disconnect)")
        scenarioTimer?.invalidate()
        scenarioTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, cadenceSec), repeats: true) { [weak self] _ in
            self?.popScenario()
        }
    }

    private func popScenario() {
        guard !scenarioQueue.isEmpty else { scenarioTimer?.invalidate(); scenarioTimer = nil; runningScenario = nil; mirror(); info("✓ scenario complete"); return }
        let em = scenarioQueue.removeFirst()
        switch em.kind {
        case .raw:
            sendRaw(em.wire)
        case .malformed:
            push(LogLine(time: stamp(), text: em.wire + "  [malformed — app should reject]", kind: .drop))
            transmit(Data(em.wire.utf8))                     // sent un-framed; the app validator rejects it
        default:
            push(LogLine(time: stamp(), text: em.wire, kind: em.kind == .stored ? .info : .out))
            MTPacket.frame(em.wire).forEach { queue($0) }    // network effects already applied by the runner
        }
    }

    // MARK: - Logging
    private static let stampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private func stamp() -> String { Self.stampFormatter.string(from: Date()) }
    private func info(_ s: String) { push(LogLine(time: stamp(), text: s, kind: .info)) }
    private func push(_ l: LogLine) {
        log.append(l); if log.count > 250 { log.removeFirst(log.count - 250) }
        let sym = l.kind == .out ? "→" : (l.kind == .inbound ? "←" : (l.kind == .drop ? "⨯" : "•"))
        print("[\(l.time)] \(sym) \(l.text)")
    }

    /// Publish telemetry to the UI, but only the values that actually changed — otherwise the
    /// 5 Hz clock would re-render the whole dashboard (and the map) every tick and lag interaction.
    private func mirror() {
        // Position is plain (read by the map loop) — always fresh, no UI publish.
        currentLat = engine.latitude
        currentLon = engine.longitude
        // Publish UI values only when the *displayed* value changes, so steady cruise doesn't
        // re-render the dashboard every tick and starve the map's render loop.
        if speedMph != engine.speedMph { speedMph = engine.speedMph }
        if rpm != engine.rpm { rpm = engine.rpm }
        if odometerMiles.rounded() != engine.odometerMiles.rounded() { odometerMiles = engine.odometerMiles }
        if (engineHours * 10).rounded() != (engine.engineHours * 10).rounded() { engineHours = engine.engineHours }
        if fuelPct.rounded() != engine.fuelLevelPct.rounded() { fuelPct = engine.fuelLevelPct }
        if fuel2Pct.rounded() != engine.fuelLevel2Pct.rounded() { fuel2Pct = engine.fuelLevel2Pct }
        if satellites != engine.satellites { satellites = engine.satellites }
        if headingDeg != engine.headingDeg { headingDeg = engine.headingDeg }
        if ignitionOn != engine.ignitionOn { ignitionOn = engine.ignitionOn }
        if ecmActive != engine.ecmActive { ecmActive = engine.ecmActive }
    }

    // MARK: - Outbound (raw control replies vs framed data packets) + network effects
    private func sendRaw(_ s: String) { transmit(Data(s.utf8)); push(LogLine(time: stamp(), text: s, kind: .out)) }

    /// Command reply / important state packet — always delivered cleanly.
    /// Network effects (loss/dup/out-of-order) apply only to the live telemetry stream,
    /// never to replies the app is actively waiting for.
    private func sendReliable(_ payload: String) {
        push(LogLine(time: stamp(), text: payload, kind: .out))
        MTPacket.frame(payload).forEach { queue($0) }
    }

    private func sendPacket(_ payload: String) {
        // Out-of-order: hold this one, emit the previously-held first.
        if Double.random(in: 0...100) < config.outOfOrderPct, heldPacket == nil {
            heldPacket = payload
            push(LogLine(time: stamp(), text: "\(payload)  [held: out-of-order]", kind: .drop))
            return
        }
        emitNow(payload)
        if let held = heldPacket { heldPacket = nil; emitNow(held) }
    }

    private func emitNow(_ payload: String) {
        // Packet loss
        if Double.random(in: 0...100) < config.packetLossPct {
            push(LogLine(time: stamp(), text: "\(payload)  [dropped: packet loss]", kind: .drop)); return
        }
        push(LogLine(time: stamp(), text: payload, kind: .out))
        let chunks = MTPacket.frame(payload)
        let send = { [weak self] in chunks.forEach { self?.queue($0) } }
        if config.extraDelayMs > 0 {
            let d = Double.random(in: 0...config.extraDelayMs) / 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: send)
        } else { send() }
        // Duplicate
        if Double.random(in: 0...100) < config.duplicatePct {
            push(LogLine(time: stamp(), text: "\(payload)  [duplicate]", kind: .out))
            chunks.forEach { queue($0) }
        }
    }

    private func transmit(_ data: Data) { queue(data) }
    private func queue(_ data: Data) { pending.append(data); drain() }

    private func drain() {
        guard manager != nil, dataChar != nil else { return }
        while let next = pending.first {
            if manager.updateValue(next, for: dataChar, onSubscribedCentrals: nil) { pending.removeFirst() } else { break }
        }
    }

    // MARK: - Continuous sim clock (runs whether or not the app is connected)
    private func ensureClock() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: uiTickSec, repeats: true) { [weak self] _ in self?.step() }
    }

    private func startStreaming() {
        streaming = true; lastIgnitionSent = nil; lastWatchdog = Date()
        sinceLastPacket = config.packetIntervalSec          // emit the first live packet promptly
        if !linkDown { status = "Connected · streaming"; statusColor = Theme.green }  // don't override OUT OF RANGE
        ensureClock()
    }

    /// One simulation step. Always advances motion + telemetry (so the map moves standalone);
    /// only transmits packets while the app is subscribed.
    private func step() {
        guard runningScenario == nil else { return }        // scenario playback owns the stream
        let dt = uiTickSec
        if drivingRoute && route.hasRoute {
            engine.ignitionOn = true
            if autoDrive {                                  // AUTO: vary cruise speed like real driving
                autoSpeedCountdown -= dt
                if autoSpeedCountdown <= 0 {
                    autoSpeedCountdown = Double.random(in: 4...9)
                    config.targetSpeedMph = Double(Int.random(in: 38...70))
                }
            }
            let driveDt = dt * config.routeTimeScale        // compress time so the truck visibly crosses the route
            updateRouteSpeed(dt: driveDt)
            let metersThisTick = engine.speedMph * 0.44704 * driveDt
            if let pos = route.advance(meters: metersThisTick) {
                engine.latitude = pos.coord.latitude; engine.longitude = pos.coord.longitude; engine.headingDeg = pos.headingDeg
            }
            if dayDriving { runDayViolations(dt: dt) }       // F3: bake in speeding + idle events along the day
            let pf = route.progressFraction                  // publish only on whole-% change (avoid 5 Hz churn)
            if Int(pf * 100) != Int(routeProgress * 100) { routeProgress = pf }
            engine.advance(dt: driveDt)
            if route.isComplete || route.progressFraction >= 0.999 {
                engine.speedMph = 0; drivingRoute = false; routeProgress = 1
                if dayDriving { dayDriving = false; info("✓ DRIVE MY DAY complete — full day of IFTA mileage logged") }
                info("route complete — arrived")
            }
        } else {
            engine.advance(dt: dt * config.timeMultiplier)
        }
        mirror()

        sinceLastPacket += dt
        if streaming && !linkDown && sinceLastPacket >= config.packetIntervalSec {   // linkDown = out of range → silent
            sinceLastPacket = 0
            if lastIgnitionSent != engine.ignitionOn { sendReliable(MTPacket.ignition(engine, on: engine.ignitionOn)); lastIgnitionSent = engine.ignitionOn }
            sendPacket(MTPacket.livePosition(engine))
        }
        // Real-tracker watchdog: app sends $wdg every ~20s; if it stops, the tracker stops streaming
        // (resumes on the next readdata). 90s is a safe margin so normal operation never trips it.
        if streaming && Date().timeIntervalSince(lastWatchdog) > 90 {
            streaming = false
            status = "Watchdog lost — stream paused"; statusColor = Theme.amber
            info("no watchdog ≥90s — a real tracker stops streaming (resumes on readdata)")
        }
    }

    private func updateRouteSpeed(dt: Double) {
        let target = config.targetSpeedMph
        let remaining = route.totalMeters - route.traveledMeters
        let v = engine.speedMph * 0.44704
        let brakeM = (v * v) / (2 * max(0.2, config.decelMphPerSec * 0.44704))
        let stepM = v * dt                                       // distance covered this (compressed) tick
        if remaining <= brakeM + stepM + 8 {                     // begin braking ≥1 tick early so we don't blow past the stop
            engine.speedMph = max(0, engine.speedMph - config.decelMphPerSec * dt)
        } else if engine.speedMph < target {
            engine.speedMph = min(target, engine.speedMph + config.accelMphPerSec * dt)
        } else if engine.speedMph > target {
            engine.speedMph = max(target, engine.speedMph - config.decelMphPerSec * dt)
        }
    }

    // MARK: - Command responder (mirrors real MT firmware)
    private func handleTrackerCommand(_ raw: String) {
        let c = raw.lowercased()
        if c.hasPrefix("readdata") {
            sendRaw("ACK,DATA")
            sendReliable(MTPacket.version(device)); sendReliable(MTPacket.version(device))   // ≥2 LV so app learns VIN/firmware
            startStreaming()
        } else if c.hasPrefix("readvin") { sendReliable(MTPacket.version(device)) }
        else if c.hasPrefix("readstr") {
            if config.storedDumpCount > 0 { dumpStoredPackets(count: config.storedDumpCount, cadenceSec: config.storedDumpCadenceSec, stopDrive: false) }
            else { sendRaw("LAST_STORED_PACKET"); sendRaw("SAVED PACKET COUNT:0") }
        }
        else if c.hasPrefix("readdtc") { sendReliable(MTPacket.dtc(device.dtcCodes, ignition: engine.ignitionOn ? 1 : 0, rpm: engine.rpm)) }
        else if c.hasPrefix("clrdtc") { device.dtcCodes = []; faults = [] }
        else if c.hasPrefix("stopdata") { sendRaw("ACK,STOP") }
        else if c.hasPrefix("$wdg") || c.hasPrefix("wdg") { lastWatchdog = Date() }   // keepalive: consume like a real tracker (no reply)
    }

    // MARK: - CBPeripheralManagerDelegate
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            commandChar = CBMutableCharacteristic(type: CBUUID(string: "7add0002-f286-4c78-adda-520c4ba3500c"),
                                                  properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
            dataChar = CBMutableCharacteristic(type: CBUUID(string: "7add0003-f286-4c78-adda-520c4ba3500c"),
                                               properties: [.notify], value: nil, permissions: [.readable])
            let service = CBMutableService(type: CBUUID(string: "7add0001-f286-4c78-adda-520c4ba3500c"), primary: true)
            service.characteristics = [commandChar, dataChar]
            peripheral.add(service)
            ensureClock()
            info("Bluetooth on — publishing tracker service")
        case .poweredOff: status = "Bluetooth OFF"; statusColor = Theme.red; info("Bluetooth is OFF")
        case .unauthorized: status = "Bluetooth denied"; statusColor = Theme.red
            info("Bluetooth permission denied — allow it for Terminal in System Settings ▸ Privacy & Security ▸ Bluetooth")
        default: status = "Bluetooth \(peripheral.state.rawValue)"; statusColor = Theme.amber
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { info("failed to add service: \(error.localizedDescription)"); return }
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid],
                            CBAdvertisementDataLocalNameKey: advertisedName])
        status = "Advertising as \(advertisedName)"; statusColor = Theme.amber
        info("advertising as \"\(advertisedName)\" — waiting for the ELD app")
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        connected = true; status = "iPhone connected"; statusColor = Theme.green
        info("✓ iPhone subscribed to data characteristic")
    }
    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        connected = false; streaming = false; heldPacket = nil; pending.removeAll()   // drop stale out-of-order hold + unsent chunks
        if runningScenario != nil { stopScenario() }             // a disconnect mid-dump clears it so live streaming resumes on reconnect
        dropTimer?.invalidate(); dropTimer = nil; linkDown = false; dropEndsAt = nil   // out-of-range ends when the link actually drops → reconnect resumes streaming
        status = "Advertising as \(advertisedName)"; statusColor = Theme.amber
        info("iPhone disconnected")
    }
    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if let v = req.value, let s = String(data: v, encoding: .utf8) {
                push(LogLine(time: stamp(), text: s, kind: .inbound)); handleTrackerCommand(s)
            }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }
    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) { drain() }
}
