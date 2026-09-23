using System;

namespace MatrackSim.Core
{
    /// <summary>
    /// All simulator behavior is driven by this config — nothing important is hardcoded.
    /// Defaults are realistic for a typical drive; the UI and scenarios override as needed.
    /// </summary>
    public class SimConfig
    {
        // Timing
        /// <summary>How often a live packet is emitted (seconds of sim time).</summary>
        public double PacketIntervalSec = 1.0;
        /// <summary>
        /// Multiplies the passage of sim time (2.0 = engine hours/odometer accrue twice as fast).
        /// NOTE: HOS *duration* clocks in the app run on real wall-clock; this only affects the
        /// odometer/engine-hours we report, not the app's 11/14/70h timers. Documented limitation.
        /// </summary>
        public double TimeMultiplier = 1.0;
        /// <summary>
        /// Internal time compression while driving a planned route, so the truck visibly crosses the
        /// map (1.0 = real time, far too slow to watch). Kept modest so the map motion reads natural
        /// relative to the displayed speed; the mph SPEED control still sets the pace.
        /// </summary>
        public double RouteTimeScale = 5;

        // Driving dynamics
        public double TargetSpeedMph = 65;
        public double AccelMphPerSec = 4;
        public double DecelMphPerSec = 7;
        public int IdleRpm = 750;
        /// <summary>rpm = idleRpm + speedMph * rpmPerMph  (rough engine model)</summary>
        public double RpmPerMph = 26;

        // DRIVE MY DAY (F3) — one-click full-day trip with baked-in event violations
        public double DayCruiseMph = 68;
        public double SpeedingViolationMph = 82;
        public double ViolationEveryMiles = 75;
        public double IdleStopSec = 45;

        // Starting telemetry
        public double StartOdometerMiles = 25_000;
        public double StartEngineHours = 4_352.5;
        public double StartFuelPct = 30;              // start low so a short leg reaches the low-fuel warning
        /// <summary>%/mile fuel burn while moving. High on purpose: a short leg (~50 mi) hits the warning
        /// and ~100 mi empties the tank, so testers reliably reach the "open the Fuel App / refuel" flow.</summary>
        public double FuelBurnPctPerMile = 0.3;
        /// <summary>Tank-1 % at/under which the sim raises the "low fuel — open the Fuel App" prompt.</summary>
        public double LowFuelWarnPct = 15;

        // Network / transport effects (0–100 = percent)
        public double PacketLossPct = 0;
        public double DuplicatePct = 0;
        public double OutOfOrderPct = 0;
        /// <summary>Extra random delay added before sending each packet (ms).</summary>
        public double ExtraDelayMs = 0;
        /// <summary>
        /// Emulated BLE signal strength 0–100 (100 = full). Weak signal is modeled as added LATENCY
        /// (ExtraDelayMs), NOT packet loss — real BLE retransmits at the link layer. 0 = out of range.
        /// (macOS/Windows expose no TX-power API, so true RSSI can't be lowered; latency emulates the link.)
        /// </summary>
        public double SignalPct = 100;
        /// <summary>
        /// F1 flow control: when true, the live stream waits for the app's $ACK before sending the next
        /// packet (true ACK-gated cadence); when false (default) it streams on PacketIntervalSec. Off by
        /// default because real-tracker ACK gating is unconfirmed — this lets devs exercise both modes.
        /// </summary>
        public bool AckGatedCadence = false;

        // Disconnect / reconnect / stored backlog
        /// <summary>When a disconnect scenario fires, how long to stay disconnected (sim seconds).</summary>
        public double ReconnectDelaySec = 600;
        /// <summary>Packets buffered while disconnected, replayed (as stored 'S' packets) on reconnect.</summary>
        public int StoredBacklogCount = 0;
        /// <summary>
        /// F1 out-of-range outage: how long to go silent. The ELD app only DISCONNECTS after ~75s of
        /// silence (15s+30s+30s retry escalation), so ≥80 = a real disconnect+reconnect; 15–75 = a stall demo.
        /// </summary>
        public double RangeOutageSec = 80;

        // ---- Stored replay (Unassigned Driving) -------------------------------------------------
        /// <summary>Lead-in after the disconnect before the recorded drive starts.</summary>
        public double StoredReplayLeadInSec = 10;
        /// <summary>
        /// The outage must OUTLAST the app's Driving→On-Duty close — 300s of zero speed plus a 65s
        /// grace — so the open driving event ends at the disconnect, before the recorded drive begins.
        /// Shorter and the event stays open and swallows the dump. Wall-clock; not compressible.
        /// </summary>
        public double StoredReplayMinOutageSec = 395;
        /// <summary>
        /// Flash depth for the offline recorder. A real MT tracker logs to flash whenever no phone is
        /// connected and hands the backlog over on the next `readstr`; without a recorder the sim loses
        /// every mile driven offline and answers "SAVED PACKET COUNT:0". ~83 min at 1s/packet.
        /// </summary>
        public int StoredFlashCapacity = 5_000;
        /// <summary>
        /// How often the offline recorder writes a flash record. Deliberately COARSER than the 1s live
        /// cadence: at 1s a 10-minute offline drive is 600 packets, and the dump goes out at ~1 packet/s
        /// (the app breaks at ~0.5s — that is the F2 repro), so uploading it would take another 10
        /// minutes of real time. At 30s the same drive is 20 packets and lands in ~20s.
        /// ponytail: 30s is a plausible tracker logging interval, not a measured one — confirm against
        /// real MT flash and retune if the hardware logs at a different rate.
        /// </summary>
        public double StoredRecordIntervalSec = 30;
        /// <summary>F2 stored-dump repro: count + cadence. ~80 @ 0.5s reproduces Harshith's fast-dump disconnect; 1.0s is safe.</summary>
        public int StoredDumpCount = 80;
        public double StoredDumpCadenceSec = 0.5;

        // HOS cycle (for cycle-exhaustion/reset scenarios)
        public double CycleDriveLimitHours = 11;
        public double CycleShiftLimitHours = 14;
        public double CycleWeeklyLimitHours = 70;

        // Identity (device info defaults live in DeviceInfo)
        public string AdvertisedName = "ELD-MA";

        // ── ESP32 serial transport (new) ─────────────────────────────────────
        public enum Transport { Ble, Esp32Serial }
        /// <summary>Which radio the sim uses: built-in WinRT BLE, or the ESP32 over USB serial.</summary>
        public Transport Link = Transport.Ble;
        /// <summary>COM port (Windows) / tty path (macOS) of the ESP32. Chosen in the UI.</summary>
        public string SerialPortName = "";
        /// <summary>Currently-applied ESP32 TX power in dBm (echoed by "#txpower ok").</summary>
        public int TxPowerDbm = 9;

        // Signal% (0–100) → TX power (dBm). Linear across the C3 step range, snapped by the firmware.
        //   100% → +9 (near/full) · 25% (POOR) → ~-6 · 0% → -12 (out of range).
        public static int SignalPctToDbm(double pct)
        {
            double dbm = -12 + (Math.Max(0, Math.Min(100, pct)) / 100.0) * 21.0;   // -12..+9
            return (int)Math.Round(dbm / 3.0, MidpointRounding.AwayFromZero) * 3;   // snap to 3-dBm grid
        }

        public static SimConfig Default => new SimConfig();
    }
}
