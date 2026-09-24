import Foundation

/// Headless validation: runs all 20 scenarios across 10 cycles (with config variation),
/// validating every emitted packet against the app-mirrored decoder (accept + chunk-frame +
/// reassembly round-trip + field decode), plus scenario-level invariants. Prints Pass/Fail
/// per cycle. Exits non-zero if anything fails. Deterministic + repeatable.
enum SelfTest {

    static func run() -> Int32 {
        print("════════════════════════════════════════════════════════════")
        print(" Matrack Truck Sim — Self-Test (encoder ↔ app-parser fidelity)")
        print("════════════════════════════════════════════════════════════")

        var allPass = true

        // 0) Encoder ↔ decoder round-trip on a known state
        if let f = roundTripUnit() { print("Round-trip unit: FAIL — \(f)"); allPass = false }
        else { print("Round-trip unit: PASS — LP/LV/LD encode→decode values match") }

        // 10 cycles, each with a deterministic config variation
        for cycle in 1...10 {
            let cfg = configForCycle(cycle)
            var failures: [String] = []
            var totalPackets = 0, controlPkts = 0, storedPkts = 0, malformedPkts = 0

            for s in Scenarios.all {
                let emitted = ScenarioRunner.run(s, config: cfg)
                totalPackets += emitted.count
                for em in emitted {
                    switch em.kind {
                    case .raw: controlPkts += 1
                    case .stored: storedPkts += 1
                    case .malformed: malformedPkts += 1
                    default: break
                    }
                    if let f = validate(em) { failures.append("[S\(s.id) \(s.name)] \(f)") }
                }
                if let f = scenarioInvariant(s, emitted) { failures.append("[S\(s.id) \(s.name)] \(f)") }
            }

            let result = failures.isEmpty ? "Pass" : "Fail"
            if !failures.isEmpty { allPass = false }
            let summary = "\(Scenarios.all.count) scenarios, \(totalPackets) packets "
                + "(\(storedPkts) stored, \(controlPkts) control, \(malformedPkts) malformed-rejected) "
                + "@ \(String(format: "%.1f", cfg.packetIntervalSec))s/pkt, loss \(Int(cfg.packetLossPct))%"
            print("Cycle \(cycle) Result:")
            print("  [\(result)] — \(failures.isEmpty ? summary : failures.prefix(3).joined(separator: " | "))")
            if !failures.isEmpty { for f in failures.prefix(8) { print("      • \(f)") } }
        }

        // Stored-replay path: the live RunScenario routes the stored/UDP scenarios (8,9,10,11,12,21)
        // through ScenarioRunner.storedReplay (dumped on the app's reconnect readstr), NOT inline run().
        // Validate that path produces well-formed, all-stored, backdated packets (no footer — readstr adds it).
        print("Stored-replay path (RunScenario for stored/UDP scenarios):")
        for s in Scenarios.all {
            let isStored: Bool
            switch s.transport { case .disconnect, .storedBacklog: isStored = true; default: isStored = (s.id == 12) }
            if !isStored { continue }
            let sr = ScenarioRunner.storedReplay(for: s, config: .default)
            let n = sr.count
            let allStored = !sr.isEmpty && sr.allSatisfy { $0.kind == .stored }
            var valid = true
            for em in sr where validate(em) != nil { valid = false; break }
            var ok = allStored && valid && n > 0
            if s.id == 7 && n != 30 { ok = false }
            if s.id == 8 && n != 300 { ok = false }
            if !ok { allPass = false }
            print("  [\(ok ? "OK" : "FAIL")] S\(s.id) \(s.name): \(n) stored packets")
        }

        // The Unassigned-Driving fix: stored packets must be stamped INSIDE the outage window, i.e.
        // at/after the disconnect. Stamped before it, they land inside the driving event the app still
        // has open for the logged-in driver and are silently classified as already-assigned.
        print("Stored-replay timestamps land inside the outage (Unassigned Driving):")
        for s in Scenarios.all {
            let isStored: Bool
            switch s.transport { case .disconnect, .storedBacklog: isStored = true; default: isStored = (s.id == 12) }
            if !isStored { continue }
            let start = Date().addingTimeInterval(10)
            let sr = ScenarioRunner.storedReplay(for: s, config: .default, from: start)
            let stamps = sr.compactMap { ScenarioRunner.utcOf($0.wire) }
            let ok = stamps.count == sr.count && !stamps.isEmpty
                && stamps.allSatisfy { $0 >= start.addingTimeInterval(-1) }
            if !ok { allPass = false }
            print("  [\(ok ? "OK" : "FAIL")] S\(s.id): \(stamps.count)/\(sr.count) stamps at/after the disconnect")
        }

        // Restart persistence: odometer and engine hours must survive a relaunch and must never move
        // backwards. A rewind is the transition that freezes mileage accrual in the ELD app.
        print("Restart persistence (odometer / engine hours never rewind):")
        do {
            let before = EngineState()
            before.odometerMiles = 25_312.5
            before.engineHours = 4_401.25
            before.latitude = 25.943368
            before.longitude = -80.224136
            before.fuelLevelPct = 47.1
            // Never the real Application Support file — a tester who runs selftest after a day of
            // driving must not lose their odometer.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("MatrackSimSelfTest", isDirectory: true)
            before.persisted.save(to: scratch)

            let after = EngineState()                       // a fresh launch starts at the defaults
            let roundTripped = SimPersistedState.load(from: scratch)
            if let saved = roundTripped { after.restore(saved) }
            let carried = abs(after.odometerMiles - 25_312.5) < 0.01
                && abs(after.engineHours - 4_401.25) < 0.01
                && abs(after.latitude - 25.943368) < 0.000001
            print("  [\(carried ? "OK" : "FAIL")] odo/hours/position carried across a restart")
            if !carried { allPass = false }

            // A stale file holding LOWER values must not drag the odometer back.
            let ahead = EngineState()
            ahead.odometerMiles = 26_000; ahead.engineHours = 4_500
            ahead.restore(SimPersistedState(odometerMiles: 100, engineHours: 1, latitude: 0, longitude: 0,
                                            headingDeg: 0, fuelLevelPct: 50, fuelLevel2Pct: 50))
            let monotonic = ahead.odometerMiles == 26_000 && ahead.engineHours == 4_500
            print("  [\(monotonic ? "OK" : "FAIL")] a stale lower reading cannot rewind the odometer")
            if !monotonic { allPass = false }

            try? FileManager.default.removeItem(at: scratch)
        }

        // The app keeps the driver's Driving event open for ~370s after the link drops, so anything
        // recorded inside that window is classified as already assigned and vanishes. Withhold it.
        print("Offline backlog withholds what the app would silently discard:")
        do {
            let cfg = SimConfig.default
            let outageStart = Date(timeIntervalSince1970: 1_700_000_000)
            let e = EngineState(); e.ignitionOn = true; e.speedMph = 60
            func rec(_ offset: Double) -> Emitted {
                Emitted(wire: ScenarioRunner.toStored(MTPacket.livePosition(e, date: outageStart.addingTimeInterval(offset))),
                        kind: .stored)
            }
            // three inside the close window, two past it
            let batch = [rec(30), rec(120), rec(360), rec(400), rec(600)]
            let split = ScenarioRunner.deliverableStored(batch, outageStart: outageStart,
                                                        appDrivingCloseSec: cfg.appDrivingCloseSec)
            let ok = split.keep.count == 2 && split.dropped == 3
            print("  [\(ok ? "OK" : "FAIL")] kept \(split.keep.count)/5 past the \(Int(cfg.appDrivingCloseSec))s close, dropped \(split.dropped)")
            if !ok { allPass = false }

            // A short outage must yield nothing rather than a batch the app throws away.
            let shortBatch = [rec(30), rec(60), rec(90)]
            let shortSplit = ScenarioRunner.deliverableStored(shortBatch, outageStart: outageStart,
                                                             appDrivingCloseSec: cfg.appDrivingCloseSec)
            let emptied = shortSplit.keep.isEmpty && shortSplit.dropped == 3
            print("  [\(emptied ? "OK" : "FAIL")] a sub-\(Int(cfg.appDrivingCloseSec))s outage delivers nothing")
            if !emptied { allPass = false }

            // Unparseable records must never be silently dropped.
            let junk = [Emitted(wire: "GARBAGE", kind: .stored)]
            let junkSplit = ScenarioRunner.deliverableStored(junk, outageStart: outageStart,
                                                            appDrivingCloseSec: cfg.appDrivingCloseSec)
            let keptJunk = junkSplit.keep.count == 1 && junkSplit.dropped == 0
            print("  [\(keptJunk ? "OK" : "FAIL")] an unparseable record is kept, not dropped")
            if !keptJunk { allPass = false }

            // The scenario lead-in has to clear the same window, or S12 files zero UDPs.
            let clears = cfg.storedReplayLeadInSec > cfg.appDrivingCloseSec
            print("  [\(clears ? "OK" : "FAIL")] scenario lead-in \(Int(cfg.storedReplayLeadInSec))s clears the \(Int(cfg.appDrivingCloseSec))s close")
            if !clears { allPass = false }
        }

        // Operator-entered telemetry must never reach the packet builder as a trapping value.
        print("Telemetry edit bounds:")
        do {
            let bad = [Double.infinity, -Double.infinity, Double.nan, -1, 1e30, SimConfig.maxOdometerMiles + 1]
            let rejected = bad.allSatisfy { !SimConfig.isValidOdometer($0) }
            let good = SimConfig.isValidOdometer(25_000) && SimConfig.isValidOdometer(0)
                && SimConfig.isValidOdometer(SimConfig.maxOdometerMiles)
            print("  [\(rejected && good ? "OK" : "FAIL")] odometer rejects inf/nan/negative/oversize, accepts the real range")
            if !(rejected && good) { allPass = false }

            let hoursOk = !SimConfig.isValidEngineHours(.nan) && !SimConfig.isValidEngineHours(1e12)
                && SimConfig.isValidEngineHours(4_352.5)
            print("  [\(hoursOk ? "OK" : "FAIL")] engine hours rejects nan/oversize, accepts the real range")
            if !hoursOk { allPass = false }

            // Every accepted value must survive the packet builder without trapping.
            let e = EngineState(); e.odometerMiles = SimConfig.maxOdometerMiles; e.engineHours = SimConfig.maxEngineHours
            let built = MTPacket.livePosition(e)
            let fields = built.components(separatedBy: ",")
            let buildable = fields.count == 17 && Int(fields[4]) != nil && Int(fields[5]) != nil
            print("  [\(buildable ? "OK" : "FAIL")] the ceiling values still build a valid 17-field packet")
            if !buildable { allPass = false }
        }

        // A recorded drive must continue the live odometer, not restart from the config default —
        // otherwise the dump sits below the live stream and the FMCSA output gets milespowerup < milesinception.
        print("Stored replay continues the live odometer:")
        do {
            let liveOdo = 31_250.75, liveHrs = 5_001.25
            for s in Scenarios.all {
                let isStored: Bool
                switch s.transport { case .disconnect, .storedBacklog: isStored = true; default: isStored = (s.id == 12) }
                if !isStored { continue }
                let sr = ScenarioRunner.storedReplay(for: s, config: .default,
                                                     from: Date(timeIntervalSince1970: 1_700_000_000),
                                                     seed: (liveOdo, liveHrs, 25.9, -80.2))
                guard let first = sr.first, let t0 = ScenarioRunner.telemetryOf(first.wire),
                      let last = sr.last, let tN = ScenarioRunner.telemetryOf(last.wire) else {
                    print("  [FAIL] S\(s.id): could not read telemetry back"); allPass = false; continue
                }
                let startsAtLive = t0.odometerMiles >= liveOdo - 0.5 && t0.engineHours >= liveHrs - 0.01
                let movesForward = tN.odometerMiles >= t0.odometerMiles && tN.engineHours >= t0.engineHours
                let ok = startsAtLive && movesForward
                if !ok { allPass = false }
                print("  [\(ok ? "OK" : "FAIL")] S\(s.id): \(String(format: "%.1f", t0.odometerMiles)) → \(String(format: "%.1f", tN.odometerMiles)) mi (live was \(String(format: "%.1f", liveOdo)))")
            }
        }

        print("────────────────────────────────────────────────────────────")
        print(allPass ? "ALL CYCLES PASS ✓" : "FAILURES PRESENT ✗")
        return allPass ? 0 : 1
    }

