# Fault injection — sending bad data on purpose

Open the **Bad data** tab in the simulator's CONNECTION panel (or press **BAD DATA** in the
footer, which jumps there). The footer button turns red and reads
`BAD DATA ▸ SENDING` whenever anything is armed, so you can see from the dashboard that the wire is
dirty without opening the panel.

One rule: **`Stop sending bad data` puts everything back.** You never have to remember what you armed.

---

## Read the three headings first

The panel is grouped by **what you will see on the phone**, not by which packet field changes. That
grouping is the whole point, and it comes from reading the ELD app's source:

| Heading | Means |
|---|---|
| ⚠ **THE PHONE WILL WARN** | A real malfunction or diagnostic appears in the app. |
| ◐ **WRONG NUMBER, NO WARNING** | The app accepts bad data and shows it. No alert. |
| ∅ **Show the ones the phone ignores** | Nothing happens anywhere. Send it to *prove* that. |

If a control is in the ∅ section, the app genuinely does nothing with that fault. That is a verified
finding, not a simulator limitation — see `SIMULATOR_FIDELITY_AUDIT.md` for the `file:line` evidence.
Do not demo those expecting an alert.

---

## ⚠ The phone will warn

| Control | What it sends | Where to look, and when |
|---|---|---|
| **Engine computer stops answering** | ECM flag = 0 while the key is on | Data Diagnostic 2, within about 3 seconds |
| **Clock is 30 minutes wrong** | Every packet stamped half an hour wrong | Red bar reading `Malfunction(T)`, after about 20 seconds. One good packet clears it |
| **No odometer or engine hours** | Odometer 0 and engine hours 0 | Data Diagnostic 3 — **but only after you change duty status.** Nothing happens until you do |
| **GPS LOCK LOST** | Drops the fix on ~1 in 5 packets, only above 5 mph | Nothing quickly. See the note below |

**About GPS LOCK LOST.** The app's positioning-compliance check cannot fire — its location rows are
written in one date format and read back in another, so its accumulator is permanently zero. The
control sends correct bad data; the app's detector is broken. Filed in the audit as A4.

---

## ◐ Wrong number, no warning

| Control | What it sends | Where to look |
|---|---|---|
| **Two different odometer readings** | Two odometer series ~3,700 mi apart, flipping every packet | Help → Bluetooth → BLE Values: the odometer visibly flips. No warning — that *is* the finding |
| **ODOMETER JUMP +58,000 mi** | One packet with a huge odometer | Logs → today: the Driving event's odometer jumps and stays. No warning at all |
| **Odometer stops moving** | The "odometer not available" value | The app keeps showing the **last** odometer as if it were live. Nothing changes on screen |
| **BAD TIME ON 1 IN 5 PACKETS** | An impossible time, scattered | Intermittent — watch the event list, don't wait for a banner |
| **DEFAULT ODOMETER ON 1 IN 5** | The unavailable sentinel, scattered | Nothing live. Only a stored dump carries it into the FMCSA file |
| **Truck powers on and off 10 times ×10** | Ten power-up/shutdown pairs at 2/s | The app speaks "Vehicle Power up" each time and re-shows its popups. It never raises Power Compliance — no code in the app can |

---

## ∅ The phone ignores these

Collapsed by default. Present so you can demonstrate the app's blind spots to someone who doubts
them.

| Control | Why nothing happens |
|---|---|
| **Send this VIN** (ALL ZEROS / LAST 6 ONLY) | Both fail the same check and behave identically. Only Troubleshoot → Run Diagnostic Check shows the VIN row red |
| **DEFAULT DATE ON 1 IN 5 PACKETS** | Both the MT and PT parsers rewrite the packet date to phone time |
| **Change where the odometer comes from** | The app parses this packet into a variable with **zero readers** and posts a notification with **zero observers** |
| **Send one broken message** | Sends one packet that is not valid at all. The app should reject it and carry on — a crash or a stalled stream is the bug. This is the only fault the live path cannot produce on its own, which is why it lives here rather than needing a scenario |

---

## How often the simulator records while offline

One stored packet **every 30 minutes**, which is what the real tracker does. While the phone is
disconnected and the engine is on, the simulator writes a flash record at that rate and hands the
whole backlog over on the app's next `readstr`.

