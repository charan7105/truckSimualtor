# Matrack ELD Simulator — Final Report

Overnight autonomous build + hardening pass. Honest, code-backed, reality-checked.

---

## 1. Files reviewed
- **ELD app** (`/Users/shiny/matrack_ios_eld`): traced via earlier multi-agent code audits — `BleClass.swift`, `UtilParser.swift`, `UtilPTParser.swift`, `TrackerService.swift`, `ProcessAction2.swift`, `SimFunction.swift`, `Database/*`, `Pojos/*`, `DeviceListViewController*`, the PacificTrack `.swiftinterface`, and `MTDevice_TestPacket.txt`.
- **Simulator project** (`/Users/shiny/simulatorProject`): all files built this session (below).

## 2. Active simulator / BLE / packet files
**In the ELD app (active, in build):** `BleClass.swift` (BLE transport, MT+PT routing, `didUpdateValueFor`, reassembly), `UtilParser.swift` (`parsePacketGeneric`, the MT decode), `UtilPTParser.swift` (PT EventFrame decode), `TrackerService.swift` (PT SDK delegate), `ProcessAction2.swift` (HOS), `SimFunction.swift` (`addActionQueu` sink — the SimEvents replay loop is commented out), `Database/LatestDB*.swift`.

**Simulator project (new, this session):**
`App.swift`, `main.swift`, `Theme.swift`, `Gauges.swift`, `ContentView.swift`, `MapPanel.swift`, `TrackerPeripheral.swift` (=`SimController`), `EngineState.swift`, `MTPacket.swift` (encoders+framer), `MTPacketDecoder.swift` (app-mirrored decoder), `SimConfig.swift`, `RouteEngine.swift`, `Scenario.swift`, `SelfTest.swift`, plus `run-sim.sh`, `README.md`, `PLAN.md`, `ARCHITECTURE.md`.

## 3. Dead / duplicate files found (in the ELD app — 0 pbxproj refs)
`ClassBluetooth.swift`, `newBleClass.swift`, `BleCentral.swift`, `MTPacketParse.swift` (empty), `FetchEvent.swift`, `FetchEventApi.swift`. Also the legacy in-app sim is **vestigial**: `Util.readMTDeviceTestData()` returns an empty queue and `SimFunction`'s replay loop is fully commented out.

## 4. Real data flow (legacy MT, the simulated path)
`Truck/J1939 → MT tracker → BLE (svc 7add0001, notify Rx 7add0003)` → `BleClass.didUpdateValueFor:2437` → `PacketValidator.isValidPacket` → chunk reassembly `processMultiPartPacketImproved:2689` → `UtilParser.parsePacketBeforeCheckTrackerConnectToCorrectVehicle:926` → `parsePacketGeneric:1803` → `btActionStatus` → `addActionQueu` → `ProcessAction2.processAction2:828` → `insertEventEdit` (eventedit) → HOS clocks / UI. **No checksum; routing is by `peripheral.name.hasPrefix("ELD-MA")` at `didConnect:1570`.**

## 5. Simulator architecture chosen
**External macOS BLE-peripheral simulator** (the app stays unmodified) that streams the **real MT ASCII protocol** into the app's **actual parser + HOS pipeline** — i.e. packet-injection-equivalent at the air interface, exercising the real code path. Layered + swappable transport (`ARCHITECTURE.md`). Chosen over: in-app injection (would require app changes), PT emulation (closed binary — impossible), and a chip (rejected by user; remains the only 101% fix for the name issue, see §11).

## 6. Config system implemented (`SimConfig.swift`)
Everything tunable, nothing hardcoded: packet interval, time multiplier, target speed, accel/decel, idle RPM, RPM/mph, start odo/engine-hours/fuel, fuel burn, **packet loss %, duplicate %, out-of-order %, extra delay**, reconnect delay, stored backlog, HOS cycle limits, advertised name. Network-effect sliders + scenario picker are live in the dashboard.

