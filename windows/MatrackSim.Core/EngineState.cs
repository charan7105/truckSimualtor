using System.Collections.Generic;

namespace MatrackSim.Core
{
    /// <summary>
    /// Static device identity the tracker reports (VIN / versions / MAC / fault codes).
    /// Defaults are safe for development against an UNPAIRED test vehicle.
    /// </summary>
    public class DeviceInfo
    {
        /// <summary>
        /// Special test VIN accepted unconditionally by the app (skips the VIN check-digit popup).
        /// Set a real 17-char VIN later — it must have a valid ISO-3779 check digit or match the vehicle's server VIN.
        /// </summary>
        public string Vin = "DafulaiElectronic";
        public string McuHW = "MAMT32";
        public string McuFW = "D1";            // must be ≥ D1 (hex 209) to unlock the app's readvin/readstr follow-ups
        public string BleHW = "MABLE10";
        public string BleFW = "0A";
        public string CanMode = "1";
        public string CanMask = "FFFFFFFF";

        /// <summary>
        /// Empty = the app validates the device regardless of the vehicle's stored MAC (safe default).
        /// Set this to the vehicle's stored MAC only if you specifically test a paired vehicle.
        /// </summary>
        public string DeviceMAC = "";

        /// <summary>Active fault codes, e.g. ["P0143"]. Reported on `readdtc`.</summary>
        public List<string> DtcCodes = new List<string>();
    }

    /// <summary>
    /// Mutable engine/telemetry state the simulator advances once per tick.
    /// Values are human-facing; conversion to on-the-wire units happens in `MTPacket`.
    /// </summary>
    public sealed class EngineState
    {
        public bool IgnitionOn = false;
        public int Rpm = 0;
        public double SpeedMph = 0.0;
        public double OdometerMiles = 25_000.0;
        public double EngineHours = 4_352.5;
        public double Latitude = 37.78687;
        public double Longitude = -121.977687;
        public int HeadingDeg = 103;

        // Extended telemetry (full LP field set)
        public double FuelLevelPct = 75.5;
        public double FuelLevel2Pct = 60.0;
        public int Satellites = 11;
        public bool EcmActive = true;

        // Config-driven model parameters (set from SimConfig)
        public int IdleRpmConfig = 750;
        public double RpmPerMphConfig = 26.0;
        public double FuelBurnPctPerMile = 0.02;

        /// <summary>GPS-derived speed on the wire (km/h). Tracks vehicle speed.</summary>
        public int GpsSpeedKmh => (int)System.Math.Round(SpeedMph * 1.60934);

        /// <summary>
        /// Advance by `dt` seconds. Integrates distance + engine hours and models RPM + fuel burn.
        /// </summary>
        public void Advance(double dt)
        {
            if (!IgnitionOn) { Rpm = 0; SpeedMph = 0; return; }
            double milesThisTick = SpeedMph * (dt / 3600.0);
            OdometerMiles += milesThisTick;
            EngineHours += dt / 3600.0;
            Rpm = SpeedMph > 0 ? IdleRpmConfig + (int)(SpeedMph * RpmPerMphConfig) : IdleRpmConfig;
            FuelLevelPct = System.Math.Max(0, FuelLevelPct - milesThisTick * FuelBurnPctPerMile);
        }
    }
}
