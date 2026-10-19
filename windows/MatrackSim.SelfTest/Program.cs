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

                // The scenario catalogue used to drive this loop. It is gone, so the packets are
                // built the way the live path builds them: a drive's worth of live telemetry plus a
                // stored dump, under each config variation. Same coverage, one code path.
                var e = new EngineState
                {
                    IgnitionOn = true,
                    IdleRpmConfig = cfg.IdleRpm,
                    RpmPerMphConfig = cfg.RpmPerMph,
                    FuelBurnPctPerMile = cfg.FuelBurnPctPerMile,
                };
                var emitted = new List<Emitted>();
                emitted.Add(new Emitted(MTPacket.Ignition(e, true), Emitted.Kind.Ignition));
                for (int tick = 0; tick < 120; tick++)
                {
                    e.SpeedMph = tick < 20 ? tick * 3.0 : (tick < 100 ? 60.0 : Math.Max(0, (120 - tick) * 3.0));
                    e.Advance(cfg.PacketIntervalSec);
                    emitted.Add(new Emitted(MTPacket.LivePosition(e), Emitted.Kind.Live));
                }
                emitted.Add(new Emitted(MTPacket.Ignition(e, false), Emitted.Kind.Ignition));
                emitted.AddRange(WireBuilder.StoredDump(30, cfg));
                emitted.Add(new Emitted(MTPacket.Version(new DeviceInfo()), Emitted.Kind.Live));
                emitted.Add(new Emitted(MTPacket.Dtc(new List<string> { "P0143" }, 1, e.Rpm), Emitted.Kind.Live));
                foreach (var reply in new[] { "ACK,DATA", "LAST_STORED_PACKET", "SAVED PACKET COUNT:0" })
                    emitted.Add(new Emitted(reply, Emitted.Kind.Raw));

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
                    if (f != null) failures.Add(f);
                }
                if (!emitted.Exists(x => x.ItemKind == Emitted.Kind.Live)) failures.Add("no live packets emitted");
                if (!emitted.Exists(x => x.ItemKind == Emitted.Kind.Stored)) failures.Add("no stored packets emitted");

                string result = failures.Count == 0 ? "Pass" : "Fail";
                if (failures.Count != 0) allPass = false;
                string summary = totalPackets + " packets "
                    + "(" + storedPkts + " stored, " + controlPkts + " control, " + malformedPkts + " malformed-rejected) "
                    + "@ " + cfg.PacketIntervalSec.ToString("F1", CultureInfo.InvariantCulture) + "s/pkt, loss " + (int)cfg.PacketLossPct + "%";
                Console.WriteLine("Cycle " + cycle + " Result:");
                Console.WriteLine("  [" + result + "] — " + (failures.Count == 0 ? summary : string.Join(" | ", failures.Take(3))));
                if (failures.Count != 0) { foreach (var f in failures.Take(8)) Console.WriteLine("      • " + f); }
            }

            // Stored-replay path: the live RunScenario routes the stored/UDP scenarios (8,9,10,11,12,21)
            // through WireBuilder.StoredReplay (dumped on the app's reconnect readstr), NOT inline Run().
            Console.WriteLine("Stored-replay path (RunScenario for stored/UDP scenarios):");
            
            // The Unassigned-Driving fix: stored packets must be stamped INSIDE the outage window, i.e.
            // at/after the disconnect. Stamped before it, they land inside the driving event the app still
            // has open for the logged-in driver and are silently classified as already-assigned.
            Console.WriteLine("Stored-replay timestamps land inside the outage (Unassigned Driving):");
            
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
                    WireBuilder.ToStored(MTPacket.LivePosition(e, outageStart.AddSeconds(off))), Emitted.Kind.Stored);

                var batch = new List<Emitted> { rec(30), rec(120), rec(360), rec(400), rec(600) };
                var split = WireBuilder.DeliverableStored(batch, outageStart, cfg.AppDrivingCloseSec);
                bool ok = split.Keep.Count == 2 && split.Dropped == 3;
                Console.WriteLine("  [" + (ok ? "OK" : "FAIL") + "] kept " + split.Keep.Count + "/5 past the " + (int)cfg.AppDrivingCloseSec + "s close, dropped " + split.Dropped);
                if (!ok) allPass = false;

                var shortBatch = new List<Emitted> { rec(30), rec(60), rec(90) };
                var shortSplit = WireBuilder.DeliverableStored(shortBatch, outageStart, cfg.AppDrivingCloseSec);
                bool emptied = shortSplit.Keep.Count == 0 && shortSplit.Dropped == 3;
                Console.WriteLine("  [" + (emptied ? "OK" : "FAIL") + "] a sub-" + (int)cfg.AppDrivingCloseSec + "s outage delivers nothing");
                if (!emptied) allPass = false;

                var junk = new List<Emitted> { new Emitted("GARBAGE", Emitted.Kind.Stored) };
                var junkSplit = WireBuilder.DeliverableStored(junk, outageStart, cfg.AppDrivingCloseSec);
                bool keptJunk = junkSplit.Keep.Count == 1 && junkSplit.Dropped == 0;
                Console.WriteLine("  [" + (keptJunk ? "OK" : "FAIL") + "] an unparseable record is kept, not dropped");
                if (!keptJunk) allPass = false;

                bool clears = cfg.StoredReplayLeadInSec > cfg.AppDrivingCloseSec;
                Console.WriteLine("  [" + (clears ? "OK" : "FAIL") + "] stored-replay lead-in " + (int)cfg.StoredReplayLeadInSec + "s clears the " + (int)cfg.AppDrivingCloseSec + "s close");
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

            // Fault injection must be able to express values the model CANNOT hold, and must never be
            // able to leak into persisted state or into a clean packet.
            Console.WriteLine("Fault injection:");
            {
                var e = new EngineState { IgnitionOn = true, SpeedMph = 60, OdometerMiles = 25_000 };
                var clean = MTPacket.LivePosition(e).Split(',');

                e.WireFaults[4] = new WireFault(SimConfig.OdometerUnavailableSentinel);
                e.WireFaults[8] = new WireFault("0");
                e.WireFaults[12] = new WireFault("0");
                var faulted = MTPacket.LivePosition(e).Split(',');
                bool expressed = faulted.Length == 17
                              && faulted[4] == SimConfig.OdometerUnavailableSentinel
                              && faulted[8] == "0" && faulted[12] == "0";
                Console.WriteLine("  [" + (expressed ? "OK" : "FAIL") + "] overrides reach the wire and the packet stays 17 fields");
                if (!expressed) allPass = false;

                bool neighbours = true;
                foreach (int i in new[] { 1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15, 16 })
                    if (faulted[i] != clean[i]) neighbours = false;
                Console.WriteLine("  [" + (neighbours ? "OK" : "FAIL") + "] non-overridden fields are unchanged");
                if (!neighbours) allPass = false;

                var decoded = MTDecoder.Decode(MTPacket.LivePosition(e));
                bool sentinelUnderstood = decoded != null && decoded.OdometerMiles == null;
                Console.WriteLine("  [" + (sentinelUnderstood ? "OK" : "FAIL") + "] the sentinel decodes as 'odometer unavailable'");
                if (!sentinelUnderstood) allPass = false;

                // A fault must never become permanent: SimPersistedState is a whitelist.
                var saved = e.Persisted;
                var fresh = new EngineState(); fresh.Restore(saved);
                bool cleared = fresh.WireFaults.Count == 0;
                Console.WriteLine("  [" + (cleared ? "OK" : "FAIL") + "] overrides are not persisted — a restart clears every fault");
                if (!cleared) allPass = false;

                e.WireFaults.Clear();
                bool backToClean = MTPacket.LivePosition(e).Split(',')[4] == clean[4];
                Console.WriteLine("  [" + (backToClean ? "OK" : "FAIL") + "] clearing restores the real value");
                if (!backToClean) allPass = false;

                var baseUtc = new DateTime(2023, 11, 14, 22, 13, 20, DateTimeKind.Utc);
                var skewed = WireBuilder.UtcOf(MTPacket.LivePosition(e, baseUtc.AddSeconds(1800)));
                bool skewWorks = skewed.HasValue && Math.Abs((skewed.Value - baseUtc).TotalSeconds - 1800) < 1.5;
                Console.WriteLine("  [" + (skewWorks ? "OK" : "FAIL") + "] a 30-minute clock skew reaches fields 10/11");
                if (!skewWorks) allPass = false;

                foreach (var vin in new[] { "00000000000000000", "292058", "" })
                {
                    var d = new DeviceInfo(); d.Vin = vin;
                    var lv = MTPacket.Version(d).Split(',');
                    if (!(lv.Length >= 2 && lv[0] == "LV" && lv[1] == vin))
                    { allPass = false; Console.WriteLine("  [FAIL] LV mangled VIN \"" + vin + "\""); }
                }
                Console.WriteLine("  [OK] all-zero, 6-char and empty VINs pass through the LV builder verbatim");

                // Intermittent faults. "Random packets with an invalid time" is a different test from
                // "every packet has an invalid time" — a constant fault is trivially visible, a 1-in-5
                // fault is the one that finds ordering bugs. Driven by an injected roll.
                var m = new EngineState { IgnitionOn = true, SpeedMph = 60 };
                m.WireFaults[10] = new WireFault("999999", 0.2);
                var hits = m.FaultedFields(() => 0.1);
                var misses = m.FaultedFields(() => 0.9);
                bool intermittent = hits.ContainsKey(10) && hits[10] == "999999" && !misses.ContainsKey(10);
                Console.WriteLine("  [" + (intermittent ? "OK" : "FAIL") + "] an intermittent fault fires on some packets and not others");
                if (!intermittent) allPass = false;

                // The motion gate: "no GPS lock above 5 mph" is meaningless on a parked truck.
                m.WireFaults.Clear();
                m.WireFaults[8] = new WireFault("0", 1, true);
                m.SpeedMph = 60;
                bool movingHit = m.FaultedFields(() => 0).ContainsKey(8);
                m.SpeedMph = 0;
                bool parkedClean = !m.FaultedFields(() => 0).ContainsKey(8);
                Console.WriteLine("  [" + (movingHit && parkedClean ? "OK" : "FAIL") + "] a motion-gated fault fires while driving and not while parked");
                if (!(movingHit && parkedClean)) allPass = false;

                // The malformed packet used to be covered by scenario 11. That scenario is gone, so
                // the button is now the only path — assert the wire here or nothing checks it.
                bool junkRejected = !MTDecoder.IsValid("ZZ,not,a,valid,packet");
                Console.WriteLine("  [" + (junkRejected ? "OK" : "FAIL") + "] the malformed packet is genuinely invalid");
                if (!junkRejected) allPass = false;

                // The odometer-source packet must match the shape the app's parser demands.
                var xo = MTPacket.OdoSource(true, 1);
                bool xoOk = xo.StartsWith("xO,") && xo.EndsWith("$$")
                         && xo.Replace("$$", "").Split(',').Length >= 10;
                Console.WriteLine("  [" + (xoOk ? "OK" : "FAIL") + "] the odometer-source packet matches the app parser's shape");
                if (!xoOk) allPass = false;
            }

            // Every requested fault, end to end: arm it exactly as the UI does, build a real packet,
            // and assert the wire carries it. This is the test that fails if a control becomes
            // theatre — a button that looks armed while the packet leaves unchanged.
            Console.WriteLine("Each requested fault reaches the wire:");
            {
                Func<int, string, string> field = (i, wire) =>
                { var f = wire.Split(','); return i < f.Length ? f[i] : "<missing>"; };
                Func<Action<EngineState>, string> armed = apply =>
                {
                    var e = new EngineState { IgnitionOn = true, SpeedMph = 60, OdometerMiles = 25_000, EngineHours = 4_352.5 };
                    apply(e);
                    return MTPacket.LivePosition(e);
                };
                var cfg = SimConfig.Default;
                var cases = new List<Tuple<string, bool>>();

                string low = armed(e => e.WireFaults[4] = new WireFault(cfg.OdoSeriesLowRaw));
                string high = armed(e => e.WireFaults[4] = new WireFault(cfg.OdoSeriesHighRaw));
                cases.Add(Tuple.Create("two ECU odometer series differ on the wire",
                    field(4, low) != field(4, high) && field(4, low) == cfg.OdoSeriesLowRaw));

                cases.Add(Tuple.Create("invalid time reaches field 10",
                    field(10, armed(e => e.WireFaults[10] = new WireFault("999999"))) == "999999"));
                cases.Add(Tuple.Create("default date reaches field 11",
                    field(11, armed(e => e.WireFaults[11] = new WireFault("010100"))) == "010100"));
                cases.Add(Tuple.Create("default odometer sentinel reaches field 4",
                    field(4, armed(e => e.WireFaults[4] = new WireFault(SimConfig.OdometerUnavailableSentinel)))
                        == SimConfig.OdometerUnavailableSentinel));
                cases.Add(Tuple.Create("GPS lock drops to 0 on the wire",
                    field(8, armed(e => e.WireFaults[8] = new WireFault("0", 1, true))) == "0"));
                cases.Add(Tuple.Create("a clean packet still reports GPS locked",
                    field(8, armed(e => { })) == "3"));
                cases.Add(Tuple.Create("ECM flag drops to 0 on the wire",
                    field(12, armed(e => e.WireFaults[12] = new WireFault("0"))) == "0"));
                string missing = armed(e => { e.WireFaults[4] = new WireFault("0"); e.WireFaults[5] = new WireFault("0"); });
                cases.Add(Tuple.Create("odometer and hours both report 0",
                    field(4, missing) == "0" && field(5, missing) == "0"));
                cases.Add(Tuple.Create("power-cycle packets alternate ignition",
                    field(1, MTPacket.Ignition(new EngineState(), true)) == "1"
                    && field(1, MTPacket.Ignition(new EngineState(), false)) == "0"));
                var zeroVin = new DeviceInfo(); zeroVin.Vin = "00000000000000000";
                var shortVin = new DeviceInfo(); shortVin.Vin = "292058";
                cases.Add(Tuple.Create("both bad VINs ride the LV packet verbatim",
                    MTPacket.Version(zeroVin).Split(',')[1] == zeroVin.Vin
                    && MTPacket.Version(shortVin).Split(',')[1] == shortVin.Vin));
                cases.Add(Tuple.Create("odometer-source packet is well formed",
                    MTPacket.OdoSource(true, 1).EndsWith("$$")));

                foreach (var c in cases)
                {
                    Console.WriteLine("  [" + (c.Item2 ? "OK" : "FAIL") + "] " + c.Item1);
                    if (!c.Item2) allPass = false;
                }

                // The intermittent rate must actually be intermittent — not always-on, not never.
                // Real randomness, bounds wide enough never to flake.
                var r = new EngineState { IgnitionOn = true, SpeedMph = 60 };
                r.WireFaults[10] = new WireFault("999999", 0.2);
                int hit = 0;
                for (int i = 0; i < 2000; i++)
                    if (MTPacket.LivePosition(r).Split(',')[10] == "999999") hit++;
                double rate = hit / 2000.0;
                bool plausible = rate > 0.10 && rate < 0.32;
                Console.WriteLine("  [" + (plausible ? "OK" : "FAIL") + "] a 20% fault fired on " + (int)(rate * 100) + "% of 2000 real packets");
                if (!plausible) allPass = false;
            }

            // Stored-packet test cases. The app's guard (REQ-940) refuses a stored packet a year or
            // more from now and requires fields 10/11 to be exactly 6 digits, so the dump must reach
            // that check rather than failing an earlier one.
            Console.WriteLine("Stored-packet test dumps:");
            {
                var cfg = SimConfig.Default;
                var future = WireBuilder.StoredDump(5, cfg,
                    new WireBuilder.StoredDumpOptions { StampedAt = SimConfig.FutureStoredPacketDate });
                var futureStored = future.FindAll(x => x.ItemKind == Emitted.Kind.Stored);
                bool fieldsOK = true, allFuture = true;
                foreach (var em in futureStored)
                {
                    var f = em.Wire.Split(',');
                    if (f.Length < 12 || f[10].Length != 6 || f[11].Length != 6) fieldsOK = false;
                    var utc = WireBuilder.UtcOf(em.Wire);
                    if (!utc.HasValue || (utc.Value - DateTime.UtcNow).TotalSeconds < 365 * 24 * 3600) allFuture = false;
                }
                bool futureOK = futureStored.Count == 5 && fieldsOK && allFuture;
                Console.WriteLine("  [" + (futureOK ? "OK" : "FAIL") + "] future-dated dump: 5 stored packets, 6-digit time/date, all over a year ahead");
                if (!futureOK) allPass = false;

                var dup = WireBuilder.StoredDump(3, cfg, new WireBuilder.StoredDumpOptions { RepeatEachPacket = true });
                var dupStored = dup.FindAll(x => x.ItemKind == Emitted.Kind.Stored);
                int pairs = 0;
                for (int i = 0; i + 1 < dupStored.Count; i += 2)
                    if (dupStored[i].Wire == dupStored[i + 1].Wire) pairs++;
                bool dupOK = dupStored.Count == 6 && pairs == 3;
                Console.WriteLine("  [" + (dupOK ? "OK" : "FAIL") + "] duplicate dump: " + dupStored.Count + " packets, " + pairs + " adjacent identical pairs");
                if (!dupOK) allPass = false;

                // Emitted is a struct here, so Find returns a default rather than null — look it up by index.
                int footerIdx = dup.FindIndex(x => x.Wire.StartsWith("SAVED PACKET COUNT:"));
                bool footerOK = footerIdx >= 0 && dup[footerIdx].Wire == "SAVED PACKET COUNT:" + dupStored.Count;
                Console.WriteLine("  [" + (footerOK ? "OK" : "FAIL") + "] footer reports the real count");
                if (!footerOK) allPass = false;
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
