# Praboo's fault list — how to run each one

Every requirement from the 2026-09 request, with the exact steps and what to expect.

**Before you start**
1. Launch the simulator. Press **START** to ignite.
2. Connect the phone (ELD app) and wait until telemetry is flowing — the log shows `→ LP,…`
   followed by `← $ACK`. If it has stopped, reconnect: an armed fault into a dead stream proves
   nothing.
3. Open **BAD DATA** in the bottom bar.
4. Arm **one fault at a time**. Two at once makes the result impossible to attribute.
5. **RESET TO CLEAN DATA** when finished.

Legend: ⚠ the phone warns · ◐ bad data, no warning · ∅ the phone does nothing

---

## 1. Virtual odo → ECU odo switching ∅

**Do:** expand *THE PHONE IGNORES THESE* → click **ODOMETER SOURCE → VIRTUAL**.

**Expect:** nothing on the phone. Ever.

**Why:** the app parses this packet into a variable with zero readers and posts a notification with
zero observers; `eventedit.odosource` is the hardcoded string `"ECM"` regardless. The source switch
is invisible to the app by construction. Run this to *demonstrate* that, not to see an alert.

---

## 2. Two ECU odo switching ◐

**Do:** click **TWO ECU ODOMETERS**. Leave it on for ~30 seconds.

**Look:** phone → Help → Bluetooth → **BLE Values**. The odometer visibly flips between two series
about 3,700 miles apart, every packet.

**Expect:** no warning of any kind.

**The stronger demo:** put the driver in **Driving** status *first*, then arm it. The day log records
**0.00 miles** for the whole drive while the odometer climbs on screen — because the app freezes
mileage accrual when the odometer reads below where the duty event started, with no diagnostic.

**This is the answer to "shouldn't it alert?"** It does not, and no code in the app can.

---

## 3. VIN all zeros ∅

**Do:** expand *THE PHONE IGNORES THESE* → **ALL ZEROS** → **SEND BAD VIN**.

**Look:** phone → Troubleshoot → **Run Diagnostic Check**. The VIN row goes red.

**Expect:** no popup, no malfunction, no disconnect. The connection stays up.

---

## 4. Partial VIN, last 6 characters ∅

**Do:** same panel → **LAST 6 ONLY** → **SEND BAD VIN**.

**Expect:** identical to #3. Both values fail the same check, so the app cannot tell them apart. One
control covers both; the presets exist so you can show the difference is *not* observable.

---

## 5. Random packets with invalid time ◐ / ⚠

Two versions, depending on what you are testing.

**Intermittent (what was asked for):** click **BAD TIME ON 1 IN 5 PACKETS**. About a fifth of packets
carry an impossible time. Watch the **event list**, not for a banner — scattered faults do not trip
the threshold detector.

**Constant (fastest visible malfunction):** click **CLOCK AHEAD +30 MIN** instead. After ~20 seconds
the phone's dashboard turns red and the title reads **Malfunction(T)**. One good packet clears it, so
leave it armed while you look.

---

## 6. Random packets with default date ∅

**Do:** expand *THE PHONE IGNORES THESE* → **DEFAULT DATE ON 1 IN 5 PACKETS** (sends `01-01-00`).

**Expect:** nothing, anywhere.

**On the PT vs MT question:** both parsers rewrite an uninitialised date to **phone time** before
anything downstream sees it. There is no surviving default year to observe in either protocol.

---

## 7. Random packets with device default odo ◐

**Do:** click **DEFAULT ODOMETER ON 1 IN 5 PACKETS** (sends the `4294967295` "unavailable" sentinel).

**Expect live:** nothing visible. The app skips the field and keeps displaying the last good
odometer — that silence *is* the finding.

**To see a consequence:** it has to arrive as a *stored* packet. Disconnect the phone, drive offline
for 10+ minutes with this armed, then reconnect. It lands in the generated FMCSA file.

---

## 8. Excessive power up / shutdown ◐

**Do:** click **POWER CYCLE STORM ×10** (ten power-up/shutdown pairs at 2 per second). One-shot.

**Expect:** the phone **speaks** "Vehicle Power up" / "Vehicle Shutdown" on each one and re-shows its
shutdown/PC popups. Turn the volume up — the audio is the clearest signal.

**Expect NOT:** Power Compliance malfunction `P` or diagnostic `1`. No code in the app raises them.

---

## 9. Speed > 5, some packets without GPS lock

**Do:** get the truck **moving above 5 mph first**, then click
**GPS LOCK LOST — 1 IN 5 PACKETS, ONLY WHILE MOVING**.

**Look:** phone → Help → Bluetooth → BLE Values shows `LOCK:0` on the affected packets.

**Expect:** no malfunction, and this one is **not** the simulator's fault. The app's positioning
check cannot fire on any install — its location rows are written in one date format and read back in
another, so its accumulator is permanently zero. Filed as A4 in `SIMULATOR_FIDELITY_AUDIT.md`.

The control is gated on motion deliberately: a parked truck legitimately has no fix, so testing it
stationary proves nothing.

---

## Do you still need the Scenarios panel?

For most of this, no. Engine on/off, idle, driving, stopping, duplicate and out-of-order packets are
all dashboard controls — the scenario just presses them for you. Offline recording now happens
automatically whenever the phone is disconnected, which covers the stored-packet cases too.

Scenarios still earn their place for one thing: **packets that do not match what the simulator is
currently doing** — a drive that supposedly happened hours ago, with timestamps you choose. That is
what the stored-replay scenarios fabricate, and the dashboard cannot.

The one capability that used to need a scenario — a deliberately malformed packet — is now a button
in BAD DATA.

The panel is down from twelve scenarios to four: **BLE disconnect during drive**, **Stored packets
later**, **Large stored backlog**, and **Unassigned Driving**. The eight that were deleted were each
a dashboard control with extra steps.

---

## Three extras that DO alert

Not on the list, found while checking it. These are the ones to use when you need to show the app
reacting to something.

| Click | Phone shows | How fast |
|---|---|---|
| **ENGINE SYNC LOST** | Data Diagnostic 2 | ~3 seconds |
| **CLOCK AHEAD +30 MIN** | Red bar, `Malfunction(T)` | ~20 seconds |
| **ODOMETER & HOURS MISSING** | Data Diagnostic 3 | on the next duty-status change |

`ODOMETER & HOURS MISSING` does nothing until you change duty status on the phone. That is the app's
rule, not a simulator limitation.

---

## Summary

Of the nine requested, **four do nothing at all** (1, 3, 4, 6), **four show bad data with no warning**
(2, 5-intermittent, 7, 8), and **one targets a detector that is broken in the app** (9).

That is a finding about the app, not a gap in the simulator. Every control sends exactly what was
asked for — verified on the wire by automated tests on both macOS and Windows.
