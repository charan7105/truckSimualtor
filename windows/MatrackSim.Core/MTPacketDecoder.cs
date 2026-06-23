using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace MatrackSim.Core
{
    /// <summary>
    /// Mirrors the Matrack ELD app's actual receive pipeline (BleClass.PacketValidator +
    /// processMultiPartPacketImproved reassembly + UtilParser.parsePacketGeneric field decode).
    ///
    /// This lets the self-test prove that packets the simulator produces are (a) accepted by the
    /// app's validator, (b) reassembled correctly from chunks, and (c) decode back to the values we
    /// encoded (round-trip). It is a faithful port of the logic extracted from the app source.
    /// </summary>
    public static class MTDecoder
    {
        public static readonly string[] ValidPrefixes =
            { "LP", "SP", "LI", "SI", "LS", "SS", "LE", "SE", "LV", "SV", "LD", "SD", "SX", "LX", "LH", "SH" };

        public static readonly string[] ValidResponses =
            { "ERR_MCU", "ACK,PGN", "ACK,STOP", "ACK,DATA", "$OTA_OK", "DATA", "SAVED",
              "DEBUG", "LAST PGN", "$START", "$STOP", "ACK,", "CAN MODE", "CANMASK",
              "LAST_STORED_PACKET", "SAVED PACKET COUNT" };

        /// <summary>Faithful port of BleClass.PacketValidator.isValidPacketFormat.</summary>
        public static bool IsValid(string packet)
        {
            if (ValidResponses.Any(p => packet.ToUpperInvariant().StartsWith(p, StringComparison.Ordinal))) return true;
            if (ValidPrefixes.Any(p => packet.StartsWith(p, StringComparison.Ordinal))) return packet.EndsWith("$$", StringComparison.Ordinal);
            if (packet.StartsWith("$", StringComparison.Ordinal) && packet.Length >= 4)
            {
                var two = new[] { packet[1], packet[2] };
                return two.All(IsHexDigit);
            }
            var l = packet.ToLowerInvariant();
            return l.StartsWith("d", StringComparison.Ordinal) || l.StartsWith("v", StringComparison.Ordinal) || l.StartsWith("e", StringComparison.Ordinal);
        }

        /// <summary>
        /// Reassemble chunk frames ("$"+total+current+reserved+payload) into the inner payload,
        /// mirroring processMultiPartPacketImproved + processCompletePacketImproved. Returns the
        /// "$"-stripped packet, or null if the chunk sequence is malformed.
        /// </summary>
        public static string Reassemble(IList<byte[]> frames)
        {
            var packetT = "";
            var expectedTotal = -1;
            for (var idx = 0; idx < frames.Count; idx++)
            {
                var f = frames[idx];
                string v;
                try { v = AsciiString(f); }
                catch { return null; }
                if (v == null || !v.StartsWith("$", StringComparison.Ordinal) || v.Length < 4) return null;
                var chars = v.ToCharArray();
                if (!TryParseHex(chars[1], out var total)) return null;
                if (!TryParseHex(chars[2], out var current)) return null;
                if (current == 0) { packetT = ""; expectedTotal = total; }
                if (current != idx || total != expectedTotal) return null;   // ordering check
                packetT += new string(chars, 4, chars.Length - 4);
                if (total - 1 == current)                                    // last chunk
                {
                    if (!v.EndsWith("$", StringComparison.Ordinal)) return null;
                    return packetT.Replace("$", "");
                }
            }
            return null;   // never saw the terminating chunk
        }

        public sealed class Decoded : IEquatable<Decoded>
        {
            public string Type = "";
            public int? Ignition;
            public int? Rpm;
            public double? SpeedMph;
            public double? OdometerMiles;
            public double? EngineHours;
            public double? Lat;
            public double? Lon;
            public bool? GpsLocked;
            public string Heading;
            public string Utctime;
            public string Utcdate;
            public int? Ecm;
            public string Fuel1;
            public string Fuel2;
            public int? Sats;
            public int? GpsSpeed;
            // LV
            public string Vin;
            public string McuFW;
            public string BleFW;
            public string DeviceMAC;
            // LD
            public int? CanMode;
            public int? DtcCount;
            public string DtcBlob;

            public bool Equals(Decoded o)
            {
                if (o == null) return false;
                return Type == o.Type
                    && Ignition == o.Ignition
                    && Rpm == o.Rpm
                    && SpeedMph == o.SpeedMph
                    && OdometerMiles == o.OdometerMiles
                    && EngineHours == o.EngineHours
                    && Lat == o.Lat
                    && Lon == o.Lon
                    && GpsLocked == o.GpsLocked
                    && Heading == o.Heading
                    && Utctime == o.Utctime
                    && Utcdate == o.Utcdate
                    && Ecm == o.Ecm
                    && Fuel1 == o.Fuel1
                    && Fuel2 == o.Fuel2
                    && Sats == o.Sats
                    && GpsSpeed == o.GpsSpeed
                    && Vin == o.Vin
                    && McuFW == o.McuFW
                    && BleFW == o.BleFW
                    && DeviceMAC == o.DeviceMAC
                    && CanMode == o.CanMode
                    && DtcCount == o.DtcCount
                    && DtcBlob == o.DtcBlob;
            }

            public override bool Equals(object obj) => Equals(obj as Decoded);

            public override int GetHashCode()
            {
                var h = new System.Text.StringBuilder();
                h.Append(Type).Append('|').Append(Ignition).Append('|').Append(Rpm).Append('|')
                 .Append(SpeedMph).Append('|').Append(OdometerMiles).Append('|').Append(EngineHours).Append('|')
                 .Append(Lat).Append('|').Append(Lon).Append('|').Append(GpsLocked).Append('|')
                 .Append(Heading).Append('|').Append(Utctime).Append('|').Append(Utcdate).Append('|')
                 .Append(Ecm).Append('|').Append(Fuel1).Append('|').Append(Fuel2).Append('|')
                 .Append(Sats).Append('|').Append(GpsSpeed).Append('|').Append(Vin).Append('|')
                 .Append(McuFW).Append('|').Append(BleFW).Append('|').Append(DeviceMAC).Append('|')
                 .Append(CanMode).Append('|').Append(DtcCount).Append('|').Append(DtcBlob);
                return h.ToString().GetHashCode();
            }
        }

        /// <summary>Faithful port of UtilParser.parsePacketGeneric / parseVin / DTC decode (same sentinels + scaling).</summary>
        public static Decoded Decode(string packet)
        {
            var v = packet.Split(',');
            var type = v.Length > 0 ? v[0] : null;
            if (type == null || type.Length == 0) return null;
            var d = new Decoded { Type = type };

            if (type == "LV" || type == "SV")
            {
                if (v.Length > 1) d.Vin = v[1];
                if (v.Length > 3) d.McuFW = v[3];
                if (v.Length > 5) d.BleFW = v[5];
                if (v.Length > 8) d.DeviceMAC = v[8];
                return d;
            }
            if (type == "LD" || type == "SD")
            {
                if (v.Length > 3) d.CanMode = ParseInt(v[3]);
                if (v.Length > 4) d.DtcCount = ParseInt(v[4]);
                if (v.Length > 6) d.DtcBlob = v[6];
                return d;
            }
            // telemetry packets (LP/SP/LI/SI/LS/SS/LE/SE) — 17-field layout
            if (v.Length < 13) return null;
            d.Ignition = ParseInt(v[1]);
            if (!v[2].StartsWith("8191", StringComparison.Ordinal)) d.Rpm = ParseInt(v[2]);   // 8191 = invalid rpm
            d.SpeedMph = (ParseDouble(v[3]) ?? 0) / 1.60934;
            if (!v[4].StartsWith("4294967295", StringComparison.Ordinal)) d.OdometerMiles = (ParseDouble(v[4]) ?? 0) * 0.0621371;
            if (!v[5].StartsWith("4294967295", StringComparison.Ordinal)) d.EngineHours = (ParseDouble(v[5]) ?? 0) / 100;
            d.Lat = ParseDouble(v[6]);
            d.Lon = ParseDouble(v[7]);
            d.GpsLocked = (v[8] == "2" || v[8] == "3");
            d.Heading = v[9];
            d.Utctime = v[10];
            d.Utcdate = v[11];
            d.Ecm = ParseInt(v[12]);
            if (v.Length > 13) d.Fuel1 = v[13];
            if (v.Length > 14) d.Fuel2 = v[14];
            if (v.Length > 15) d.Sats = ParseInt(v[15]);
            if (v.Length > 16) d.GpsSpeed = ParseInt(v[16]);
            return d;
        }

        // --- Swift parity helpers ---------------------------------------------------------------

        /// <summary>Mirrors Swift Int(String) — full-string base-10 parse, nil on failure.</summary>
        private static int? ParseInt(string s)
        {
            if (int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var r)) return r;
            return null;
        }

        /// <summary>Mirrors Swift Double(String) — nil on failure.</summary>
        private static double? ParseDouble(string s)
        {
            if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var r)) return r;
            return null;
        }

        /// <summary>Mirrors Swift Int(String, radix:16) for a single hex char, nil on failure.</summary>
        private static bool TryParseHex(char c, out int value)
        {
            if (c >= '0' && c <= '9') { value = c - '0'; return true; }
            if (c >= 'a' && c <= 'f') { value = c - 'a' + 10; return true; }
            if (c >= 'A' && c <= 'F') { value = c - 'A' + 10; return true; }
            value = 0;
            return false;
        }

        /// <summary>Mirrors Swift Character.isHexDigit.</summary>
        private static bool IsHexDigit(char c) => TryParseHex(c, out _);

        /// <summary>Mirrors Swift String(data:encoding:.ascii) — null if any byte is non-ASCII.</summary>
        private static string AsciiString(byte[] data)
        {
            if (data == null) return null;
            foreach (var b in data) if (b > 0x7F) return null;
            return Encoding.ASCII.GetString(data);
        }
    }
}
