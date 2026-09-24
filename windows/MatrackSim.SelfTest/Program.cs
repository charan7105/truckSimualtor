using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using MatrackSim.Core;

namespace MatrackSim.SelfTest
{
    /// <summary>
    /// Headless validation: runs all 20 scenarios across 10 cycles (with config variation),
    /// validating every emitted packet against the app-mirrored decoder (accept + chunk-frame +
    /// reassembly round-trip + field decode), plus scenario-level invariants. Prints Pass/Fail
    /// per cycle. Exits non-zero if anything fails. Deterministic + repeatable.
    /// </summary>
    public static class Program
    {
        public static int Main()
        {
            Console.WriteLine("════════════════════════════════════════════════════════════");
            Console.WriteLine(" Matrack Truck Sim — Self-Test (encoder ↔ app-parser fidelity)");
            Console.WriteLine("════════════════════════════════════════════════════════════");

            bool allPass = true;

            // 0) Encoder ↔ decoder round-trip on a known state
            var rtFail = RoundTripUnit();
            if (rtFail != null) { Console.WriteLine("Round-trip unit: FAIL — " + rtFail); allPass = false; }
            else { Console.WriteLine("Round-trip unit: PASS — LP/LV/LD encode→decode values match"); }

            // 10 cycles, each with a deterministic config variation
            for (int cycle = 1; cycle <= 10; cycle++)
            {
                var cfg = ConfigForCycle(cycle);
                var failures = new List<string>();
                int totalPackets = 0, controlPkts = 0, storedPkts = 0, malformedPkts = 0;

                foreach (var s in Scenarios.All)
                {
                    var emitted = ScenarioRunner.Run(s, cfg);
                    totalPackets += emitted.Count;
                    foreach (var em in emitted)
                    {
                        switch (em.ItemKind)
                        {
                            case Emitted.Kind.Raw: controlPkts += 1; break;
                            case Emitted.Kind.Stored: storedPkts += 1; break;
                            case Emitted.Kind.Malformed: malformedPkts += 1; break;
                            default: break;
                        }
                        var f = Validate(em);
                        if (f != null) failures.Add("[S" + s.Id + " " + s.Name + "] " + f);
                    }
                    var inv = ScenarioInvariant(s, emitted);
                    if (inv != null) failures.Add("[S" + s.Id + " " + s.Name + "] " + inv);
                }

                string result = failures.Count == 0 ? "Pass" : "Fail";
                if (failures.Count != 0) allPass = false;
                string summary = Scenarios.All.Count + " scenarios, " + totalPackets + " packets "
                    + "(" + storedPkts + " stored, " + controlPkts + " control, " + malformedPkts + " malformed-rejected) "
                    + "@ " + cfg.PacketIntervalSec.ToString("F1", CultureInfo.InvariantCulture) + "s/pkt, loss " + (int)cfg.PacketLossPct + "%";
                Console.WriteLine("Cycle " + cycle + " Result:");
                Console.WriteLine("  [" + result + "] — " + (failures.Count == 0 ? summary : string.Join(" | ", failures.Take(3))));
                if (failures.Count != 0) { foreach (var f in failures.Take(8)) Console.WriteLine("      • " + f); }
            }

            // Stored-replay path: the live RunScenario routes the stored/UDP scenarios (8,9,10,11,12,21)
            // through ScenarioRunner.StoredReplay (dumped on the app's reconnect readstr), NOT inline Run().
            Console.WriteLine("Stored-replay path (RunScenario for stored/UDP scenarios):");
            foreach (var s in Scenarios.All)
            {
                bool isStored = s.Transport.TKind == Transport.TransportKind.Disconnect
                             || s.Transport.TKind == Transport.TransportKind.StoredBacklog
                             || s.Id == 12;
                if (!isStored) continue;
                var sr = ScenarioRunner.StoredReplay(s, SimConfig.Default);
                int n = sr.Count;
                bool allStored = n > 0 && sr.TrueForAll(em => em.ItemKind == Emitted.Kind.Stored);
                bool valid = true;
                foreach (var em in sr) { if (Validate(em) != null) { valid = false; break; } }
                bool ok = allStored && valid && n > 0;
                if (s.Id == 7 && n != 30) ok = false;
                if (s.Id == 8 && n != 300) ok = false;
                if (!ok) allPass = false;
                Console.WriteLine("  [" + (ok ? "OK" : "FAIL") + "] S" + s.Id + " " + s.Name + ": " + n + " backdated stored packets");
            }

            // The Unassigned-Driving fix: stored packets must be stamped INSIDE the outage window, i.e.
            // at/after the disconnect. Stamped before it, they land inside the driving event the app still
            // has open for the logged-in driver and are silently classified as already-assigned.
            Console.WriteLine("Stored-replay timestamps land inside the outage (Unassigned Driving):");
            foreach (var s in Scenarios.All)
            {
                bool isStored = s.Transport.TKind == Transport.TransportKind.Disconnect
                             || s.Transport.TKind == Transport.TransportKind.StoredBacklog
                             || s.Id == 12;
                if (!isStored) continue;
                var start = DateTime.UtcNow.AddSeconds(10);
                var sr = ScenarioRunner.StoredReplay(s, SimConfig.Default, start);
                int stamped = 0;
                foreach (var em in sr)
                {
                    var utc = ScenarioRunner.UtcOf(em.Wire);
                    if (utc.HasValue && utc.Value >= start.AddSeconds(-1)) stamped++;
                }
                bool ok = sr.Count > 0 && stamped == sr.Count;
                if (!ok) allPass = false;
                Console.WriteLine("  [" + (ok ? "OK" : "FAIL") + "] S" + s.Id + ": " + stamped + "/" + sr.Count + " stamps at/after the disconnect");
            }

            // Restart persistence: odometer and engine hours must survive a relaunch and never move
            // backwards. A rewind is the transition that freezes mileage accrual in the ELD app.
            Console.WriteLine("Restart persistence (odometer / engine hours never rewind):");
            {
                var before = new EngineState
                {
                    OdometerMiles = 25_312.5, EngineHours = 4_401.25,
                    Latitude = 25.943368, Longitude = -80.224136, FuelLevelPct = 47.1,
                };
                // Never the real LocalAppData file — a tester who runs selftest after a day of driving
                // must not lose their odometer.
                string scratch = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "MatrackSimSelfTest");
                before.Persisted.Save(scratch);

                var after = new EngineState();                   // a fresh launch starts at the defaults
                var roundTripped = SimPersistedState.Load(scratch);
                if (roundTripped != null) after.Restore(roundTripped);
                bool carried = Math.Abs(after.OdometerMiles - 25_312.5) < 0.01
                            && Math.Abs(after.EngineHours - 4_401.25) < 0.01
                            && Math.Abs(after.Latitude - 25.943368) < 0.000001;
                Console.WriteLine("  [" + (carried ? "OK" : "FAIL") + "] odo/hours/position carried across a restart");
                if (!carried) allPass = false;

                // A stale file holding LOWER values must not drag the odometer back.
                var ahead = new EngineState { OdometerMiles = 26_000, EngineHours = 4_500 };
                ahead.Restore(new SimPersistedState { OdometerMiles = 100, EngineHours = 1, FuelLevelPct = 50, FuelLevel2Pct = 50 });
                bool monotonic = ahead.OdometerMiles == 26_000 && ahead.EngineHours == 4_500;
                Console.WriteLine("  [" + (monotonic ? "OK" : "FAIL") + "] a stale lower reading cannot rewind the odometer");
                if (!monotonic) allPass = false;

                try { System.IO.Directory.Delete(scratch, true); } catch { }
            }

