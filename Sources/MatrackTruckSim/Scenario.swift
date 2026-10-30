import Foundation

/// One emitted item on the wire (what the tracker would send the app).
struct Emitted {
    enum Kind { case live, stored, ignition, raw, malformed }
    let wire: String
    let kind: Kind
}


/// Transport behavior overlaid on the packet stream (deterministic for repeatable tests).


/// Deterministically simulates a scenario tick-by-tick and returns the exact wire sequence.
/// Shares the real packet builders (MTPacket) so output is byte-identical to the live sim.
/// Wire-packet helpers shared by the offline recorder, the stored dump and the self-test.
///
/// This used to also run a catalogue of twelve scenarios. Every one of them turned out to be a
/// dashboard control with extra steps, and keeping a second code path that did the same job is how
/// the Unassigned Driving timing shipped broken for weeks while its own self-test stayed green.
/// The catalogue is gone; these builders remain because the live path genuinely needs them.
enum WireBuilder {

    // MARK: helpers


    static func toStored(_ live: String) -> String {
        guard let first = live.first, first == "L" else { return live }
        return "S" + live.dropFirst()
    }

    /// Stamp for record `i` of `count`, spaced `dt` apart and ENDING at `endingAt` (default now).
    /// The last record lands on `endingAt` itself — a real backlog runs right up to the moment the
    /// phone connects, and the app reads the newest record as "where the truck was when I arrived".
    static func backdated(_ i: Int, _ count: Int, _ dt: Double, endingAt: Date = Date()) -> Date {
        endingAt.addingTimeInterval(-Double(count - 1 - i) * dt)
    }

    /// Split a flash backlog into what the app can actually use and what it would silently discard.
    ///
    /// The app does NOT treat the disconnect as the boundary: it keeps the driver's Driving event open
    /// for `appDrivingCloseSec` after the link drops, then stamps the closing On-Duty event at the
    /// moment that grace expires, and reports the Driving window as ending THERE. Records stamped
    /// inside that window are classified as already assigned to the logged-in driver and produce
    /// nothing — no Unassigned Driving Period, no error, no UI.
    ///
    /// Unparseable records are kept, never silently dropped.
    static func deliverableStored(_ records: [Emitted], outageStart: Date,
                                  appDrivingCloseSec: Double) -> (keep: [Emitted], dropped: Int) {
        let cutoff = outageStart.addingTimeInterval(appDrivingCloseSec)
        let keep = records.filter { em in
            guard let utc = utcOf(em.wire) else { return true }
            return utc >= cutoff
        }
        return (keep, records.count - keep.count)
    }

    /// Read the odometer / engine hours / position back off a telemetry packet. Lets the caller advance
    /// the live engine to exactly where a recorded drive ended, so the stored dump and the live stream
    /// never disagree about how far the truck has gone.
    static func telemetryOf(_ wire: String) -> (odometerMiles: Double, engineHours: Double, latitude: Double, longitude: Double)? {
        let f = wire.components(separatedBy: ",")
        guard f.count > 7,
              let rawOdo = Double(f[4]), let rawHrs = Double(f[5]),
              let lat = Double(f[6]), let lon = Double(f[7]) else { return nil }
        return (rawOdo * 0.0621371, rawHrs / 100.0, lat, lon)
    }

    /// Parse the UTC a telemetry packet carries back out of the wire (fields 10 = HHMMSS, 11 = DDMMYY).
    /// Used by the self-test to prove stored packets are stamped inside the outage window.
    static func utcOf(_ wire: String) -> Date? {
        let f = wire.components(separatedBy: ",")
        guard f.count > 11, f[10].count == 6, f[11].count == 6 else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss ddMMyy"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: "\(f[10]) \(f[11])")
    }

    /// Stamp for a stored packet recorded DURING an outage that began at `start`.
    ///
    /// The old behaviour backdated every packet into the minutes immediately BEFORE the disconnect,
    /// which is exactly the span the ELD app has already attributed to the logged-in driver — so all
    /// of them were classified as assigned and no Unassigned Driving Period was ever produced. Anchor
    /// the recorded drive to the start of the outage instead, where nothing is attributed to anyone.
    static func recorded(_ i: Int, _ dt: Double, from start: Date) -> Date {
        start.addingTimeInterval(Double(i) * dt)
    }

