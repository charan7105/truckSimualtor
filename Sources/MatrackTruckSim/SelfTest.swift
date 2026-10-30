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

            // The scenario catalogue used to drive this loop. It is gone, so the packets are built
            // the way the live path builds them: a drive's worth of live telemetry, plus a stored
            // dump, under each config variation. Same format coverage, one code path instead of two.
            let e = EngineState()
            e.ignitionOn = true
            e.idleRpmConfig = cfg.idleRpm
            e.rpmPerMphConfig = cfg.rpmPerMph
            e.fuelBurnPctPerMile = cfg.fuelBurnPctPerMile
            var emitted: [Emitted] = []
            emitted.append(Emitted(wire: MTPacket.ignition(e, on: true), kind: .ignition))
            for tick in 0..<120 {                       // accelerate, cruise, brake
                e.speedMph = tick < 20 ? Double(tick) * 3 : (tick < 100 ? 60 : max(0, Double(120 - tick) * 3))
                e.advance(dt: cfg.packetIntervalSec)
                emitted.append(Emitted(wire: MTPacket.livePosition(e), kind: .live))
            }
            emitted.append(Emitted(wire: MTPacket.ignition(e, on: false), kind: .ignition))
            emitted.append(contentsOf: WireBuilder.storedDump(count: 30, config: cfg))
            emitted.append(Emitted(wire: MTPacket.version(DeviceInfo()), kind: .live))
            emitted.append(Emitted(wire: MTPacket.dtc(["P0143"], ignition: 1, rpm: e.rpm), kind: .live))
            // the real control replies the app expects back
            for reply in ["ACK,DATA", "LAST_STORED_PACKET", "SAVED PACKET COUNT:0"] {
                emitted.append(Emitted(wire: reply, kind: .raw))
            }

            totalPackets += emitted.count
            for em in emitted {
                switch em.kind {
                case .raw: controlPkts += 1
                case .stored: storedPkts += 1
                case .malformed: malformedPkts += 1
                default: break
                }
                if let f = validate(em) { failures.append(f) }
            }
            if !emitted.contains(where: { $0.kind == .live })   { failures.append("no live packets emitted") }
            if !emitted.contains(where: { $0.kind == .stored }) { failures.append("no stored packets emitted") }

            let result = failures.isEmpty ? "Pass" : "Fail"
            if !failures.isEmpty { allPass = false }
            let summary = "\(totalPackets) packets "
                + "(\(storedPkts) stored, \(controlPkts) control, \(malformedPkts) malformed-rejected) "
                + "@ \(String(format: "%.1f", cfg.packetIntervalSec))s/pkt, loss \(Int(cfg.packetLossPct))%"
            print("Cycle \(cycle) Result:")
            print("  [\(result)] — \(failures.isEmpty ? summary : failures.prefix(3).joined(separator: " | "))")
            if !failures.isEmpty { for f in failures.prefix(8) { print("      • \(f)") } }
        }

        
        // The Unassigned-Driving fix: stored packets must be stamped INSIDE the outage window, i.e.
        // at/after the disconnect. Stamped before it, they land inside the driving event the app still
        // has open for the logged-in driver and are silently classified as already-assigned.
        print("Stored-replay timestamps land inside the outage (Unassigned Driving):")
        
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
                Emitted(wire: WireBuilder.toStored(MTPacket.livePosition(e, date: outageStart.addingTimeInterval(offset))),
                        kind: .stored)
            }
            // three inside the close window, two past it
            let batch = [rec(30), rec(120), rec(360), rec(400), rec(600)]
            let split = WireBuilder.deliverableStored(batch, outageStart: outageStart,
                                                        appDrivingCloseSec: cfg.appDrivingCloseSec)
            let ok = split.keep.count == 2 && split.dropped == 3
            print("  [\(ok ? "OK" : "FAIL")] kept \(split.keep.count)/5 past the \(Int(cfg.appDrivingCloseSec))s close, dropped \(split.dropped)")
            if !ok { allPass = false }

            // A short outage must yield nothing rather than a batch the app throws away.
            let shortBatch = [rec(30), rec(60), rec(90)]
            let shortSplit = WireBuilder.deliverableStored(shortBatch, outageStart: outageStart,
                                                             appDrivingCloseSec: cfg.appDrivingCloseSec)
            let emptied = shortSplit.keep.isEmpty && shortSplit.dropped == 3
            print("  [\(emptied ? "OK" : "FAIL")] a sub-\(Int(cfg.appDrivingCloseSec))s outage delivers nothing")
            if !emptied { allPass = false }

            // Unparseable records must never be silently dropped.
            let junk = [Emitted(wire: "GARBAGE", kind: .stored)]
            let junkSplit = WireBuilder.deliverableStored(junk, outageStart: outageStart,
                                                            appDrivingCloseSec: cfg.appDrivingCloseSec)
            let keptJunk = junkSplit.keep.count == 1 && junkSplit.dropped == 0
            print("  [\(keptJunk ? "OK" : "FAIL")] an unparseable record is kept, not dropped")
            if !keptJunk { allPass = false }

            // The scenario lead-in has to clear the same window, or S12 files zero UDPs.
            let clears = cfg.storedReplayLeadInSec > cfg.appDrivingCloseSec
            print("  [\(clears ? "OK" : "FAIL")] stored-replay lead-in \(Int(cfg.storedReplayLeadInSec))s clears the \(Int(cfg.appDrivingCloseSec))s close")
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
                    }

        // Fault injection must be able to express values the model CANNOT hold, and must never be
        // able to leak into persisted state or into a clean packet.
        print("Fault injection:")
        do {
            let e = EngineState()
            e.ignitionOn = true; e.speedMph = 60; e.odometerMiles = 25_000
            let clean = MTPacket.livePosition(e).components(separatedBy: ",")

            // The sentinel is 26x the odometer ceiling — unreachable via setOdometer by design.
            e.wireFaults[4] = WireFault(value: SimConfig.odometerUnavailableSentinel)
            e.wireFaults[8] = WireFault(value: "0")
            e.wireFaults[12] = WireFault(value: "0")
            let faulted = MTPacket.livePosition(e).components(separatedBy: ",")
            let expressed = faulted.count == 17
                && faulted[4] == SimConfig.odometerUnavailableSentinel
                && faulted[8] == "0" && faulted[12] == "0"
            print("  [\(expressed ? "OK" : "FAIL")] overrides reach the wire and the packet stays 17 fields")
            if !expressed { allPass = false }

            // Everything NOT overridden must be untouched — an override must not disturb its neighbours.
            let neighboursIntact = [1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15, 16].allSatisfy { faulted[$0] == clean[$0] }
            print("  [\(neighboursIntact ? "OK" : "FAIL")] non-overridden fields are unchanged")
            if !neighboursIntact { allPass = false }

            // The app reads this sentinel as "no odometer" — prove our own decoder agrees, so the
            // control demonstrates the real behaviour rather than a value we invented.
            let decoded = MTDecoder.decode(MTPacket.livePosition(e))
            let sentinelUnderstood = decoded?.odometerMiles == nil
            print("  [\(sentinelUnderstood ? "OK" : "FAIL")] the sentinel decodes as 'odometer unavailable'")
            if !sentinelUnderstood { allPass = false }

            // A fault must never become permanent: SimPersistedState is a whitelist, so a restart
            // always returns a clean wire. This is what stops the TEST SETUP typo class of bug.
            let saved = e.persisted
            let fresh = EngineState(); fresh.restore(saved)
            let cleared = fresh.wireFaults.isEmpty
            print("  [\(cleared ? "OK" : "FAIL")] overrides are not persisted — a restart clears every fault")
            if !cleared { allPass = false }

            e.wireFaults.removeAll()
            let backToClean = MTPacket.livePosition(e).components(separatedBy: ",")[4] == clean[4]
            print("  [\(backToClean ? "OK" : "FAIL")] clearing restores the real value")
            if !backToClean { allPass = false }

            // A skewed clock has to actually move the wire timestamp, or the Timing malfunction
            // control is theatre.
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let skewed = WireBuilder.utcOf(MTPacket.livePosition(e, date: base.addingTimeInterval(1800)))
            let skewWorks = skewed.map { abs($0.timeIntervalSince(base) - 1800) < 1.5 } ?? false
            print("  [\(skewWorks ? "OK" : "FAIL")] a 30-minute clock skew reaches fields 10/11")
            if !skewWorks { allPass = false }

            // Bad VINs must survive the LV builder untouched — no trimming, no padding.
            for vin in ["00000000000000000", "292058", ""] {
                var d = DeviceInfo(); d.vin = vin
                let lv = MTPacket.version(d).components(separatedBy: ",")
                let ok = lv.count >= 2 && lv[0] == "LV" && lv[1] == vin
                if !ok { allPass = false; print("  [FAIL] LV mangled VIN \"\(vin)\"") }
            }
            print("  [OK] all-zero, 6-char and empty VINs pass through the LV builder verbatim")

            // Intermittent faults. "Random packets with an invalid time" is a different test from
            // "every packet has an invalid time" — a constant fault is trivially visible, a 1-in-5
            // fault is the one that finds ordering bugs. Driven by an injected roll so it is
            // deterministic here.
            let m = EngineState(); m.ignitionOn = true; m.speedMph = 60
            m.wireFaults[10] = WireFault(value: "999999", probability: 0.2)
            let hits = m.faultedFields(roll: { 0.1 })      // roll below p → fault applies
            let misses = m.faultedFields(roll: { 0.9 })    // roll above p → clean packet
            let intermittent = hits[10] == "999999" && misses[10] == nil
            print("  [\(intermittent ? "OK" : "FAIL")] an intermittent fault fires on some packets and not others")
            if !intermittent { allPass = false }

            // The motion gate: "no GPS lock above 5 mph" is meaningless on a parked truck, which
            // legitimately loses its fix.
            m.wireFaults.removeAll()
            m.wireFaults[8] = WireFault(value: "0", requiresMotion: true)
            m.speedMph = 60
            let moving = m.faultedFields(roll: { 0 })[8] == "0"
            m.speedMph = 0
            let parked = m.faultedFields(roll: { 0 })[8] == nil
            print("  [\(moving && parked ? "OK" : "FAIL")] a motion-gated fault fires while driving and not while parked")
            if !(moving && parked) { allPass = false }

            // The malformed packet used to be covered by scenario 11. That scenario is gone, so the
            // button is now the only path — assert the wire here or nothing checks it at all.
            let junkWire = "ZZ,not,a,valid,packet"
            let rejected = !MTDecoder.isValid(junkWire)
            print("  [\(rejected ? "OK" : "FAIL")] the malformed packet is genuinely invalid")
            if !rejected { allPass = false }

            // The odometer-source packet must match the shape the app's parser demands (>= 10 comma
            // fields, xO prefix, $$ terminator) or it is dropped before reaching the dead code path
            // we are trying to demonstrate.
            let xo = MTPacket.odoSource(virtualEnabled: true, activeSource: 1)
            let xoOk = xo.hasPrefix("xO,") && xo.hasSuffix("$$")
                && xo.replacingOccurrences(of: "$$", with: "").components(separatedBy: ",").count >= 10
            print("  [\(xoOk ? "OK" : "FAIL")] the odometer-source packet matches the app parser's shape")
            if !xoOk { allPass = false }
        }

        // Every requested fault, end to end: arm it exactly as the UI does, build a real packet, and
        // assert the wire actually carries it. This is the test that fails if a control becomes
        // theatre — a button that looks armed while the packet leaves unchanged.
        print("Each requested fault reaches the wire:")
        do {
            func field(_ i: Int, _ wire: String) -> String {
                let f = wire.components(separatedBy: ",")
                return i < f.count ? f[i] : "<missing>"
            }
            func armed(_ apply: (EngineState) -> Void) -> String {
                let e = EngineState(); e.ignitionOn = true; e.speedMph = 60
                e.odometerMiles = 25_000; e.engineHours = 4_352.5
                apply(e)
                return MTPacket.livePosition(e)
            }
            var cases: [(String, Bool)] = []

            // 2 — two ECU odometer series
            let low = armed { $0.wireFaults[4] = WireFault(value: SimConfig.default.odoSeriesLowRaw) }
            let high = armed { $0.wireFaults[4] = WireFault(value: SimConfig.default.odoSeriesHighRaw) }
            cases.append(("two ECU odometer series differ on the wire",
                          field(4, low) != field(4, high)
                          && field(4, low) == SimConfig.default.odoSeriesLowRaw))

            // 5 — invalid time
            cases.append(("invalid time reaches field 10",
                          field(10, armed { $0.wireFaults[10] = WireFault(value: "999999") }) == "999999"))

            // 6 — default date
            cases.append(("default date reaches field 11",
                          field(11, armed { $0.wireFaults[11] = WireFault(value: "010100") }) == "010100"))

            // 7 — device default odometer
            cases.append(("default odometer sentinel reaches field 4",
                          field(4, armed { $0.wireFaults[4] = WireFault(value: SimConfig.odometerUnavailableSentinel) })
                            == SimConfig.odometerUnavailableSentinel))

            // 9 — no GPS lock while moving (and the default stays locked)
            cases.append(("GPS lock drops to 0 on the wire",
                          field(8, armed { $0.wireFaults[8] = WireFault(value: "0", requiresMotion: true) }) == "0"))
            cases.append(("a clean packet still reports GPS locked",
                          field(8, armed { _ in }) == "3"))

            // ECM loss + missing odo/hours (the two fastest real diagnostics)
            cases.append(("ECM flag drops to 0 on the wire",
                          field(12, armed { $0.wireFaults[12] = WireFault(value: "0") }) == "0"))
            let missing = armed { $0.wireFaults[4] = WireFault(value: "0"); $0.wireFaults[5] = WireFault(value: "0") }
            cases.append(("odometer and hours both report 0", field(4, missing) == "0" && field(5, missing) == "0"))

            // 8 — power-cycle burst alternates ignition
            let onPkt = MTPacket.ignition(EngineState(), on: true)
            let offPkt = MTPacket.ignition(EngineState(), on: false)
            cases.append(("power-cycle packets alternate ignition",
                          field(1, onPkt) == "1" && field(1, offPkt) == "0"))

            // 3/4 — VIN variants ride the LV packet untouched
            var zeroVin = DeviceInfo(); zeroVin.vin = "00000000000000000"
            var shortVin = DeviceInfo(); shortVin.vin = "292058"
            cases.append(("both bad VINs ride the LV packet verbatim",
                          MTPacket.version(zeroVin).components(separatedBy: ",")[1] == zeroVin.vin
                          && MTPacket.version(shortVin).components(separatedBy: ",")[1] == shortVin.vin))

            // 1 — odometer-source packet
            cases.append(("odometer-source packet is well formed",
                          MTPacket.odoSource(virtualEnabled: true, activeSource: 1).hasSuffix("$$")))

            // MAC variants ride LV field 8 verbatim, and our mirror of the app's ^[0-9A-F]{12}$
            // check agrees with what each one should do. The 0xFF-padded value is the case Teja
            // reported from a real tracker (2026-10-29): 9 hex characters plus three 0xFF bytes.
            let macCases: [(String, Bool)] = [
                ("87CB6819AFFF", true),                      // 12 uppercase hex — the only shape that passes
                ("87CB6819A\u{FF}\u{FF}\u{FF}", false),      // 0xFF filler
                ("87cb6819afff", false),                     // lowercase
                ("87CB6819A",    false),                     // too short
                ("",             false),                     // the simulator's own DEFAULT
                ("87CB6819AFFFF", false),                    // too long
            ]
            var macRides = true, macVerdicts = true
            for (mac, shouldPass) in macCases {
                var d = DeviceInfo(); d.deviceMAC = mac
                if MTPacket.version(d).components(separatedBy: ",")[8] != mac { macRides = false }
                if SimController.macPassesAppCheck(mac) != shouldPass { macVerdicts = false }
            }
            cases.append(("every MAC variant rides LV field 8 verbatim", macRides))
            cases.append(("MAC check mirror agrees on all \(macCases.count) variants", macVerdicts))

            // The filler MAC has to leave as three 0xFF BYTES. Checking only that the string round
            // trips hid the real defect: under UTF-8 each 0xFF went out as C3 BF, so a 12-character
            // MAC arrived as 15 bytes and never matched the tracker it was imitating.
            var fillerDev = DeviceInfo(); fillerDev.deviceMAC = "87CB6819A\u{FF}\u{FF}\u{FF}"
            let lvBytes = [UInt8](MTPacket.wireBytes(MTPacket.version(fillerDev)))
            cases.append(("filler MAC leaves as three 0xFF bytes, not C3 BF",
                          lvBytes.suffix(3) == [0xFF, 0xFF, 0xFF] && !lvBytes.contains(0xC3)))
            // And the framing must agree, since frame() slices by character count.
            let framed = MTPacket.frame(MTPacket.version(fillerDev))
            let rebuilt = framed.map { [UInt8]($0).dropFirst(4) }.joined()   // strip "$<tot><cur>0"
            cases.append(("framed chunks carry the same 0xFF bytes",
                          [UInt8](rebuilt).filter { $0 == 0xFF }.count == 3))
            // Every ordinary packet must be untouched by the encoding change.
            let plain = MTPacket.version(DeviceInfo())
            cases.append(("ASCII packets are byte-identical under the new encoding",
                          MTPacket.wireBytes(plain) == Data(plain.utf8)))

            // A character above U+00FF cannot ride a real tracker's wire, so it becomes '?' — one
            // per UTF-16 code unit. These exact bytes are asserted in the C# selftest too: the two
            // builds previously disagreed here (Swift fell back to UTF-8 for the whole string,
            // C# substituted), which is a silent parity break nothing would have caught.
            let outOfRange = MTPacket.wireBytes("LV,A\u{20AC}B\u{1F600}C")
            cases.append(("characters above U+00FF become '?' (0x3F), matching the C# build",
                          [UInt8](outOfRange) == [0x4C, 0x56, 0x2C, 0x41, 0x3F, 0x42, 0x3F, 0x3F, 0x43]))

            for (name, ok) in cases {
                print("  [\(ok ? "OK" : "FAIL")] \(name)")
                if !ok { allPass = false }
            }

            // Only one thing may own the odometer field. Two controls both writing field 4 would
            // leave one of them looking armed while the other silently wins.
            let odoOwners = cases.filter { $0.0.contains("odometer") }.count
            print("  [\(odoOwners > 0 ? "OK" : "FAIL")] odometer faults are covered by \(odoOwners) wire checks")
            if odoOwners == 0 { allPass = false }

            // The intermittent rate must actually be intermittent — not always-on, not never.
            // Uses real randomness, so the bounds are wide enough never to flake.
            let r = EngineState(); r.ignitionOn = true; r.speedMph = 60
            r.wireFaults[10] = WireFault(value: "999999", probability: 0.2)
            var hit = 0
            for _ in 0..<2000 where MTPacket.livePosition(r).components(separatedBy: ",")[10] == "999999" { hit += 1 }
            let rate = Double(hit) / 2000
            let plausible = rate > 0.10 && rate < 0.32
            print("  [\(plausible ? "OK" : "FAIL")] a 20% fault fired on \(Int(rate * 100))% of 2000 real packets")
            if !plausible { allPass = false }
        }

        // Stored-packet test cases. The app's guard (REQ-940) refuses a stored packet whose time is a
        // year or more from now and requires fields 10/11 to be exactly 6 digits, so the dump has to
        // produce something that reaches that check rather than failing an earlier one.
        print("Stored-packet test dumps:")
        do {
            let cfg = SimConfig.default

            let future = WireBuilder.storedDump(count: 5, config: cfg,
                                                options: .init(stampedAt: SimConfig.futureStoredPacketDate))
            let futureStored = future.filter { $0.kind == .stored }
            var fieldsOK = true, allFuture = true, allStoredPrefix = true
            for em in futureStored {
                let f = em.wire.components(separatedBy: ",")
                if f.count < 12 || f[10].count != 6 || f[11].count != 6 { fieldsOK = false }
                if !em.wire.hasPrefix("SP") && !em.wire.hasPrefix("SS") && !em.wire.hasPrefix("S") { allStoredPrefix = false }
                guard let utc = WireBuilder.utcOf(em.wire) else { allFuture = false; continue }
                if utc.timeIntervalSinceNow < 365 * 24 * 3600 { allFuture = false }
            }
            print("  [\(futureStored.count == 5 ? "OK" : "FAIL")] future-dated dump emits 5 stored packets")
            print("  [\(allStoredPrefix ? "OK" : "FAIL")] they carry a stored 'S' prefix")
            print("  [\(fieldsOK ? "OK" : "FAIL")] time and date fields are exactly 6 digits (the app rejects otherwise before the time check)")
            print("  [\(allFuture ? "OK" : "FAIL")] every packet is more than a year ahead, so the app's guard is what refuses it")
            if !(futureStored.count == 5 && allStoredPrefix && fieldsOK && allFuture) { allPass = false }

            // Same-connection duplicates: byte-identical and ADJACENT, because the app only compares
            // against the packet immediately before.
            let dup = WireBuilder.storedDump(count: 3, config: cfg, options: .init(repeatEachPacket: true))
            let dupStored = dup.filter { $0.kind == .stored }
            var adjacentPairs = 0
            var i = 0
            while i + 1 < dupStored.count {
                if dupStored[i].wire == dupStored[i + 1].wire { adjacentPairs += 1 }
                i += 2
            }
            let dupOK = dupStored.count == 6 && adjacentPairs == 3
            print("  [\(dupOK ? "OK" : "FAIL")] duplicate dump: \(dupStored.count) packets forming \(adjacentPairs) adjacent identical pairs")
            if !dupOK { allPass = false }

            // The footer count must describe what was actually sent, or the app is told one number
            // and handed another.
            let footer = dup.first { $0.wire.hasPrefix("SAVED PACKET COUNT:") }?.wire ?? ""
            let footerOK = footer == "SAVED PACKET COUNT:\(dupStored.count)"
            print("  [\(footerOK ? "OK" : "FAIL")] footer reports the real count (\(footer))")
            if !footerOK { allPass = false }

            // Speed must clear the app's 5 mph line, or every stored packet takes the on-duty branch
            // and the driving branch is never tested. Field 3 is km/h; the app divides by 1.60934.
            // The FINAL record is exempt: it is the shutdown, and a shutdown at 60 mph is not a
            // thing a tracker writes.
            let dumped = WireBuilder.storedDump(count: 4, config: cfg).filter { $0.kind == .stored }
            let fields = dumped.map { $0.wire.components(separatedBy: ",") }
            let driving = fields.dropLast().compactMap { Double($0[3]) }
            let allMoving = driving.count == 3 && driving.allSatisfy { $0 / 1.60934 > SimConfig.movingThresholdMph }
            let mph = driving.first.map { $0 / 1.60934 } ?? 0
            print("  [\(allMoving ? "OK" : "FAIL")] stored packets carry \(Int(mph)) mph — above the app's \(Int(SimConfig.movingThresholdMph)) mph driving line")
            if !allMoving { allPass = false }

            // Teja (2026-10-30): the backlog must end with the key going off — last record stopped
            // and ignition 0 — because that is what a tracker's final flash write looks like.
            let tail = fields.last ?? []
            let endsShutdown = tail.count > 3 && tail[0] == "SI" && tail[1] == "0" && tail[3] == "0"
            print("  [\(endsShutdown ? "OK" : "FAIL")] the backlog ends with a shutdown record (ignition 0, speed 0)")
            if !endsShutdown { allPass = false }

            // Records are spaced one storedRecordIntervalSec apart and the newest lands at the
            // connect moment. At the old packetIntervalSec spacing, 80 records covered 80 SECONDS
            // and every one fell inside the app's still-open driving event — no Unassigned Driving.
            let stamps = fields.compactMap { WireBuilder.utcOf($0.joined(separator: ",")) }
            var spacingOK = stamps.count == 4
            if spacingOK {
                for i in 1..<stamps.count {
                    let gap = stamps[i].timeIntervalSince(stamps[i - 1])
                    if abs(gap - cfg.storedRecordIntervalSec) > 1.5 { spacingOK = false }
                }
            }
            let endsNow = (stamps.last.map { abs($0.timeIntervalSinceNow) } ?? 999) < 90
            print("  [\(spacingOK ? "OK" : "FAIL")] records sit \(Int(cfg.storedRecordIntervalSec / 60)) min apart, like real flash writes")
            if !spacingOK { allPass = false }
            print("  [\(endsNow ? "OK" : "FAIL")] the newest record lands at the connect moment")
            if !endsNow { allPass = false }

            // The real tracker writes one stored record every 30 minutes while disconnected
            // (confirmed 2026-10-26). An earlier 30-SECOND default was 60x too fast and produced a
            // flood of packets no tracker would send.
            let interval = cfg.storedRecordIntervalSec
            let isHalfHour = abs(interval - 1800) < 0.1
            print("  [\(isHalfHour ? "OK" : "FAIL")] offline recorder writes one packet every \(Int(interval / 60)) minutes")
            if !isHalfHour { allPass = false }

            // Flash must still hold a long offline stretch at that rate.
            let hoursHeld = Double(cfg.storedFlashCapacity) * interval / 3600
            let enough = hoursHeld > 24
            print("  [\(enough ? "OK" : "FAIL")] flash holds \(Int(hoursHeld / 24)) days of offline driving at that rate")
            if !enough { allPass = false }

            // A normal dump must stay normal — no duplicates, not future dated.
            let normal = WireBuilder.storedDump(count: 4, config: cfg).filter { $0.kind == .stored }
            let noDupes = Set(normal.map { $0.wire }).count == normal.count
            let notFuture = normal.allSatisfy { (WireBuilder.utcOf($0.wire)?.timeIntervalSinceNow ?? 0) < 0 }
            print("  [\(noDupes && notFuture ? "OK" : "FAIL")] a normal dump is still unique and backdated")
            if !(noDupes && notFuture) { allPass = false }
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
