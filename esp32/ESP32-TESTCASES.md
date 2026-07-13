# ESP32 tracker test cases

All cases are at the **tracker level** — does the board behave like a real MT tracker on the radio.
The phone/app is only used as the measuring tool. Do the step → check the ✅.

**Setup:** ESP32 plugged into the PC · sim running → pick port → **LINK** · phone with **nRF Connect**
(free BLE scanner) · ELD app (test account) for the connection cases.

---

## A. Advertising & identity

**1. Advertises**
Power the board.
✅ nRF Connect shows **ELD-MA** with service `7add0001…`.

**2. Survives a power cycle**
Unplug the board, wait 10s, plug back.
✅ ELD-MA is advertising again by itself, no PC action needed.

**3. Re-advertises after a disconnect**
Connect a phone, then turn phone Bluetooth off.
✅ Board goes back to advertising (visible in scanner again) so the next connect works.

## B. Connection

**4. Phone connects**
Connect the ELD app (iPhone and Android if possible).
✅ Connects; sim shows "Device connected (ESP32)".

**5. Two-way traffic**
Watch the sim's packet log while connected.
✅ Telemetry goes out; the phone's commands (`readdata`, `$wdg` ~every 20s) come back in. Both directions through the board.

**6. Reconnect loop**
Connect → DROP → BACK, 5 times in a row.
✅ Reconnects every time, no stuck state, no board reset needed.

## C. Signal / TX power (the reason this board exists)

**7. Signal control works**
RSSI slider 100 → 0 → 100.
✅ Scanner shows the signal drop ~20 dB and recover.

**8. Every power step**
Slider slowly 0 → 100.
✅ Signal climbs in steps: −12, −9, −6, −3, 0, +3, +6, +9 dBm. Note the scanner reading at each.

**9. Weak but connected = no data loss**
Slider at 10–20%, stay connected, stream 2 minutes.
✅ Every packet still arrives (BLE retries itself). Nothing lost, just slower.

**10. Walking away = moving the slider**
a) Slider 100, walk the phone away until it disconnects, walk back → reconnects.
b) Stand still, do it with the slider only: 100 → 0 → 100.
✅ Same behavior both times. Clicks replace walking.

**11. Find the drop point**
Lower one step at a time, ~1 min each.
✅ Note the dBm where the phone actually disconnects (we need it to tune the presets).

**12. Flicker (weak spot)**
Click **FLICKER** — the signal wobbles by itself every ~1.5s at the weak edge.
✅ Scanner shows the signal jumping; the connection flaps (drops/returns); board never locks up. Click again to stop.

## D. Out of range & recovery

**13. DROP / BACK**
DROP → ✅ ELD-MA vanishes from the scanner, phone disconnects.
BACK → ✅ board advertises again, phone reconnects by itself.

**14. Board reboot mid-use**
While connected and streaming, pull the board's USB, 10s, plug back (re-LINK if needed).
✅ Phone drops, then reconnects once ELD-MA returns — like a tracker power-cycling in the truck.

## E. Data & stress through the board

**15. Big stored dump**
Sim scenario 8 (300 saved packets), then DUMP STORED at 0.5s cadence.
✅ All packets make it through the serial→BLE path, no freeze, no garbled frames.

**16. Garbage packet**
Sim scenario 11 (malformed packet).
✅ Passed through untouched; nothing on the board breaks.

**17. Soak**
Connected + streaming for 30+ minutes.
✅ No random drops, no lock-up, board not hot.

**18. Overnight at the weak point** (start before leaving, check in the morning)
Set the slider just above the drop point you found in case 11 (barely-alive signal). Leave it connected and streaming overnight. The sim writes everything to its log file automatically.
✅ Morning check: still connected (or cleanly reconnected), board responsive, not hot.
📋 Then look at the log (`%LocalAppData%\MatrackSim\logs\matracksim.log`) and count: how many disconnects, did every reconnect succeed, any hour-long gaps.

**19. Overnight FLICKER**
Second night (or another board): leave **FLICKER** on overnight — thousands of weak⇄almost-gone swings.
✅ Morning: board still alive and controllable (`#status` replies), app reconnects, no stuck advertising.

### What these two nights catch (the problems we're hunting)
- **Memory leaks / heap creep** on the board → it dies or stops advertising after hours.
- **Reconnect-storm handling** — hundreds of drop/reconnect cycles → does anything get stuck (board, Windows serial, phone app).
- **Serial buffer overflow** on the PC↔board link during long streaming.
- **Stored-data pileup** — every disconnect buffers packets; overnight = a big backlog. Does the morning replay work or choke.
- **Board overheating / brownout** on cheap USB power.
- **Phone-side battery/doze** — Android may kill the app's BLE at night; note if the gap is phone-caused, not board-caused.

---

## App experience (optional — can be added later)
If he wants to also watch the app side while running the above: auto-**Driving** kicks in past 5 mph (case 5 data),
disconnect mid-drive replays the missed miles (case 13/14), and driving while logged out creates an
**Unassigned Driving** entry to claim. Not required for the hardware sign-off.

## Ship-if
**1, 4, 5, 7, 9, 10, 13, 14, 17** pass → the board is a valid tracker stand-in and we merge.
