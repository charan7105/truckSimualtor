# Stored-packet test cases — future dates and duplicates

Covers the `storepacketchanges` branch of the ELD app (REQ-940, REQ-942).
Controls are in the simulator's **Bad data** tab (CONNECTION panel, or the footer BAD DATA button),
under *Show the ones the phone ignores* (expand it).

---

## What the app branch actually does

**REQ-940 — bad-time guard** (`UtilParser.storedPacketTimeProblem`)

A stored packet is skipped when any of these is true:

- fewer than 12 fields
- field 10 (HHmmss) or field 11 (ddMMyy) is not **exactly 6 digits**
- the two together do not parse as a real date/time
- the packet time is **1 year or more from now, in either direction**

On a skip the app writes an audit row and an `app_logs` WARN tagged `[MT_STORED]` with the reason,
the stored id, and the first 200 characters of the raw packet. The row is still deleted with its
batch. A *next* packet that fails the check no longer bounds the current one's PC/YM/driving range.

Worth knowing why this guard exists: on iOS a malformed date made `dateTimeConvert` return **now**,
not a nonsense year — so before the fix a bad packet was silently recorded at the current time.

**REQ-942 — frame assembler** (`BleClass.swift`)

Chunks must arrive strictly in order; a repeated chunk is skipped; one `$ACK` per frame; the
assembler resets on every connect. Note **chunk 0 always starts a new frame** and is never treated
as a repeat — so this does *not* de-duplicate a whole packet that is sent twice. That is a different
mechanism (below).

---

## Test case 1 — future-dated stored packets

**Button:** `Saved data dated in the future (2030)` — five stored packets, all stamped 1 Jan 2030.

**Expected:** every packet skipped. Nothing recorded, no events, no mileage.

**Where to check:** Troubleshoot → support dump, then the `audit` table. Rows read:

```
Stored packet skipped: packet time 2030-01-01 00:00:00 is N days from now (1 year or more).
stored id == <id> packet == "SP,1,750,..."
```

The simulator keeps the time and date fields as valid 6-digit values on purpose — otherwise the app
would reject them on the format check and you would never reach the 1-year guard you are testing.

---

## Test case 2 — duplicate stored packets

The app's only packet-level de-dup is in `UtilParser` (~:1236): it compares each stored packet's MD5
against **the immediately previous stored packet**. `prevStoredMD5Packet` lives in `GlobalVariables`
and is **never reset** — not on connect, not on disconnect.

Two consequences worth testing, and one worth knowing:

### 2a — same connection
**Button:** `Same saved data sent twice` — each packet sent twice, back to back.

Sequence: `connect → lp → ss → ss(duplicate)`

**Expected:** the second of each pair is dropped. They are adjacent and byte-identical, which is
exactly the shape the comparison catches.

### 2b — across connections
**Button:** `Send the same saved data again after reconnect` — re-sends the previous dump byte for byte.

Sequence: `connect → lp → ss → LAST_STORED_PACKET → disconnect → connect → lp → ss(same) → LAST_STORED_PACKET`

Run a dump, drop the link, reconnect, then press the button.

**Expected:** also dropped — because `prevStoredMD5Packet` survives the disconnect and the live `lp`
packets do not touch it. If the app process restarted in between, the variable resets to empty and
the duplicate **will** be accepted.

### The gap neither case covers

The comparison is only against the *immediately previous* packet. A duplicate with a different
stored packet in between — `ss(A) → ss(B) → ss(A)` — is **not** caught. If that matters, it needs a
different de-dup, and the simulator would need a control for it.

---

## Stored packets now drive at 60 mph

Teja flagged this: the dump used to leave the engine at 0 mph, so every stored packet carried
speed 0 and took the app's `speed <= 5 && ignition == 1` on-duty branch. The driving branch
(`speed >= 5`) was never exercised at all.

The dump now drives at 60 mph (`SimConfig.storedDumpSpeedMph`), which is well clear of the app's
5 mph movement line. All three test controls inherit it, so the future-dated and duplicate dumps are
driving packets too.

## Verified in the simulator

Self-test assertions on both macOS and Windows:

- the future-dated dump emits stored packets with 6-digit time/date fields, all more than a year ahead
- the duplicate dump produces adjacent identical pairs, not merely repeated content
- `SAVED PACKET COUNT` reports what was actually sent, including duplicates
- a normal dump is still unique and backdated

Everything in the simulator log is tagged, so `grep FAULT# matracksim.log` shows what was sent and
when. The app's side comes from its own support dump — correlate by timestamp.
