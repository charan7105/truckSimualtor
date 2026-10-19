# Reply to Praboo — fault injection findings

Hi Praboo,

Earlier you asked for these to be added in the simulator:

1. Virtual odo to ECU odo switching
2. Two ECU odo switching
3. VIN all zeros
4. Partial VIN, only last 6 chars
5. Random packets with invalid time
6. Random packets with default date
7. Random packets with device default odo
8. Excessive power up and shutdown packets
9. Speed > 5, some packets without GPS lock

All nine are now buttons in the simulator.

**Only #5 triggers anything in the app** — invalid time raises `Malfunction(T)`, and only when the
clock is off by more than 10 minutes, across 20 packets, with the truck moving.

**Four are silent because the app can't catch them:**

- **#3, #4 VIN** — the mismatch handler exists at `Utils.swift:4209`, message already written.
  Nothing calls it.
- **#8 Power up/shutdown** — Power Compliance has no raiser anywhere. The app can display it and let
  a driver clear it, but nothing creates it.
- **#9 GPS lock** — the detector runs, but location rows are written with `Date.description` and read
  back as `"yyyy-MM-dd HH:mm:ss +zzzz"` (`UtilDate.swift:442`). Every parse fails, so malfunction `L`
  can never fire.

**Four the app ignores by design** — #1, #2, #6, #7. No rule requires a check and the ECU is treated
as authoritative. I'd leave these alone; adding alerts would cause false positives on real trackers.

**But #2 uncovered something worth your attention.** `Util.aculatedmilescheck` (`Utils.swift:4971`)
looks like an odometer plausibility check and is dead code — both branches call
`UpdateAccumulatedMiles`, which discards its argument and recomputes in SQL
(`LatestDB_New.swift:8790`). An odometer jump gets booked as real driven miles; a downward jump
freezes the event's mileage. No alert, and the numbers are wrong. **I'd look at this one first.**

On your PT vs MT question for #6: both parsers rewrite an uninitialised date to phone time, so no
default year survives in either. They don't differ.

All nine buttons stay in regardless — the ignored ones are labelled as ignored, so they can be used
to demonstrate the gap rather than wait for an alert that won't come.
