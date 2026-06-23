# Connection, Signal & Disconnect Behaviour (Simulator)

How the **CONNECTION · SIGNAL** controls work, what the phone (the unmodified Matrack ELD app)
actually experiences, and which real-world tracker conditions each one reproduces.

Everything here is **at the application/Bluetooth layer** — the Mac cannot change its real radio
power, so weak-signal and out-of-range are reproduced by their *effect*, except **DROP**, which is a
genuine BLE teardown (a real disconnect).

---

## The controls (CONNECTION · SIGNAL panel)

| Control | What the sim does | What the phone sees | Real-world equivalent |
|---|---|---|---|
| **FULL** | sends every packet (`packetLossPct = 0`) | normal stream | healthy link |
| **WEAK** | drops ~40% of packets (`packetLossPct = 40`) | gaps / stutter, **still connected** | fringe/weak signal |
| **POOR** | drops ~75% of packets (`packetLossPct = 75`) | heavy gaps, **still connected** | very weak signal |
| **DROP** | **tears down the BLE session** (stop advertising + remove service + release the peripheral manager) | **real disconnect in ~1–2 s** | device reset / power loss / "went away" |
| **BACK** (DROP toggles to this) | re-creates the peripheral → **re-advertises** | phone rescans and **reconnects**, stream resumes | back in range / device powered up |
| **Auto-return** slider | how long DROP stays disconnected before auto re-advertising | reconnects when it elapses | — |

WEAK/POOR = **lossy but connected**. DROP = **disconnected**. They are different conditions.

---

## How DROP works (the forced disconnect)

macOS `CBPeripheralManager` has **no API to disconnect a specific central**. The faithful way to force
an immediate, real disconnect is to drop the whole peripheral session:

```
stopAdvertising()
removeAllServices()
manager = nil          ← the connected phone drops here (~1–2 s)
```

On **BACK** (or when Auto-return elapses) the sim re-creates the manager (`startBLE()`), which
re-advertises “ELD-MA”; the app — which is always scanning for ELD-MA — finds it and reconnects.
This is the real **out-of-range → back-in-range** round trip. No fake packets; the real Bluetooth
stack drops and restores the link, so the app runs its normal disconnect/reconnect logic.

---

## Two flavours of a *real* disconnect

Field disconnects happen two different ways (both seen in real logs — `CBError Code=6` and `Code=7`).
The sim can reproduce **both**:

| Real cause | Low-level signature | Sim method | Speed |
|---|---|---|---|
| **Out of range / signal fade** | supervision **timeout** (`CBError Code 6`) | **silence/timeout** — go quiet, let the app time out (`dropLink()`; ~75 s) | slow (~75 s) |
| **Device reset / power loss / went away** | **peer-initiated** drop (`CBError Code 7`) | **DROP** — forced teardown (`forceDisconnect()`) | immediate (~1–2 s) |

- The **DROP button** currently uses the **forced teardown** (immediate, “device went away” flavour).
- The **silence/timeout** mechanism still exists in code (`dropLink`) for the *out-of-range supervision
  timeout* flavour; it can be wired to a control if a `Code 6` repro is needed.

> The app's **reaction** (disconnect → reconnect) is the same either way. The difference is the
> low-level error code / cause. To confirm which one a given test produced, check the disconnect
> **reason/CBError** the app logs.

**Important timing:** the silence/timeout method only makes the app disconnect after **~75 s** of
silence (the app's retry escalation: 15 s + 30 s + 30 s). Less than that is only a *stall*, not a
disconnect. The forced **DROP** has no such wait — it drops immediately.

---

## Reproducing the stored-packet-dump disconnect (Harshith's bug)

Separate from signal/range — this is the **STORED DUMP** control in the same panel.

- **Cause (identified):** the app pulls stored packets after connect (`readstr`); when they are dumped
  too fast, the tracker disconnects. ~**500 ms** cadence breaks it; **1 s** is safe.
- **Reproduce:** set **Count** (e.g. 80) and **Cadence = 0.50 s**, press **DUMP STORED** → reproduces
  the disconnect. Set **Cadence = 1.0 s** → completes cleanly.
- **Note:** `readstr` does **not** auto-dump (the app sends it on every connect; auto-dumping at
  500 ms would self-trigger the disconnect on every connection). The dump is **on-demand only**, via
  the button.

---

## What the simulator can and cannot reproduce

**Can** (faithful to a real tracker):
- BLE GATT service/characteristics, packet formats (LP/LV/…), and all commands (`readdata`, `readvin`,
  `$wdg`, `readstr`, …) — verified field-by-field against the app's parser; self-test 10/10.
- Real disconnect ↔ reconnect (DROP/BACK).
- Weak-signal / packet-loss effects (WEAK/POOR).
- The stored-dump disconnect bug (on demand).

**Cannot** (physics, not a gap):
- The **real RF environment** — interference, RSSI fade, the customer's noisy-area drops. The Mac
  can't change its radio, so no software here can replicate it. That needs a dedicated radio
  (e.g. ESP32) or a real device in the field. (Vijay acknowledged this in the 2026‑06‑19 meeting.)
- It also does not change the **RSSI number** the app may read — only data flow, not signal strength.

---

## Quick test checklist (on the phone)

1. Launch the sim → footer shows **Advertising as ELD-MA** → connect the app → stream scrolls.
2. **WEAK / POOR** → packet stream shows `[dropped: packet loss]`, app updates get patchy, stays connected.
3. **DROP** → phone disconnects within ~1–2 s.
4. **BACK** → phone rescans and reconnects, stream resumes.
5. **STORED DUMP @ 0.5 s** → reproduces the disconnect; **@ 1.0 s** → completes cleanly.

---

*Files: signal/disconnect logic in `Sources/MatrackTruckSim/TrackerPeripheral.swift`
(`setSignal` / `forceDisconnect` / `teardownBLE` / `resumeLink` / `dropLink` / `dumpStoredPackets`);
UI in `ControlsDrawer.swift` (`NetworkPanel`). Byte-for-byte fidelity vs a physical tracker:
see `VERIFY_WITH_REAL_TRACKER.md`.*
