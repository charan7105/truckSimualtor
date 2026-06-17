import Foundation
import CoreBluetooth
import CoreLocation
import SwiftUI

// The simulator core: a BLE peripheral that impersonates a legacy Matrack "MT" tracker,
// exposed as an ObservableObject so the SwiftUI control panel can drive + observe it.

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

    // Live telemetry (mirrored from EngineState each tick)
    @Published var ignitionOn = false
    @Published var autoDrive = false
    @Published var speedMph = 0.0
    @Published var rpm = 0
    @Published var odometerMiles = 25_000.0
    @Published var engineHours = 4_352.5
    @Published var fuelPct = 78.0
    @Published var satellites = 11
    @Published var headingDeg = 103
    @Published var ecmActive = true
    // Read directly by the map's render loop — deliberately NOT @Published so position updates
    // don't re-render the whole dashboard every tick (which starved the map and caused stutter).
    var currentLat = 37.78687
    var currentLon = -121.977687

    // Identity / diagnostics
    @Published var vin = ""
    @Published var firmware = ""
    @Published var faults: [String] = []
    @Published var log: [LogLine] = []

    // Config (everything tunable)
    @Published var config = SimConfig.default

    // Route driving
    @Published var drivingRoute = false
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
    private let uiTickSec = 0.2                // smooth sim/UI clock (decoupled from packet cadence)
    private var sinceLastPacket = 0.0
    private var autoSpeedCountdown = 0.0       // AUTO: seconds until the next random target-speed change

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
        autoDrive = false; drivingRoute = false
        engine.ignitionOn = on
        if !on { engine.speedMph = 0 }
        ensureClock(); mirror(); info("engine \(on ? "ON" : "OFF")")
    }

    func setSpeed(_ mph: Double) {
        if runningScenario != nil { stopScenario() }
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
        autoDrive = on
        if on {
            engine.ignitionOn = true
            autoSpeedCountdown = 0                                  // pick a fresh auto speed immediately
            if route.hasRoute && !drivingRoute { beginDrive() }     // continue the current route, no reset
            ensureClock()
        }
        info("auto speed \(on ? "on" : "off")")
    }
    func injectFault(_ code: String) { if !device.dtcCodes.contains(code) { device.dtcCodes.append(code) }; faults = device.dtcCodes; info("fault \(code) armed (app sees it on next readdtc)") }
    func clearFaults() { device.dtcCodes = []; faults = []; info("faults cleared") }
    func sendVINNow() { sendReliable(MTPacket.version(device)) }

    // MARK: - Route driving (from → to)
    @MainActor
    func loadRoute(from: String, to: String) async {
        routeBusy = true; defer { routeBusy = false }
        do {
            let pts = try await Directions.route(from: from, to: to)
            route.setRoute(pts)
            routeCoords = pts
            routeVersion += 1
            routeInfo = "\(from) → \(to) · \(String(format: "%.0f", route.totalMiles)) mi"
            routeProgress = 0
            info("route loaded: \(routeInfo)")
        } catch {
            routeInfo = "Route error: \(error.localizedDescription)"
            info(routeInfo)
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
        if route.isComplete { route.reset() }   // re-drive a finished route from the start
        drivingRoute = true
        engine.ignitionOn = true
        routeProgress = route.progressFraction
        let p = route.positionAt(route.traveledMeters)
        engine.latitude = p.coord.latitude; engine.longitude = p.coord.longitude; engine.headingDeg = p.headingDeg
        ensureClock()
        mirror()
        info("driving route…")
    }

    func stopRouteDrive() { drivingRoute = false; engine.speedMph = 0; mirror(); info("route drive stopped") }

    // MARK: - Live scenario playback (plays a scenario's exact packet sequence over BLE)
    private var scenarioTimer: Timer?
    private var scenarioQueue: [Emitted] = []
    @Published var runningScenario: String?

    func runScenario(_ s: Scenario) {
        autoDrive = false; drivingRoute = false             // step() pauses normal emission while a scenario runs
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
    private func stamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date()) }
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
        streaming = true; lastIgnitionSent = nil
        sinceLastPacket = config.packetIntervalSec          // emit the first live packet promptly
        status = "Connected · streaming"; statusColor = Theme.green
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
            routeProgress = route.progressFraction
            engine.advance(dt: driveDt)
            if route.isComplete || route.progressFraction >= 0.999 {
                engine.speedMph = 0; drivingRoute = false; routeProgress = 1
                info("route complete — arrived")
            }
        } else {
            engine.advance(dt: dt * config.timeMultiplier)
        }
        mirror()

        sinceLastPacket += dt
        if streaming && sinceLastPacket >= config.packetIntervalSec {
            sinceLastPacket = 0
            if lastIgnitionSent != engine.ignitionOn { sendReliable(MTPacket.ignition(engine, on: engine.ignitionOn)); lastIgnitionSent = engine.ignitionOn }
            sendPacket(MTPacket.livePosition(engine))
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
        else if c.hasPrefix("readstr") { sendRaw("LAST_STORED_PACKET"); sendRaw("SAVED PACKET COUNT:0") }
        else if c.hasPrefix("readdtc") { sendReliable(MTPacket.dtc(device.dtcCodes, ignition: engine.ignitionOn ? 1 : 0, rpm: engine.rpm)) }
        else if c.hasPrefix("clrdtc") { device.dtcCodes = []; faults = [] }
        else if c.hasPrefix("stopdata") { sendRaw("ACK,STOP") }
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
        connected = false; streaming = false; heldPacket = nil   // drop any stale out-of-order hold
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