            // The app keeps the driver's Driving event open for ~370s after the link drops, so anything
            // recorded inside that window is classified as already assigned and vanishes. Withhold it.
            Console.WriteLine("Offline backlog withholds what the app would silently discard:");
            {
                var cfg = SimConfig.Default;
                var outageStart = new DateTime(2023, 11, 14, 22, 13, 20, DateTimeKind.Utc);
                var e = new EngineState { IgnitionOn = true, SpeedMph = 60 };
                Func<double, Emitted> rec = off => new Emitted(
                    ScenarioRunner.ToStored(MTPacket.LivePosition(e, outageStart.AddSeconds(off))), Emitted.Kind.Stored);

                var batch = new List<Emitted> { rec(30), rec(120), rec(360), rec(400), rec(600) };
                var split = ScenarioRunner.DeliverableStored(batch, outageStart, cfg.AppDrivingCloseSec);
                bool ok = split.Keep.Count == 2 && split.Dropped == 3;
                Console.WriteLine("  [" + (ok ? "OK" : "FAIL") + "] kept " + split.Keep.Count + "/5 past the " + (int)cfg.AppDrivingCloseSec + "s close, dropped " + split.Dropped);
                if (!ok) allPass = false;

                var shortBatch = new List<Emitted> { rec(30), rec(60), rec(90) };
                var shortSplit = ScenarioRunner.DeliverableStored(shortBatch, outageStart, cfg.AppDrivingCloseSec);
                bool emptied = shortSplit.Keep.Count == 0 && shortSplit.Dropped == 3;
                Console.WriteLine("  [" + (emptied ? "OK" : "FAIL") + "] a sub-" + (int)cfg.AppDrivingCloseSec + "s outage delivers nothing");
                if (!emptied) allPass = false;

                var junk = new List<Emitted> { new Emitted("GARBAGE", Emitted.Kind.Stored) };
                var junkSplit = ScenarioRunner.DeliverableStored(junk, outageStart, cfg.AppDrivingCloseSec);
                bool keptJunk = junkSplit.Keep.Count == 1 && junkSplit.Dropped == 0;
                Console.WriteLine("  [" + (keptJunk ? "OK" : "FAIL") + "] an unparseable record is kept, not dropped");
                if (!keptJunk) allPass = false;

                bool clears = cfg.StoredReplayLeadInSec > cfg.AppDrivingCloseSec;
                Console.WriteLine("  [" + (clears ? "OK" : "FAIL") + "] scenario lead-in " + (int)cfg.StoredReplayLeadInSec + "s clears the " + (int)cfg.AppDrivingCloseSec + "s close");
                if (!clears) allPass = false;
            }

