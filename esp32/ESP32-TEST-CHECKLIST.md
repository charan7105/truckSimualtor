# ESP32 test guide — what to do in the sim & how it should behave

The simulator (Mac/Windows) generates all the telemetry; the **ESP32 is the BLE radio** the phone
connects to, fed over USB. Goal of this test: confirm the board works and that the **real RSSI**
control (impossible without hardware) actually changes the phone's signal.

**You need:** an ESP32-**C3** board + USB cable · the Windows PC with `MatrackSim.exe` (the ESP32 build) ·
a phone with the Matrack ELD app (**test account only**) · a BLE scanner app (nRF Connect / LightBlue).

---

## Step 0 — Flash the board (do this first)
- Open `esp32/MatrackEldAdvertiser/MatrackEldAdvertiser.ino` in Arduino IDE (esp32 core installed), select the ESP32-C3 board, **Upload**.
- **Expected:** Serial Monitor @115200 prints `#ELD-MA advertising`.
- ⚠️ **If it won't compile**, it's the TX-power enum names for your core version — adjust the `POWER_STEPS` table and tell us.

## Step 1 — Board advertises (BLE scanner, no sim yet)
- Open a BLE scanner near the board.
- **Expected:** you see **`ELD-MA`** advertising service `7add0001…`.

## Step 2 — RSSI actually moves (serial monitor, no sim yet) ⭐ the key test
- In the Serial Monitor, send `#txpower -12`, then `#txpower 9`.
- **Expected:** in the scanner, `ELD-MA`'s **RSSI drops ~21 dB and recovers**. `#status` echoes the applied dBm.
- ❗ If RSSI doesn't move, the whole feature doesn't work — stop and report (board/firmware issue).

## Step 3 — Sim connects through the ESP32
- Plug the board into the PC. Run `MatrackSim.exe`. In the **CONNECTION · SIGNAL** panel: pick the board's **COM port**, click **LINK**.
- **Expected:** status shows `ESP32 on COMx`.

## Step 4 — Phone connects + gets telemetry
- Open the ELD app on the phone (test account).
- **Expected:** app connects; sim status shows `Device connected (ESP32)`; the phone shows **live telemetry** (speed/engine/GPS) exactly like normal BLE mode. Start the engine / drive a route to confirm data flows.

## Step 5 — RSSI slider drives the phone's real signal ⭐
- Drag the **RSSI slider** from 100 → 0.
- **Expected:** the **phone's signal bar / measured RSSI falls smoothly**, then rises when you drag it back. `FULL` ≈ +9 dBm, `POOR` ≈ -6 dBm.

## Step 6 — Out of range → reconnect
- Click **DROP**.
- **Expected:** the phone **loses the device** (board stops advertising); click **BACK** and the phone **reconnects** on its own.

## Step 7 — Stability
- Leave it connected a few minutes; drive a route.
- **Expected:** no random disconnects; the stream stays alive (the app's watchdog keeps it going).

---

## Pass = these three
1. **Step 0** — firmware compiles + flashes.
2. **Step 2** — RSSI actually moves in a scanner.
3. **Step 5** — the slider moves the phone's real signal.

If those pass, the ESP32 feature is real and we merge it to the main build.

## Why hardware — what the software sim CAN'T do
Only the ESP32 can test the **real radio**: actual **RSSI/TX-power**, **true signal loss** (not just going
silent), **reliable connection completion** on any PC, and **physical range** (walls/distance). The pure
simulator has no radio, so none of these are testable without the board.
