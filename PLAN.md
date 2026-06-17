# Matrack Truck Simulator — Build Plan

A software replacement for the physical J1939/truck-simulator box. A desktop program pretends to be the legacy **MT** Bluetooth tracker so the **unmodified** Matrack iOS ELD app (on a real iPhone) connects to it and receives synthetic engine data — to test FMCSA/HOS calculations.

```
Mac/PC  ──Bluetooth (BLE)──▶  ELD App (real iPhone)
```

## Confirmed facts this is built on (from the ELD app source)
- GATT service `7add0001-f286-4c78-adda-520c4ba3500c`; char `7add0002` = app writes commands (`readdata`, `$wdg,4327`); char `7add0003` = app subscribes, we push data via Notify.
- App scans filtering on service `7add0001`, and treats a device as an MT tracker only if its **name starts `ELD-MA`**.
- Protocol is plain ASCII, **no checksum, no encryption, no pairing**. No VIN/version handshake required before data is parsed.
- The "correct vehicle" MAC check is bypassed when the test vehicle has no stored MAC. **No real anti-spoofing.**
- Packet (LP) format: `LP,<ign 0|1>,<rpm>,<speed km/h>,<odo ×10 km>,<engHrs ×100>,<lat>,<lon>,<gpsLock 2|3>,<heading>,<HHMMSS utc>,<DDMMYY utc>,<ecm>`. `LI,1`=power-up, `LI,0`=shutdown. Live=`L` prefix, Stored=`S`.
- App converts: speed km/h ÷1.60934 → mph; odometer raw ×0.0621371 → miles; engine-hours ÷100.
- HOS triggers: speed ≥5 mph + engine on → auto-Driving; stop (≤5 mph) → 300s+70s → auto-OnDuty.
- BLE framing the app reassembles: chunks `$<total><current><reserved><payload>`, total/current single decimal digits (≤9 chunks), assembled payload ends `$$`.

## Known risks (must be confirmed on real hardware)
- macOS drops an advertised name >8 bytes → we advertise the short name **`ELD-MA`** (6 bytes) and connect by tapping it in the app's list.
- Exact `reserved` byte (header index 3) + real padding — not derivable from code; lock via a real-packet capture (you have the device-tester).
- Bluetooth permission for the program on macOS (granted to Terminal/the app on first run).

---

## Phase 1 — Proof-of-concept (THIS REPO, build first)
Goal: prove a Mac can get the unmodified ELD app to connect and show live data.
- macOS Swift program (`MatrackTruckSim`) that advertises as `ELD-MA`, exposes the 3 characteristics, answers `readdata`, and streams `LP`/`LI` packets at 1 Hz.
- Minimal keyboard control (engine on/off, speed up/down, stop) to prove it is controllable.
- **Pass criteria:** iPhone discovers `ELD-MA`, connects, and the ELD app shows the speed and auto-switches to **Driving** at ≥5 mph.
- If it passes → the hard part is proven; proceed to Phase 2. If the name/connect fails → fall back to a $5–10 ESP32 BLE chip (same protocol).

## Phase 2 — Full Mac simulator app
- SwiftUI control panel: engine on/off, speed slider/dial, odometer/engine-hours, RPM.
- **Map + route driving:** pick start→destination (MapKit) or load a GPX; the sim "drives" the route, emitting realistic lat/lon, heading, speed, climbing odometer.
- Scenario engine (JSON): the 14 test scenarios (drive→stop, disconnect/reconnect, stored-packet replay, duplicates, out-of-order, HOS violation, etc.).
- Stored-packet replay (`S`-prefix) for reconnect/backlog scenarios.
- Live outbound-packet log + connection status.

## Phase 3 — J1939 diagnostics (DTC / fault codes)
- Emit `SD`/`LD` diagnostic packets (ASCII, not real CAN) to drive the app's fault-code/DTC list.
- Model the ignition-gated `readdtc`/`clrdtc` round-trip.
- Note: DTCs land in the diagnostics list, **not** the HOS malfunction pipeline.

## Phase 4 — Windows port
- Reuse the protocol/scenario logic; reimplement the BLE peripheral with Windows `GattServiceProvider` (C#/.NET).
- Windows forces the advertised name = PC computer name → rename the test PC to start with `ELD-MA`.
- Verify the PC's Bluetooth adapter supports the peripheral role (main Windows risk).

## Safety (operational — the ELD app is unmodified, so data is treated as real)
- Use a **dedicated test driver account + test vehicle**.
- Point the app at the **test server**, never production.
- **Never** trigger an FMCSA/DOT data transfer from the test phone.
- Keep the test device clearly labeled; wipe app data between runs.

## Validation
- Golden replay (feed known packets, diff resulting logs/clocks).
- Parity test: same drive on the hardware box vs the sim, diff the DB/logs.
