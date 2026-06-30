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
    var fuelLevelPct = 75.5
    var fuelLevel2Pct = 60.0
    var satellites = 11
    var ecmActive = true

    // Config-driven model parameters (set from SimConfig)
    var idleRpmConfig = 750
    var rpmPerMphConfig = 26.0
    var fuelBurnPctPerMile = 0.02

    /// GPS-derived speed on the wire (km/h). Tracks vehicle speed.
    var gpsSpeedKmh: Int { Int((speedMph * 1.60934).rounded()) }

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
