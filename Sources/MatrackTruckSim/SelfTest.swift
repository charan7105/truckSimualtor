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
            switch s.transport { case .disconnect, .storedBacklog: isStored = true; default: isStored = (s.id == 21) }
            if !isStored { continue }
            let sr = ScenarioRunner.storedReplay(for: s, config: .default)
            let n = sr.count
            let allStored = !sr.isEmpty && sr.allSatisfy { $0.kind == .stored }
            var valid = true
            for em in sr where validate(em) != nil { valid = false; break }
            var ok = allStored && valid && n > 0
            if s.id == 11 && n != 30 { ok = false }
            if s.id == 12 && n != 300 { ok = false }
            if !ok { allPass = false }
            print("  [\(ok ? "OK" : "FAIL")] S\(s.id) \(s.name): \(n) backdated stored packets")
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
        case 2, 19:   // engine off → at least one shutdown (ignition 0) ignition packet
            let hasShutdown = em.contains { $0.kind == .ignition && (MTDecoder.decode($0.wire)?.ignition == 0) }
            return hasShutdown ? nil : "expected a shutdown (ignition=0) event"
        case 8, 9, 10:   // disconnect → stored replay present
            let stored = em.filter { $0.kind == .stored }.count
            let marker = em.contains { $0.wire.hasPrefix("LAST_STORED_PACKET") }
            return (stored > 0 && marker) ? nil : "expected stored replay after reconnect (got \(stored) stored)"
        case 11:
            let stored = em.filter { $0.kind == .stored }.count
            return stored == 30 ? nil : "expected 30 stored backlog packets, got \(stored)"
        case 12:
            let stored = em.filter { $0.kind == .stored }.count
            return stored == 300 ? nil : "expected 300 stored backlog packets, got \(stored)"
        case 13:   // duplicates: some consecutive identical wires
            var dup = false
            for i in 1..<max(1, em.count) where em[i].wire == em[i-1].wire && em[i].kind == .live { dup = true; break }
            return dup ? nil : "expected duplicate packets"
        case 15:   // parse failure injected + rejected
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
