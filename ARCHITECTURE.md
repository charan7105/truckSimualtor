# Matrack Truck Sim — Architecture (powerful + accurate)

Design goal: a software truck/tracker that the **unmodified** ELD app cannot tell apart from real hardware, for HOS + diagnostics testing. Two non-negotiables:
- **Accurate** — every byte, unit, timing, and handshake matches the real MT tracker, and we *prove* it.
- **Powerful** — full data surface (VIN, engine, GPS, events, DTC), real map-route driving, and every test scenario, all controllable.

## 1. Design principles
1. **Single source of truth = the app's own parser.** Every encoder is the mathematical inverse of `UtilParser` (e.g. wire km/h = mph × 1.60934; raw odo = miles ÷ 0.0621371; engHrs = hours × 100). We derive, never guess.
2. **Round-trip provable.** Encode → decode must equal the input; and a real captured packet → decode → re-encode must be **byte-identical**. This is the accuracy gate.
3. **Physically consistent state.** Odometer integrates speed over time; engine-hours integrate run-time; GPS follows a real route; values are monotonic. No teleporting numbers (which the app's monotonicity guards would reject anyway).
4. **Faithful firmware behavior.** Correct command/response handshake, watchdog cadence, 1 Hz live packets, intermediate-log timing, and stored-packet replay on reconnect.
5. **Capture-validated.** The few things not derivable from code (chunk "reserved" byte, padding, exact handshake timing) are locked from one real-tracker capture before we call them done.
6. **Safe by construction.** Test account + test server only; never a real driver; never an FMCSA submit.

## 2. Layered architecture (each layer swappable + testable)

```
┌─ Control & Visualization (SwiftUI) ── control panel · live gauges · map · packet log · scenario runner
├─ Validation Harness ───────────────── golden-replay · round-trip tests · parity-vs-hardware
├─ Scenario Engine ──────────────────── declarative timelines: drive/stop/disconnect/reconnect/stored/DTC/violation
├─ Route & GPS Engine ───────────────── MapKit routing or GPX → interpolate lat/lon/heading/speed each tick
├─ Vehicle/Engine Model ─────────────── state: ignition,rpm,speed,odo,engHrs,fuel,sats,GPS,VIN,version,DTCs (+physics)
├─ Firmware Emulation ───────────────── command responder · handshake · watchdog · stored-packet buffer · ACK semantics
├─ Protocol Codec ───────────────────── encode+DECODE every packet (LP/LI/LS/LV/LD/SP/SI/SS/SD/…) · chunk framer
└─ Transport (pluggable) ────────────── MacCorePeripheral (now) | WindowsGatt (later) | ESP32Serial (fallback)
```

**Why these boundaries:**
- **Transport is an interface** (`advertise()`, `onCommand`, `notify(Data)`) → Mac now, Windows/ESP32 later with zero changes above it.
- **Protocol Codec encodes *and* decodes** → decoding is what makes us provably accurate (round-trip + capture replay) and lets the Validation Harness read real captures.
- **Firmware Emulation is separate from the engine model** → the "device behavior" (handshake, watchdog, stored flush, ACKs) is faithful regardless of what data is flowing.
- **Scenario/Route engines drive the model, not the wire** → one scenario produces correct packets across any transport.

## 3. Accuracy mechanisms (how we guarantee fidelity)
- **Inverse-of-parser encoders** with unit tests for every field (mph↔km/h, miles↔raw odo, hours↔×100, UTC HHMMSS/DDMMYY, lat/lon precision, DTC SPN/FMI hex).
- **Round-trip test suite:** `decode(encode(state)) == state` for all packet types.
- **Capture replay:** feed the bundled real packets (`MTDevice_TestPacket.txt`) + any new captures through our decoder, re-encode, assert **byte-identical** framing. Locks the reserved byte/padding.
- **Golden-replay test:** drive a known scenario, then assert the app's resulting DB rows / duty clocks / events match a saved baseline.
- **Parity test (acceptance gate):** same drive on the physical truck box vs the sim → diff the app's logs. This is the definition of "accurate enough."
- **Monotonicity + sentinels respected:** never emit values the app rejects (e.g. odo jumps that fail its digit-length guard, or `8191` rpm / `4294967295` sentinels) unless a scenario explicitly tests that rejection.

## 4. Power features (capability set)
- **Full data surface:** VIN, firmware/BLE version, ignition, rpm, speed, odometer, engine-hours, fuel, satellites, GPS (lat/lon/heading/lock), DTC/fault codes — every type the app can display.
- **Real route driving:** pick start→destination on a map (MapKit) or load a GPX; the rig "drives" it with realistic speed/heading/odometer/GPS, including stops at lights.
- **Scenario library (the 14 + custom):** engine on/off, speed sweeps, stop-after-drive, BLE disconnect/reconnect (10 min & hours), stored-packet replay, large backlog, duplicates, out-of-order, duty-status conflict, HOS violation, DTC/fault injection.
- **Record & replay:** capture a real tracker session and replay it deterministically (great for regression).
- **Live control panel + map + packet log;** one-click scenarios and manual override.
- **Multi-transport:** Mac today; Windows (`GattServiceProvider`) and ESP32 (fallback) behind the same interface.

## 5. Safety / isolation
Dedicated test driver + test vehicle (no stored MAC); test server only; on-screen SIMULATOR banner; never trigger FMCSA/DOT transfer; wipe app data between runs.

## 6. Build phases
- **P1 (done):** POC — `ELD-MA` advertise + `readdata` + `LP`/`LI` stream. ✅ Proven on a real iPhone.
- **P2 — Protocol completeness:** full `LP` fields + `LI`/`LS` + **VIN (`LV`)** + command responder (handshake/watchdog/ACK) + round-trip tests. *(field spec from the running mapping)*
- **P3 — Engine model + map routes:** physics + MapKit/GPX route driving.
- **P4 — Scenario engine:** the 14 scenarios incl. disconnect/reconnect + stored replay (`S`-packets).
- **P5 — DTC/J1939 fault codes** (`LD`/`SD` + read/clear flow).
- **P6 — Control-panel UI + validation harness** (golden-replay, parity).
- **P7 — Windows port** (same layers; `GattServiceProvider`).

## 7. Needs a real capture to be byte-exact
- Chunk header "reserved" byte (index 3) + payload padding scheme.
- Exact handshake timing/responses (`ACK,DATA`, watchdog interval, stored-flush order).
- Real `LV` (VIN) and `LD` (DTC) payloads to confirm field positions.
*(You have a real tracker + the device-tester — one capture session locks all of these.)*
