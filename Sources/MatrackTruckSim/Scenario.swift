import Foundation

/// One emitted item on the wire (what the tracker would send the app).
struct Emitted {
    enum Kind { case live, stored, ignition, raw, malformed }
    let wire: String
    let kind: Kind
}

/// A timed driving phase.
struct Phase {
    var seconds: Double
    var targetSpeedMph: Double
    var ignition: Bool
}

/// Transport behavior overlaid on the packet stream (deterministic for repeatable tests).
enum Transport: Equatable {
    case clean
    case packetLoss(everyN: Int)
    case duplicate(everyN: Int)
    case outOfOrder(everyN: Int)
    case disconnect(afterSec: Double, gapSec: Double)   // buffer during outage → replay as stored on reconnect (interval-independent)
    case storedBacklog(count: Int)                // pre-existing stored packets delivered up front
    case parseFailure(atTick: Int)                // inject a malformed packet the app must reject
}

struct Scenario {
    let id: Int
    let name: String
    let expect: String
    var phases: [Phase]
    var transport: Transport = .clean
    var appSteps: [String] = []          // what to do in the ELD app to observe this scenario
}

/// Deterministically simulates a scenario tick-by-tick and returns the exact wire sequence.
/// Shares the real packet builders (MTPacket) so output is byte-identical to the live sim.
enum ScenarioRunner {
    static func run(_ s: Scenario, config: SimConfig) -> [Emitted] {
        let e = EngineState()
        e.odometerMiles = config.startOdometerMiles
        e.engineHours = config.startEngineHours
        e.fuelLevelPct = config.startFuelPct
        e.idleRpmConfig = config.idleRpm
        e.rpmPerMphConfig = config.rpmPerMph
        e.fuelBurnPctPerMile = config.fuelBurnPctPerMile
        e.ignitionOn = false

        var out: [Emitted] = []
        var lastIgn: Bool? = nil
        var tick = 0
        var held: String? = nil
        var buffer: [String] = []          // packets captured while "disconnected"
        let dt = config.packetIntervalSec

        // Disconnect window resolved to ticks from time (interval-independent).
        var dcAt = -1, dcGap = 0
        if case .disconnect(let aSec, let gSec) = s.transport {
            dcAt = Int((aSec / dt).rounded()); dcGap = max(1, Int((gSec / dt).rounded()))
        }
        var storedFlushed = false
        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            for p in buffer { out.append(Emitted(wire: toStored(p), kind: .stored)) }
            out.append(Emitted(wire: "LAST_STORED_PACKET", kind: .raw))
            out.append(Emitted(wire: "SAVED PACKET COUNT:\(buffer.count)", kind: .raw))
            buffer.removeAll(); storedFlushed = true
        }

        // pre-existing stored backlog delivered first
        if case .storedBacklog(let count) = s.transport {
            for i in 0..<count {
                e.advance(dt: dt)
                let stored = toStored(MTPacket.livePosition(e, date: backdated(i, count, dt)))
                out.append(Emitted(wire: stored, kind: .stored))
            }
            out.append(Emitted(wire: "LAST_STORED_PACKET", kind: .raw))
            out.append(Emitted(wire: "SAVED PACKET COUNT:\(count)", kind: .raw))
        }

