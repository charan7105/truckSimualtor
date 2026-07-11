# Test cases — ESP32 + Simulator + ELD app

How to use: do each step, then check the ✅. If it happens → PASS. If not → FAIL, write down what you saw.

**Setup:** ESP32 plugged into the PC · sim running → pick the port → click **LINK** · phone with ELD app (test account) · install **nRF Connect** on the phone (free Bluetooth scanner — we need it because the ELD app never shows signal strength).

---

## A. Board & signal

**1. Board is alive**
Power the board.
✅ nRF Connect shows a device called **ELD-MA**.

**2. Signal control works**
Drag the sim's **RSSI slider** down to 0, then back to 100.
✅ In nRF Connect, ELD-MA's signal gets much weaker, then strong again.

**3. FULL / POOR buttons**
Click **FULL**, then **POOR**.
✅ Signal strong on FULL, clearly weaker on POOR.

**4. Phone connects**
Open the ELD app and connect to ELD-MA.
✅ App connects. Sim says "Device connected (ESP32)".

**5. DROP / BACK**
Click **DROP**.
✅ Phone loses the device ("Bluetooth Disconnected").
Click **BACK**.
✅ Phone reconnects by itself.

**6. Walking away = moving the slider (must match)**
a) Slider at 100. **Walk away** with the phone until it disconnects, walk back — it reconnects.
b) Come back, stand still. Do the same with **only the slider**: 100 → 0, wait, → 100.
✅ The app behaves the **same** both times. That means clicks can replace walking.

## B. Engine & driving

**7. Engine ON**
Toggle **ENGINE** on.
✅ App logs a power-up event.

**8. Engine OFF**
Toggle **ENGINE** off.
✅ App logs a shutdown, speed shows 0.

**9. Driving starts by itself**
Set speed to 60 km/h.
✅ App switches to **Driving** on its own (happens just past 5 mph).

**10. Idling is not driving**
Engine on, speed 0. Wait a bit.
✅ App stays **On-Duty** — never flips to Driving.

**11. Stopping ends driving**
Drive, then press **STOP** and wait ~6 minutes.
✅ App asks "change to On-Duty?" — and if you ignore it, it switches by itself.

## C. Losing connection & saved data

**12. Disconnect while driving** (run scenario **6** in the sim)
✅ Link drops mid-drive, reconnects, and the missed miles come back — nothing lost.

**13. Saved packets** (run scenario **7**, then **8**)
✅ App handles 30 saved packets, then 300 — no freeze, no bad logs.

**14. Fast dump**
Set Cadence to **0.5s**, click **DUMP STORED**.
✅ App survives it. (Also try 1.0s — that one must always work.)

**15. Driving with nobody logged in** (run scenario **12**)
Log OUT of the app → sim drives 5 min → log back IN.
✅ App shows an **Unassigned Driving** period and asks you to claim or reject it.

## D. Bad data — app must never crash

**16. Duplicates** (scenario **9**) → ✅ no double miles.
**17. Wrong order** (scenario **10**) → ✅ app handles it.
**18. Garbage packet** (scenario **11**) → ✅ app ignores it, keeps running.
**19. Silence** — set signal to 0 and wait.
✅ App retries, disconnects on its own within ~1 minute, reconnects when data returns.

---

## The 9 that matter most
**1, 2, 4, 5** (board + signal) · **9, 11** (driving on/off) · **12, 15** (lost data comes back) · **18** (no crash).
If these 9 pass, we ship it.
