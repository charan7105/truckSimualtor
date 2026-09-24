import Foundation

/// Static device identity the tracker reports (VIN / versions / MAC / fault codes).
/// Defaults are safe for development against an UNPAIRED test vehicle.
struct DeviceInfo {
    /// Special test VIN accepted unconditionally by the app (skips the VIN check-digit popup).
    /// Set a real 17-char VIN later — it must have a valid ISO-3779 check digit or match the vehicle's server VIN.
    var vin = "DafulaiElectronic"
    var mcuHW = "MAMT32"
    var mcuFW = "D1"            // must be ≥ D1 (hex 209) to unlock the app's readvin/readstr follow-ups
    var bleHW = "MABLE10"
    var bleFW = "0A"
    var canMode = "1"
    var canMask = "FFFFFFFF"
    /// Empty = the app validates the device regardless of the vehicle's stored MAC (safe default).
    /// Set this to the vehicle's stored MAC only if you specifically test a paired vehicle.
    var deviceMAC = ""
    /// Active fault codes, e.g. ["P0143"]. Reported on `readdtc`.
    var dtcCodes: [String] = []
}

/// Mutable engine/telemetry state the simulator advances once per tick.
/// Values are human-facing; conversion to on-the-wire units happens in `MTPacket`.
final class EngineState {
    var ignitionOn = false
    var rpm = 0
    var speedMph = 0.0
    var odometerMiles = 25_000.0
    var engineHours = 4_352.5
    var latitude = 37.78687
    var longitude = -121.977687
    var headingDeg = 103

    // Extended telemetry (full LP field set)
    var fuelLevelPct = 30.0
    var fuelLevel2Pct = 24.0
    var satellites = 11
    var ecmActive = true

    /// FAULT INJECTION — raw wire-field overrides by index (0…16), substituted verbatim in
    /// `MTPacket.telemetry` just before the fields are joined.
    ///
    /// Deliberately bypasses the miles→Int conversion, `SimConfig.isValidOdometer` and the
    /// forward-only `setOdometer` guard: the whole point is to emit values a healthy tracker never
    /// would. It is NOT in `SimPersistedState`, so a restart always clears it — a junk odometer can
    /// never become permanent the way a typo in the TEST SETUP field once could.
    var wireOverride: [Int: String] = [:]

    // Config-driven model parameters (set from SimConfig)
    var idleRpmConfig = 750
    var rpmPerMphConfig = 26.0
    var fuelBurnPctPerMile = 0.02

    /// GPS-derived speed on the wire (km/h). Tracks vehicle speed.
    var gpsSpeedKmh: Int { Int((speedMph * 1.60934).rounded()) }

    /// Both tanks dry — the engine stalls, so the truck can't move until it's refueled.
    var outOfFuel: Bool { fuelLevelPct <= 0 && fuelLevel2Pct <= 0 }

    /// Advance by `dt` seconds. Integrates distance + engine hours and models RPM + fuel burn.
    func advance(dt: Double) {
        guard ignitionOn else { rpm = 0; speedMph = 0; return }
        let milesThisTick = speedMph * (dt / 3600.0)
        odometerMiles += milesThisTick
        engineHours += dt / 3600.0
        rpm = speedMph > 0 ? idleRpmConfig + Int(speedMph * rpmPerMphConfig) : idleRpmConfig
        // Both tanks drain with distance (dual-tank crossfeed); tank 2 a touch slower so they don't read identical.
        fuelLevelPct  = max(0, fuelLevelPct  - milesThisTick * fuelBurnPctPerMile)
        fuelLevel2Pct = max(0, fuelLevel2Pct - milesThisTick * fuelBurnPctPerMile * 0.85)
    }
}

/// Tracker state that MUST survive a process restart.
///
/// A physical tracker's odometer and engine hours are monotonic and its last position is retained
/// across a power cycle. A simulator restart that rewinds them emits a transition no real device can
/// produce, and the ELD app reacts badly: `ProcessAction2` only accrues miles while the live odometer
/// exceeds the current event's start odometer, so a rewind freezes the active event's mileage until
/// the truck re-covers the lost distance.
struct SimPersistedState: Codable {
    var odometerMiles: Double
    var engineHours: Double
    var latitude: Double
    var longitude: Double
    var headingDeg: Int
    var fuelLevelPct: Double
    var fuelLevel2Pct: Double

    /// Where the live simulator keeps its state. `directory` exists so tests can point somewhere
    /// disposable — the self-test used to save and then DELETE this exact file, wiping a real
    /// session's odometer and reintroducing the rewind this type exists to prevent.
    static func fileURL(in directory: URL? = nil) -> URL? {
        let dir: URL
        if let directory = directory {
            dir = directory
        } else {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
            dir = base.appendingPathComponent("MatrackSim", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    static func load(from directory: URL? = nil) -> SimPersistedState? {
        guard let url = fileURL(in: directory), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SimPersistedState.self, from: data)
    }

    func save(to directory: URL? = nil) {
        guard let url = SimPersistedState.fileURL(in: directory),
              let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension EngineState {
    var persisted: SimPersistedState {
        SimPersistedState(odometerMiles: odometerMiles, engineHours: engineHours,
                          latitude: latitude, longitude: longitude, headingDeg: headingDeg,
                          fuelLevelPct: fuelLevelPct, fuelLevel2Pct: fuelLevel2Pct)
    }

    /// Restore a previous session. Odometer and engine hours move FORWARD only — a stale file holding
    /// a lower value than the configured floor keeps the floor, so the wire value can never regress.
    func restore(_ s: SimPersistedState) {
        odometerMiles = max(odometerMiles, s.odometerMiles)
        engineHours = max(engineHours, s.engineHours)
        latitude = s.latitude
        longitude = s.longitude
        headingDeg = s.headingDeg
        fuelLevelPct = s.fuelLevelPct
        fuelLevel2Pct = s.fuelLevel2Pct
    }
}
