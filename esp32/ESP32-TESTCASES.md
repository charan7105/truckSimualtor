# Test cases — ESP32 + Simulator + ELD app

How to use: do each step, then check the ✅. If it happens → PASS. If not → FAIL, write down what you saw.

**Setup:** ESP32 plugged into the PC · sim running → pick the port → click **LINK** · phone with ELD app (test account) · install **nRF Connect** on the phone (free Bluetooth scanner — we need it because the ELD app never shows signal strength).

---

## A. Board basics

**1. Board is alive**
Power the board.
✅ nRF Connect shows a device called **ELD-MA**.

**2. Phone connects (iPhone)**
Open the ELD app on an iPhone, connect to ELD-MA.
✅ App connects. Sim says "Device connected (ESP32)".

**3. Phone connects (Android)**
Same with an Android phone — it shows a device list first.
✅ ELD-MA appears in the list (with a signal number), connects after tapping it.

**4. Data flows**
Engine on, speed 60 in the sim.
✅ Phone shows live speed/engine — same as it did without the board.

**5. Commands come back**
Watch the sim's packet log while connected.
✅ You see the phone's commands arriving (readdata, $wdg every ~20s). That proves 2-way traffic through the board.

## B. Signal control (the reason we built this)

**6. Signal moves**
Drag the **RSSI slider** 100 → 0 → 100.
✅ In nRF Connect, ELD-MA's signal drops a lot, then recovers.

**7. Every step works**
Move the slider slowly from 0 to 100.
✅ Signal climbs in steps (the board supports -12, -9, -6, -3, 0, +3, +6, +9 dBm). Note the reading at each step.

**8. FULL / POOR buttons**
Click **FULL**, then **POOR**.
✅ Strong (~+9) vs clearly weaker (~−6).

**9. Weak signal ≠ lost data**
Set the slider to 10–20% (very weak) but stay connected. Let it drive 2 minutes.
✅ Phone still gets every packet (Bluetooth retries on its own) — just possibly slower. No miles lost.

**10. Connecting while weak**
Disconnect. Set slider to 10%. Try to connect the phone from a few meters away.
✅ Behaves like connecting to a far-away truck — slow or fails. At 100% it connects instantly.

**11. Walking away = moving the slider (must match)**
a) Slider at 100. **Walk away** with the phone until it disconnects, walk back — it reconnects.
b) Stand still next to the board. Do the same with **only the slider**: 100 → 0, wait, → 100.
✅ The app behaves the **same** both times. Clicks can replace walking.

**12. Find the drop point**
Lower the slider one step at a time and wait ~1 min per step.
✅ Write down the dBm where the phone actually disconnects — we need that number for tuning the presets.

**12b. Flickering connection (weak spot)**
Click the **FLICKER** button. The signal now wobbles by itself every ~1.5s between "barely there" and "almost gone" — like a phone sitting right at the edge of range.
✅ In nRF Connect the signal jumps up and down. The ELD app's connection flaps — drops and comes back — but the app never crashes and no recorded miles are lost. Click FLICKER again to stop.

## C. Out of range & recovery

**13. DROP / BACK**
Click **DROP**.
✅ ELD-MA vanishes from nRF Connect; phone says/speaks "Bluetooth Disconnected".
Click **BACK**.
✅ Board advertises again; phone reconnects **by itself** (no taps).

**14. Board reboot = tracker reboot**
While connected and driving, pull the board's USB, wait 10s, plug it back. Click LINK again if needed.
✅ Phone drops, then reconnects once ELD-MA is back — like a real tracker power-cycling in the truck.

**15. Disconnect while driving** (run scenario **6** in the sim)
✅ Link drops mid-drive, reconnects, and the missed miles come back — nothing lost.

**16. Driving with nobody logged in** (run scenario **12**)
Log OUT of the app → sim drives 5 min → log back IN.
✅ App shows an **Unassigned Driving** period and asks you to claim or reject it.

**17. Silence test**
Sim connected, then set signal to 0 and wait.
✅ App retries, disconnects on its own within ~1 minute, reconnects when data returns.

## D. Stress — must never crash

**18. Saved packets** (run scenario **7**, then **8**)
✅ App handles 30 saved packets, then 300, through the board — no freeze.

**19. Fast dump**
Set Cadence to **0.5s**, click **DUMP STORED**.
✅ App survives it through the board. (1.0s must always pass.)

**20. Garbage packet** (scenario **11**) → ✅ app ignores it, keeps running.

**21. Leave it running**
Connected + driving for 30+ minutes.
✅ No random drops, no board lock-up, board not hot.

---

## The ones that matter most
**1, 2, 4** (board works) · **6, 9, 11** (real signal control) · **13, 14** (out-of-range & recovery) · **21** (stable).
If these pass, we ship it.