    // MARK: per-packet validation against the app-mirrored decoder
    private static func validate(_ em: Emitted) -> String? {
        switch em.kind {
        case .raw:
            return MTDecoder.isValid(em.wire) ? nil : "control reply not recognized by app: '\(em.wire)'"
        case .malformed:
            return MTDecoder.isValid(em.wire) ? "malformed packet wrongly accepted: '\(em.wire)'" : nil
        case .live, .stored, .ignition:
            let frames = MTPacket.frame(em.wire)
            if frames.count > 9 { return "too many chunks (\(frames.count) > 9): '\(em.wire)'" }
            for fr in frames {
                guard let s = String(data: fr, encoding: .ascii) else { return "chunk not ASCII" }
                if !MTDecoder.isValid(s) { return "chunk rejected by app validator: '\(s)'" }
            }
            guard let reassembled = MTDecoder.reassemble(frames) else { return "reassembly failed: '\(em.wire)'" }
            if reassembled != em.wire { return "reassembly mismatch: '\(reassembled)' != '\(em.wire)'" }
            guard let d = MTDecoder.decode(reassembled) else { return "decode failed: '\(em.wire)'" }
            if !MTDecoder.validPrefixes.contains(d.type) { return "unknown packet type '\(d.type)'" }
            return nil
        }
    }

