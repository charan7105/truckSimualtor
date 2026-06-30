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
    var startFuelPct: Double = 78
    /// %/mile fuel burn while moving.
    var fuelBurnPctPerMile: Double = 0.02

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
    /// F2 stored-dump repro: count + cadence. ~80 @ 0.5s reproduces Harshith's fast-dump disconnect; 1.0s is safe.
    var storedDumpCount: Int = 80
    var storedDumpCadenceSec: Double = 0.5

    // MARK: HOS cycle (for cycle-exhaustion/reset scenarios)
    var cycleDriveLimitHours: Double = 11
    var cycleShiftLimitHours: Double = 14
    var cycleWeeklyLimitHours: Double = 70

    // MARK: Identity (device info defaults live in DeviceInfo)
    var advertisedName: String = "ELD-MA"

    static let `default` = SimConfig()
}