            // Operator-entered telemetry must never reach the packet builder as a trapping value.
            Console.WriteLine("Telemetry edit bounds:");
            {
                double[] bad = { double.PositiveInfinity, double.NegativeInfinity, double.NaN, -1, 1e30, SimConfig.MaxOdometerMiles + 1 };
                bool rejected = true;
                foreach (var v in bad) if (SimConfig.IsValidOdometer(v)) rejected = false;
                bool good = SimConfig.IsValidOdometer(25_000) && SimConfig.IsValidOdometer(0)
                         && SimConfig.IsValidOdometer(SimConfig.MaxOdometerMiles);
                Console.WriteLine("  [" + (rejected && good ? "OK" : "FAIL") + "] odometer rejects inf/nan/negative/oversize, accepts the real range");
                if (!(rejected && good)) allPass = false;

                bool hoursOk = !SimConfig.IsValidEngineHours(double.NaN) && !SimConfig.IsValidEngineHours(1e12)
                            && SimConfig.IsValidEngineHours(4_352.5);
                Console.WriteLine("  [" + (hoursOk ? "OK" : "FAIL") + "] engine hours rejects nan/oversize, accepts the real range");
                if (!hoursOk) allPass = false;

                var ceil = new EngineState { OdometerMiles = SimConfig.MaxOdometerMiles, EngineHours = SimConfig.MaxEngineHours };
                var fields = MTPacket.LivePosition(ceil).Split(',');
                bool buildable = fields.Length == 17 && int.TryParse(fields[4], out _) && int.TryParse(fields[5], out _);
                Console.WriteLine("  [" + (buildable ? "OK" : "FAIL") + "] the ceiling values still build a valid 17-field packet");
                if (!buildable) allPass = false;
            }