    // MARK: scenario-level invariants
    private static func scenarioInvariant(_ s: Scenario, _ em: [Emitted]) -> String? {
        switch s.id {
        case 2:   // engine off → at least one shutdown (ignition 0) ignition packet
            let hasShutdown = em.contains { $0.kind == .ignition && (MTDecoder.decode($0.wire)?.ignition == 0) }
            return hasShutdown ? nil : "expected a shutdown (ignition=0) event"
        case 6:   // disconnect → stored replay present (inline run() output)
            let stored = em.filter { $0.kind == .stored }.count
            let marker = em.contains { $0.wire.hasPrefix("LAST_STORED_PACKET") }
            return (stored > 0 && marker) ? nil : "expected stored replay after reconnect (got \(stored) stored)"
        case 7:
            let stored = em.filter { $0.kind == .stored }.count
            return stored == 30 ? nil : "expected 30 stored backlog packets, got \(stored)"
        case 8:
            let stored = em.filter { $0.kind == .stored }.count
            return stored == 300 ? nil : "expected 300 stored backlog packets, got \(stored)"
        case 9:   // duplicates: some consecutive identical wires
            var dup = false
            for i in 1..<max(1, em.count) where em[i].wire == em[i-1].wire && em[i].kind == .live { dup = true; break }
            return dup ? nil : "expected duplicate packets"
        case 11:   // parse failure injected + rejected
            return em.contains { $0.kind == .malformed } ? nil : "expected an injected malformed packet"
        default:
            // every scenario must emit at least one valid live packet
            return em.contains { $0.kind == .live } ? nil : "no live packets emitted"
        }
    }

