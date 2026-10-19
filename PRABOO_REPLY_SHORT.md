# Reply to Praboo — fault injection findings

Hi Praboo,

Earlier you asked to add these in the simulator:

1. Virtual odo to ECU odo switching
2. Two ECU odo switching
3. VIN all zeros
4. Partial VIN, only last 6 chars
5. Random packets with invalid time
6. Random packets with default date
7. Random packets with device default odo
8. Excessive power up and shutdown packets
9. Speed > 5, some packets without GPS lock

All nine are added. Each one is a button now.

I tested them with the app today. **Only #5 shows anything.** Invalid time raises Malfunction(T).
For that the clock must be wrong by more than 10 minutes, it needs 20 packets, and the truck must be
moving.

The other eight show nothing.

**Four of them the app cannot catch:**

- **#3, #4 VIN** — the mismatch handler is already written in the app
  (`Util.addVinMalfunctionasOtherDataMalfunction`, Utils.swift:4209). The message is written also.
  But no one calls this function.
- **#8 Power up/shutdown** — there is no code anywhere that raises Power Compliance. The app can show
  it and the driver can clear it, but nothing creates it.
- **#9 GPS lock** — the detector runs, but the location rows are saved using `Date.description` and
  read back using format `"yyyy-MM-dd HH:mm:ss +zzzz"` (UtilDate.swift:442). The format does not
  match, so every read fails and the count stays zero. Malfunction L can never come.

**Four the app ignores by design** — #1, #2, #6, #7. No rule asks for a check here, and the ECU
value is taken as correct. Better to leave these. If we add alerts, real trackers will give false
alarms.

**One more thing came out of #2, please check this.** `Util.aculatedmilescheck` (Utils.swift:4971)
looks like an odometer check but it is dead code. Both branches call `UpdateAccumulatedMiles`, and
that method throws away the value we pass and calculates again in SQL (LatestDB_New.swift:8790).
So if the odometer jumps, those miles are saved as real driven miles. If it goes down, the event
mileage freezes. No alert, and the numbers are wrong. Please look at this one first.

For your PT vs MT question on #6: both parsers change an empty date to phone time. So no default
year is visible in either one. Both behave the same.

All nine buttons stay in the simulator. The ones the app ignores are marked as ignored, so we can
use them to show the gap instead of waiting for an alert that will not come.
