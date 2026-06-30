# Simulator Fidelity Audit — Real Tracker vs iOS vs Android vs Simulator

**Date:** 2026-06-30
**Method:** Parallel deep code-read of five repos. Every claim is backed by `file:line`. Anything not provable from code is marked **Needs verification**, not assumed.

## Repos reviewed (ground truth → implementation)

| Role | Repo | Key files |
|---|---|---|
| **Real tracker (authority)** | `matrack_ios_device_tester` | `MatrackBluetooth/.../Bluetooth.swift`, `Utils/UtilParser.swift` |
| **iOS app (production)** | `matrack_ios_eld` | `MatrackELD/BleClass.swift` (`BLEControl` singleton), `Utils/UtilParser.swift`, `ProcessAction2.swift` |
| **Android app (production)** | `…/praboosieva-androideld-…` (pkg `com.matrack.eld`) | `UI/BluetoothSync/BluetoothForeGroundService.java`, `util/UtilParser.java`, `util/BleUtils.java` |
| **Simulator (Mac)** | `simulatorProject` | `Sources/MatrackTruckSim/{TrackerPeripheral,MTPacket,EngineState,SimConfig,Scenario,SelfTest}.swift` |
| **Simulator (Windows)** | `simulatorProject/windows` | `MatrackSim.App/TrackerPeripheral.cs`, `MatrackSim.Core/{MTPacket,EngineState,SimConfig}.cs` |
| **Admin/website** | `matrackAdminApp` | Flutter; only a backend boolean `bleconnection` — no BLE/telemetry/RSSI |

> **Note on the named Android path:** `/Users/shiny/androideld` is **empty**. The live Android code is the `praboosieva-androideld-…` checkout in `~/Downloads`.

---

## The GATT contract (all five agree — confirmed)