    // MARK: encoder↔decoder round-trip on known values
    private static func roundTripUnit() -> String? {
        let e = EngineState()
        e.ignitionOn = true; e.speedMph = 63.5; e.odometerMiles = 70_123.0
        e.engineHours = 5_001.25; e.satellites = 9; e.idleRpmConfig = 700; e.rpmPerMphConfig = 26
        e.rpm = 700 + Int(63.5 * 26)
        let lp = MTPacket.livePosition(e)
        guard let d = MTDecoder.decode(lp) else { return "LP decode nil" }
        if d.type != "LP" { return "type \(d.type)" }
        if abs((d.speedMph ?? -1) - 63.5) > 1.0 { return "speed \(d.speedMph ?? -1)" }
        if abs((d.odometerMiles ?? -1) - 70_123.0) > 1.0 { return "odo \(d.odometerMiles ?? -1)" }
        if abs((d.engineHours ?? -1) - 5_001.25) > 0.02 { return "engHrs \(d.engineHours ?? -1)" }
        if d.ignition != 1 { return "ignition \(d.ignition ?? -1)" }
        if d.sats != 9 { return "sats \(d.sats ?? -1)" }
        if d.gpsLocked != true { return "gpsLock" }

        var dev = DeviceInfo(); dev.dtcCodes = ["P0143", "U0101"]
        guard let lv = MTDecoder.decode(MTPacket.version(dev)) else { return "LV decode nil" }
        if lv.vin != dev.vin { return "vin \(lv.vin ?? "")" }
        if lv.mcuFW != dev.mcuFW { return "mcuFW \(lv.mcuFW ?? "")" }
        guard let ld = MTDecoder.decode(MTPacket.dtc(dev.dtcCodes, ignition: 1, rpm: 700)) else { return "LD decode nil" }
        if ld.dtcCount != 2 { return "dtcCount \(ld.dtcCount ?? -1)" }
        if ld.dtcBlob != "0143C101" { return "dtcBlob \(ld.dtcBlob ?? "")" }
        return nil
    }

    // MARK: deterministic config per cycle (varies coverage)
    private static func configForCycle(_ cycle: Int) -> SimConfig {
        var c = SimConfig.default
        c.packetIntervalSec = [1.0, 0.5, 2.0, 1.0, 0.25, 1.5, 1.0, 0.5, 1.0, 1.0][cycle - 1]
        c.targetSpeedMph = [65, 55, 70, 45, 65, 60, 75, 50, 65, 62][cycle - 1]
        c.packetLossPct = Double([0, 0, 10, 0, 20, 0, 5, 0, 0, 0][cycle - 1])
        c.accelMphPerSec = [4, 6, 3, 5, 4, 4, 8, 4, 4, 4][cycle - 1]
        return c
    }
}
