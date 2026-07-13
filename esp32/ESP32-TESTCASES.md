# ESP32 test cases

Format: **Do** this → **Check** this happens. Mark ✅ or ❌.

Setup: board on USB · sim → pick port → **LINK** · phone with ELD app (test account) + **nRF Connect** (scanner).

---

## Board

**1.** Do: power the board.
Check: scanner shows **ELD-MA**.

**2.** Do: unplug board 10s, plug back.
Check: ELD-MA advertising again by itself.

**3.** Do: connect the ELD app.
Check: connects; sim says "Device connected (ESP32)".

**4.** Do: watch the sim log while connected.
Check: data goes out, phone commands (`readdata`, `$wdg`) come back.

**5.** Do: DROP → BACK, 5 times.
Check: reconnects every time.

## Signal

**6.** Do: RSSI slider 100 → 0 → 100.
Check: scanner signal drops ~20 dB, comes back.

**7.** Do: slider slowly 0 → 100.
Check: signal climbs in steps (−12…+9 dBm).

**8.** Do: slider at 15%, stream 2 min.
Check: weak but nothing lost.

**9.** Do: a) walk away till it disconnects, walk back. b) same with slider only.
Check: app behaves the **same** both times.

**10.** Do: lower one step at a time, 1 min each.
Check: write down the dBm where the phone drops.

**11.** Do: click **FLICKER**, leave 5 min.
Check: signal jumps in scanner, connection flaps, nothing crashes.

## Recovery

**12.** Do: DROP.
Check: ELD-MA gone from scanner, phone disconnects.

**13.** Do: BACK.
Check: phone reconnects by itself.

**14.** Do: pull the board's USB mid-drive, 10s, plug back, click **LINK** again.
Check: phone reconnects once ELD-MA returns.

## Stress

**15.** Do: scenario 8 (300 stored packets), then DUMP STORED at 0.5s.
Check: all arrive, no freeze.

**16.** Do: scenario 11 (garbage packet).
Check: app ignores it, keeps running.

**17.** Do: leave connected + driving 30 min.
Check: no drops, board not hot.

**18.** Do: slider just above the drop point (from #10), leave overnight.
Check morning: still connected (or cleanly reconnected), board alive; sim log shows how many drops.

**19.** Do: FLICKER on, leave overnight.
Check morning: board still answers, app reconnects.

## Driver scenes

**20. Morning walk-up** — Do: slider 0, raise slowly to 100, engine ON.
Check: phone connects by itself "as he walks up".

**21. Fuel stop** — Do: STOP the truck, slider to **5** (not 0 — 0 auto-returns after the Auto-return timer), wait 15 min, slider to 100.
Check: reconnects itself, idle time all there.

**22. Tunnel** — Do: set **Auto-return to 120s**, drive at 65, click DROP, let it come back on its own.
Check: miles replay in, no hole in the trip.

**23. Bad phone spot** (the #1 complaint) — Do: FLICKER on, drive a 30-min route.
Check: connection flaps all along, but final log complete — no lost or doubled miles.

**24. Pre-trip** — Do: ENGINE on/off 5 times, 1 min apart.
Check: every on/off logged, none missed or doubled.

**25. Sleeper night** — Do: engine off, slider 40, overnight.
Check morning: connected, no phantom driving events.

**26. Phone reboot** — Do: mid-drive, phone Bluetooth off 5 min, on.
Check: reconnects, missed miles replay.

**27. No phone** — Do: run sim **scenario 12** (it scripts this: log out → sim drives → log back in).
Check: drive arrives as **Unassigned Driving** to claim.

---

**Ship-if:** 1, 3, 4, 6, 8, 9, 12, 13, 17 pass.
