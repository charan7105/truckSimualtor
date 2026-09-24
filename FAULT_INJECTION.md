# Fault injection — sending bad data on purpose

Open the **BAD DATA** button in the simulator's footer. The button turns red and reads
`BAD DATA ▸ SENDING` whenever anything is armed, so you can see from the dashboard that the wire is
dirty without opening the panel.

One rule: **`RESET TO CLEAN DATA` puts everything back.** You never have to remember what you armed.

---

## Read the three headings first

The panel is grouped by **what you will see on the phone**, not by which packet field changes. That
grouping is the whole point, and it comes from reading the ELD app's source:

| Heading | Means |
|---|---|
| ⚠ **THE PHONE WILL WARN** | A real malfunction or diagnostic appears in the app. |
| ◐ **WRONG NUMBER, NO WARNING** | The app accepts bad data and shows it. No alert. |
| ∅ **THE PHONE IGNORES THIS** | Nothing happens anywhere. Send it to *prove* that. |

If a control is in the ∅ section, the app genuinely does nothing with that fault. That is a verified
finding, not a simulator limitation — see `SIMULATOR_FIDELITY_AUDIT.md` for the `file:line` evidence.
Do not demo those expecting an alert.

---

## ⚠ The phone will warn

| Control | What it sends | Where to look, and when |
|---|---|---|
| **ENGINE SYNC LOST** | ECM flag = 0 while the key is on | Data Diagnostic 2, within about 3 seconds |
| **CLOCK AHEAD +30 MIN** | Every packet stamped half an hour wrong | Red bar reading `Malfunction(T)`, after about 20 seconds. One good packet clears it |
| **ODOMETER & HOURS MISSING** | Odometer 0 and engine hours 0 | Data Diagnostic 3 — **but only after you change duty status.** Nothing happens until you do |
| **GPS LOCK LOST** | Drops the fix on ~1 in 5 packets, only above 5 mph | Nothing quickly. See the note below |

**About GPS LOCK LOST.** The app's positioning-compliance check cannot fire — its location rows are
written in one date format and read back in another, so its accumulator is permanently zero. The
control sends correct bad data; the app's detector is broken. Filed in the audit as A4.

---

## ◐ Wrong number, no warning

| Control | What it sends | Where to look |
|---|---|---|
| **TWO ECU ODOMETERS** | Two odometer series ~3,700 mi apart, flipping every packet | Help → Bluetooth → BLE Values: the odometer visibly flips. No warning — that *is* the finding |
| **ODOMETER JUMP +58,000 mi** | One packet with a huge odometer | Logs → today: the Driving event's odometer jumps and stays. No warning at all |
| **ODOMETER STUCK** | The "odometer not available" value | The app keeps showing the **last** odometer as if it were live. Nothing changes on screen |
| **BAD TIME ON 1 IN 5 PACKETS** | An impossible time, scattered | Intermittent — watch the event list, don't wait for a banner |
| **DEFAULT ODOMETER ON 1 IN 5** | The unavailable sentinel, scattered | Nothing live. Only a stored dump carries it into the FMCSA file |
| **POWER CYCLE STORM ×10** | Ten power-up/shutdown pairs at 2/s | The app speaks "Vehicle Power up" each time and re-shows its popups. It never raises Power Compliance — no code in the app can |

---

## ∅ The phone ignores these

Collapsed by default. Present so you can demonstrate the app's blind spots to someone who doubts
them.

| Control | Why nothing happens |
|---|---|
| **SEND BAD VIN** (ALL ZEROS / LAST 6 ONLY) | Both fail the same check and behave identically. Only Troubleshoot → Run Diagnostic Check shows the VIN row red |
| **DEFAULT DATE ON 1 IN 5 PACKETS** | Both the MT and PT parsers rewrite the packet date to phone time |
| **ODOMETER SOURCE → VIRTUAL** | The app parses this packet into a variable with **zero readers** and posts a notification with **zero observers** |

---

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
