using System;
using System.Collections.Generic;
using System.Globalization;

namespace MatrackSim.Core
{
    /// <summary>One emitted item on the wire (what the tracker would send the app).</summary>
    public struct Emitted
    {
        public enum Kind { Live, Stored, Ignition, Raw, Malformed }
        public string Wire;
        public Kind ItemKind;

        public Emitted(string wire, Kind kind)
        {
            Wire = wire;
            ItemKind = kind;
        }
    }


    /// <summary>
    /// Deterministically simulates a scenario tick-by-tick and returns the exact wire sequence.
    /// Shares the real packet builders (MTPacket) so output is byte-identical to the live sim.
    /// </summary>
    /// <summary>
    /// Wire-packet helpers shared by the offline recorder, the stored dump and the self-test.
    /// This used to also run a catalogue of twelve scenarios; every one turned out to be a dashboard
    /// control with extra steps, and the duplicate path is how the Unassigned Driving timing shipped
    /// broken while its own self-test stayed green.
    /// </summary>
    public static class WireBuilder
    {
        

        // MARK: helpers
        

        

        public static string ToStored(string live)
        {
            if (string.IsNullOrEmpty(live) || live[0] != 'L') return live;
            return "S" + live.Substring(1);
        }

        /// <summary>
        /// Split a flash backlog into what the app can actually use and what it would silently discard.
        ///
        /// The app does NOT treat the disconnect as the boundary: it keeps the driver's Driving event
        /// open for appDrivingCloseSec after the link drops, then stamps the closing On-Duty event when
        /// that grace expires and reports the Driving window as ending THERE. Records stamped inside
        /// that window are classified as already assigned and produce nothing — no Unassigned Driving
        /// Period, no error, no UI. Unparseable records are kept, never silently dropped.
        /// </summary>
        public static (List<Emitted> Keep, int Dropped) DeliverableStored(
            List<Emitted> records, DateTime outageStart, double appDrivingCloseSec)
        {
            var cutoff = outageStart.AddSeconds(appDrivingCloseSec);
            var keep = new List<Emitted>();
            foreach (var em in records)
            {
                var utc = UtcOf(em.Wire);
                if (!utc.HasValue || utc.Value >= cutoff) keep.Add(em);
            }
            return (keep, records.Count - keep.Count);
        }

        /// <summary>
        /// Read the odometer / engine hours / position back off a telemetry packet, so the caller can
        /// advance the live engine to exactly where a recorded drive ended and the stored dump and the
        /// live stream never disagree about how far the truck has gone.
        /// </summary>
        public static (double OdometerMiles, double EngineHours, double Latitude, double Longitude)? TelemetryOf(string wire)
        {
            if (string.IsNullOrEmpty(wire)) return null;
            var f = wire.Split(',');
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            if (f.Length <= 7) return null;
            if (!double.TryParse(f[4], System.Globalization.NumberStyles.Float, inv, out double rawOdo)) return null;
            if (!double.TryParse(f[5], System.Globalization.NumberStyles.Float, inv, out double rawHrs)) return null;
            if (!double.TryParse(f[6], System.Globalization.NumberStyles.Float, inv, out double lat)) return null;
            if (!double.TryParse(f[7], System.Globalization.NumberStyles.Float, inv, out double lon)) return null;
            return (rawOdo * 0.0621371, rawHrs / 100.0, lat, lon);
        }

        /// <summary>
        /// Parse the UTC a telemetry packet carries back out of the wire (fields 10 = HHMMSS, 11 = DDMMYY).
        /// Used by the self-test to prove stored packets are stamped inside the outage window.
        /// </summary>
        public static DateTime? UtcOf(string wire)
        {
            if (string.IsNullOrEmpty(wire)) return null;
            var f = wire.Split(',');
            if (f.Length <= 11 || f[10].Length != 6 || f[11].Length != 6) return null;
            if (DateTime.TryParseExact(f[10] + " " + f[11], "HHmmss ddMMyy",
                                       System.Globalization.CultureInfo.InvariantCulture,
                                       System.Globalization.DateTimeStyles.AssumeUniversal
                                     | System.Globalization.DateTimeStyles.AdjustToUniversal,
                                       out DateTime parsed))
                return parsed;
            return null;
        }

        /// <summary>
        /// Stamp for a stored packet recorded DURING an outage that began at `start`.
        ///
        /// The old behaviour backdated every packet into the minutes immediately BEFORE the disconnect,
        /// which is exactly the span the ELD app has already attributed to the logged-in driver — so all
        /// of them were classified as assigned and no Unassigned Driving Period was ever produced. Anchor
        /// the recorded drive to the start of the outage instead, where nothing is attributed to anyone.
        /// </summary>
        public static DateTime Recorded(int i, double dt, DateTime start)
        {
            return start.AddSeconds(i * dt);
        }

        public static DateTime Backdated(int i, int count, double dt)
        {
            return DateTime.UtcNow.AddSeconds(-(double)(count - i) * dt);
        }

        /// <summary>
        /// F2: the exact wire sequence a real `readstr` dump produces — N stored 'S' packets + footers.
        /// Played back at a configurable cadence to reproduce the fast-dump disconnect (≈0.5s breaks, 1s is fine).
        /// </summary>
        public static List<Emitted> StoredDump(int count, SimConfig config)
        {
            var e = new EngineState();
            e.OdometerMiles = config.StartOdometerMiles;
            e.EngineHours = config.StartEngineHours;
            e.FuelLevelPct = config.StartFuelPct;
            e.IdleRpmConfig = config.IdleRpm;
            e.RpmPerMphConfig = config.RpmPerMph;
            e.FuelBurnPctPerMile = config.FuelBurnPctPerMile;
            e.IgnitionOn = true;
            double dt = config.PacketIntervalSec;
            var output = new List<Emitted>();
            int n = Math.Max(0, count);
            for (int i = 0; i < n; i++)
            {
                e.Advance(dt);
                output.Add(new Emitted(ToStored(MTPacket.LivePosition(e, Backdated(i, count, dt))), Emitted.Kind.Stored));
            }
            output.Add(new Emitted("LAST_STORED_PACKET", Emitted.Kind.Raw));
            output.Add(new Emitted("SAVED PACKET COUNT:" + count.ToString(CultureInfo.InvariantCulture), Emitted.Kind.Raw));
            return output;
        }

        // Backdated stored 'S' packets for a stored-replay / unassigned-driving scenario. NO footer here:
        // the readstr handler appends LAST_STORED_PACKET + the count AFTER the app reconnects, because that
        // post-reconnect readstr is the only state in which both apps run stored replay (and UDP) classification.
        /// <summary>
        /// `start` is the instant the BLE link drops; the recorded drive is stamped forward from there.
        /// Null keeps the legacy pre-disconnect backdating so the headless self-test keeps its shape.
        /// </summary>
        /// <summary>
        /// seedOdometer/seedEngineHours/seedLat/seedLon carry the LIVE engine's state. Without them the
        /// replay started from StartOdometerMiles while the live engine is persisted across launches, so
        /// the dump could sit hundreds of miles BELOW the live stream — the app writes milesinception
        /// from the stored packet but milesinceptionlatest from the live status, then re-seeds odoPowerup
        /// from the newest PowerUpShutdown row, putting milespowerup below milesinception in the output.
        /// </summary>
        
    }

    // MARK: - The 20 required scenarios
    
}