            // A truncated state file must be rejected outright, not silently zeroed (that makes
            // OutOfFuel true and DRIVE do nothing).
            {
                bool partialRejected = SimPersistedState.FromJson("{\"odometerMiles\":1,\"engineHours\":2}") == null;
                Console.WriteLine("  [" + (partialRejected ? "OK" : "FAIL") + "] a truncated state file is rejected, not zero-filled");
                if (!partialRejected) allPass = false;
            }

            Console.WriteLine("────────────────────────────────────────────────────────────");
            Console.WriteLine(allPass ? "ALL CYCLES PASS ✓" : "FAILURES PRESENT ✗");
            return allPass ? 0 : 1;
        }

        // MARK: per-packet validation against the app-mirrored decoder
        private static string Validate(Emitted em)
        {
            switch (em.ItemKind)
            {
                case Emitted.Kind.Raw:
                    return MTDecoder.IsValid(em.Wire) ? null : "control reply not recognized by app: '" + em.Wire + "'";
                case Emitted.Kind.Malformed:
                    return MTDecoder.IsValid(em.Wire) ? "malformed packet wrongly accepted: '" + em.Wire + "'" : null;
                case Emitted.Kind.Live:
                case Emitted.Kind.Stored:
                case Emitted.Kind.Ignition:
                {
                    var frames = MTPacket.Frame(em.Wire);
                    if (frames.Count > 9) return "too many chunks (" + frames.Count + " > 9): '" + em.Wire + "'";
                    foreach (var fr in frames)
                    {
                        string s = AsciiOrNull(fr);
                        if (s == null) return "chunk not ASCII";
                        if (!MTDecoder.IsValid(s)) return "chunk rejected by app validator: '" + s + "'";
                    }
                    var reassembled = MTDecoder.Reassemble(frames);
                    if (reassembled == null) return "reassembly failed: '" + em.Wire + "'";
                    if (reassembled != em.Wire) return "reassembly mismatch: '" + reassembled + "' != '" + em.Wire + "'";
                    var d = MTDecoder.Decode(reassembled);
                    if (d == null) return "decode failed: '" + em.Wire + "'";
                    if (!MTDecoder.ValidPrefixes.Contains(d.Type)) return "unknown packet type '" + d.Type + "'";
                    return null;
                }
                default:
                    return null;
            }
        }

        // MARK: scenario-level invariants
        private static string ScenarioInvariant(Scenario s, List<Emitted> em)
        {
            switch (s.Id)
            {
                case 2:   // engine off → at least one shutdown (ignition 0) ignition packet
                {
                    bool hasShutdown = em.Any(x =>
                    {
                        if (x.ItemKind != Emitted.Kind.Ignition) return false;
                        var dec = MTDecoder.Decode(x.Wire);
                        return dec != null && dec.Ignition == 0;
                    });
                    return hasShutdown ? null : "expected a shutdown (ignition=0) event";
                }
                case 6:   // disconnect → stored replay present (inline Run() output)
                {
                    int stored = em.Count(x => x.ItemKind == Emitted.Kind.Stored);
                    bool marker = em.Any(x => x.Wire.StartsWith("LAST_STORED_PACKET", StringComparison.Ordinal));
                    return (stored > 0 && marker) ? null : "expected stored replay after reconnect (got " + stored + " stored)";
                }
                case 7:
                {
                    int stored = em.Count(x => x.ItemKind == Emitted.Kind.Stored);
                    return stored == 30 ? null : "expected 30 stored backlog packets, got " + stored;
                }
                case 8:
                {
                    int stored = em.Count(x => x.ItemKind == Emitted.Kind.Stored);
                    return stored == 300 ? null : "expected 300 stored backlog packets, got " + stored;
                }
                case 9:   // duplicates: some consecutive identical wires
                {
                    bool dup = false;
                    for (int i = 1; i < Math.Max(1, em.Count); i++)
                    {
                        if (em[i].Wire == em[i - 1].Wire && em[i].ItemKind == Emitted.Kind.Live) { dup = true; break; }
                    }
                    return dup ? null : "expected duplicate packets";
                }
                case 11:   // parse failure injected + rejected
                    return em.Any(x => x.ItemKind == Emitted.Kind.Malformed) ? null : "expected an injected malformed packet";
                default:
                    // every scenario must emit at least one valid live packet
                    return em.Any(x => x.ItemKind == Emitted.Kind.Live) ? null : "no live packets emitted";
            }
        }

