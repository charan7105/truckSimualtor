# Reply to Teja — stored packet test cases

Hi Teja,

I checked the `storepacketchanges` branch and added both test cases to the simulator as per the
requirement. Built and tested, and it is live now:

**https://truck-simualtor.vercel.app** (Mac and Windows)

Open **BAD DATA** in the bottom bar, then expand the last section.

**Test 1 — future date**
Press **STORED: FUTURE DATE (2030)**. Sends 5 stored packets dated 1 Jan 2030.
The app should skip all of them. Check Troubleshoot → support dump → `audit` table:
`Stored packet skipped: packet time ... is N days from now`

**Test 2a — same connection**
Press **STORED: DUPLICATES, SAME CONNECTION**. Each packet goes twice, one after the other.
The second one should be dropped.

**Test 2b — different connection**
DUMP STORED → press DROP → wait for reconnect → press **STORED: REPEAT AFTER RECONNECT**.
Sends the same packets again, byte for byte.

One thing on 2b — I think it will be dropped, but only by luck. `prevStoredMD5Packet` is never
reset on connect or disconnect, so the old value survives the reconnect and catches the duplicate.
If the app is restarted in between, the value resets and the duplicate will be accepted.

**One case we are not covering:** `ss(A) → ss(B) → ss(A)`. The app only checks the previous packet,
so a duplicate with a different packet in between will pass through. Tell me if you want this added
— it is a small change.
