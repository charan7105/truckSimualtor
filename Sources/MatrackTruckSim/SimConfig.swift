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
    /// map (1.0 = real time, far too slow to watch). Not user-facing — the single mph SPEED control
    /// sets the pace (faster mph → arrives sooner); this just keeps the timescale watchable.
    var routeTimeScale: Double = 25

    // MARK: Driving dynamics
    var targetSpeedMph: Double = 65
    var accelMphPerSec: Double = 4
    var decelMphPerSec: Double = 7
    var idleRpm: Int = 750
    /// rpm = idleRpm + speedMph * rpmPerMph  (rough engine model)
    var rpmPerMph: Double = 26

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

    // MARK: Disconnect / reconnect / stored backlog
    /// When a disconnect scenario fires, how long to stay disconnected (sim seconds).
    var reconnectDelaySec: Double = 600
    /// Packets buffered while disconnected, replayed (as stored 'S' packets) on reconnect.
    var storedBacklogCount: Int = 0

    // MARK: HOS cycle (for cycle-exhaustion/reset scenarios)
    var cycleDriveLimitHours: Double = 11
    var cycleShiftLimitHours: Double = 14
    var cycleWeeklyLimitHours: Double = 70

    // MARK: Identity (device info defaults live in DeviceInfo)
    var advertisedName: String = "ELD-MA"

    static let `default` = SimConfig()
}