        // MARK: encoder↔decoder round-trip on known values
        private static string RoundTripUnit()
        {
            var e = new EngineState();
            e.IgnitionOn = true; e.SpeedMph = 63.5; e.OdometerMiles = 70_123.0;
            e.EngineHours = 5_001.25; e.Satellites = 9; e.IdleRpmConfig = 700; e.RpmPerMphConfig = 26;
            e.Rpm = 700 + (int)(63.5 * 26);
            string lp = MTPacket.LivePosition(e);
            var d = MTDecoder.Decode(lp);
            if (d == null) return "LP decode nil";
            if (d.Type != "LP") return "type " + d.Type;
            if (Math.Abs((d.SpeedMph ?? -1) - 63.5) > 1.0) return "speed " + (d.SpeedMph ?? -1);
            if (Math.Abs((d.OdometerMiles ?? -1) - 70_123.0) > 1.0) return "odo " + (d.OdometerMiles ?? -1);
            if (Math.Abs((d.EngineHours ?? -1) - 5_001.25) > 0.02) return "engHrs " + (d.EngineHours ?? -1);
            if (d.Ignition != 1) return "ignition " + (d.Ignition ?? -1);
            if (d.Sats != 9) return "sats " + (d.Sats ?? -1);
            if (d.GpsLocked != true) return "gpsLock";

            var dev = new DeviceInfo(); dev.DtcCodes = new List<string> { "P0143", "U0101" };
            var lv = MTDecoder.Decode(MTPacket.Version(dev));
            if (lv == null) return "LV decode nil";
            if (lv.Vin != dev.Vin) return "vin " + (lv.Vin ?? "");
            if (lv.McuFW != dev.McuFW) return "mcuFW " + (lv.McuFW ?? "");
            var ld = MTDecoder.Decode(MTPacket.Dtc(dev.DtcCodes, 1, 700));
            if (ld == null) return "LD decode nil";
            if (ld.DtcCount != 2) return "dtcCount " + (ld.DtcCount ?? -1);
            if (ld.DtcBlob != "0143C101") return "dtcBlob " + (ld.DtcBlob ?? "");
            return null;
        }

        // MARK: deterministic config per cycle (varies coverage)
        private static SimConfig ConfigForCycle(int cycle)
        {
            var c = SimConfig.Default;
            c.PacketIntervalSec = new double[] { 1.0, 0.5, 2.0, 1.0, 0.25, 1.5, 1.0, 0.5, 1.0, 1.0 }[cycle - 1];
            c.TargetSpeedMph = new double[] { 65, 55, 70, 45, 65, 60, 75, 50, 65, 62 }[cycle - 1];
            c.PacketLossPct = (double)new int[] { 0, 0, 10, 0, 20, 0, 5, 0, 0, 0 }[cycle - 1];
            c.AccelMphPerSec = new double[] { 4, 6, 3, 5, 4, 4, 8, 4, 4, 4 }[cycle - 1];
            return c;
        }

        /// <summary>Mirrors Swift String(data:encoding:.ascii) — null if any byte is non-ASCII.</summary>
        private static string AsciiOrNull(byte[] data)
        {
            if (data == null) return null;
            foreach (var b in data) if (b > 0x7F) return null;
            return Encoding.ASCII.GetString(data);
        }
    }
}
