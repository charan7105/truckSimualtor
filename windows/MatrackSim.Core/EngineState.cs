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

        /// <summary>
        /// FAULT INJECTION — raw wire-field overrides by index (0…16), substituted verbatim in
        /// MTPacket.Telemetry just before the fields are joined.
        ///
        /// Deliberately bypasses the miles→int conversion, SimConfig.IsValidOdometer and the
        /// forward-only SetOdometer guard: the whole point is to emit values a healthy tracker never
        /// would. It is NOT part of SimPersistedState, so a restart always clears it — a junk
        /// odometer can never become permanent.
        /// </summary>
        public System.Collections.Generic.Dictionary<int, WireFault> WireFaults =
            new System.Collections.Generic.Dictionary<int, WireFault>();

        /// <summary>
        /// Which fields are faulted on THIS packet. Pure given `roll`, so the probability and
        /// motion-gate logic can be tested without waiting on chance.
        /// </summary>
        public System.Collections.Generic.Dictionary<int, string> FaultedFields(System.Func<double> roll)
        {
            var outv = new System.Collections.Generic.Dictionary<int, string>();
            if (WireFaults.Count == 0) return outv;
            foreach (var kv in WireFaults)
            {
                var f = kv.Value;
                if (f.RequiresMotion && SpeedMph <= SimConfig.MovingThresholdMph) continue;
                if (f.Probability < 1 && roll() >= f.Probability) continue;
                outv[kv.Key] = f.Value;
            }
            return outv;
        }

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
    /// One injected wire fault.
    ///
    /// Probability exists because real trackers misbehave INTERMITTENTLY — "random packets with an
    /// invalid time" is not the same test as "every packet has an invalid time". A constant fault is
    /// trivially visible; a 1-in-5 fault is the one that finds ordering and state-machine bugs.
    /// </summary>
    public sealed class WireFault
    {
        public string Value { get; set; }
        /// <summary>0…1 share of packets that carry this fault. 1.0 = every packet.</summary>
        public double Probability { get; set; } = 1;
        /// <summary>Only inject while the truck is moving — a parked tracker legitimately loses its fix.</summary>
        public bool RequiresMotion { get; set; }

        public WireFault(string value, double probability = 1, bool requiresMotion = false)
        { Value = value; Probability = probability; RequiresMotion = requiresMotion; }
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

        public static string FilePath => PathIn(null);

        /// <summary>
        /// `directory` exists so tests can point somewhere disposable — the self-test used to save and
        /// then DELETE the live file, wiping a real session's odometer.
        /// </summary>
        public static string PathIn(string directory)
        {
            string dir = directory;
            if (string.IsNullOrEmpty(dir))
            {
                string baseDir = System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData);
                dir = System.IO.Path.Combine(baseDir, "MatrackSim");
            }
            try { System.IO.Directory.CreateDirectory(dir); } catch { }
            return System.IO.Path.Combine(dir, "state.json");
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
            // Every field is required. Defaulting a missing one to 0 is worse than rejecting the file:
            // a truncated write (the save runs every 5s) would put the truck at (0,0) with both tanks
            // empty, which makes OutOfFuel true — DRIVE is then accepted and silently does nothing.
            if (!TryNumber(json, "latitude", out double la)) return null;
            if (!TryNumber(json, "longitude", out double lo)) return null;
            if (!TryNumber(json, "headingDeg", out double hd)) return null;
            if (!TryNumber(json, "fuelLevelPct", out double f1)) return null;
            if (!TryNumber(json, "fuelLevel2Pct", out double f2)) return null;
            st.Latitude = la;
            st.Longitude = lo;
            st.HeadingDeg = (int)hd;
            st.FuelLevelPct = f1;
            st.FuelLevel2Pct = f2;
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

        public static SimPersistedState Load(string directory = null)
        {
            try
            {
                string path = PathIn(directory);
                if (!System.IO.File.Exists(path)) return null;
                return FromJson(System.IO.File.ReadAllText(path));
            }
            catch { return null; }
        }

        /// <summary>Write via a temp file so a kill mid-write can never leave a half-written state.</summary>
        public void Save(string directory = null)
        {
            try
            {
                string path = PathIn(directory);
                string tmp = path + ".tmp";
                System.IO.File.WriteAllText(tmp, ToJson());
                if (System.IO.File.Exists(path)) System.IO.File.Replace(tmp, path, null);
                else System.IO.File.Move(tmp, path);
            }
            catch { }
        }
    }
}
