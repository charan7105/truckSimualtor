# Reply to Teja — stored packet test cases

Hi Teja,

I went through the `storepacketchanges` branch and added simulator support for both test cases.
It is built and live — download the latest from:

**https://matrack-sim-setup.vercel.app**  (Mac and Windows both updated)

Open the **BAD DATA** button in the bottom bar, then expand the last section.

---

## Test case 1 — future dated packets (2030)

Press **STORED: FUTURE DATE (2030)**. It sends 5 stored packets, all stamped 1 Jan 2030.

**What should happen:** the app should skip every one of them. Nothing recorded, no events,
no mileage.

**Where to check:** Troubleshoot → support dump, then the `audit` table. You should see rows like:

```
Stored packet skipped: packet time 2030-01-01 00:00:00 is N days from now (1 year or more).
stored id == <id> packet == "SP,1,750,..."
```

One point — the simulator keeps the time and date fields as proper 6 digit values. If they are
malformed, the app rejects them on the format check first and you never reach the 1 year guard we
are actually testing.

---

## Test case 2a — duplicates on the same connection

Press **STORED: DUPLICATES, SAME CONNECTION**. Each stored packet is sent twice, one after the
other.

Sequence: `connect → lp → ss → ss(duplicate)`

**What should happen:** the second copy of each pair is dropped.

---

## Test case 2b — duplicates on different connections

1. Press **DUMP STORED** (normal dump)
2. Press **DROP** to disconnect, wait for it to reconnect
3. Press **STORED: REPEAT AFTER RECONNECT** — it sends the same packets again, byte for byte

Sequence: `connect → lp → ss → last_stored → disconnect → connect → lp → ss(same) → last_stored`

**What should happen:** I think these will also be dropped, but for a weak reason. The app keeps
`prevStoredMD5Packet` in GlobalVariables and it is never reset on connect or disconnect. The live
`lp` packets do not touch it. So the old value survives the reconnect and catches the duplicate.
If the app is restarted in between, the value resets to empty and the duplicate will be accepted.

Please confirm what you actually see here.

---

## One gap neither test covers

The app compares only against the **immediately previous** stored packet (UtilParser ~:1236). So
this case is not caught:

```
ss(A) → ss(B) → ss(A)
```

A duplicate with a different packet in between goes through. If this is a case you want to test,
tell me and I will add one more button — it is a small change.

---

Everything the simulator sends is in its log, so if something looks wrong we can confirm from the
simulator side whether the packets went out correctly before looking at the app.