    /// F2: the exact wire sequence a real `readstr` dump produces — N stored 'S' packets + footers.
    /// Played back at a configurable cadence to reproduce the fast-dump disconnect (≈0.5s breaks, 1s is fine).
    /// How a stored dump should deviate from a normal one, for the REQ-940 / REQ-942 test cases.
    ///
    /// `stampedAt` replaces the usual backdating so every packet carries one chosen instant — the
    /// app refuses a stored packet whose time is a year or more from now, so a 2030 stamp is the
    /// way to exercise that guard.
    ///
    /// `repeatEachPacket` emits every packet twice back to back. The app's only packet-level
    /// de-dup is a comparison against the IMMEDIATELY previous stored packet, so a back-to-back
    /// repeat is the case it should catch; a repeat with a different packet in between is the case
    /// it will not.
    struct StoredDumpOptions {
        var stampedAt: Date?
        var repeatEachPacket = false
        /// Where the backlog starts counting from. Defaults to the config's starting telemetry, but
        /// the live sim passes its CURRENT odometer/hours so the recorded drive continues the truck
        /// the app has already been watching instead of restarting it somewhere else.
        var startOdometerMiles: Double?
        var startEngineHours: Double?
        static let normal = StoredDumpOptions()
    }

    static func storedDump(count: Int, config: SimConfig,
                           options: StoredDumpOptions = .normal) -> [Emitted] {
        let e = EngineState()
        e.odometerMiles = options.startOdometerMiles ?? config.startOdometerMiles
        e.engineHours = options.startEngineHours ?? config.startEngineHours
        e.fuelLevelPct = config.startFuelPct
        e.idleRpmConfig = config.idleRpm
        e.rpmPerMphConfig = config.rpmPerMph
        // A backlog does NOT burn fuel. At 30-minute spacing each record covers ~30 miles, which at
        // the normal burn rate empties a 30% tank by the THIRD record — so 77 of an 80-record dump
        // reported 0% and the app was told the truck drove two days on an empty tank. Modelling
        // refuelling across a backlog is not what this dump is for; holding the level is the honest
        // reading. EngineState.advance clamps at 0, so nothing ever flagged it.
        e.fuelBurnPctPerMile = 0
        e.ignitionOn = true
        // A stored packet with speed 0 takes the app's on-duty branch; the driving branch needs
        // speed >= 5. Without this every dump exercised only half the stored-packet handling.
        e.speedMph = config.storedDumpSpeedMph
        // Flash records, NOT live packets. The old spacing was packetIntervalSec — one SECOND apart —
        // so "80 stored packets" covered the last 80 seconds instead of the last 40 hours. Every one
        // of them then landed inside the driving event the app still has open (appDrivingCloseSec),
        // got classified as already assigned, and produced no Unassigned Driving Period at all.
        // A real tracker writes one record every storedRecordIntervalSec while the phone is away.
        let dt = config.storedRecordIntervalSec
        let last = max(0, count) - 1
        var out: [Emitted] = []
        for i in 0..<max(0, count) {
            e.advance(dt: dt)
            // The newest record is the key going off: a tracker's final flash write before it sleeps
            // is a shutdown, so the backlog ends stopped rather than mid-drive at 60 mph.
            if i == last {
                e.speedMph = 0
                e.ignitionOn = false
            }
            let at = options.stampedAt ?? backdated(i, count, dt)
            let wire = toStored(i == last ? MTPacket.ignition(e, on: false, date: at)
                                          : MTPacket.livePosition(e, date: at))
            out.append(Emitted(wire: wire, kind: .stored))
            // Byte-identical repeat, immediately after — the only shape the app's de-dup looks for.
            if options.repeatEachPacket { out.append(Emitted(wire: wire, kind: .stored)) }
        }
        let sent = out.filter { $0.kind == .stored }.count
        out.append(Emitted(wire: "LAST_STORED_PACKET", kind: .raw))
        out.append(Emitted(wire: "SAVED PACKET COUNT:\(sent)", kind: .raw))
        return out
    }

    /// Backdated stored 'S' packets for a stored-replay / unassigned-driving scenario — the drive that
    /// happened while the phone was disconnected, or a pre-existing backlog. NO footer here: the readstr
    /// handler appends LAST_STORED_PACKET + the count AFTER the app reconnects, because that post-reconnect
    /// readstr is the only state in which both apps run stored replay (and UDP/unassigned classification).
    /// Timestamps are backdated so they fall outside the logged-in driver's duty windows → flagged UDP.
    /// `from` is the instant the BLE link drops; the recorded drive is stamped forward from there.
    /// Defaults to the legacy pre-disconnect backdating so the headless self-test keeps its shape.
    /// Recorded drives are FLASH records, so they use `storedRecordIntervalSec`, not the 1s live
    /// cadence. At 1s a 5-minute scenario was 305 packets that then took 5 minutes to dump back.
}

// MARK: - The 20 required scenarios

