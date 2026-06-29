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

    /// <summary>A timed driving phase.</summary>
    public struct Phase
    {
        public double Seconds;
        public double TargetSpeedMph;
        public bool Ignition;

        public Phase(double seconds, double targetSpeedMph, bool ignition)
        {
            Seconds = seconds;
            TargetSpeedMph = targetSpeedMph;
            Ignition = ignition;
        }
    }

    /// <summary>
    /// Transport behavior overlaid on the packet stream (deterministic for repeatable tests).
    /// Swift enum-with-associated-values ported to a kind tag + parameter fields.
    /// </summary>
    public struct Transport : IEquatable<Transport>
    {
        public enum TransportKind { Clean, PacketLoss, Duplicate, OutOfOrder, Disconnect, StoredBacklog, ParseFailure }

        public TransportKind TKind;
        public int EveryN;       // packetLoss / duplicate / outOfOrder
        public double AfterSec;  // disconnect
        public double GapSec;    // disconnect
        public int Count;        // storedBacklog
        public int AtTick;       // parseFailure

        public static Transport Clean()
        {
            return new Transport { TKind = TransportKind.Clean };
        }

        public static Transport PacketLoss(int everyN)
        {
            return new Transport { TKind = TransportKind.PacketLoss, EveryN = everyN };
        }

        public static Transport Duplicate(int everyN)
        {
            return new Transport { TKind = TransportKind.Duplicate, EveryN = everyN };
        }

        public static Transport OutOfOrder(int everyN)
        {
            return new Transport { TKind = TransportKind.OutOfOrder, EveryN = everyN };
        }

        // buffer during outage → replay as stored on reconnect (interval-independent)
        public static Transport Disconnect(double afterSec, double gapSec)
        {
            return new Transport { TKind = TransportKind.Disconnect, AfterSec = afterSec, GapSec = gapSec };
        }

        // pre-existing stored packets delivered up front
        public static Transport StoredBacklog(int count)
        {
            return new Transport { TKind = TransportKind.StoredBacklog, Count = count };
        }

        // inject a malformed packet the app must reject
        public static Transport ParseFailure(int atTick)
        {
            return new Transport { TKind = TransportKind.ParseFailure, AtTick = atTick };
        }

        public bool Equals(Transport other)
        {
            if (TKind != other.TKind) return false;
            switch (TKind)
            {
                case TransportKind.PacketLoss:
                case TransportKind.Duplicate:
                case TransportKind.OutOfOrder:
                    return EveryN == other.EveryN;
                case TransportKind.Disconnect:
                    return AfterSec == other.AfterSec && GapSec == other.GapSec;
                case TransportKind.StoredBacklog:
                    return Count == other.Count;
                case TransportKind.ParseFailure:
                    return AtTick == other.AtTick;
                default:
                    return true;
            }
        }

        public override bool Equals(object obj)
        {
            return obj is Transport other && Equals(other);
        }

        public override int GetHashCode()
        {
            int h = (int)TKind;
            h = (h * 397) ^ EveryN;
            h = (h * 397) ^ AfterSec.GetHashCode();
            h = (h * 397) ^ GapSec.GetHashCode();
            h = (h * 397) ^ Count;
            h = (h * 397) ^ AtTick;
            return h;
        }
    }

    public struct Scenario
    {
        public int Id;
        public string Name;
        public string Expect;
        public List<Phase> Phases;
        public Transport Transport;
        public List<string> AppSteps;

        public Scenario(int id, string name, string expect, List<Phase> phases,
                        Transport? transport = null, List<string> appSteps = null)
        {
            Id = id;
            Name = name;
            Expect = expect;
            Phases = phases;
            Transport = transport ?? MatrackSim.Core.Transport.Clean();
            AppSteps = appSteps ?? new List<string>();
        }

        // Shown directly in the WPF scenario ComboBox (which displays each item via ToString()).
        // Matches the macOS Menu label format exactly: "5. Driving highway".
        public override string ToString() => string.IsNullOrEmpty(Name) ? base.ToString() : $"{Id}. {Name}";
    }

    /// <summary>
    /// Deterministically simulates a scenario tick-by-tick and returns the exact wire sequence.
    /// Shares the real packet builders (MTPacket) so output is byte-identical to the live sim.
    /// </summary>
    public static class ScenarioRunner
    {
        public static List<Emitted> Run(Scenario s, SimConfig config)
        {
            var e = new EngineState();
            e.OdometerMiles = config.StartOdometerMiles;
            e.EngineHours = config.StartEngineHours;
            e.FuelLevelPct = config.StartFuelPct;
            e.IdleRpmConfig = config.IdleRpm;
            e.RpmPerMphConfig = config.RpmPerMph;
            e.FuelBurnPctPerMile = config.FuelBurnPctPerMile;
            e.IgnitionOn = false;

            var output = new List<Emitted>();
            bool? lastIgn = null;
            int tick = 0;
            string held = null;
            var buffer = new List<string>();   // packets captured while "disconnected"
            double dt = config.PacketIntervalSec;

            // Disconnect window resolved to ticks from time (interval-independent).
            int dcAt = -1, dcGap = 0;
            if (s.Transport.TKind == Transport.TransportKind.Disconnect)
            {
                dcAt = (int)Math.Round(s.Transport.AfterSec / dt, MidpointRounding.AwayFromZero);
                dcGap = Math.Max(1, (int)Math.Round(s.Transport.GapSec / dt, MidpointRounding.AwayFromZero));
            }
            bool storedFlushed = false;

            Action flushBuffer = () =>
            {
                if (buffer.Count == 0) return;
                foreach (var p in buffer) output.Add(new Emitted(ToStored(p), Emitted.Kind.Stored));
                output.Add(new Emitted("LAST_STORED_PACKET", Emitted.Kind.Raw));
                output.Add(new Emitted("SAVED PACKET COUNT:" + buffer.Count.ToString(CultureInfo.InvariantCulture), Emitted.Kind.Raw));
                buffer.Clear();
                storedFlushed = true;
            };

            // pre-existing stored backlog delivered first
            if (s.Transport.TKind == Transport.TransportKind.StoredBacklog)
            {
                int count = s.Transport.Count;
                for (int i = 0; i < count; i++)
                {
                    e.Advance(dt);
                    string stored = ToStored(MTPacket.LivePosition(e, Backdated(i, count, dt)));
                    output.Add(new Emitted(stored, Emitted.Kind.Stored));
                }
                output.Add(new Emitted("LAST_STORED_PACKET", Emitted.Kind.Raw));
                output.Add(new Emitted("SAVED PACKET COUNT:" + count.ToString(CultureInfo.InvariantCulture), Emitted.Kind.Raw));
            }

            foreach (var phase in s.Phases)
            {
                int ticks = Math.Max(1, (int)Math.Round(phase.Seconds / dt, MidpointRounding.AwayFromZero));
                for (int t = 0; t < ticks; t++)
                {
                    e.IgnitionOn = phase.Ignition;
                    RampSpeed(e, phase.TargetSpeedMph, config);
                    e.Advance(dt * config.TimeMultiplier);

                    // disconnect window?
                    bool disconnected = (dcAt >= 0 && tick >= dcAt && tick < dcAt + dcGap);

                    // ignition change → LI event
                    if (lastIgn != e.IgnitionOn)
                    {
                        string li = MTPacket.Ignition(e, e.IgnitionOn);
                        RouteEmit(li, Emitted.Kind.Ignition, disconnected, buffer, output, ref held, tick, s.Transport);
                        lastIgn = e.IgnitionOn;
                    }

                    // parse-failure injection
                    if (s.Transport.TKind == Transport.TransportKind.ParseFailure && tick == s.Transport.AtTick)
                    {
                        output.Add(new Emitted("ZZ,not,a,valid,packet", Emitted.Kind.Malformed));
                    }

                    string lp = MTPacket.LivePosition(e);
                    RouteEmit(lp, Emitted.Kind.Live, disconnected, buffer, output, ref held, tick, s.Transport);

                    // reconnect boundary → flush buffered as stored
                    if (dcAt >= 0 && tick == dcAt + dcGap - 1) flushBuffer();
                    tick += 1;
                }
            }
            if (held != null) output.Add(new Emitted(held, Emitted.Kind.Live));   // flush any held out-of-order packet
            if (dcAt >= 0 && !storedFlushed) flushBuffer();                         // outage outlasted the run → replay at end
            return output;
        }

        // MARK: helpers
        private static void RampSpeed(EngineState e, double target, SimConfig config)
        {
            if (e.SpeedMph < target)
                e.SpeedMph = Math.Min(target, e.SpeedMph + config.AccelMphPerSec * config.PacketIntervalSec);
            else if (e.SpeedMph > target)
                e.SpeedMph = Math.Max(target, e.SpeedMph - config.DecelMphPerSec * config.PacketIntervalSec);
        }

        private static void RouteEmit(string wire, Emitted.Kind kind, bool disconnected,
                                      List<string> buffer, List<Emitted> output, ref string held,
                                      int tick, Transport transport)
        {
            if (disconnected) { buffer.Add(wire); return; }
            switch (transport.TKind)
            {
                case Transport.TransportKind.PacketLoss when transport.EveryN > 0 && tick % transport.EveryN == 0:
                    return;  // dropped in flight
                case Transport.TransportKind.Duplicate when transport.EveryN > 0 && tick % transport.EveryN == 0:
                    output.Add(new Emitted(wire, kind));
                    output.Add(new Emitted(wire, kind));
                    break;
                case Transport.TransportKind.OutOfOrder when transport.EveryN > 0 && tick % transport.EveryN == 0 && held == null:
                    held = wire;  // hold; flushed after the next emit
                    break;
                default:
                    output.Add(new Emitted(wire, kind));
                    if (held != null) { string h = held; held = null; output.Add(new Emitted(h, kind)); }
                    break;
            }
        }

        public static string ToStored(string live)
        {
            if (string.IsNullOrEmpty(live) || live[0] != 'L') return live;
            return "S" + live.Substring(1);
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
        public static List<Emitted> StoredReplay(Scenario s, SimConfig config)
        {
            var e = new EngineState();
            e.OdometerMiles = config.StartOdometerMiles;
            e.EngineHours = config.StartEngineHours;
            e.FuelLevelPct = config.StartFuelPct;
            e.IdleRpmConfig = config.IdleRpm;
            e.RpmPerMphConfig = config.RpmPerMph;
            e.FuelBurnPctPerMile = config.FuelBurnPctPerMile;
            double dt = config.PacketIntervalSec;
            var output = new List<Emitted>();
            if (s.Transport.TKind == Transport.TransportKind.StoredBacklog)
            {
                e.IgnitionOn = true;
                int count = Math.Max(0, s.Transport.Count);
                for (int i = 0; i < count; i++)
                {
                    e.Advance(dt);
                    output.Add(new Emitted(ToStored(MTPacket.LivePosition(e, Backdated(i, count, dt))), Emitted.Kind.Stored));
                }
                return output;
            }
            int total = 0;
            foreach (var p in s.Phases) total += Math.Max(1, (int)Math.Round(p.Seconds / dt, MidpointRounding.AwayFromZero));
            int idx = 0;
            foreach (var phase in s.Phases)
            {
                int ticks = Math.Max(1, (int)Math.Round(phase.Seconds / dt, MidpointRounding.AwayFromZero));
                for (int t = 0; t < ticks; t++)
                {
                    e.IgnitionOn = phase.Ignition;
                    RampSpeed(e, phase.TargetSpeedMph, config);
                    e.Advance(dt);
                    output.Add(new Emitted(ToStored(MTPacket.LivePosition(e, Backdated(idx, total, dt))), Emitted.Kind.Stored));
                    idx++;
                }
            }
            return output;
        }
    }

    // MARK: - The 20 required scenarios
    public static class Scenarios
    {
        public static readonly List<Scenario> All = BuildAll();

        private static List<Scenario> BuildAll()
        {
            var list = new List<Scenario>
            {
                new Scenario(1, "Engine ON", "PowerUp event, engine on",
                    new List<Phase> { new Phase(5, 0, true) },
                    appSteps: new List<string> { "Connect the ELD app to ELD-MA", "Tap RUN", "App shows engine power-up → On-Duty" }),
                new Scenario(2, "Engine OFF", "Shutdown event",
                    new List<Phase> { new Phase(3, 0, true), new Phase(3, 0, false) },
                    appSteps: new List<string> { "Tap RUN", "App logs an engine shutdown / power-off event" }),
                new Scenario(3, "Idle", "On-duty, no driving",
                    new List<Phase> { new Phase(30, 0, true) },
                    appSteps: new List<string> { "Tap RUN", "Engine on but not moving → app stays On-Duty (not Driving)" }),
                new Scenario(4, "Driving highway", "Auto-driving at ~65 mph",
                    new List<Phase> { new Phase(5, 0, true), new Phase(40, 65, true) },
                    appSteps: new List<string> { "Tap RUN", "At ~65 mph the app shows Driving; speed & location update live" }),
                new Scenario(5, "Stop after drive", "Driving → stop → on-duty",
                    new List<Phase> { new Phase(30, 60, true), new Phase(370, 0, true) },   // stop must outlast the app's ~6-min zero-speed grace (wall-clock, uncompressible)
                    appSteps: new List<string> { "Tap RUN", "Drive, then stay stopped (engine on) ~6 min → app moves Driving → On-Duty" }),
                new Scenario(6, "BLE disconnect during drive", "Buffer then stored replay",
                    new List<Phase> { new Phase(60, 60, true) },
                    transport: Transport.Disconnect(15, 20),
                    appSteps: new List<string> { "Tap RUN", "Link drops mid-drive, then reconnects", "App replays buffered 'stored' packets — no miles lost" }),
                new Scenario(7, "Stored packets later", "Stored backlog processed",
                    new List<Phase> { new Phase(20, 50, true) },
                    transport: Transport.StoredBacklog(30),
                    appSteps: new List<string> { "Tap RUN", "App receives a stored backlog up front and processes it" }),
                new Scenario(8, "Large stored backlog", "Big stored batch, no corruption",
                    new List<Phase> { new Phase(10, 50, true) },
                    transport: Transport.StoredBacklog(300),
                    appSteps: new List<string> { "Tap RUN", "300 stored packets delivered → app stays stable, no corruption" }),
                new Scenario(9, "Duplicate packets", "Duplicates dropped by app dedup",
                    new List<Phase> { new Phase(40, 60, true) },
                    transport: Transport.Duplicate(5),
                    appSteps: new List<string> { "Tap RUN", "Duplicate packets are sent → app de-dupes (no double miles)" }),
                new Scenario(10, "Out-of-order packets", "App tolerates reordering",
                    new List<Phase> { new Phase(40, 60, true) },
                    transport: Transport.OutOfOrder(6),
                    appSteps: new List<string> { "Tap RUN", "Packets arrive reordered → app tolerates it without errors" }),
                new Scenario(11, "Packet parsing failure", "Malformed packet rejected, no crash",
                    new List<Phase> { new Phase(30, 55, true) },
                    transport: Transport.ParseFailure(10),
                    appSteps: new List<string> { "Tap RUN", "A malformed packet is sent → app rejects it and keeps running (no crash)" }),
                new Scenario(12, "Unassigned Driving (log out first)",
                    "Drive with NO driver logged in → app files Unassigned Driving (UDP) to claim",
                    new List<Phase> { new Phase(5, 0, true), new Phase(300, 60, true) },
                    appSteps: new List<string>
                    {
                        "Log OUT of the ELD app (no driver assigned)",
                        "Tap RUN — the truck drives with nobody logged in",
                        "Log back IN → app shows pending Unassigned Driving",
                        "Claim or reject the driving block",
                    }),
            };
            return list;
        }
    }
}
