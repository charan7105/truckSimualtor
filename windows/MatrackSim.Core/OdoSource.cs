using System.Collections.Generic;
using System.Linq;

namespace MatrackSim.Core
{
    /// <summary>
    /// Odometer source slots. POSITIONAL: they map 1:1 onto the source fields of the odo-report
    /// packet, which the ELD app parses from index 9 onward (MatrackELD/Utils/OdoSource.swift).
    /// Order must not change. Mirrors OdoSourceSlot in the Swift build.
    /// </summary>
    public enum OdoSourceSlot
    {
        Pgn65248 = 0,       // J1939 PGN 65248 (SPN 245, by request every 10 s) - priority 1 (best)
        Pgn65217Sa17 = 1,   // J1939 PGN 65217 from SA 0x17 (broadcast)         - priority 2
        Pgn65217Sa00 = 2,   // J1939 PGN 65217 from SA 0x00 (broadcast)         - priority 3
        VirtualGps = 3,     // J1939 Virtual (GPS/speed accumulator)            - overrides all
    }

    public static class OdoSourceSlotNames
    {
        /// <summary>Names copied from the app's OdoPacket.knownSourceNames so the two cannot drift.</summary>
        public static string Display(OdoSourceSlot s)
        {
            switch (s)
            {
                case OdoSourceSlot.Pgn65248:     return "Odo PGN65248";
                case OdoSourceSlot.Pgn65217Sa17: return "Odo PGN65217 SA17";
                case OdoSourceSlot.Pgn65217Sa00: return "Odo PGN65217 SA0";
                default:                         return "Virtual (GPS)";
            }
        }
        public static OdoSourceSlot[] All => new[]
        {
            OdoSourceSlot.Pgn65248, OdoSourceSlot.Pgn65217Sa17,
            OdoSourceSlot.Pgn65217Sa00, OdoSourceSlot.VirtualGps
        };
    }

    /// <summary>One configured odometer source. Mirrors OdoSourceConfig in the Swift build.</summary>
    public class OdoSourceConfig
    {
        public bool Enabled;
        /// <summary>
        /// Miles this source reads ABOVE the truck's odometer. An offset rather than an absolute
        /// start because the customer evidence is explicit that both counters rise with the truck;
        /// a fixed start would stop counting the moment the operator edited the odometer.
        /// </summary>
        public double OffsetMiles;
        public OdoSourceConfig(bool enabled, double offsetMiles) { Enabled = enabled; OffsetMiles = offsetMiles; }
    }

    /// <summary>
    /// The source-selection ladder, as pure functions so the app and the selftest exercise the SAME
    /// code. Mirrors OdoLadder in the Swift build.
    /// </summary>
    public static class OdoLadder
    {
        /// <summary>Enabled slots in priority order. Virtual "overrides all", so it leads when on.</summary>
        public static List<int> ActiveSlots(List<OdoSourceConfig> sources)
        {
            var slots = new List<int>();
            foreach (var s in OdoSourceSlotNames.All)
            {
                int i = (int)s;
                if (i < sources.Count && sources[i].Enabled) slots.Add(i);
            }
            int v = slots.IndexOf((int)OdoSourceSlot.VirtualGps);
            if (v >= 0) { slots.RemoveAt(v); slots.Insert(0, (int)OdoSourceSlot.VirtualGps); }
            return slots;
        }

        /// <summary>
        /// Which slot the live odometer reads from. A LOCKED slot wins over the flip - that is
        /// exactly the 00FD behaviour under test ("once locked, whatever is the locked one").
        /// </summary>
        public static int? Selected(List<OdoSourceConfig> sources, bool flipEnabled,
                                    int? lockedSlot, bool onSecond)
        {
            var slots = ActiveSlots(sources);
            if (lockedSlot.HasValue && slots.Contains(lockedSlot.Value)) return lockedSlot.Value;
            if (slots.Count == 0) return null;
            if (!flipEnabled || slots.Count < 2) return slots[0];
            return onSecond ? slots[1] : slots[0];
        }

        /// <summary>What the source model should do with wire field 4 on this tick.</summary>
        public enum Field4Action { LeaveAlone, Write, ClearOurs }

        /// <summary>
        /// Pulled out as a pure function because getting it wrong is invisible: clearing field 4
        /// unconditionally wipes any odometer fault the tester armed (ODOMETER STUCK, ODOMETER JUMP,
        /// the 1-in-5 variants) before a single packet carries it. Mirrors OdoLadder.field4Action.
        /// </summary>
        public static Field4Action DecideField4(int? selected, List<OdoSourceConfig> sources,
                                                bool weOwnIt, bool userFaultPresent, out int slot)
        {
            slot = selected ?? -1;
            // A fault the tester armed owns field 4 outright. Without this the source model either
            // DELETED it (stale ownership on an offset-0 slot) or OVERWROTE it every tick (a locked
            // slot with a non-zero offset).
            if (userFaultPresent) return Field4Action.LeaveAlone;
            double offset = selected.HasValue && selected.Value < sources.Count
                ? sources[selected.Value].OffsetMiles : 0;
            if (!selected.HasValue || offset == 0)
                return weOwnIt ? Field4Action.ClearOurs : Field4Action.LeaveAlone;
            return Field4Action.Write;
        }

        /// <summary>Report only when there is more than one source to choose between.</summary>
        public static bool ShouldReport(List<OdoSourceConfig> sources) => ActiveSlots(sources).Count >= 2;
    }
}
