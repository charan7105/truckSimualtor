import Foundation
import CoreBluetooth
import CoreLocation
import SwiftUI

// The simulator core: a BLE peripheral that impersonates a legacy Matrack "MT" tracker,
// exposed as an ObservableObject so the SwiftUI control panel can drive + observe it.

/// Power-on state machine for the cinematic ignition sequence.
enum ClusterPhase { case cold, igniting, sweep, settle, live }

/// Who the dashboard scenario banner is waiting on, right now.
enum ScenarioActor { case working, yourTurn, done }

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
    @Published var autoSignal = true                // AUTO: self-driving signal sweep (full↔weak↔poor), on by default
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

    // Guided scenario walkthrough — presented as a CENTERED overlay on the cockpit (not a corner sheet)
    @Published var guidedScenario: Scenario?
    @Published var guidedStep = 0

    // Low-fuel → "open the Fuel App / refuel" prompt, shown as a centered overlay. Edge-triggered so it
    // fires once when tank 1 crosses the warning level, and once more when both tanks run dry.
    @Published var showLowFuel = false
    private var lowFuelNotified = false
    private var outOfFuelNotified = false

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
    private var lastDataPayload: String?       // F1: last live packet — re-emitted if the app NAKs ($ERR)
    private var awaitingAck = false            // F1: between a live packet and its $ACK (only when ackGatedCadence)
    private var awaitingAckSince: Date?
    private var lastWatchdog = Date()          // app sends $wdg every ~20s; a real tracker stops streaming if it stops
    private let bootOdometerMiles = SimConfig.default.startOdometerMiles   // for trip distance
    private let uiTickSec = 0.2                // smooth sim/UI clock (decoupled from packet cadence)
    private var sinceLastPacket = 0.0
    private var autoSpeedCountdown = 0.0       // AUTO: seconds until the next random target-speed change
    private var autoSignalCountdown = 0.0      // AUTO signal: seconds until the next random signal level
    private var autoSignalDipCountdown = Double.random(in: 300...600)   // AUTO signal: seconds until the next out-of-range dip (dead zone)
    private var dropTimer: Timer?             // F1: out-of-range outage timer
    @Published var flickerOn = false          // edge-of-range signal wobble (see setFlicker)
    private var flickerTimer: Timer?
    private var flickerLow = false
    // ESP32 serial transport (alternative to CoreBluetooth — see startSerial)
    private var serialFD: Int32 = -1
    private var serialSource: DispatchSourceRead?
    private var serialLineBuf = ""
    private var nextViolationAtMeters = 0.0   // F3: distance-triggered violation scheduler
    private var violationHoldSec = 0.0        // F3: remaining seconds of the active violation
    private var violationIsIdle = false       // F3: alternate speeding ↔ idle

    override init() {
        super.init()
        applyConfigToEngine()
        vin = device.vin
        firmware = "\(device.mcuFW) · BLE \(device.bleFW)"
        // Fuel-app link: broadcast the live position on the LAN (the Fuel App's "Link to sim" reads it).
        // Started here — not in a view's onAppear — so it runs at launch regardless of window rendering.
        SimBridge.shared.position = { [weak self] in
            guard let self else { return (0, 0, 0, 0, "") }
            return (self.currentLat, self.currentLon, self.headingDeg, self.speedMph,
                    self.routeFrom.isEmpty ? "Free drive" : "\(self.routeFrom) → \(self.routeTo)")
        }
        SimBridge.shared.start()
    }

    func startBLE() {
        if config.link == .esp32Serial { startSerial(); return }
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // MARK: - ESP32 serial transport (alternative to CoreBluetooth)
    // The desktop sim still generates every byte; the ESP32 is just the radio, fed over USB serial.
    // 1 framed line == 1 BLE notification (frames are ASCII with no newline — see MTPacket.frame).

    /// tty devices that look like a USB-serial adapter (the ESP32 shows up as /dev/cu.usb…/cu.SLAB…/cu.wchusb…).
    var availableSerialPorts: [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return all.filter { $0.hasPrefix("cu.") }.map { "/dev/\($0)" }.sorted()
    }

    func startSerial() {
        stopSerial()
        guard !config.serialPortName.isEmpty else { status = "No serial port selected"; statusColor = Theme.red; return }
        let fd = open(config.serialPortName, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            status = "Serial open failed"; statusColor = Theme.red
            info("✗ \(config.serialPortName): \(String(cString: strerror(errno)))")
            return
        }
        // 115200 8N1, raw.
        var tio = termios()
        tcgetattr(fd, &tio)
        cfmakeraw(&tio)
        cfsetispeed(&tio, speed_t(B115200))
        cfsetospeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CREAD | CLOCAL)
        tcsetattr(fd, TCSANOW, &tio)
        serialFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.serialReadable() }
        src.setCancelHandler { close(fd) }
        serialSource = src
        src.resume()
        status = "ESP32 on \(config.serialPortName)"; statusColor = Theme.amber
        info("serial transport open on \(config.serialPortName) @115200")
        setTxPower(config.txPowerDbm)                 // push the current signal level to the board
    }

    func stopSerial() {
        serialSource?.cancel(); serialSource = nil    // cancel handler closes the fd
        serialFD = -1
        serialLineBuf = ""
    }

    private func serialReadable() {
        guard serialFD >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(serialFD, &buf, buf.count)
        guard n > 0 else { return }
        serialLineBuf += String(decoding: buf[0..<n], as: UTF8.self)
        while let nl = serialLineBuf.firstIndex(of: "\n") {
            var line = String(serialLineBuf[serialLineBuf.startIndex..<nl])
            serialLineBuf.removeSubrange(serialLineBuf.startIndex...nl)
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { onSerialLine(line) }
        }
    }

    // Map ESP32 events onto the SAME state the BLE path drives (connected/streaming, command responder).
    private func onSerialLine(_ line: String) {
        if line.hasPrefix("<") {                                             // a command the ELD app wrote
            let c = String(line.dropFirst())
            push(LogLine(time: stamp(), text: c, kind: .inbound)); handleTrackerCommand(c)
        } else if line.hasPrefix("#connected") || line.hasPrefix("#subscribed") {
            connected = true; status = "Device connected (ESP32)"; statusColor = Theme.green; info("✓ ELD app connected via ESP32")
        } else if line.hasPrefix("#disconnected") {
            connected = false; streaming = false; heldPacket = nil; pending.removeAll()
            status = "Advertising as \(advertisedName) (ESP32)"; statusColor = Theme.amber; info("ELD app disconnected")
        } else { info(line) }                                               // #txpower ok / #status / banner
    }

    private func serialWrite(_ s: String) {
        guard serialFD >= 0 else { return }
        let bytes = Array(s.utf8)
        _ = bytes.withUnsafeBytes { write(serialFD, $0.baseAddress, bytes.count) }
    }

    /// Send a local control command to the ESP32 (no-op unless the serial port is open).
    private func serialControl(_ cmd: String) {
        guard config.link == .esp32Serial, serialFD >= 0 else { return }
        serialWrite(cmd + "\n")
    }

    /// Command the ESP32's real BLE TX power (no-op in BLE mode — macOS has no TX-power API).
    func setTxPower(_ dbm: Int) {
        config.txPowerDbm = dbm
        serialControl("#txpower \(dbm)")
    }

    // FLICKER: emulate sitting at the very edge of range — the signal rapidly wobbles between
    // "barely there" and "almost gone", so the phone sees a flapping connection (the classic
    // weak-spot / doorway-of-the-truck behavior). ESP32 mode wobbles the REAL TX power
    // (-12 ⇄ -3 dBm every 1.5s); BLE mode wobbles the emulated latency instead.
    func setFlicker(_ on: Bool) {
        flickerOn = on
        flickerTimer?.invalidate(); flickerTimer = nil
        if on {
            autoSignal = false                        // manual effect takes over from AUTO (same rule as presets)
            info("〰 flicker on — signal wobbling at the edge of range")
            flickerTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.flickerLow.toggle()
                if self.config.link == .esp32Serial {
                    self.setTxPower(self.flickerLow ? -12 : -3)       // real RSSI flaps at the edge
                } else {
                    self.config.signalPct = self.flickerLow ? 5 : 25  // BLE mode: latency flaps (no real RSSI)
                    self.config.extraDelayMs = self.latencyMsFor(self.config.signalPct)
                }
            }
            flickerTimer?.fire()
        } else {
            info("〰 flicker off — signal restored")
            setSignal(100)                             // settle back to full, like AUTO-off does
        }
    }

    /// Tear down the current transport and start the other (UI toggle: BLE ⇄ ESP32).
    func switchTransport(_ t: SimConfig.Transport) {
        guard config.link != t else { return }
        if config.link == .ble { teardownBLE() } else { stopSerial() }
        config.link = t
        startBLE()   // routes to startSerial() when t == .esp32Serial
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
        // A restart must look like a power cycle, not a factory reset. Carry the odometer, engine
        // hours, position and fuel across launches — see SimPersistedState for why the app cares.
        if let saved = SimPersistedState.load() { engine.restore(saved) }
        mirror()
    }

    // MARK: - Test setup: dial the truck to a starting state

    /// Set the odometer directly — park the truck just short of a threshold instead of driving to it.
    ///
    /// FORWARD ONLY while the app is streaming. A live rewind is the exact transition that freezes
    /// mileage accrual in the ELD app: it only accrues while the live odometer exceeds the current
    /// event's start odometer, so a lower reading silently stops the active event from gaining miles
    /// until the truck re-covers the lost distance. With no app subscribed there is nothing to
    /// confuse, so any value is allowed.
    @discardableResult
    func setOdometer(_ miles: Double) -> Bool {
        // A non-finite or absurd value is fatal, not cosmetic: MTPacket converts miles to the raw
        // x10-km integer, so anything outside Int range traps — and because the value is persisted on
        // the same call, the crash then repeats on every launch. Reject before it can be stored.
        guard SimConfig.isValidOdometer(miles) else {
            info("⚠ odometer must be 0…\(Int(SimConfig.maxOdometerMiles)) mi — \"\(miles)\" rejected")
            return false
        }
        // Forward-only while the app is ATTACHED. Gate on `connected`, not `streaming`: streaming also
        // goes false on a watchdog lapse and between stopdata/readdata while the GATT link is alive and
        // the app still holds an open duty event whose eventStartOdo it restores from the DB.
        if connected && miles < engine.odometerMiles {
            info("⚠ odometer can't go backwards while the app is connected — \(Int(engine.odometerMiles)) → \(Int(miles)) rejected (disconnect first)")
            return false
        }
        engine.odometerMiles = miles
        engine.persisted.save(); mirror(); info("odometer set to \(String(format: "%.1f", miles)) mi")
        return true
    }

    /// Engine hours, same rules and for the same reasons.
    @discardableResult
    func setEngineHours(_ hours: Double) -> Bool {
        guard SimConfig.isValidEngineHours(hours) else {
            info("⚠ engine hours must be 0…\(Int(SimConfig.maxEngineHours)) h — \"\(hours)\" rejected")
            return false
        }
        if connected && hours < engine.engineHours {
            info("⚠ engine hours can't go backwards while the app is connected — \(String(format: "%.2f", engine.engineHours)) → \(String(format: "%.2f", hours)) rejected (disconnect first)")
            return false
        }
        engine.engineHours = hours
        engine.persisted.save(); mirror(); info("engine hours set to \(String(format: "%.2f", hours)) h")
        return true
    }

    /// Fuel levels. Unlike odometer/hours these legitimately move both ways — refuelling is normal.
    func setFuel(tank1: Double? = nil, tank2: Double? = nil) {
        if let t1 = tank1 { engine.fuelLevelPct = min(100, max(0, t1)) }
        if let t2 = tank2 { engine.fuelLevel2Pct = min(100, max(0, t2)) }
        engine.persisted.save(); mirror()
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

    // Guided walkthrough control (centered overlay)
    func startGuided(_ s: Scenario) { guidedStep = 0; guidedScenario = s }
    func advanceGuided() {
        guard let s = guidedScenario else { return }
        if s.appSteps[guidedStep].uppercased().contains("RUN") { runScenario(s) }   // the "Tap RUN" step fires the real sim action
        if guidedStep + 1 < s.appSteps.count { guidedStep += 1 } else { guidedScenario = nil }
    }
    func cancelGuided() { guidedScenario = nil }
    func setFuel(_ pct: Double) { engine.fuelLevelPct = max(0, min(100, pct)); mirror() }
    func setFuel2(_ pct: Double) { engine.fuelLevel2Pct = max(0, min(100, pct)); mirror() }

    /// Refuel BOTH tanks to `pct` — the "arrived at a station, fill up" action from the low-fuel prompt.
    func refuel(toPct pct: Double) {
        let p = max(0, min(100, pct))
        engine.fuelLevelPct = p; engine.fuelLevel2Pct = p
        lowFuelNotified = false; outOfFuelNotified = false; showLowFuel = false
        mirror(); info("refueled to \(Int(p))%")
    }
    func dismissLowFuel() { showLowFuel = false }

    /// Edge-triggered low-fuel prompting: fire once when tank 1 hits the warning level, and once more when
    /// both tanks run dry (truck stalls). Each arm resets after a refuel so it can fire again next drain.
    private func detectLowFuel() {
        if engine.fuelLevelPct <= config.lowFuelWarnPct {
            if !lowFuelNotified { lowFuelNotified = true; showLowFuel = true
                info("low fuel \(Int(engine.fuelLevelPct))% — open the Fuel App, find a station, refuel") }
        } else if engine.fuelLevelPct > config.lowFuelWarnPct + 3 {
            lowFuelNotified = false
        }
        if engine.outOfFuel {
            if !outOfFuelNotified { outOfFuelNotified = true; showLowFuel = true
                status = "Out of fuel — refuel to continue"; statusColor = Theme.red
                info("OUT OF FUEL — truck stopped; refuel to continue") }
        } else {
            outOfFuelNotified = false
        }
    }
    func sendVINNow() { sendReliable(MTPacket.version(device)); info("↻ VIN packet sent (\(device.vin.isEmpty ? "empty" : device.vin))") }

    // MARK: - Fault injection

    /// Names for the wire fields, so the UI and the log can say what is being faked rather than
    /// printing a bare index. Index matches the 17-field telemetry layout.
    static let wireFieldNames = ["type", "ignition", "rpm", "speed", "odometer", "engine hours",
                                 "latitude", "longitude", "GPS lock", "heading", "time", "date",
                                 "ECM", "fuel 1", "fuel 2", "satellites", "GPS speed"]

    /// Override one telemetry field on the wire, or pass nil to clear it.
    /// Arm or clear a wire fault. `probability` < 1 makes it intermittent — the shape most of the
    /// requested faults actually need, because a constant fault is trivially visible while a
    /// 1-in-5 fault is the one that finds ordering bugs in the consumer.
    func setWireOverride(field: Int, value: String?, probability: Double = 1, requiresMotion: Bool = false) {
        guard (0..<Self.wireFieldNames.count).contains(field) else { return }
        let name = Self.wireFieldNames[field]
        if let value = value, !value.isEmpty {
            // TWO ECU ODOMETERS rewrites field 4 on every tick, so it would silently overwrite any
            // other odometer fault the tester arms. Turn it off rather than let them fight — a
            // control that appears armed while something else wins is exactly the confusion this
            // panel exists to avoid.
            if field == 4 && odoAlternating {
                odoAlternating = false
                info("  (two ECU odometers turned off — it would overwrite this)")
            }
            engine.wireFaults[field] = WireFault(value: value, probability: probability, requiresMotion: requiresMotion)
            let how = probability >= 1 ? "every packet" : "~\(Int(probability * 100))% of packets"
            let gate = requiresMotion ? " (only above \(Int(SimConfig.movingThresholdMph)) mph)" : ""
            info("⚠ faking \(name) = \(value) on \(how)\(gate)")
        } else if engine.wireFaults.removeValue(forKey: field) != nil {
            info("✓ \(name) back to the real value")
        }
        mirror()
    }

    /// Everything currently being faked, in field order — drives the UI's "what is armed" line.
    var activeFaults: [(field: Int, name: String, value: String, probability: Double)] {
        engine.wireFaults.keys.sorted().map {
            ($0, Self.wireFieldNames[$0], engine.wireFaults[$0]?.value ?? "", engine.wireFaults[$0]?.probability ?? 1)
        }
    }

    var faultsArmed: Bool { !engine.wireFaults.isEmpty || config.timeSkewSec != 0 || odoAlternating }

    /// One button back to a clean wire — the tester must never have to remember what they armed.
    func clearAllFaults() {
        let n = engine.wireFaults.count + (config.timeSkewSec != 0 ? 1 : 0) + (odoAlternating ? 1 : 0)
        engine.wireFaults.removeAll()
        config.timeSkewSec = 0
        odoAlternating = false
        mirror()
        info(n > 0 ? "✓ wire is clean again — \(n) fault\(n == 1 ? "" : "s") cleared" : "wire was already clean")
    }

    /// Two ECU odometer series, flipping every packet. This is the shape Praboo described: the ECU
    /// reporting two different odometers. The app never alerts — it books the jump as driven miles,
    /// or freezes the event's mileage at 0 if the low series sits below where the duty event began.
    func setOdoAlternating(_ on: Bool) {
        odoAlternating = on
        if on {
            // Same reason in reverse: drop any standing odometer fault so only one thing owns field 4.
            if engine.wireFaults.removeValue(forKey: 4) != nil {
                info("  (cleared the other odometer fault — only one can own that field)")
            }
            info("⚠ two ECU odometer series — flipping every packet (the app will NOT alert)")
        } else {
            engine.wireFaults.removeValue(forKey: 4)
            info("✓ odometer back to one series")
        }
        mirror()
    }

    /// Send the odometer-source packet. Included because it is literally what was asked for — and
    /// because sending it PROVES the app does nothing with it.
    func sendOdoSourcePacket(virtual: Bool) {
        sendRaw(MTPacket.odoSource(virtualEnabled: virtual, activeSource: virtual ? 1 : 0))
        info("↻ odometer-source packet sent (\(virtual ? "virtual" : "ECU")) — the app parses it into a variable nothing reads")
    }

    /// A burst of alternating ignition packets. Cannot go through step(): that path is edge-triggered
    /// on `lastIgnitionSent`, so it emits at most one LI per real ignition change. 500ms spacing is
    /// deliberate — whole-second spacing between same-direction packets hits the app's own de-dup.
    func powerCycleBurst(cycles: Int = 10, intervalSec: Double = 0.5) {
        guard cycles > 0 else { return }
        powerBurstTimer?.invalidate()
        var remaining = cycles * 2
        var on = !engine.ignitionOn
        info("⚡️ power-cycle burst — \(cycles) power-up/shutdown pairs at \(Int(1 / max(0.05, intervalSec)))/s")
        powerBurstTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, intervalSec), repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard remaining > 0 else {
                t.invalidate(); self.powerBurstTimer = nil
                self.lastIgnitionSent = self.engine.ignitionOn      // resync so step() doesn't re-announce
                self.info("⚡️ power-cycle burst finished")
                return
            }
            self.sendReliable(MTPacket.ignition(self.engine, on: on))
            on.toggle()
            remaining -= 1
        }
    }

    // MARK: - F1: signal strength + out-of-range emulation
    /// Signal 100→0. Weak signal = added LATENCY (not packet loss): real BLE retransmits at the link layer,
    /// so a fringe link delivers every packet, just slower — then cleanly disconnects at the edge. (We can't
    /// fake RSSI itself: a Mac/PC peripheral has no TX-power API, so the phone's signal bar reflects real
    /// distance, not this control.) At 0 it goes out of range = silent → the app eventually times out
    /// and reconnects; see SimConfig.rangeOutageSec for why that takes longer than it looks.
    private var preDropSignalPct: Double = 100          // signal level to restore after a transient outage
    private func latencyMsFor(_ pct: Double) -> Double { max(0, (100 - pct) * 9) }   // FULL 0ms · WEAK(70) ~270ms · POOR(40) ~540ms
    func setSignal(_ pct: Double) {
        config.signalPct = pct
        setTxPower(SimConfig.signalPctToDbm(pct))       // ESP32 mode → real RSSI on the phone; BLE mode → no-op
        config.extraDelayMs = latencyMsFor(pct)         // weak signal → jittery latency via the emitNow() delay
        config.packetLossPct = 0                         // BLE does NOT drop app packets on weak signal — it retransmits
        if pct <= 0 { if !linkDown { dropLink(seconds: config.rangeOutageSec) } }   // idempotent: a slider drag to 0 arms once
        else if linkDown { resumeLink() }
    }

    /// AUTO signal = self-driving connection demo: periodically reassign the emulated BLE signal
    /// strength so the link sweeps full ↔ weak ↔ poor on its own. A manual preset or DROP turns it
    /// off (a deliberate override), mirroring how a manual speed set ends AUTO cruise.
    func setAutoSignal(_ on: Bool) {
        autoSignal = on
        if on { autoSignalCountdown = 0; autoSignalDipCountdown = Double.random(in: 300...600); ensureClock() }   // reassign a level next tick; schedule first dead-zone dip
        else { setSignal(100) }                            // switching AUTO off leaves the link at full
        info("auto signal \(on ? "on" : "off")")
    }

    /// EMULATED out-of-range: suppress telemetry for `seconds`. We never stop advertising (the app
    /// reconnects by scanning, so it must stay discoverable). After roughly 90-120s of silence the app disconnects
    /// and auto-reconnects on its own — exactly the real out-of-range round-trip.
    func dropLink(seconds: Double) {
        preDropSignalPct = config.signalPct >= 1 ? config.signalPct : 100   // remember weak level to restore on return
        linkDown = true
        config.signalPct = 0
        // ESP32 mode: real out-of-range = not discoverable at all, so stop the board advertising too
        // (the board keeps its BLE identity, so the phone reconnects fine on #adv on).
        serialControl("#adv off")
        status = "OUT OF RANGE — silent \(Int(seconds))s"; statusColor = Theme.red
        let disconnects = seconds >= config.appDisconnectsAfterSec
        info("📵 out of range: telemetry suppressed for \(Int(seconds))s — \(disconnects ? "long enough for the app to drop and reconnect" : "a stall demo; the app will NOT disconnect under \(Int(config.appDisconnectsAfterSec))s")")
        dropEndsAt = Date().addingTimeInterval(max(1, seconds))
        dropTimer?.invalidate()
        dropTimer = Timer.scheduledTimer(withTimeInterval: max(1, seconds), repeats: false) { [weak self] _ in self?.resumeLink() }
    }

    /// Immediate FORCED disconnect — exactly what the app sees in the field. macOS has no per-central
    /// disconnect API, so we tear down the whole peripheral session (stop advertising + remove services +
    /// drop the manager); the connected central drops within ~1–2s. On return (timer or BACK) we re-advertise
    /// and the app auto-reconnects via its scan — the real out-of-range → back-in-range cycle.
    func forceDisconnect(seconds: Double) {
        preDropSignalPct = config.signalPct >= 1 ? config.signalPct : 100
        linkDown = true
        config.signalPct = 0
        status = "OUT OF RANGE — link dropped"; statusColor = Theme.red
        info("⛔️ forced disconnect — link torn down (app sees a real disconnect)")
        dropEndsAt = Date().addingTimeInterval(max(1, seconds))
        serialControl("#adv off")   // ESP32 mode: stop advertising so the phone truly loses the device
        teardownBLE()               // BLE mode: drop the CB manager (no-op in ESP32 mode)
        dropTimer?.invalidate()
        dropTimer = Timer.scheduledTimer(withTimeInterval: max(1, seconds), repeats: false) { [weak self] _ in self?.resumeLink() }
    }

    /// Drop the peripheral session so the central is forced to disconnect immediately.
    private func teardownBLE() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil                                  // releasing the session severs the active connection
        dataChar = nil; commandChar = nil
        connected = false; streaming = false; heldPacket = nil; pending.removeAll()
    }

    /// Back in range: resume. If we forced a disconnect (manager torn down) we re-advertise so the app
    /// reconnects; otherwise just restore the stream/status.
    func resumeLink() {
        dropTimer?.invalidate(); dropTimer = nil; dropEndsAt = nil
        linkDown = false
        if config.signalPct < 1 { config.signalPct = preDropSignalPct }    // restore the pre-drop weak level (or 100)
        config.extraDelayMs = latencyMsFor(config.signalPct); config.packetLossPct = 0
        if config.link == .esp32Serial {                                   // ESP32: re-advertise on the board, don't reopen the port
            serialControl("#adv on")                                       // recover if a forced disconnect stopped advertising
            info("📶 back in range — telemetry resumes")
            if connected && streaming { status = "Connected · streaming"; statusColor = Theme.green }
            else if connected { status = "Device connected"; statusColor = Theme.green }
            else { status = "Advertising as \(advertisedName) (ESP32)"; statusColor = Theme.amber }
        } else if manager == nil {                                         // forced-disconnect teardown → bring the radio back
            info("📶 back in range — re-advertising for reconnect")
            startBLE()                                                     // recreates the peripheral → re-advertises → app rescans & reconnects
        } else {
            info("📶 back in range — telemetry resumes")
            if connected && streaming { status = "Connected · streaming"; statusColor = Theme.green }
            else if connected { status = "Device connected"; statusColor = Theme.green }
        }
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

    /// No route loaded but the truck is moving (manual speed / quick-set): advance the GPS along the
    /// current heading. Without this the sim reports speed > 0 with a frozen lat/lon forever — a
    /// combination no real tracker can produce, and the reason the truck never moved on the app's map.
    private func deadReckon(dt: Double) {
        guard engine.speedMph > 0, dt > 0 else { return }
        let meters = engine.speedMph * 0.44704 * dt
        let rad = Double(engine.headingDeg) * .pi / 180
        engine.latitude += meters * cos(rad) / 111_320.0
        // Guard the cos(lat) term so a near-polar latitude can't divide by ~0.
        let scale = max(0.05, cos(engine.latitude * .pi / 180))
        engine.longitude += meters * sin(rad) / (111_320.0 * scale)
    }

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
    private var stateSaveCountdown: Double = 0    // periodic persist of odo/hours/position (SimPersistedState)
    private var sinceLastStored: Double = 0       // offline flash recorder cadence
    private var powerBurstTimer: Timer?           // fault injection: rapid ignition storm
    @Published var odoAlternating = false         // fault injection: two ECU odometer series
    private var odoSeriesHigh = false
    private var outageStartedAt: Date?            // when the current offline window began (see step())
    private var undeliveredStored: [Emitted] = [] // backlog handed to the dump but not yet fully sent
    private var flashFullWarned = false
    private var pendingStored: [Emitted] = []     // stored packets, dumped on the app's next readstr (post-reconnect)
    private var pendingStoredCadence: Double = 1.0
    @Published var runningScenario: String?

    // Live dashboard banner for a running scenario — so the user always sees what's happening,
    // even when the gauges are idle (stored-replay scenarios re-send a past drive, so speed stays 0).
    @Published var scenarioStatus: String?            // banner text; nil = no banner
    @Published var scenarioActor: ScenarioActor = .working
    @Published var scenarioProgress: Double?          // 0…1, or nil for indeterminate (spinner)
    private var scenarioTotal = 0
    private var bannerClearTimer: Timer?

    private func banner(_ text: String, _ actor: ScenarioActor = .working, _ progress: Double? = nil) {
        bannerClearTimer?.invalidate()
        scenarioStatus = text; scenarioActor = actor; scenarioProgress = progress
    }
    private func bannerDone(_ text: String) {
        banner(text, .done, 1)
        bannerClearTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in self?.clearBanner() }
    }
    private func clearBanner() {
        bannerClearTimer?.invalidate()
        scenarioStatus = nil; scenarioActor = .working; scenarioProgress = nil; scenarioTotal = 0
    }

    func runScenario(_ s: Scenario) {
        autoDrive = false; drivingRoute = false; dayDriving = false   // step() pauses normal emission while a scenario runs
        runningScenario = s.name
        // Stored-replay / Unassigned-Driving scenarios must arrive as a real flash dump on RECONNECT:
        // both apps run stored replay (and UDP classification) ONLY right after the readstr they send on
        // reconnect. Replaying inline over the live link is silently ignored (storedEventsProcessed==true).
        if Self.isStoredReplay(s) {
            // The drive is recorded INSIDE the outage, and the outage outlasts the app's
            // Driving→On-Duty close, so the app's open driving event ends before the recording
            // starts. Both halves are required — see SimConfig.storedReplayMinOutageSec.
            let dt = max(0.05, config.packetIntervalSec)
            let start = Date().addingTimeInterval(config.storedReplayLeadInSec)
            // Seed from the LIVE engine so the recorded drive continues from where the truck actually is.
            let stored = ScenarioRunner.storedReplay(
                for: s, config: config, from: start,
                seed: (engine.odometerMiles, engine.engineHours, engine.latitude, engine.longitude))
            // The truck really did drive during the outage: advance the live engine to the end of the
            // recording, so the first live packet after the dump continues it instead of rewinding.
            if let last = stored.last, let t = ScenarioRunner.telemetryOf(last.wire) {
                engine.odometerMiles = max(engine.odometerMiles, t.odometerMiles)
                engine.engineHours = max(engine.engineHours, t.engineHours)
                engine.latitude = t.latitude; engine.longitude = t.longitude
                engine.persisted.save()
            }
            let span = config.storedReplayLeadInSec + Double(stored.count) * dt
            let outage = max(config.storedReplayMinOutageSec, span + 20)
            info("▶ scenario '\(s.name)' — recording \(stored.count) stored packets during a \(Int(outage))s offline window; the app must stay logged in and reconnect on its own")
            replayStored(stored, cadenceSec: dt, outageSec: outage)
            return
        }
        scenarioQueue = ScenarioRunner.run(s, config: config)
        scenarioTotal = scenarioQueue.count
        banner("Streaming “\(s.name)” to the app…", .working, 0)
        info("▶ scenario '\(s.name)' — \(scenarioQueue.count) packets (effects baked in)")
        scenarioTimer?.invalidate()
        scenarioTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, config.packetIntervalSec), repeats: true) { [weak self] _ in
            self?.popScenario()
        }
    }

    /// Scenarios whose `expect:` depends on the app processing STORED packets (replay or Unassigned Driving):
    /// they only fire after a genuine disconnect→reconnect→readstr, never from an inline live stream.
    static func isStoredReplay(_ s: Scenario) -> Bool {
        if s.id == 12 { return true }                                   // Unassigned Driving (UDP)
        switch s.transport { case .disconnect, .storedBacklog: return true; default: return false }
    }

    /// Stash backdated stored packets and force a REAL BLE disconnect. When the app reconnects and sends
    /// readstr, the handler dumps them + LAST_STORED_PACKET + the true count — the only sequence that makes
    /// both apps run stored replay / UDP classification.
    func replayStored(_ stored: [Emitted], cadenceSec: Double, outageSec: Double = 8) {
        guard !stored.isEmpty else { return }
        pendingStored = stored
        pendingStoredCadence = cadenceSec
        banner("Recording \(stored.count) packets offline for \(Int(outageSec))s — the app reconnects and claims them…", .working, nil)
        forceDisconnect(seconds: outageSec)
    }

    /// Split the flash backlog into what is worth sending and what the app would silently discard.
    ///
    /// The app does NOT treat the disconnect as the boundary. It keeps the driver's Driving event open
    /// for `appDrivingCloseSec` after the link drops, and stamps the closing On-Duty event at the moment
    /// that grace expires — so `getDrivingLog` reports the Driving window as ending there, not at the
    /// disconnect. Records stamped inside that window are classified as already assigned to the logged-in
    /// driver and produce nothing at all: no Unassigned Driving Period, no error, no UI. Sending them
    /// anyway is what made the old build look like it was working when it was not.
    private func storedRecordsWorthSending() -> (deliverable: [Emitted], suppressed: Int) {
        guard !pendingStored.isEmpty else { return ([], 0) }
        guard let outageStart = outageStartedAt else { return (pendingStored, 0) }   // scenario-armed batch: already anchored
        let (keep, dropped) = ScenarioRunner.deliverableStored(pendingStored, outageStart: outageStart,
                                                               appDrivingCloseSec: config.appDrivingCloseSec)
        if keep.isEmpty {
            let gap = Int(Date().timeIntervalSince(outageStart))
            info("⚠ offline gap \(gap)s is under \(Int(config.appDrivingCloseSec))s — the app still has the driver's Driving event open and would file every one of these against it. Nothing to send; drive offline longer for an Unassigned Driving Period.")
        } else if dropped > 0 {
            info("⚠ withholding \(dropped) packets from the first \(Int(config.appDrivingCloseSec))s of the outage — the app's Driving event was still open then, so it would classify them as already assigned")
        }
        return (keep, dropped)
    }

    func stopScenario() {
        scenarioTimer?.invalidate(); scenarioQueue.removeAll(); runningScenario = nil; clearBanner(); info("scenario stopped")
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
        guard !scenarioQueue.isEmpty else {
            scenarioTimer?.invalidate(); scenarioTimer = nil; runningScenario = nil
            // The dump finished, so the flash records really did go out — only now is it safe to
            // forget them. If the app had dropped mid-dump they would still be in pendingStored.
            if !undeliveredStored.isEmpty { undeliveredStored = []; pendingStored = [] }
            bannerDone("Done — check the app.")
            mirror(); info("✓ scenario complete"); return
        }
        let em = scenarioQueue.removeFirst()
        if scenarioTotal > 0 { scenarioProgress = min(1, 1 - Double(scenarioQueue.count) / Double(scenarioTotal)) }
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
        Self.appendToLogFile(time: l.time, sym: sym, text: l.text)
    }

    // Persistent on-disk log (mirror of TrackerPeripheral.cs). The in-UI list is capped at 250 lines and
    // vanishes on exit, so every LogLine is also appended here to diagnose BLE/connection problems after
    // the fact. Path is announced in the log on startup. All file I/O is best-effort — logging must never
    // crash the app.
    private static let logFileLock = NSLock()
    private static var _logFilePath: String?
    private static var logSessionStarted = false
    private static let sessionStampFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    static var logFilePath: String {
        if let p = _logFilePath { return p }
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = base.appendingPathComponent("MatrackSim/logs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _logFilePath = dir.appendingPathComponent("matracksim.log").path
        } catch {
            _logFilePath = ""   // unwritable → disable file logging
        }
        return _logFilePath!
    }

    private static func appendToLogFile(time: String, sym: String, text: String) {
        let path = logFilePath
        if path.isEmpty { return }
        logFileLock.lock(); defer { logFileLock.unlock() }
        if !logSessionStarted {
            logSessionStarted = true
            // Keep the file from growing without bound across many sessions.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int, size > 2_000_000 {
                try? Data().write(to: URL(fileURLWithPath: path))
            }
            appendString("\n===== MatrackSim session started \(sessionStampFormatter.string(from: Date())) =====\n", to: path)
        }
        appendString("[\(time)] \(sym) \(text)\n", to: path)
    }

    private static func appendString(_ s: String, to path: String) {
        guard let data = s.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            fh.seekToEndOfFile(); fh.write(data)   // append
        } else {
            try? data.write(to: URL(fileURLWithPath: path))   // file didn't exist yet → create it
        }
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
        // Weak signal adds LATENCY, never drops: real BLE retransmits at the link layer, so the app gets
        // every packet — just later (and jittered). Silent packet loss is not a real BLE failure mode.
        lastDataPayload = payload                                   // F1: remember it in case the app NAKs
        if config.ackGatedCadence { awaitingAck = true; awaitingAckSince = Date() }
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
        if config.link == .esp32Serial {
            guard serialFD >= 0 else { pending.removeAll(); return }
            while let next = pending.first {
                serialWrite(String(decoding: next, as: UTF8.self) + "\n")   // 1 frame = 1 line = 1 BLE notify
                pending.removeFirst()
            }
            return
        }
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
        // Do NOT clear lastIgnitionSent here. Real firmware sends LI only on an ignition CHANGE; the
        // app has no dedup (UtilParser has no check against its own engineIgnition), so re-announcing
        // on every resubscribe files a phantom PowerUp/Shutdown event per reconnect. It is still nil on
        // the first connect of a session, so the genuine opening LI is unaffected.
        streaming = true; lastWatchdog = Date()
        sinceLastPacket = config.packetIntervalSec          // emit the first live packet promptly
        if !linkDown { status = "Connected · streaming"; statusColor = Theme.green }  // don't override OUT OF RANGE
        ensureClock()
    }

    /// One simulation step. Always advances motion + telemetry (so the map moves standalone);
    /// only transmits packets while the app is subscribed.
    private func step() {
        guard runningScenario == nil else { return }        // scenario playback owns the stream
        let dt = uiTickSec
        if autoSignal && !linkDown {                        // AUTO: sweep signal strength on its own (skip while out of range)
            autoSignalCountdown -= dt
            if autoSignalCountdown <= 0 {
                autoSignalCountdown = Double.random(in: 3...6)
                setSignal(Double(Int.random(in: 20...100)))
            }
            autoSignalDipCountdown -= dt                     // occasional dead-zone: a real out-of-range dip (tunnel / rural gap)
            if autoSignalDipCountdown <= 0 {
                autoSignalDipCountdown = Double.random(in: 300...600)
                dropLink(seconds: config.rangeOutageSec)
            }
        }
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
            if engine.outOfFuel {                           // stalled: empty tanks → coast to a stop, ignore the target
                engine.speedMph = max(0, engine.speedMph - config.decelMphPerSec * driveDt)
            } else {
                updateRouteSpeed(dt: driveDt)
            }
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
            if engine.outOfFuel { engine.speedMph = 0 }     // stalled: can't move on empty tanks
            engine.advance(dt: dt * config.timeMultiplier)
            deadReckon(dt: dt * config.timeMultiplier)      // no route loaded: still move the GPS
        }
        if odoAlternating {                                 // two ECU series: flip on every tick
            odoSeriesHigh.toggle()
            engine.wireFaults[4] = WireFault(value: odoSeriesHigh ? config.odoSeriesHighRaw : config.odoSeriesLowRaw)
        }
        stateSaveCountdown -= dt                            // persist so a restart resumes, not resets
        if stateSaveCountdown <= 0 { stateSaveCountdown = 5; engine.persisted.save() }
        mirror()
        detectLowFuel()                                     // raise the "open the Fuel App / refuel" prompt when low

        // Offline flash recorder. A real tracker keeps logging while no phone is connected and hands
        // the backlog to the app on its next readstr. Without this, driving the sim with the app
        // disconnected produced NOTHING — the app asked, got "SAVED PACKET COUNT:0", and the whole
        // offline drive never existed (no miles, no Unassigned Driving Period).
        // Gate on `connected`, not `streaming`: streaming also goes false on a 90s watchdog lapse and
        // between stopdata/readdata while the GATT link is alive. In those windows the app is still
        // attached but will never re-issue readstr (it sends it once per connection), so anything
        // buffered there would sit in flash forever with both sides thinking they were fine.
        if (!connected || linkDown) && engine.ignitionOn {
            if outageStartedAt == nil { outageStartedAt = Date() }
            sinceLastStored += dt
            if sinceLastStored >= config.storedRecordIntervalSec {
                sinceLastStored = 0
                if pendingStored.count < config.storedFlashCapacity {
                    pendingStored.append(Emitted(wire: ScenarioRunner.toStored(MTPacket.livePosition(engine)), kind: .stored))
                    // Tell the operator it is recording — otherwise an offline drive looks like the sim
                    // is doing nothing, which is exactly how the missing recorder went unnoticed.
                    if pendingStored.count % 20 == 0 {
                        info("⏺ recording offline — \(pendingStored.count) packets buffered (sent on the app's next readstr)")
                    }
                } else if !flashFullWarned {
                    flashFullWarned = true
                    info("⚠ stored flash full (\(config.storedFlashCapacity) packets) — older offline miles stop being recorded")
                }
            }
        } else {
            sinceLastStored = 0
            outageStartedAt = nil
        }

        sinceLastPacket += dt
        // F1: when ack-gated, hold the next packet until the app's $ACK — but never stall forever
        // (a lost ACK proceeds after 3 intervals), so the stream is robust if the app misses one.
        let ackReady = !config.ackGatedCadence || !awaitingAck
            || (awaitingAckSince.map { Date().timeIntervalSince($0) > config.packetIntervalSec * 3 } ?? true)
        if streaming && !linkDown && ackReady && sinceLastPacket >= config.packetIntervalSec {   // linkDown = out of range → silent
            sinceLastPacket = 0
            if lastIgnitionSent != engine.ignitionOn { sendReliable(MTPacket.ignition(engine, on: engine.ignitionOn)); lastIgnitionSent = engine.ignitionOn }
            // Fault injection: timeSkewSec shifts the clock the app sees in fields 10/11.
            sendPacket(MTPacket.livePosition(engine, date: Date().addingTimeInterval(config.timeSkewSec)))
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
        guard !linkDown else { return }   // OUT OF RANGE: total silence — don't answer commands either, so the app times out and disconnects
        if c.hasPrefix("readdata") {
            sendRaw("ACK,DATA")
            sendReliable(MTPacket.version(device)); sendReliable(MTPacket.version(device))   // ≥2 LV so app learns VIN/firmware
            startStreaming()
        } else if c.hasPrefix("readvin") { sendReliable(MTPacket.version(device)) }
        else if c.hasPrefix("readstr") {
            // The app sends readstr automatically after every connect, and resets its
            // storedEventsProcessed flag to false right before it — so THIS is the moment to deliver a
            // backlog. If a stored-replay/UDP scenario armed one (via replayStored → forceDisconnect),
            // dump it now so the app actually runs replay/UDP classification. Otherwise reply empty.
            let (deliverable, suppressed) = storedRecordsWorthSending()
            if !deliverable.isEmpty {
                let n = deliverable.count
                var q = deliverable
                q.append(Emitted(wire: "LAST_STORED_PACKET", kind: .raw))
                q.append(Emitted(wire: "SAVED PACKET COUNT:\(n)", kind: .raw))
                // Keep the backlog until it has actually gone out. Real flash is not erased when the
                // dump STARTS — if the app drops mid-dump (write backpressure, a background
                // transition), clearing here loses the drive for good and the next readstr answers
                // "SAVED PACKET COUNT:0". popScenario() clears it once the queue drains.
                undeliveredStored = deliverable
                flashFullWarned = false
                pendingStoredCadence = max(1.0, pendingStoredCadence)   // never dump faster than the app tolerates
                scenarioQueue = q
                scenarioTotal = q.count
                runningScenario = "Stored replay (\(n))"
                banner("Reconnected — sending the recorded trip to the app…", .working, 0)
                scenarioTimer?.invalidate()
                scenarioTimer = Timer.scheduledTimer(withTimeInterval: pendingStoredCadence, repeats: true) { [weak self] _ in self?.popScenario() }
                // Don't assert an outcome the sim cannot observe: the app still has to have a vehicle
                // assigned, and it alone decides whether these become an Unassigned Driving Period.
                info("▶ app sent readstr → dumping \(n) stored packets recorded while offline (the app decides if a UDP is filed; it needs a vehicle assigned)")
                if suppressed > 0 {
                    info("   (\(suppressed) earlier packets withheld — see the note above)")
                }
            } else {
                pendingStored = []
                sendRaw("LAST_STORED_PACKET"); sendRaw("SAVED PACKET COUNT:0")
            }
        }
        else if c.hasPrefix("readdtc") { sendReliable(MTPacket.dtc(device.dtcCodes, ignition: engine.ignitionOn ? 1 : 0, rpm: engine.rpm)) }
        else if c.hasPrefix("clrdtc") { device.dtcCodes = []; faults = [] }
        else if c.hasPrefix("stopdata") { sendRaw("ACK,STOP") }
        else if c.hasPrefix("$ack") || c.hasPrefix("ack") { awaitingAck = false }   // F1: app confirmed the last frame (mirrors real $ACK flow control)
        else if c.hasPrefix("$err") || c.hasPrefix("err") {                          // F1: app rejected a frame → retransmit, like real firmware
            awaitingAck = false
            if let p = lastDataPayload { push(LogLine(time: stamp(), text: "\(p)  [retransmit ← $ERR]", kind: .out)); emitNow(p) }
        }
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
            info("log file: \(Self.logFilePath)")
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
        connected = true; status = "Device connected"; statusColor = Theme.green
        info("✓ Device subscribed to data characteristic")
    }
    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        // A drop mid-dump must NOT lose the drive: restore whatever was handed to the dump but never
        // confirmed, so the next readstr can deliver it again. Real flash is only erased once read.
        if !undeliveredStored.isEmpty {
            pendingStored = undeliveredStored + pendingStored
            undeliveredStored = []
            scenarioQueue.removeAll(); scenarioTimer?.invalidate(); scenarioTimer = nil; runningScenario = nil
            info("↩︎ link dropped mid-dump — \(pendingStored.count) stored packets kept for the next readstr")
        }
        connected = false; streaming = false; heldPacket = nil; pending.removeAll()   // drop stale out-of-order hold + unsent chunks
        awaitingAck = false; awaitingAckSince = nil                                    // F1: clear ack-gate so reconnect streams cleanly
        if runningScenario != nil { stopScenario() }             // a disconnect mid-dump clears it so live streaming resumes on reconnect
        dropTimer?.invalidate(); dropTimer = nil; linkDown = false; dropEndsAt = nil   // out-of-range ends when the link actually drops → reconnect resumes streaming
        status = "Advertising as \(advertisedName)"; statusColor = Theme.amber
        info("Device disconnected")
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
