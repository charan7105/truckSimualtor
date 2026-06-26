# Matrack Truck Sim

A macOS **control-panel app** that turns your Mac into a legacy Matrack **MT** Bluetooth tracker, so the **unmodified** Matrack ELD app (on a real iPhone) connects to it and receives realistic engine data — for testing FMCSA/HOS calculations and diagnostics without the physical truck simulator.

**🔗 Team site (downloads + setup + field guide):** https://truck-simualtor.vercel.app

See `PLAN.md` (roadmap) and `ARCHITECTURE.md` (design).

## What it does
- Advertises over Bluetooth as **`ELD-MA`** with the tracker's GATT service/characteristics.
- Streams the **full MT data surface**: VIN + firmware/BLE version, ignition, rpm, speed, odometer, engine-hours, fuel, satellites, GPS (lat/lon/heading/lock), ECM, and J1939 **DTC fault codes**.
- Answers the app's commands like real firmware (`readdata`→`ACK,DATA`, `readvin`→`LV`, `readdtc`→`LD`, `clrdtc`, `stopdata`→`ACK,STOP`).
- A futuristic dashboard UI: glowing speedometer, telemetry panels, fuel ring, diagnostics, and a live packet console.

## Requirements
- A **Mac** with Bluetooth (a real Bluetooth radio — not over screen-share).
- A **real iPhone** (the iOS Simulator has no Bluetooth) with the Matrack ELD app, logged in to a **TEST account / test vehicle** (never production).
- The test vehicle should have **no stored tracker MAC** (fresh/unpaired) so the app accepts the simulator.

## Run it
```bash
cd /Users/shiny/simulatorProject
swift run
```
A dashboard **window** opens. First run: macOS asks to allow **Bluetooth** — click **Allow** (if denied, enable it in **System Settings ▸ Privacy & Security ▸ Bluetooth**). The status pill (top-right) goes **amber “Advertising as ELD-MA”**, then **green “iPhone connected”** once your phone joins.

## Using the control panel
- **Speedometer + presets** (STOP / 35 / 55 / 65) and a fine **speed slider**.
- **ENGINE** toggle (power up/down) and **AUTO** toggle (auto-drives to 65 mph hands-free).
- **Vehicle panel:** VIN + firmware; **fuel ring**; telemetry tiles (odometer, engine hours, RPM, heading, satellites, ECM).
- **Diagnostics:** tap a fault code (P0143 / P0217 / C0035 / U0101) to inject it; **CLEAR** removes them.
- **Live packet stream:** every `→` outgoing packet and `←` incoming app command, in real time.

## Test on the iPhone
1. In the ELD app, open the device scan/connect screen.
2. Find **`ELD-MA`** and **tap to connect** (tap — don’t type a MAC).
3. The dashboard pill turns green; the packet console shows `← readdata` then `→ LP,...`.
4. Leave **AUTO** on (or press **65**) — the app should show **~65 mph and switch to Driving**, plus the VIN, fuel, and satellites.
5. Tap a **fault code** — it should appear in the app’s diagnostics/fault list.

Verify packet encoders without Bluetooth: `swift run MatrackTruckSim selftest`

## Pass / fail
- **PASS:** iPhone connects to `ELD-MA` and shows speed/Driving + VIN + faults → proceed to Phase 3 (map routes) / Phase 4 (scenarios).
- **FAIL (won't connect / routes to "PT"):** likely the device-name behavior — note exactly where it stopped; we adjust or move the BLE to a $5–10 ESP32 chip (same protocol).

## Notes / to confirm with a real-packet capture
- The chunk-header "reserved" byte + padding are best-guess from code; a capture via the device-tester locks them byte-exact.
- Fuel %, GPS-speed unit, and a few DTC subfields are inferred from the parser; confirm against a real `LP`/`LV`/`LD` capture.
