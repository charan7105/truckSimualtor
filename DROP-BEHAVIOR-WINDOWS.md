# Windows DROP behavior — decision & why it can't be byte-identical to Mac

_Decided 2026-06-26. Verified against the actual Windows BLE SDK (net8.0-windows10.0.19041.0)._

## The hard platform limit (verified, not opinion)

On **macOS** the DROP button does a hard disconnect (`manager = nil`) and the iPhone auto-reconnects,
because CoreBluetooth re-advertises under the **same BLE identity** after a teardown.

On **Windows** that exact behavior is **impossible**. Verified against the WinRT API surface this app
targets:

- `GattServiceProvider` exposes only `StartAdvertising` / `StopAdvertising` / `Service` /
  `AdvertisementStatus` — **no per-central disconnect**.
- `GattLocalCharacteristic` exposes `SubscribedClients` + `NotifyValueAsync` — **no disconnect**.
- `GattSubscribedClient` exposes only `{ Session, MaxNotificationSize }` — **no disconnect/dispose**.
- `GattSession` / `BluetoothLEDevice.Dispose()` are **central-role** APIs; they do not terminate an
  inbound (phone-initiated) connection to our peripheral.

**The only way to drop the phone on Windows is to release the `GattServiceProvider`** — and releasing it
**re-randomizes the BLE advertising address** (no WinRT stable-address pin; the link is unbonded, so iOS
has no IRK to resolve the new address). Result: the phone never recognizes the re-advertised device and
**never reconnects** — the original bug.

**Therefore, on Windows you can have a clean instant disconnect OR auto-reconnect, but not both.** Mac's
API gives both; Windows' API does not. There is no flag or workaround — it is a missing capability in
Windows itself.

## Decision: keep "disconnect + auto-reconnect" (the soft model)

DROP uses the macOS "out-of-range" soft model (`Drop_Click → DropLink`): the radio service stays alive and
advertising (stable identity), and the simulator just goes silent. The iPhone hits its own no-data timeout,
disconnects, and reconnects to the still-live peripheral — **proven working** in the on-device packet log
(repeated `iPhone disconnected → readdata → ACK,DATA,LV,LV,LI,LP → iPhone subscribed`).

**Known cosmetic difference vs Mac:** while the link is silent during the outage, the iPhone keeps re-asking
`readvin` ~once/second (it's *connected* and waiting for a reply). On Mac the phone is fully disconnected,
so it can't poll. This `readvin` is **inbound from the phone, not sent by the sim**, and it is exactly what
a real tracker that went out of BLE range would produce (silence → phone retries → drop → reconnect).

## Does this still act like a real tracker? — Yes

- **Wire protocol is byte-for-byte correct** (audit-verified): LV/LP/LI/version/DTC/ignition packets,
  framing, checksums, units, rounding — all identical to the Mac reference.
- **Command handling is correct**: `readdata`, `readvin`, `readstr`, `readdtc`, `clrdtc`, `stopdata`,
  `$wdg` watchdog — all respond like real MT firmware.
- **Streaming, watchdog, reconnect** all behave correctly; on-device end-to-end test passed.
- The `readvin` retries during a DROP are **realistic out-of-range behavior**, not a malfunction.

**The only behavioral difference from Mac is the DROP *mechanism*** (timeout-based silent outage instead of
an instant hard cut). It does **not** change how the device behaves as a tracker.

## Troubleshooting notes

- No functional issue: the device answers every command correctly and streams correct packets. The DROP
  noise does not affect any other test.
- DROP is **not instant** — the real disconnect lands after the app's ~75–80s no-data timeout (tunable via
  the **Auto-return** slider). Expect that delay when demoing a drop/reconnect cycle.
- **Safety constraint (unchanged):** use a **TEST account on the TEST server only** — never a real driver's
  account / production data, and never trigger a DOT/FMCSA data transfer.