        for phase in s.phases {
            let ticks = max(1, Int((phase.seconds / dt).rounded()))
            for _ in 0..<ticks {
                e.ignitionOn = phase.ignition
                rampSpeed(e, toward: phase.targetSpeedMph, config: config)
                e.advance(dt: dt * config.timeMultiplier)

                // disconnect window?
                let disconnected = (dcAt >= 0 && tick >= dcAt && tick < dcAt + dcGap)

                // ignition change → LI event
                if lastIgn != e.ignitionOn {
                    let li = MTPacket.ignition(e, on: e.ignitionOn)
                    routeEmit(li, kind: .ignition, disconnected: disconnected, buffer: &buffer, out: &out, held: &held, tick: tick, transport: s.transport)
                    lastIgn = e.ignitionOn
                }

                // parse-failure injection
                if case .parseFailure(let at) = s.transport, tick == at {
                    out.append(Emitted(wire: "ZZ,not,a,valid,packet", kind: .malformed))
                }

                let lp = MTPacket.livePosition(e)
                routeEmit(lp, kind: .live, disconnected: disconnected, buffer: &buffer, out: &out, held: &held, tick: tick, transport: s.transport)

                // reconnect boundary → flush buffered as stored
                if dcAt >= 0, tick == dcAt + dcGap - 1 { flushBuffer() }
                tick += 1
            }
        }
        if let h = held { out.append(Emitted(wire: h, kind: .live)) }   // flush any held out-of-order packet
        if dcAt >= 0 && !storedFlushed { flushBuffer() }                 // outage outlasted the run → replay at end
        return out
    }

    // MARK: helpers
    private static func rampSpeed(_ e: EngineState, toward target: Double, config: SimConfig) {
        if e.speedMph < target { e.speedMph = min(target, e.speedMph + config.accelMphPerSec * config.packetIntervalSec) }
        else if e.speedMph > target { e.speedMph = max(target, e.speedMph - config.decelMphPerSec * config.packetIntervalSec) }
    }

    private static func routeEmit(_ wire: String, kind: Emitted.Kind, disconnected: Bool,
                                  buffer: inout [String], out: inout [Emitted], held: inout String?,
                                  tick: Int, transport: Transport) {
        if disconnected { buffer.append(wire); return }
        switch transport {
        case .packetLoss(let n) where n > 0 && tick % n == 0:
            return  // dropped in flight
        case .duplicate(let n) where n > 0 && tick % n == 0:
            out.append(Emitted(wire: wire, kind: kind)); out.append(Emitted(wire: wire, kind: kind))
        case .outOfOrder(let n) where n > 0 && tick % n == 0 && held == nil:
            held = wire  // hold; flushed after the next emit
        default:
            out.append(Emitted(wire: wire, kind: kind))
            if let h = held { held = nil; out.append(Emitted(wire: h, kind: kind)) }
        }
    }

    static func toStored(_ live: String) -> String {
        guard let first = live.first, first == "L" else { return live }
        return "S" + live.dropFirst()
    }

    static func backdated(_ i: Int, _ count: Int, _ dt: Double) -> Date {
        Date(timeIntervalSinceNow: -Double(count - i) * dt)
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
    static func storedDump(count: Int, config: SimConfig) -> [Emitted] {
        let e = EngineState()
        e.odometerMiles = config.startOdometerMiles
        e.engineHours = config.startEngineHours
        e.fuelLevelPct = config.startFuelPct
        e.idleRpmConfig = config.idleRpm
        e.rpmPerMphConfig = config.rpmPerMph
        e.fuelBurnPctPerMile = config.fuelBurnPctPerMile
        e.ignitionOn = true
        let dt = config.packetIntervalSec
        var out: [Emitted] = []
        for i in 0..<max(0, count) {
            e.advance(dt: dt)
            out.append(Emitted(wire: toStored(MTPacket.livePosition(e, date: backdated(i, count, dt))), kind: .stored))
        }
        out.append(Emitted(wire: "LAST_STORED_PACKET", kind: .raw))
        out.append(Emitted(wire: "SAVED PACKET COUNT:\(count)", kind: .raw))
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
    static func storedReplay(for s: Scenario, config: SimConfig, from start: Date? = nil) -> [Emitted] {
        let e = EngineState()
        e.odometerMiles = config.startOdometerMiles
        e.engineHours = config.startEngineHours
        e.fuelLevelPct = config.startFuelPct
        e.idleRpmConfig = config.idleRpm
        e.rpmPerMphConfig = config.rpmPerMph
        e.fuelBurnPctPerMile = config.fuelBurnPctPerMile
        let dt = max(1, config.storedRecordIntervalSec)
        var out: [Emitted] = []
        // pre-existing backlog (scenarios 11/12): N backdated stored positions
        if case .storedBacklog(let count) = s.transport {
            e.ignitionOn = true
            for i in 0..<max(0, count) {
                e.advance(dt: dt)
                let at = start.map { recorded(i, dt, from: $0) } ?? backdated(i, count, dt)
                out.append(Emitted(wire: toStored(MTPacket.livePosition(e, date: at)), kind: .stored))
            }
            return out
        }
        // drive scenarios (8/9/10/21): replay the phases as backdated stored packets (speed preserved →
        // 60-mph phase yields driving stored packets → driving UDP for scenario 21)
        var total = 0
        for p in s.phases { total += max(1, Int((p.seconds / dt).rounded())) }
        var idx = 0
        for phase in s.phases {
            let ticks = max(1, Int((phase.seconds / dt).rounded()))
            for _ in 0..<ticks {
                e.ignitionOn = phase.ignition
                rampSpeed(e, toward: phase.targetSpeedMph, config: config)
                e.advance(dt: dt)
                let at = start.map { recorded(idx, dt, from: $0) } ?? backdated(idx, total, dt)
                out.append(Emitted(wire: toStored(MTPacket.livePosition(e, date: at)), kind: .stored))
                idx += 1
            }
        }
        return out
    }
}

// MARK: - The 20 required scenarios

enum Scenarios {
    static let all: [Scenario] = [
        Scenario(id: 1, name: "Engine ON", expect: "PowerUp event, engine on",
                 phases: [Phase(seconds: 5, targetSpeedMph: 0, ignition: true)],
                 appSteps: ["Connect the ELD app to ELD-MA", "Tap RUN", "App shows engine power-up → On-Duty"]),
        Scenario(id: 2, name: "Engine OFF", expect: "Shutdown event",
                 phases: [Phase(seconds: 3, targetSpeedMph: 0, ignition: true),
                          Phase(seconds: 3, targetSpeedMph: 0, ignition: false)],
                 appSteps: ["Tap RUN", "App logs an engine shutdown / power-off event"]),
        Scenario(id: 3, name: "Idle", expect: "On-duty, no driving",
                 phases: [Phase(seconds: 30, targetSpeedMph: 0, ignition: true)],
                 appSteps: ["Tap RUN", "Engine on but not moving → app stays On-Duty (not Driving)"]),
        Scenario(id: 4, name: "Driving highway", expect: "Auto-driving at ~65 mph",
                 phases: [Phase(seconds: 5, targetSpeedMph: 0, ignition: true),
                          Phase(seconds: 40, targetSpeedMph: 65, ignition: true)],
                 appSteps: ["Tap RUN", "At ~65 mph the app shows Driving; speed & location update live"]),
        Scenario(id: 5, name: "Stop after drive", expect: "Driving → stop → on-duty",
                 phases: [Phase(seconds: 30, targetSpeedMph: 60, ignition: true),
                          Phase(seconds: 370, targetSpeedMph: 0, ignition: true)],   // stop must outlast the app's ~6-min zero-speed grace (wall-clock, uncompressible)
                 appSteps: ["Tap RUN", "Drive, then stay stopped (engine on) ~6 min → app moves Driving → On-Duty"]),
        Scenario(id: 6, name: "BLE disconnect during drive", expect: "Buffer then stored replay",
                 phases: [Phase(seconds: 60, targetSpeedMph: 60, ignition: true)],
                 transport: .disconnect(afterSec: 15, gapSec: 20),
                 appSteps: ["Tap RUN", "Link drops mid-drive, then reconnects", "App replays buffered 'stored' packets — no miles lost"]),
        Scenario(id: 7, name: "Stored packets later", expect: "Stored backlog processed",
                 phases: [Phase(seconds: 20, targetSpeedMph: 50, ignition: true)],
                 transport: .storedBacklog(count: 30),
                 appSteps: ["Tap RUN", "App receives a stored backlog up front and processes it"]),
        Scenario(id: 8, name: "Large stored backlog", expect: "Big stored batch, no corruption",
                 phases: [Phase(seconds: 10, targetSpeedMph: 50, ignition: true)],
                 transport: .storedBacklog(count: 300),
                 appSteps: ["Tap RUN", "300 stored packets delivered → app stays stable, no corruption"]),
        Scenario(id: 9, name: "Duplicate packets", expect: "Duplicates dropped by app dedup",
                 phases: [Phase(seconds: 40, targetSpeedMph: 60, ignition: true)],
                 transport: .duplicate(everyN: 5),
                 appSteps: ["Tap RUN", "Duplicate packets are sent → app de-dupes (no double miles)"]),
        Scenario(id: 10, name: "Out-of-order packets", expect: "App tolerates reordering",
                 phases: [Phase(seconds: 40, targetSpeedMph: 60, ignition: true)],
                 transport: .outOfOrder(everyN: 6),
                 appSteps: ["Tap RUN", "Packets arrive reordered → app tolerates it without errors"]),
        Scenario(id: 11, name: "Packet parsing failure", expect: "Malformed packet rejected, no crash",
                 phases: [Phase(seconds: 30, targetSpeedMph: 55, ignition: true)],
                 transport: .parseFailure(atTick: 10),
                 appSteps: ["Tap RUN", "A malformed packet is sent → app rejects it and keeps running (no crash)"]),
        Scenario(id: 12, name: "Unassigned Driving (~7 min)",
                 expect: "Drive with NO driver logged in → app files Unassigned Driving (UDP) to claim",
                 phases: [Phase(seconds: 5, targetSpeedMph: 0, ignition: true),
                          Phase(seconds: 300, targetSpeedMph: 60, ignition: true)],
                 appSteps: [
                    "Stay logged IN and leave Bluetooth on — no log-out needed. Tap Run it.",
                    "The link drops and the truck 'drives' offline. This takes ~7 minutes of real time: the app needs 5 minutes of no movement plus a grace period to close your Driving event before the recorded drive can belong to nobody. It cannot be sped up.",
                    "Wait for the app to reconnect to ELD-MA on its own — the drive is sent automatically.",
                    "Open Unidentified / Unassigned Driving and claim or reject the period.",
                 ]),
    ]
}