| Item | Value | Confirmed in |
|---|---|---|
| Service UUID | `7add0001-f286-4c78-adda-520c4ba3500c` | tester, iOS, Android, sim (Swift `:744`, C# `:1100`) |
| Tx (app→tracker, **Write**) | `7add0002-…` | all |
| Rx (tracker→app, **Notify**) | `7add0003-…` | all |
| Frame layout | `$` + hex(total) + hex(current) + 1 reserved byte + payload; payload from **index 4** | tester, iOS `:2696`, Android `:5919`, sim |
| Stored prefix | `L*` = live, `S*` = stored | all |
| Watchdog payload | `$wdg,4327` | all |

This core is a **Match** everywhere. The findings below are where they diverge.

---

## Findings (per dimension)

### F1 — `$ACK`/`$ERR` flow control  ❌ **MISMATCH (highest impact)**
- **Real tracker:** every reassembled frame is answered with **`$ACK`** (ok) / **`$ERR`** (bad); the app's write loop is **event-driven, drained on write-complete** — not a fixed interval (`Bluetooth.swift:546-622, 1120-1156`).
- **iOS:** sends `$ACK`/`sendACKImproved` after each complete valid packet, `sendACKWithError` on bad (`BleClass.swift:539, 2750, 2782, 2682`).
- **Android:** sends `$ACK` (one per packet), and **even on malformed packets** so the device advances its pointer (`BluetoothForeGroundService.java:4099-4106, 5958, 6003-6008`).
- **Simulator:** streams on a **fixed 1.0s timer** (`TrackerPeripheral.swift:670-673`) and **does not handle incoming `$ACK`/`$ERR`** — the command handler only matches `readdata/readvin/readstr/readdtc/clrdtc/stopdata/$wdg` (`:700-734`). Incoming `$ACK` falls through, ignored.
- **Impact:** the sim cannot reproduce anything in the ACK round-trip: stored-pointer advancement, ACK-gated cadence, `$ERR` retransmit, or "app stopped ACKing" stalls. This is the single biggest "packet generator vs real tracker" gap.
- **Required fix:** (a) consume `$ACK`/`$ERR` in `handleTrackerCommand`; (b) optionally gate the next live packet on the prior `$ACK` (true flow control) instead of the fixed timer. **Tracker-side requirement that the next push *waits* for `$ACK` is Needs verification** (firmware behavior, not provable from app code) — but the sim ignoring `$ACK` entirely is confirmed.

### F2 — RSSI / signal strength  ⚠️ **MISMATCH (simulator limitation — validates ESP32)**
- **Real tracker:** does not put RSSI in packets; device-tester reads `didReadRSSI` but only `print`s it (`Bluetooth.swift:442-444`).
- **iOS:** **reads and persists** RSSI — sorts the scan list by RSSI (`BleClass.swift:1220`), and on **live L-packets** attaches `readRSSI()` to the stored `MTDataPacket` when `getUserRssiEnable==1` (`:2731-2742, 3328`). No weak-RSSI logic gates connection/HOS (`estimateDistanceFromRSSI` exists but unused, `:3060`).
- **Android:** reads RSSI at scan (`BleUtils.java:66-69`), event-driven `readRemoteRssi()` at failure moments + an **opt-in 60s audit** (`…Service.java:2485-2509, 3128-3158`); `RSSI_WEAK_DBM=-85` is used **only to attribute** a disconnect to RF, never to gate (`:2451, 2515`).
- **Simulator:** **cannot set RSSI** — no TX-power API on macOS/Windows (Swift `:233-235`). Models weak signal as **added latency** (`latencyMsFor = (100-pct)*9` ms, `:237`), never touches RSSI.
- **Impact:** both apps **record/upload RSSI**, but against the sim they will always see a strong desk-distance signal. The sim cannot exercise weak-RSSI recording/audit features at realistic values. Modeling weak-signal-as-latency is correct for *link behavior*, but it does **not** produce the RSSI *numbers* the apps log.
- **Required fix:** real RSSI needs a radio with programmable TX power — **ESP32** (independently confirms the hardware decision). No laptop-software fix exists.

### F3 — Device identification: name vs service UUID  ❌ **MISMATCH (platform-split)**
- **Real tracker / iOS:** identify by **name prefix `ELD-MA`** (`Bluetooth.swift:84`; `BleClass.swift:1447,1463,1570`). iOS **manual** connect additionally splits the name on `":"` and verifies the **last-4 of MAC**, i.e. expects **`ELD-MA:<last4>`** (`BleClass.swift:1462-1480`).
- **Android:** identifies by the **`7add0001` service UUID in the advertisement**; the `ELD-MA` **name checks are commented out** (`BLEScanResultFragment.java:534-555, 567-575`). Name-independent.
- **Simulator (Mac):** advertises name **`ELD-MA`** (no colon/last-4 by default) **and** the service UUID (`SimConfig.swift:68`, `TrackerPeripheral.swift:759`).
- **Simulator (Windows):** **cannot set a per-app name** — broadcasts the **machine name**; the PC must be renamed to start with `ELD-MA` (`TrackerPeripheral.cs:21-25, 240`). Service UUID is advertised normally.
- **Impact:**
  - **Android:** connects to **both** sim builds regardless of name (UUID match). ✅
  - **iOS first-connect** (`hasPrefix`) works with bare `ELD-MA`. ✅
  - **iOS manual device-picker** splits on `":"` + last-4 → bare `ELD-MA` has no `":"` → that path **fails** (memory-documented). ❌
  - **iOS + Windows sim** needs the PC renamed to `ELD-MA…`, plus the known macOS name-cache caveat (ComputerName=`ELD-MA`).
- **Required fix:** advertise **`ELD-MA:<last4>`** by default (Mac) to satisfy iOS manual connect; document the Windows machine-rename requirement (already done). Android needs nothing.

### F4 — Watchdog timing  ✅ **MATCH (safe margin)**
- **Real tracker:** `$wdg,4327` every **50s** (`Bluetooth.swift:1120`).
- **iOS:** every **20s** (`Constants.watchdogInterval=20.0`, `BleClass.swift:168, 2474`).
- **Android:** every **20s**, critical escalation at **150s** (`…Service.java:3952, 2770`).
- **Simulator:** consumes `$wdg` silently (no reply — correct), pauses stream only after **90s** of silence (`TrackerPeripheral.swift:677-681`). 90s > all observed intervals → never falsely pauses. ✅
- **Incorrect prior assumption corrected:** earlier notes assumed ~20s only; the real device-tester actually uses **50s**, and the production apps use **20s**. The sim's 90s timeout is safely above both — no change needed.

### F5 — LP packet fields & units  ✅ **MATCH (sim is canonical; Android self-inconsistent)**
- **Field order (0–16)** identical across tester, iOS, Android, sim.
- **Speed:** wire = km/h. iOS `÷1.60934` (`UtilParser.swift:1827`), **sim encodes `×1.60934`** (`MTPacket.swift:25`) → **exact match with iOS**. **Android uses `÷1.609`** (`UtilParser.java:160,2127`) — a ~0.02% less-precise constant, inconsistent with its own `1.609344` distance math. *(Android app bug, not a sim defect.)*
- **Odometer** `×0.0621371` (km→mi, tracker sends 10×), **engine hours** `÷100` — match everywhere.
- **Required fix:** none in the sim. (Optionally flag the Android `1.609` constant to the Android team.)

### F6 — Chunk reassembly radix & max chunks  ✅ **MATCH ≤9 chunks / ⚠️ verify >144B**
- **Apps** read total/current as **hex**, support up to **15 (0xF)** chunks (iOS `:2676-2681`, Android `:5914-5915`).
- **Sim** writes total/current as **decimal digits** and caps at **9 chunks** (`size = max(16, ceil(len/9))`, `MTPacket.swift:86-92`). For ≤9 chunks decimal == hex, so it agrees; all packets <144B fit. Self-test verifies byte-exact reassembly <144B (`SelfTest.swift`).
- **Required fix:** none for current packet sizes. **Needs verification** with one real-tracker capture for any payload >144B (would need 10–15 chunks → decimal/hex digits diverge at 10+).

### F7 — Packet drops on weak signal  ✅ **MATCH (correct design — resolves the original concern)**
- **Real BLE** retransmits at the link layer; neither app does per-packet sequence/gap detection (iOS uses 10s/30s resend timers `:688-707`; Android relies on `$ACK` + tracker resend).
- **Simulator** deliberately **does not drop** app packets on weak signal — `setSignal` forces `packetLossPct=0` and applies latency instead (`TrackerPeripheral.swift:241`).
- **Verdict on your example ("we intended RSSI but implemented packet drops"):** the sim does **not** implement packet drops on the live path — it implements **latency**, which is the **correct** BLE behavior. Packet-dropping would have been wrong. ✅

### F8 — Reconnect / disconnect  ✅ **MATCH (core) / ⚠️ minor gaps**
- **iOS:** auto-reconnect ≤10 attempts @15s, treats `CBError Code=6` and clean disconnect as out-of-range → reconnect, 2–4s backoff (`BleClass.swift:1821-1929, 1416-1437`).
- **Android:** `mtreconnect` flag drives `autoConnect` true/false; explicit GATT **133/8** handling; MTU 256→128 (`…Service.java:2584-2587, 295-296, 5489`).
- **Simulator:** two real modes — `dropLink` (silent stall, keeps advertising → app times out ~75s) and `forceDisconnect` (tears down peripheral → app drops in 1–2s), both auto-recover (`TrackerPeripheral.swift:259-310`). Covers supervision-timeout and peer-disconnect.
- **Minor gap:** sim does not reproduce Android **GATT 133 connect-time** failures (stack-level, hard to emulate). Low impact.

### F9 — Out-of-order / duplicate  ✅ **MATCH (sim can exercise app dedup)**
- **iOS:** drops a live packet equal to previous; stored dedup by MD5; no reordering (`BleClass.swift:2726`, `UtilParser.swift:1160-1167`).
- **Android:** drops content-equal duplicates, excludes `LX/SX`, drops stale-gatt notifications; no reordering (`…Service.java:5947-5950, 5787-5798`).
- **Simulator:** can **inject** out-of-order (`outOfOrderPct`) and duplicates (`duplicatePct`), default 0 (`TrackerPeripheral.swift:572-597`).
- **Required fix:** none. Note for users: these are **off by default** — enable them to test the apps' dedup paths.

### F10 — Stored-packet replay  ✅ **MATCH (protocol-exact)**
- **Apps:** `readstr` → stored `S*` packets → `LAST_STORED_PACKET` + `SAVED PACKET COUNT:n`; iOS resets live-count on stored, dedups MD5 (`UtilParser.swift:1137-1167`); iOS auto-`readstr` every 300s (`BleClass.swift:529-532`).
- **Real tracker:** gates `readstr` on **firmware ≥209** via the LV response (`UtilParser.swift:106` in tester).
- **Simulator:** converts L→S, dumps `pendingStored` on reconnect+`readstr`, emits the exact `LAST_STORED_PACKET` / `SAVED PACKET COUNT:n` sentinels, backdates timestamps (`Scenario.swift:140-176`, `TrackerPeripheral.swift:708-729`). C# identical (`TrackerPeripheral.cs:1040-1064`).
- **⚠️ Needs verification:** does the sim's LV firmware value satisfy the **≥209** gate so the **real iOS app** actually issues `readstr`? If the sim reports a lower firmware, stored-replay scenarios won't trigger on a real device. Confirm the LV `mcuFW` field value.

### F11 — `clrdtc` command  ✅ **MATCH (correction to prior assumption)**
- **iOS** *does* send `clrdtc` (`BleClass.swift:528`) — it is a **real** command.
- Device-tester and Android have no literal `clrdtc` token (Android clears via a flag flow then `readdtc`).
- **Simulator** handles `clrdtc` (clears DTC + faults). ✅ Correct for iOS. *(Earlier suspicion that `clrdtc` was sim-invented was wrong.)*

### F12 — Windows vs Mac simulator parity  ✅ **MATCH (near line-for-line)**
- Core files (`MTPacket`/`SimConfig`/`EngineState`) are essentially identical; packet format, framing, units, latency model, commands, watchdog, stored-replay, reconnect, telemetry all at parity.
- **Windows advertises real BLE** via WinRT `GattServiceProvider` (no stub/mock) and honestly reports if the adapter lacks peripheral role (`TrackerPeripheral.cs:1087-1098`).
- **Platform-forced divergences:** machine-name advertising (F3); no notify back-pressure in `Drain()` (could drop a notification under heavy congestion where Mac retries); count-based connection detection; extra teardown handler-detach to suppress stale WinRT callbacks. UI-only features (scenario banner, guided walkthrough) intentionally not ported.

---

## Scenario test matrix

| # | Scenario | Real behavior | iOS | Android | Simulator | Status |
|---|---|---|---|---|---|---|
| 1 | Normal connection | scan→connect→`readdata`→stream + `$ACK`/`$wdg` | name-prefix | UUID | advertises name+UUID, ACK ignored | ✅ connects / ❌ ACK loop (F1) |
| 2 | Weak RSSI | app records real RSSI; no gating | persists per-packet | 60s audit | **can't lower RSSI**; latency instead | ❌ (F2 — ESP32) |
| 3 | Packet drops | link-layer retransmit (no app drops) | timer resend | `$ACK`+resend | latency, no drop | ✅ (F7) |
| 4 | Disconnect/reconnect | Code 6/7 → reconnect | ≤10@15s | GATT133/autoConnect | dropLink + forceDisconnect | ✅ core (F8) |
| 5 | Long disconnection (>80s) | supervision timeout → reconnect | reconnect | reconnect | `forceDisconnect`/`rangeOutageSec=80` | ✅ |
| 6 | Stored replay | `readstr`→`S*`→`LAST_STORED_PACKET`/`COUNT` | ✓ + 300s | ✓ | exact sentinels, backdated | ✅ / ⚠️ verify firmware gate (F10) |
| 7 | Out-of-order | apps don't reorder | dedup | dedup | inject `outOfOrderPct` (off by default) | ✅ |
| 8 | Duplicate | dedup vs previous | drop== prev | drop== prev | inject `duplicatePct` (off by default) | ✅ |
| 9 | Ignition on/off | `LI/SI` field[1] events | power-up/down | power-up/down | `LI` sent reliably on change | ✅ |
| 10 | Speed changes | km/h on wire → mph | ÷1.60934 | ÷1.609 | ×1.60934 | ✅ (iOS) / Android self-inconsistent (F5) |
| 11 | Command response | `readdata/readvin/readstr/readdtc/clrdtc/stopdata/$wdg` | sends all | sends most | handles all **except `$ACK`/`$ERR`** | ⚠️ (F1) |

---

## Confirmed mismatches (ranked)

1. **`$ACK`/`$ERR` flow control not modeled** — sim free-runs on a 1s timer, ignores ACKs (F1). *High.*
2. **RSSI cannot be produced** — apps record/upload RSSI; sim can't set it (F2). *High — needs ESP32.*
3. **iOS manual-connect name** — sim default `ELD-MA` lacks `:<last4>` that iOS manual selection requires (F3). *Medium.*
4. **Windows machine-name advertising** — PC must be renamed for iOS; Android unaffected (F3). *Medium (documented).*

## Incorrect assumptions corrected
- Watchdog is **not** uniformly ~20s: real device-tester = **50s**, apps = **20s** (F4).
- `clrdtc` is **real** (iOS sends it), not a sim invention (F11).
- The "we implemented packet drops instead of RSSI" worry is **moot** — the sim implements **latency** (correct BLE behavior), not drops (F7).

## Missing simulator behaviors (to add before senior-dev handoff)
1. Consume `$ACK`/`$ERR`; optionally ACK-gate cadence (F1).
2. Default advertised name `ELD-MA:<last4>` on Mac (F3).
3. Verify LV firmware ≥209 so real iOS issues `readstr` (F10).
4. Real RSSI — **only** via ESP32 hardware (F2).
5. *(Optional)* large-packet (>144B) framing parity check with a real capture (F6).

## Production-readiness verdict

| Use case | Verdict |
|---|---|
| **Telemetry / parsing / units / ignition / speed** | ✅ **Ready** — byte-exact vs both apps. |
| **Stored-packet replay** | ✅ Ready (⚠️ confirm firmware gate triggers real iOS `readstr`). |
| **Disconnect / reconnect / out-of-range** | ✅ Ready for the common modes; Android GATT-133 connect failures not reproduced. |
| **Android, end-to-end** | ✅ **High fidelity** — UUID identification makes it immune to the naming issues. |
| **iOS, end-to-end** | ✅ Ready **after** the `ELD-MA:<last4>` name fix + the documented ComputerName workaround. |
| **`$ACK` flow-control / stored-pointer debugging** | ❌ **Not ready** — model `$ACK` first (F1). |
| **Weak-RSSI recording/upload debugging** | ❌ **Not possible on a laptop** — requires ESP32 (F2). |

**Overall:** the simulator is a **faithful tracker for telemetry, parsing, stored-replay, and reconnect debugging** (not a "fake packet generator" for those paths). Two gaps stop it short of full real-tracker behavior: it **ignores the `$ACK` protocol** (fixable in software) and it **cannot produce real RSSI** (fixable only with ESP32 hardware). Close F1 in software and adopt the ESP32 for F2, and the sandbox covers the full contract.
