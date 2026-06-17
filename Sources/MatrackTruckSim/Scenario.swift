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

    private static func toStored(_ live: String) -> String {
        guard let first = live.first, first == "L" else { return live }
        return "S" + live.dropFirst()
    }

    private static func backdated(_ i: Int, _ count: Int, _ dt: Double) -> Date {
        Date(timeIntervalSinceNow: -Double(count - i) * dt)
    }
}

// MARK: - The 20 required scenarios

enum Scenarios {
    static let all: [Scenario] = [
        Scenario(id: 1, name: "Engine ON", expect: "PowerUp event, engine on",
                 phases: [Phase(seconds: 5, targetSpeedMph: 0, ignition: true)]),
        Scenario(id: 2, name: "Engine OFF", expect: "Shutdown event",
                 phases: [Phase(seconds: 3, targetSpeedMph: 0, ignition: true),
                          Phase(seconds: 3, targetSpeedMph: 0, ignition: false)]),
        Scenario(id: 3, name: "Idle", expect: "On-duty, no driving",
                 phases: [Phase(seconds: 30, targetSpeedMph: 0, ignition: true)]),
        Scenario(id: 4, name: "Driving low speed", expect: "Auto-driving at ~25 mph",
                 phases: [Phase(seconds: 5, targetSpeedMph: 0, ignition: true),
                          Phase(seconds: 30, targetSpeedMph: 25, ignition: true)]),
        Scenario(id: 5, name: "Driving highway", expect: "Auto-driving at ~65 mph",
                 phases: [Phase(seconds: 5, targetSpeedMph: 0, ignition: true),
                          Phase(seconds: 40, targetSpeedMph: 65, ignition: true)]),
        Scenario(id: 6, name: "Speed changes", expect: "Speed varies; stays driving",
                 phases: [Phase(seconds: 15, targetSpeedMph: 65, ignition: true),
                          Phase(seconds: 15, targetSpeedMph: 30, ignition: true),
                          Phase(seconds: 15, targetSpeedMph: 55, ignition: true)]),
        Scenario(id: 7, name: "Stop after drive", expect: "Driving → stop → on-duty",
                 phases: [Phase(seconds: 30, targetSpeedMph: 60, ignition: true),
                          Phase(seconds: 30, targetSpeedMph: 0, ignition: true)]),
        Scenario(id: 8, name: "BLE disconnect during drive", expect: "Buffer then stored replay",
                 phases: [Phase(seconds: 60, targetSpeedMph: 60, ignition: true)],
                 transport: .disconnect(afterSec: 15, gapSec: 20)),
        Scenario(id: 9, name: "Reconnect after 10 min", expect: "Stored replay after long outage",
                 phases: [Phase(seconds: 60, targetSpeedMph: 60, ignition: true)],
                 transport: .disconnect(afterSec: 10, gapSec: 600)),
        Scenario(id: 10, name: "Reconnect after hours", expect: "Large stored replay after very long outage",
                 phases: [Phase(seconds: 90, targetSpeedMph: 60, ignition: true)],
                 transport: .disconnect(afterSec: 10, gapSec: 7200)),
        Scenario(id: 11, name: "Stored packets later", expect: "Stored backlog processed",
                 phases: [Phase(seconds: 20, targetSpeedMph: 50, ignition: true)],
                 transport: .storedBacklog(count: 30)),
        Scenario(id: 12, name: "Large stored backlog", expect: "Big stored batch, no corruption",
                 phases: [Phase(seconds: 10, targetSpeedMph: 50, ignition: true)],
                 transport: .storedBacklog(count: 300)),
        Scenario(id: 13, name: "Duplicate packets", expect: "Duplicates dropped by app dedup",
                 phases: [Phase(seconds: 40, targetSpeedMph: 60, ignition: true)],
                 transport: .duplicate(everyN: 5)),
        Scenario(id: 14, name: "Out-of-order packets", expect: "App tolerates reordering",
                 phases: [Phase(seconds: 40, targetSpeedMph: 60, ignition: true)],
                 transport: .outOfOrder(everyN: 6)),
        Scenario(id: 15, name: "Packet parsing failure", expect: "Malformed packet rejected, no crash",
                 phases: [Phase(seconds: 30, targetSpeedMph: 55, ignition: true)],
                 transport: .parseFailure(atTick: 10)),
        Scenario(id: 16, name: "Duty status conflict", expect: "Speed>0 with ignition cycling",
                 phases: [Phase(seconds: 15, targetSpeedMph: 60, ignition: true),
                          Phase(seconds: 5, targetSpeedMph: 60, ignition: false),
                          Phase(seconds: 15, targetSpeedMph: 60, ignition: true)]),
        Scenario(id: 17, name: "HOS violation (timing-limited)", expect: "Long drive; HOS clock is wall-clock bound",
                 phases: [Phase(seconds: 120, targetSpeedMph: 65, ignition: true)]),
        Scenario(id: 18, name: "Cycle exhaustion (timing-limited)", expect: "Very long drive",
                 phases: [Phase(seconds: 180, targetSpeedMph: 65, ignition: true)]),
        Scenario(id: 19, name: "Cycle reset/recovery", expect: "Long off period after drive",
                 phases: [Phase(seconds: 30, targetSpeedMph: 60, ignition: true),
                          Phase(seconds: 60, targetSpeedMph: 0, ignition: false)]),
        Scenario(id: 20, name: "Long simulation loop", expect: "Many phases, stable",
                 phases: (0..<10).flatMap { _ in
                     [Phase(seconds: 10, targetSpeedMph: 65, ignition: true),
                      Phase(seconds: 6, targetSpeedMph: 0, ignition: true)]
                 }),
        Scenario(id: 21, name: "Unassigned Driving (log out first)",
                 expect: "Drive with NO driver logged in → app files Unassigned Driving (UDP) to claim",
                 phases: [Phase(seconds: 5, targetSpeedMph: 0, ignition: true),
                          Phase(seconds: 300, targetSpeedMph: 60, ignition: true)]),
    ]
}
