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
        public double StartFuelPct = 78;
        /// <summary>%/mile fuel burn while moving.</summary>
        public double FuelBurnPctPerMile = 0.02;

        // Network / transport effects (0–100 = percent)
        public double PacketLossPct = 0;
        public double DuplicatePct = 0;
        public double OutOfOrderPct = 0;
        /// <summary>Extra random delay added before sending each packet (ms).</summary>
        public double ExtraDelayMs = 0;
        /// <summary>
        /// Emulated BLE signal strength 0–100 (100 = full). Maps to packetLossPct = 100 − signalPct;
        /// 0 = out of range. (macOS has no TX-power API, so "weak signal" is emulated via loss + drop.)
        /// </summary>
        public double SignalPct = 100;

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
        /// <summary>F2 stored-dump repro: count + cadence. ~80 @ 0.5s reproduces Harshith's fast-dump disconnect; 1.0s is safe.</summary>
        public int StoredDumpCount = 80;
        public double StoredDumpCadenceSec = 0.5;

        // HOS cycle (for cycle-exhaustion/reset scenarios)
        public double CycleDriveLimitHours = 11;
        public double CycleShiftLimitHours = 14;
        public double CycleWeeklyLimitHours = 70;

        // Identity (device info defaults live in DeviceInfo)
        public string AdvertisedName = "ELD-MA";

        public static SimConfig Default => new SimConfig();
    }
}