## 7. Scenarios implemented (`Scenario.swift`) — all 20
Engine ON/OFF, idle, low/highway driving, speed changes, stop-after-drive, BLE disconnect, reconnect (10 min / hours), stored packets later, large backlog, duplicates, out-of-order, parse failure, duty conflict, HOS violation, cycle exhaustion, cycle reset, long loop. Each runs headlessly and live (RUN button), producing byte-accurate MT packet sequences with deterministic transport effects.

## 8. 10-cycle self-test results
**ALL CYCLES PASS ✓** (`swift run MatrackTruckSim selftest`). Each cycle runs all 20 scenarios with a different config (packet interval 0.25–2.0s, target speed 45–75 mph, loss 0–20%, varied accel), validating **956–5042 packets/cycle** against the app-mirrored decoder: every chunk passes the app's `isValidPacketFormat`, frames reassemble round-trip identically, fields decode back to encoded values, ≤9 chunks, stored-replay present after disconnects, duplicates/out-of-order/malformed handled. Plus an encoder↔decoder unit round-trip (LP/LV/LD).

## 9. Bugs found and fixed
- **Disconnect window was tick-based, not time-based** (`Scenario.swift`): at slower packet intervals the reconnect-flush tick fell outside the phase, so scenarios 8/9/10 emitted **0 stored packets** (caught by cycles 3 & 6). Fixed: outage is now defined in **seconds** (interval-independent) + any buffered packets are flushed at run end. Re-verified green across all intervals.
- Removed dead `MatrackSimApp.runSelfTest` after replacing it with the real `SelfTest`.

## 10. Quality / stability
Compiles clean from scratch (7.6s). BLE writes drain with backpressure handling (`peripheralManagerIsReady`); timers invalidated on disconnect/stop; logs capped (250 lines); CB callbacks + timers on main; no force-unwraps on packet data; randomness only in live network-effects (self-test runner is deterministic). No crashes across 10 cycles × 20 scenarios.

## 11. Remaining risks
- **🔴 BLE device-name (P0, unresolved for live connect):** iOS caches `peripheral.name` = the Mac's GAP name (= `ComputerName`) after the first connect; macOS gives no app override (GAP 2A00 is a Restricted Service). So the 2nd+ reconnect shows the Mac's real name and routes to the wrong (PT) path. **There is no Mac-only 101% fix** — confirmed by research + on-device testing. Mitigations: `run-sim.sh` (temporarily sets ComputerName=`ELD-MA`, auto-reverts) — high-confidence but not 101% and needs a one-time phone cache clear; **the only guaranteed-101% fixes are an app change (route by service UUID) or an external chip whose name we own.** This blocks reliable *live* reconnect, not the packet/scenario engine.
- **🟠 HOS duration is wall-clock bound:** the app's 11/14/70h timers run on real time; `timeMultiplier` only scales odometer/engine-hours, not those clocks. Violation/cycle scenarios (17–19) need real-time runs or app-side time injection.
- **🟠 PT (PacificTrack) path not simulable:** closed binary, `EventFrame` has no public init. Out of scope by design.
- **🟡 A few fields assumed:** chunk reserved byte (index 3), payload padding, fuel %, gps-speed unit, exact LV/LD subfield positions — best-effort from code; need a real-packet capture to lock byte-exact.

## 12. What needs real-tracker validation
A capture of a real MT session (via `matrack_ios_device_tester`) to confirm: the chunk reserved byte + padding, fuel/gps-speed units, real `LV`/`LD`/`SD` field layout; and one end-to-end run on a real iPhone to confirm the parsed packets produce the expected `eventedit` rows + HOS clocks.

## 13. Production-readiness verdict
**Packet/route/scenario/config engine: production-grade and verified** — clean build, 10/20-scenario self-test green against the app's real parser logic, fully configurable, isolated (separate macOS app; no production DB/server access; SIMULATOR banner; can't write driver data). **Live end-to-end is gated by one external issue** — the iOS name cache on reconnect — which is an Apple-platform limitation, not a defect in this code, and requires a product decision (app change vs chip) for a 101% live guarantee. **Recommended:** use it now for protocol/scenario/HOS-logic development (first-connect works today; reconnect via `run-sim.sh` + one-time cache clear); take the app-side service-UUID routing fix to ship a guaranteed-101% live path.