Thirty minutes per packet is slow if you only want to see the recorder working, so the rate is
adjustable: **CONNECTION → Saved data → Save one every**. Drop it to 0.5m for a quick check and put it
back to 30m for realistic data. Flash holds 5,000 records — about 104 days at the real rate.

## Getting an Unassigned Driving Period

This used to be a scenario button. It is now just how the simulator behaves, so there is nothing to
press — but the timing matters and it is easy to conclude it is broken when it is working.

1. Connect the phone and drive normally for a minute so the app has a live stream.
2. **Disconnect the phone** (or press DROP). The simulator keeps recording to flash, exactly like a
   real tracker with no phone in range — you will see `⏺ recording offline — N packets buffered`.
3. Keep driving for **at least 10 minutes**. This cannot be sped up, and the reason is on the app's
   side: it holds your Driving event open for about 6 minutes after the link drops (5 minutes of no
   movement plus a grace period). Anything recorded inside that window is filed against *you*, not
   as unassigned. The simulator withholds those packets rather than sending data the app will
   silently discard.
4. Reconnect. The backlog goes over automatically on the app's `readstr`.
5. Open **Unidentified / Unassigned Driving** and claim or reject the period.

**If nothing appears:** the app only files this when the drive falls outside *your* duty windows. Set
yourself **Off Duty** before disconnecting — a Driving event that is still the newest event can read
as open-ended and absorb the whole recording. Also confirm the test account has a vehicle assigned;
without one the app discards the entire batch silently.

## Why some faults are intermittent

Four controls fire on roughly 1 packet in 5 rather than on every packet. That is deliberate and it
matches how real trackers misbehave.

A fault on *every* packet is trivially visible and tends to be handled by the first guard it meets. A
fault on *some* packets is the one that finds ordering bugs, stale-state bugs, and "the app averaged
over the bad value" bugs. If you want a constant fault for a quick visual check, use the ⚠ section —
those are always-on by design.

`GPS LOCK LOST` is additionally gated on motion: it only fires above 5 mph, because a parked truck
legitimately has no fix and testing that proves nothing.

---

## Proving later that a fault was injected

Every arm, clear and one-shot is written to the simulator's persistent log with a `FAULT#` tag and
a per-run session id:

```
[14:37:12] • FAULT#A3F1-1 ARMED — field 8 (GPS lock) = 0, ~20% of packets (only above 5 mph)
[14:41:03] • FAULT#A3F1-2 CLEARED — field 8 (GPS lock)
[14:41:05] • FAULT#A3F1-3 ONE-SHOT — power-cycle burst, 10 pairs at 2/s
```

So `grep FAULT# ~/Library/Application\ Support/MatrackSim/logs/matracksim.log` gives the complete
timeline of what was faked and when, months later, without reading the whole file. The session id
is stable for one run of the simulator, so you can tell two sittings apart.

**The app keeps its own record, separately.** The simulator cannot write into it. To get the phone's
side, use **Troubleshoot → support dump**, which uploads the `audit`, `bletroubleshoot`,
`bleconnectionhistory` and `vehicle` tables. The `audit` rows are where the app records the
decisions it makes silently — "MT stored packet stoped due to vehicle id is less than 0", "Packet
skipped via Stored Action queue MT". That is the difference between *never arrived*, *arrived and
was discarded*, and *processed with no visible result* — three outcomes that look identical on
screen.

Correlate the two by timestamp. Nothing joins them automatically.

**One trap:** the Help screen's "enable logging" toggle does not enable anything — its body is
commented out, and it still shows "Logging enabled". Bugfender is already active from launch, so
the logs exist regardless; just don't read that toast as confirmation.

## Things worth knowing

**Faults never survive a restart.** They are not written to the state file. Quit and relaunch and the
wire is clean. This is deliberate: an earlier bug let a bad odometer persist and crash the simulator
on every launch.

**Faults bypass the safety guards on purpose.** The odometer normally refuses to go backwards while
the app is connected, and rejects absurd values. Fault injection ignores all of that — emitting
values a healthy tracker never would is the entire point. That is why it is a separate panel and why
one button clears it.

**One fault at a time, unless you mean it.** The status line lists everything armed. Two faults at
once makes it much harder to attribute what you see on the phone.
