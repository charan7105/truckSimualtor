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
        public double FuelLevelPct = 30.0;
        public double FuelLevel2Pct = 24.0;
        public int Satellites = 11;
        public bool EcmActive = true;

        // Config-driven model parameters (set from SimConfig)
        public int IdleRpmConfig = 750;
        public double RpmPerMphConfig = 26.0;
        public double FuelBurnPctPerMile = 0.02;

        /// <summary>GPS-derived speed on the wire (km/h). Tracks vehicle speed.</summary>
        public int GpsSpeedKmh => (int)System.Math.Round(SpeedMph * 1.60934, System.MidpointRounding.AwayFromZero);

        /// <summary>Both tanks dry — the engine stalls, so the truck can't move until it's refueled.</summary>
        public bool OutOfFuel => FuelLevelPct <= 0 && FuelLevel2Pct <= 0;

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
            // Both tanks drain with distance (dual-tank crossfeed); tank 2 a touch slower so they don't read identical.
            FuelLevelPct  = System.Math.Max(0, FuelLevelPct  - milesThisTick * FuelBurnPctPerMile);
            FuelLevel2Pct = System.Math.Max(0, FuelLevel2Pct - milesThisTick * FuelBurnPctPerMile * 0.85);
        }

        public SimPersistedState Persisted => new SimPersistedState
        {
            OdometerMiles = OdometerMiles, EngineHours = EngineHours,
            Latitude = Latitude, Longitude = Longitude, HeadingDeg = HeadingDeg,
            FuelLevelPct = FuelLevelPct, FuelLevel2Pct = FuelLevel2Pct,
        };

        /// <summary>
        /// Restore a previous session. Odometer and engine hours move FORWARD only — a stale file holding
        /// a lower value than the configured floor keeps the floor, so the wire value can never regress.
        /// </summary>
        public void Restore(SimPersistedState s)
        {
            OdometerMiles = System.Math.Max(OdometerMiles, s.OdometerMiles);
            EngineHours = System.Math.Max(EngineHours, s.EngineHours);
            Latitude = s.Latitude;
            Longitude = s.Longitude;
            HeadingDeg = s.HeadingDeg;
            FuelLevelPct = s.FuelLevelPct;
            FuelLevel2Pct = s.FuelLevel2Pct;
        }
    }

    /// <summary>
    /// Tracker state that MUST survive a process restart (mirror of Swift SimPersistedState).
    ///
    /// A physical tracker's odometer and engine hours are monotonic and its last position is retained
    /// across a power cycle. A simulator restart that rewinds them emits a transition no real device can
    /// produce, and the ELD app reacts badly: it only accrues miles while the live odometer exceeds the
    /// current event's start odometer, so a rewind freezes the active event's mileage until the truck
    /// re-covers the lost distance.
    /// </summary>
    public sealed class SimPersistedState
    {
        public double OdometerMiles { get; set; }
        public double EngineHours { get; set; }
        public double Latitude { get; set; }
        public double Longitude { get; set; }
        public int HeadingDeg { get; set; }
        public double FuelLevelPct { get; set; }
        public double FuelLevel2Pct { get; set; }

        public static string FilePath
        {
            get
            {
                string baseDir = System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData);
                string dir = System.IO.Path.Combine(baseDir, "MatrackSim");
                try { System.IO.Directory.CreateDirectory(dir); } catch { }
                return System.IO.Path.Combine(dir, "state.json");
            }
        }

        // netstandard2.0 has no System.Text.Json, and the payload is seven numbers — hand-rolled so the
        // Core assembly stays dependency-free and byte-comparable with the Swift JSON.
        public string ToJson()
        {
            var c = System.Globalization.CultureInfo.InvariantCulture;
            return "{"
                + "\"odometerMiles\":" + OdometerMiles.ToString("R", c)
                + ",\"engineHours\":" + EngineHours.ToString("R", c)
                + ",\"latitude\":" + Latitude.ToString("R", c)
                + ",\"longitude\":" + Longitude.ToString("R", c)
                + ",\"headingDeg\":" + HeadingDeg.ToString(c)
                + ",\"fuelLevelPct\":" + FuelLevelPct.ToString("R", c)
                + ",\"fuelLevel2Pct\":" + FuelLevel2Pct.ToString("R", c)
                + "}";
        }

        public static SimPersistedState FromJson(string json)
        {
            if (string.IsNullOrWhiteSpace(json)) return null;
            var st = new SimPersistedState();
            if (!TryNumber(json, "odometerMiles", out double odo)) return null;
            if (!TryNumber(json, "engineHours", out double hrs)) return null;
            st.OdometerMiles = odo;
            st.EngineHours = hrs;
            st.Latitude = TryNumber(json, "latitude", out double la) ? la : 0;
            st.Longitude = TryNumber(json, "longitude", out double lo) ? lo : 0;
            st.HeadingDeg = TryNumber(json, "headingDeg", out double hd) ? (int)hd : 0;
            st.FuelLevelPct = TryNumber(json, "fuelLevelPct", out double f1) ? f1 : 0;
            st.FuelLevel2Pct = TryNumber(json, "fuelLevel2Pct", out double f2) ? f2 : 0;
            return st;
        }

        private static bool TryNumber(string json, string key, out double value)
        {
            value = 0;
            int k = json.IndexOf("\"" + key + "\"", System.StringComparison.Ordinal);
            if (k < 0) return false;
            int colon = json.IndexOf(':', k);
            if (colon < 0) return false;
            int i = colon + 1;
            while (i < json.Length && char.IsWhiteSpace(json[i])) i++;
            int start = i;
            while (i < json.Length && (char.IsDigit(json[i]) || json[i] == '-' || json[i] == '+' || json[i] == '.' || json[i] == 'e' || json[i] == 'E')) i++;
            return double.TryParse(json.Substring(start, i - start), System.Globalization.NumberStyles.Float,
                                   System.Globalization.CultureInfo.InvariantCulture, out value);
        }

        public static SimPersistedState Load()
        {
            try
            {
                string path = FilePath;
                if (!System.IO.File.Exists(path)) return null;
                return FromJson(System.IO.File.ReadAllText(path));
            }
            catch { return null; }
        }

        public void Save()
        {
            try { System.IO.File.WriteAllText(FilePath, ToJson()); } catch { }
        }
    }
}
