import Foundation

/// All simulator behavior is driven by this config — nothing important is hardcoded.
/// Defaults are realistic for a typical drive; the UI and scenarios override as needed.
struct SimConfig: Codable, Equatable {

    // MARK: Timing
    /// How often a live packet is emitted (seconds of sim time).
    var packetIntervalSec: Double = 1.0
    /// Multiplies the passage of sim time (2.0 = engine hours/odometer accrue twice as fast).
    /// NOTE: HOS *duration* clocks in the app run on real wall-clock; this only affects the
    /// odometer/engine-hours we report, not the app's 11/14/70h timers. Documented limitation.
    var timeMultiplier: Double = 1.0
    /// Internal time compression while driving a planned route, so the truck visibly crosses the
    /// map (1.0 = real time, far too slow to watch). Kept modest so the map motion reads natural
    /// relative to the displayed speed; the mph SPEED control still sets the pace.
    var routeTimeScale: Double = 5

    // MARK: Driving dynamics
    var targetSpeedMph: Double = 65
    var accelMphPerSec: Double = 4
    var decelMphPerSec: Double = 7
    var idleRpm: Int = 750
    /// rpm = idleRpm + speedMph * rpmPerMph  (rough engine model)
    var rpmPerMph: Double = 26

    // MARK: DRIVE MY DAY (F3) — one-click full-day trip with baked-in event violations
    var dayCruiseMph: Double = 68
    var speedingViolationMph: Double = 82
    var violationEveryMiles: Double = 75
    var idleStopSec: Double = 45

    // MARK: Starting telemetry
    var startOdometerMiles: Double = 25_000
    var startEngineHours: Double = 4_352.5
    var startFuelPct: Double = 30                 // start low so a short leg reaches the low-fuel warning
    /// %/mile fuel burn while moving. High on purpose: a short leg (~50 mi) hits the warning and
    /// ~100 mi empties the tank, so testers reliably reach the "open the Fuel App / refuel" flow.
    var fuelBurnPctPerMile: Double = 0.3
    /// Tank-1 % at/under which the sim raises the "low fuel — open the Fuel App" prompt.
    var lowFuelWarnPct: Double = 15

    // MARK: Network / transport effects (0–100 = percent)
    var packetLossPct: Double = 0
    var duplicatePct: Double = 0
    var outOfOrderPct: Double = 0
    /// Extra random delay added before sending each packet (ms).
    var extraDelayMs: Double = 0
    /// Emulated BLE signal strength 0–100 (100 = full). Weak signal is modeled as added LATENCY
    /// (extraDelayMs), NOT packet loss — real BLE retransmits at the link layer. 0 = out of range.
    /// (macOS/Windows expose no TX-power API, so true RSSI can't be lowered; latency emulates the link.)
    var signalPct: Double = 100
    /// F1 flow control: when true, the live stream waits for the app's $ACK before sending the next
    /// packet (true ACK-gated cadence); when false (default) it streams on packetIntervalSec. Off by
    /// default because real-tracker ACK gating is unconfirmed — this lets devs exercise both modes.
    var ackGatedCadence: Bool = false

    // MARK: Disconnect / reconnect / stored backlog
    /// When a disconnect scenario fires, how long to stay disconnected (sim seconds).
    var reconnectDelaySec: Double = 600
    /// Packets buffered while disconnected, replayed (as stored 'S' packets) on reconnect.
    var storedBacklogCount: Int = 0
    /// F1 out-of-range outage: how long to go silent. The ELD app only DISCONNECTS after ~75s of
    /// silence (15s+30s+30s retry escalation), so ≥80 = a real disconnect+reconnect; 15–75 = a stall demo.
    var rangeOutageSec: Double = 80

    // MARK: Stored replay (Unassigned Driving)
    /// Stored-replay scenarios record a drive that happened while the tracker was OFFLINE, so the
    /// packets must be stamped INSIDE the BLE outage — not in the minutes before it. Anything stamped
    /// before the disconnect still falls inside the driving event the app has open for the logged-in
    /// driver (the app keeps pushing that event's end time to the latest live packet), so every packet
    /// is classified as already-assigned and no Unassigned Driving Period is ever created.
    var storedReplayLeadInSec: Double = 10
    /// The outage must also OUTLAST the app's Driving→On-Duty close — 300s of zero speed plus a 65s
    /// grace — so the open driving event ends at the disconnect, before the recorded drive begins.
    /// Shorter and the event stays open and swallows the dump. This is wall-clock and not compressible.
    var storedReplayMinOutageSec: Double = 395
    /// Flash depth for the offline recorder. A real MT tracker logs to flash whenever no phone is
    /// connected and hands the backlog over on the next `readstr`; without a recorder the sim simply
    /// loses every mile driven offline and answers "SAVED PACKET COUNT:0". ~83 min at 1s/packet.
    var storedFlashCapacity: Int = 5_000
    /// F2 stored-dump repro: count + cadence. ~80 @ 0.5s reproduces Harshith's fast-dump disconnect; 1.0s is safe.
    var storedDumpCount: Int = 80
    var storedDumpCadenceSec: Double = 0.5

    // MARK: HOS cycle (for cycle-exhaustion/reset scenarios)
    var cycleDriveLimitHours: Double = 11
    var cycleShiftLimitHours: Double = 14
    var cycleWeeklyLimitHours: Double = 70

    // MARK: Identity (device info defaults live in DeviceInfo)
    var advertisedName: String = "ELD-MA"

    // MARK: ESP32 serial transport (new)
    enum Transport: String, Codable { case ble, esp32Serial }
    /// Which radio the sim uses: built-in CoreBluetooth, or the ESP32 over USB serial.
    var link: Transport = .ble
    /// tty path of the ESP32 (e.g. "/dev/cu.usbserial-0001"). Chosen in the UI.
    var serialPortName: String = ""
    /// Currently-applied ESP32 TX power in dBm (echoed by "#txpower ok").
    var txPowerDbm: Int = 9

    // Signal% (0–100) → TX power (dBm). Linear across the C3 step range, snapped by the firmware.
    //   100% → +9 (near/full) · 25% (POOR) → ~-6 · 0% → -12 (out of range).
    static func signalPctToDbm(_ pct: Double) -> Int {
        let dbm = -12 + (max(0, min(100, pct)) / 100.0) * 21.0    // -12..+9
        return Int((dbm / 3.0).rounded()) * 3                     // snap to 3-dBm grid
    }

    static let `default` = SimConfig()
}
