# Draft reply to Praboo — not sent

Review before sending. Every claim below is from reading `matrack_ios_eld`; none has been
confirmed on a device.

---

Hi Praboo,

I built all the fault controls you listed. Before wiring them up I read through the ELD app
source to confirm what each one actually triggers, and the results changed the design enough
that I want to flag them.

**The odometer one: the app does not alert, and no code exists that could.**

You asked "when it fluctuates, App should have trigger with alert, right?" I went looking for
that check. `Util.aculatedmilescheck` (Utils.swift:4971) looks exactly like it — a plausibility
comparison on the odometer. It is dead code. Both branches (ProcessAction2.swift:1821 and :1825)
call `UpdateAccumulatedMiles`, and that method discards its `milesInevent` argument and
recomputes the value in SQL (LatestDB_New.swift:8790). Setting the miles to 0 before the call
changes nothing.

So an odometer jump is booked as driven miles in full. A jump *downward* is silently dropped by
the `odoInception > eventStartOdo` guard at :1812 — the duty event's mileage just freezes, with
no diagnostic and nothing on screen.

To be fair to the app: FMCSA does not require an odometer plausibility check, and the ECU is
treated as authoritative, so "no alert" is defensible. The *accounting* is the problem, not the
missing warning.

**The odometer-source channel is parsed and then thrown away.**

The MT `xO` packet does carry a source indicator, including a `virtualEnabled` flag. The app
parses it properly (BleClass.swift:3272 → OdoSource.swift) and stores it in
`GlobalVar.shared.mtOdoPacket`. That variable is written in three places and read in none. The
`MTOdoPacketReceived` notification it posts has zero observers. Meanwhile `eventedit.odosource`
is the hardcoded string "ECM" (ProcessAction2.swift:5047), and the server recomputes it from the
event's origin regardless. Virtual-to-ECU switching is invisible by construction.

**Three more worth a ticket, found while checking the list:**

1. **Power Compliance can never fire.** Nothing in the app raises malfunction 'P' or diagnostic
   '1' — no helper exists. The code appears only in switch cases that display or clear it, plus a
   Help screen that lets a driver clear it manually. So the app can show a malfunction it has no
   way to create.

2. **VIN mismatch handling exists but is never called.**
   `Util.addVinMalfunctionasOtherDataMalfunction(serverVin:vin:)` is live code at Utils.swift:4209,
   with the message "Vehicle identification Number mismatch, Expected VIN is X but found Y" already
   written. It has zero callers. An earlier copy at :4108 is commented out entirely. An all-zero or
   6-character VIN passes silently today.

3. **Positioning compliance 'L' is inert on every install.** The location rows are written with
   `Date.description` but read back with the format "yyyy-MM-dd HH:mm:ss +zzzz" (UtilDate.swift:442),
   so every parse returns nil and the accumulator stays at zero forever.

**What I built**

All the controls are in, behind a BAD DATA button, grouped by what the phone actually does:

- *The phone warns*: engine sync lost, clock skew, odometer + hours missing
- *Wrong number, no warning*: two ECU odometers, odometer jump, odometer stuck, power-cycle
  storm, bad time on 1 in 5 packets, default odometer on 1 in 5
- *The phone ignores it*: bad VIN (all zeros and last-6 both), default date, odometer-source
  switch, malformed packet

The ones the app ignores are still shipped, labelled as ignored, because being able to
*demonstrate* a blind spot is useful — but nobody will demo one expecting an alert.

I made the "random packets" ones genuinely intermittent, about 1 in 5, rather than corrupting
every packet. The GPS-lock one additionally only fires above 5 mph, since a parked truck losing
its fix proves nothing.

**Two questions for you**

1. On the default date — both the MT and PT parsers rewrite an uninitialised date to phone time,
   so nothing downstream ever sees it. Is that what you expected, or were you chasing a case where
   it survives?
2. Are the dead odometer check, the unwired VIN handler and the inert positioning detector things
   your team wants to fix? The simulator can drive all three the moment they work — TWO ECU
   ODOMETERS reproduces the odometer condition in about ten seconds.
