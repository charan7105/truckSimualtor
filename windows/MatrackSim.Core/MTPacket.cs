using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace MatrackSim.Core
{
    /// <summary>
    /// Builds legacy MT tracker ASCII packets and the BLE chunk framing the ELD app reassembles.
    ///
    /// Telemetry packets (LP/SP/LI/SI/LS/SS/LE/SE) all share ONE 17-field layout
    /// (confirmed from UtilParser.parsePacketGeneric, indices 0–16):
    ///   type,ign,rpm,speed(km/h),odo(×10 km),engHrs(×100),lat,lon,gpsLock(2|3),heading,HHMMSS,DDMMYY,ecm,fuel1,fuel2,sats,gpsSpeed
    /// The app converts: speed ÷1.60934 → mph, odometer ×0.0621371 → miles, engineHours ÷100.
    /// </summary>
    public static class MTPacket
    {
        private const double KmhPerMph = 1.60934;
        private const double MilesPerRawOdo = 0.0621371;   // miles = rawOdo * this  ⇒  rawOdo = miles / this

        public static string LivePosition(EngineState e) => Telemetry("LP", e, DateTime.UtcNow);
        public static string LivePosition(EngineState e, DateTime date) => Telemetry("LP", e, date);

        public static string SpeedChange(EngineState e) => Telemetry("LS", e, DateTime.UtcNow);
        public static string SpeedChange(EngineState e, DateTime date) => Telemetry("LS", e, date);

        public static string EngineEvent(EngineState e) => Telemetry("LE", e, DateTime.UtcNow);
        public static string EngineEvent(EngineState e, DateTime date) => Telemetry("LE", e, date);

        /// <summary>Ignition packet ("LI"): on == power-up (ign 1), off == shutdown (ign 0).</summary>
        public static string Ignition(EngineState e, bool on) => Ignition(e, on, DateTime.UtcNow);

        public static string Ignition(EngineState e, bool on, DateTime date) =>
            Telemetry("LI", e, date, on ? 1 : 0);

        private static string Telemetry(string prefix, EngineState e, DateTime date, int? ignitionOverride = null)
        {
            int ign = ignitionOverride ?? (e.IgnitionOn ? 1 : 0);
            int speedKmh = (int)Math.Round(e.SpeedMph * KmhPerMph, MidpointRounding.AwayFromZero);
            int rawOdo = (int)Math.Round(e.OdometerMiles / MilesPerRawOdo, MidpointRounding.AwayFromZero);
            int engHrsX100 = (int)Math.Round(e.EngineHours * 100, MidpointRounding.AwayFromZero);
            var (hhmmss, ddmmyy) = UtcTokens(date);
            var fields = new[]
            {
                prefix,                                                              // 0  type
                ign.ToString(CultureInfo.InvariantCulture),                         // 1  ignition
                e.Rpm.ToString(CultureInfo.InvariantCulture),                       // 2  rpm
                speedKmh.ToString(CultureInfo.InvariantCulture),                    // 3  speed km/h
                rawOdo.ToString(CultureInfo.InvariantCulture),                      // 4  odometer ×10 km
                engHrsX100.ToString(CultureInfo.InvariantCulture),                  // 5  engine hours ×100
                e.Latitude.ToString("F6", CultureInfo.InvariantCulture),           // 6  latitude
                e.Longitude.ToString("F6", CultureInfo.InvariantCulture),          // 7  longitude
                "3",                                                                // 8  GPS lock (2|3 = locked)
                e.HeadingDeg.ToString(CultureInfo.InvariantCulture),               // 9  heading
                hhmmss,                                                              // 10 HHMMSS utc
                ddmmyy,                                                              // 11 DDMMYY utc
                e.EcmActive ? "1" : "0",                                            // 12 ecm
                e.FuelLevelPct.ToString("F1", CultureInfo.InvariantCulture),       // 13 fuel tank 1 (%)
                e.FuelLevel2Pct.ToString("F1", CultureInfo.InvariantCulture),      // 14 fuel tank 2 (%)
                e.Satellites.ToString(CultureInfo.InvariantCulture),               // 15 satellites
                e.GpsSpeedKmh.ToString(CultureInfo.InvariantCulture)               // 16 gps speed
            };
            return string.Join(",", fields);
        }

        /// <summary>Version/VIN packet: LV,VIN,mcuHW,mcuFW,bleHW,bleFW,canMode,canMask,deviceMAC</summary>
        public static string Version(DeviceInfo d) =>
            string.Join(",", new[] { "LV", d.Vin, d.McuHW, d.McuFW, d.BleHW, d.BleFW, d.CanMode, d.CanMask, d.DeviceMAC });

        /// <summary>DTC packet (OBD-II path): LD,ign,rpm,canMode(0),count,spare(0),hexBlob</summary>
        public static string Dtc(IReadOnlyList<string> codes, int ignition, int rpm)
        {
            string blob = string.Concat(codes.Select(EncodeObd2));
            return string.Join(",", new[]
            {
                "LD",
                ignition.ToString(CultureInfo.InvariantCulture),
                rpm.ToString(CultureInfo.InvariantCulture),
                "0",
                codes.Count.ToString(CultureInfo.InvariantCulture),
                "0",
                blob
            });
        }

        /// <summary>
        /// Encode an OBD-II code (e.g. "P0143") into its 4 hex chars.
        /// High 2 bits of nibble 0 = system (P=0,C=1,B=2,U=3), next 2 bits = first digit, then 3 hex digits.
        /// </summary>
        private static string EncodeObd2(string code)
        {
            var sys = new Dictionary<char, int> { { 'P', 0 }, { 'C', 1 }, { 'B', 2 }, { 'U', 3 } };
            string upper = code.ToUpperInvariant();
            char[] c = upper.ToCharArray();
            if (c.Length != 5 || !sys.TryGetValue(c[0], out int s)) return "0000";
            int d0 = HexDigitValue(c[1]);
            if (d0 < 0 || d0 > 3) return "0000";
            int firstNibble = s * 4 + d0;
            return firstNibble.ToString("X", CultureInfo.InvariantCulture) + upper.Substring(2, 3);
        }

        /// <summary>Mirror of Swift's Character.hexDigitValue: 0–9/A–F/a–f → value, else -1.</summary>
        private static int HexDigitValue(char ch)
        {
            if (ch >= '0' && ch <= '9') return ch - '0';
            if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
            if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
            return -1;
        }

        private static (string, string) UtcTokens(DateTime date)
        {
            DateTime u = date.ToUniversalTime();
            string hhmmss = string.Format(CultureInfo.InvariantCulture, "{0:D2}{1:D2}{2:D2}", u.Hour, u.Minute, u.Second);
            string ddmmyy = string.Format(CultureInfo.InvariantCulture, "{0:D2}{1:D2}{2:D2}", u.Day, u.Month, u.Year % 100);
            return (hhmmss, ddmmyy);
        }

        /// <summary>
        /// Split a payload into the app's BLE chunk frames.
        /// Each frame = "$" + &lt;total digit&gt; + &lt;current digit&gt; + &lt;1 reserved char&gt; + &lt;payload slice&gt;;
        /// the assembled payload ends with "$$"; total/current are single decimal digits (≤9 chunks).
        /// </summary>
        public static List<byte[]> Frame(string payload)
        {
            char[] body = (payload + "$$").ToCharArray();
            int size = Math.Max(16, (int)Math.Ceiling(body.Length / 9.0));
            var slices = new List<char[]>();
            for (int start = 0; start < body.Length; start += size)
            {
                int end = Math.Min(start + size, body.Length);
                var slice = new char[end - start];
                Array.Copy(body, start, slice, 0, end - start);
                slices.Add(slice);
            }
            int total = slices.Count;
            var frames = new List<byte[]>(total);
            for (int i = 0; i < total; i++)
            {
                // reserved char = '0' (app ignores index 3)
                string frame = "$" + total.ToString(CultureInfo.InvariantCulture)
                                   + i.ToString(CultureInfo.InvariantCulture)
                                   + "0" + new string(slices[i]);
                frames.Add(Encoding.UTF8.GetBytes(frame));
            }
            return frames;
        }
    }
}
