# Test cases — simulator + ESP32 → ELD app

Simple pass/fail cases. Each one: **Do** (in the sim) → **Expect** (on the phone).
Setup: ESP32 flashed + plugged into the PC · sim app running, port picked, **LINK** on ·
phone with ELD app, **test account only** · nRF Connect (scanner) installed on the phone.

> Note: the ELD app has **no signal-bar display** — RSSI cases (1–3) are checked with the
> scanner app, not the ELD UI.

---

## A. ESP32 / signal (the hardware-only cases)

1. **Board shows up** — Power the board. → Scanner shows **ELD-MA**.
2. **RSSI moves** — Drag the sim's RSSI slider 100 → 0 → 100. → In the scanner, ELD-MA's RSSI drops ~20 dB and comes back.
3. **Presets** — Click FULL, then POOR. → Scanner RSSI strong (~+9 dBm) vs weak (~−6 dBm).
4. **Connect through the board** — Open the ELD app, connect to ELD-MA. → App connects; sim says "Device connected (ESP32)". iOS banner turns orange (engine off).
5. **Real out-of-range** — Click **DROP**. → ELD-MA vanishes from the scanner; ELD app disconnects (says/speaks "Bluetooth Disconnected"). Click **BACK** → app reconnects by itself.
6. **Walk-away vs slider — must behave the SAME** (the key equivalence test):
   - **6a. Real walk** — Slider at 100. Walk the phone away / behind a wall until the app disconnects. Walk back → it reconnects. Note what the app did (weak → disconnect → auto-reconnect, time it took).
   - **6b. Buttons only** — Phone next to the board. Drag the slider 100 → 25 → 0, wait for the disconnect, then slide back to 100 (or DROP → BACK).
   - **Pass:** the app behaves the **same** in 6a and 6b — same disconnect, same auto-reconnect, same stored-data replay after. That proves we can reproduce "driver walked away from the truck" with clicks, no walking.

## B. Engine & driving (duty status)

7. **Engine ON** — Toggle ENGINE on. → App records a Power-Up event; iOS banner goes orange → green.
8. **Engine OFF** — Toggle ENGINE off. → Shutdown event; speed goes 0.
9. **Auto Driving** — Set speed to 60 km/h (or run scenario 4 "Driving highway"). → When speed passes **5 mph**, app auto-switches to **Driving** and shows the driving screen.
10. **Idle ≠ Driving** — Engine on, speed 0 (scenario 3). → App stays **On-Duty**, never Driving.
11. **Stop → On-Duty** — Drive, then STOP and wait ~6 minutes (scenario 5). → App pops "change to On-Duty?"; if ignored ~1 more minute → auto **On-Duty** event.

## C. Disconnect & stored data

12. **Disconnect during drive** — Run scenario 6. → Link drops mid-drive, reconnects, buffered packets replay as stored data — **no miles lost**.
13. **Stored backlog** — Run scenario 7 (30 packets), then 8 (300 packets). → App processes them; no freeze, no corrupt logs.
14. **Fast dump** — Set Cadence 0.5 s, click DUMP STORED. → This is the known field stress case; app should survive (1.0 s must always pass).
15. **Unassigned driving** — Run scenario 12: log OUT of the app, sim drives 5 min, log back IN. → App shows an **Unidentified/Unassigned Driving** period to claim or reject.

## D. Bad data (app must not break)

16. **Duplicates** — Run scenario 9 (or Dup slider). → No double miles; duplicates dropped.
17. **Out-of-order** — Run scenario 10 (or Reorder slider). → App tolerates it, no crash.
18. **Malformed packet** — Run scenario 11. → App rejects it and keeps running.
19. **Silence** — In BLE mode use signal 0 / out-of-range. → App retries, then disconnects on its own (~30–75 s of silence) and auto-reconnects when data returns.

## E. Diagnostics & identity

20. **DTC codes** — Inject P0143 + P0217 in the sim's DIAGNOSTICS panel. → App's DTC screen lists them after its next read.
21. **Clear DTC** — Clear from the app (its Clear DTC button). → Sim receives `clrdtc`; codes gone on next read.
22. **VIN** — Edit the VIN in the sim (17 chars). → App picks up the new VIN; a wrong/mismatched VIN shows the VIN-mismatch popup (iOS).

## F. Fuel

23. **Low fuel** — Drag FUEL 1 below 15%. → Sim shows the low-fuel prompt; fuel level field updates in the app's BLE values screen. Refuel preset clears it.

---

**Must-pass core:** 1, 2, 4, 5 (ESP32 works + real RSSI) · 9, 11 (duty status) · 12, 15 (stored/UDP) · 18 (no crash).
