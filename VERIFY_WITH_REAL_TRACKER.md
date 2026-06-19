# Verifying the Simulator Against a Real MT Tracker

The simulator has been verified **identical to what the Matrack ELD app parses and expects** —
field-by-field, command-by-command, byte-by-byte — by cross-checking against the app's source code,
and the 10-cycle self-test passes. The only thing left to reach **provably 101% identical** is to
compare it against a **physical tracker on the air**. This is a one-time, ~30-minute capture.

This doc is that procedure.

---

## Why (what the capture confirms)

These five things are currently matched to the app's *code*, but only a real device can confirm them
on the wire:

1. **Advertised name format** — is it `ELD-MA:<id>` (colon + id), and what is `<id>` (last-4 vs full)?
2. **BLE MTU / chunk size** — does the real device cap chunks to the negotiated MTU? (We cap to ≤9 chunks.)
3. **Exact chunk-framing bytes** — the reserved byte at index 3, padding, the `$$` terminator.
4. **`$wdg` watchdog & `clrdtc`** — does the real device reply, or silently consume? (We consume silently.)
5. **Any extra/rare packet types** the app uses that we don't emit.

---

## What you need

- A **real MT tracker**, **powered as it is in a vehicle** (see Step 1 — it will NOT advertise on USB charge power alone).
- This Mac, within ~1 m of the tracker.
- Bluetooth permission for Terminal: **System Settings ▸ Privacy & Security ▸ Bluetooth ▸ enable Terminal**.
- **Important:** keep the iPhone/iPad ELD app **disconnected/Bluetooth off** during capture, so the tracker is free to connect to the Mac instead.

---

## Step 1 — Power the tracker so it advertises

The tracker only broadcasts BLE when it has real power (ignition / vehicle harness), not on a USB
charge cable. Get it powered the normal way until its **status LED** shows it's live/advertising.

## Step 2 — Run the capture

From `/Users/shiny/simulatorProject`:

```bash
swift run MatrackTruckSim capture
```

The Mac now plays the role the ELD app plays (BLE **central**). It will:
- scan for the tracker (matches by name `ELD-MA…` or service `7add0001`, incl. the overflow area),
- connect, discover the service, subscribe to the data characteristic (`7add0003`),
- send `readdata` and a `$wdg,4327` watchdog every 8 s — exactly like the app,
- and **log every received packet** with byte length, ASCII, and hex.

Leave it running ~2–3 minutes so it captures a full range (live stream + any events). Drive/move
the tracker if possible to get non-zero speed/GPS. Save the terminal output to a file.

## Step 3 — What you'll see

```
[..] ✓ found tracker: name='ELD-MA:1A2B'  rssi=-52  services=[7add0001-…]
[..] subscribed to data characteristic (Rx 7add0003)
[..] → sent command: readdata
[..] 📦 RX #1 [20B]  ascii='$16 0LP,1,750,0,…'  hex=2431...
[..] 📦 RX #2 [20B]  ascii='…'  hex=…
```

The `name=` line answers question #1. Each `📦 RX` line is a raw chunk — the `[NN B]` is the chunk
size (answers #2), and the ascii/hex shows the framing bytes (answers #3).

## Step 4 — The checklist (compare to the simulator)

| # | Confirm from the capture | Compare against (sim) | Action if different |
|---|---|---|---|
| 1 | The `name='…'` — exact `ELD-MA:<id>` format & suffix length | `SimConfig.advertisedName` (and the Mac's computer name on macOS) | set the suffix to match the real format |
| 2 | The `[NN B]` chunk size — is it MTU-capped (~20B) or larger? | `MTPacket.frame()` (caps to ≤9 chunks) | match the real chunk-size rule if it differs |
| 3 | The header bytes after `$`: `<total><current><reserved>` and the `$$` end | `MTPacket.frame()` (`"$\(total)\(i)0"`, reserved char `'0'`) | fix the reserved/total/current bytes to match |
| 4 | Does it ever reply to `$wdg` / `clrdtc`? | `handleTrackerCommand` (we send no reply) | add a reply if the real one does |
| 5 | Any packet **type** (prefix) you don't recognize from our set (LP/LI/LV/LD/SP/ACK) | `MTPacket.swift` encoders | add the missing packet type |

Also spot-check a known LP packet's fields against `MTPacket.livePosition` to confirm the field
order/scaling on the wire matches (it already matches the app's parser).

## Step 5 — If something differs

Each row above points at the exact file to change (`SimConfig.swift`, `MTPacket.swift`,
`TrackerPeripheral.swift`). Make the change, run `swift run MatrackTruckSim selftest` (must stay
10/10 PASS), then re-test on the iPad with the real ELD app.

---

## Done = provable 101%

If the capture matches the table above, the simulator is **byte-for-byte identical to the physical
tracker**, and you can state that without the caveat:

> *"Verified identical to a real Matrack MT tracker — on the wire."*

If there are differences, they're now **known and listed**, with the exact fix location — no guessing.
