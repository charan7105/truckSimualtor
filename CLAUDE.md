# CLAUDE.md — Matrack Truck Simulator

Orientation for Claude Code and for developers picking this up. Read this first, then the linked docs.

## What this project is

A **software BLE tracker simulator**: a Mac or Windows PC impersonates a legacy Matrack **"MT"** J1939
tracker over Bluetooth LE, so the **unmodified Matrack ELD app** (iOS/Android) connects to it and receives
realistic engine/GPS telemetry — for bench/QA testing without the physical tracker hardware.

- **macOS app** — `Sources/MatrackTruckSim/` (Swift/SwiftUI). Working, used daily.
- **Windows port** — `windows/` (C#/.NET, WinRT BLE + WPF). Near line-for-line parity with the Swift.

## ⚠️ Hard rules (do not break)

- **Test account on the TEST server only.** Never a real driver's account/production data; never trigger a
  DOT/FMCSA data transfer.
- **Swift ⇄ C# parity:** the packet/engine/scenario **logic is mirrored 1:1** between `Sources/MatrackTruckSim`
  (Swift) and `windows/MatrackSim.Core` + `windows/MatrackSim.App` (C#). Any change to shared behavior
  (packet format, framing, commands, engine, scenarios) **must be made on both sides**, and both self-tests
  must still pass.

## 🔴 The #1 blocker developers hit: "Adapter can't advertise"

Windows BLE advertising **requires the Bluetooth adapter to support the *peripheral* role.** Most laptops'
**built-in** Bluetooth is **central-only** — it can scan but not advertise. When that's the case the app
honestly reports **"Adapter can't advertise"** and the phone will never see it. This is **not a code bug.**

- Check support: run the peripheral-role one-liner in `windows/README.md`. `True` = OK, `False` = can't advertise.
- Fixes: use a **peripheral-capable USB BLE dongle**, or the **ESP32 advertiser** (planned hardware, see
  `SIMULATOR_FIDELITY_AUDIT.md`). macOS does not have this limitation.
- Advertising still needs **Bluetooth ON**; `failed to create GATT service: RadioNotAvailable` = radio off.

The macOS side has no peripheral-role limit but **cannot control RSSI / TX power** (no OS API) — the reason
the ESP32 is planned. See the audit doc.

## Architecture / where things live

| Area | Swift (macOS) | C# (Windows) |
|---|---|---|
| BLE peripheral + command handling | `TrackerPeripheral.swift` | `MatrackSim.App/TrackerPeripheral.cs` |
| Packet build + chunk framing | `MTPacket.swift` | `MatrackSim.Core/MTPacket.cs` |
| Packet decode (self-test mirror of the app parser) | `MTPacketDecoder.swift` | `MatrackSim.Core/MTPacketDecoder.cs` |
| Engine/telemetry model | `EngineState.swift` | `MatrackSim.Core/EngineState.cs` |
| Scenarios | `Scenario.swift` | `MatrackSim.Core/Scenario.cs` |
| Config (all tunables) | `SimConfig.swift` | `MatrackSim.Core/SimConfig.cs` |
| Headless self-test | `SelfTest.swift` (`swift run MatrackTruckSim selftest`) | `MatrackSim.SelfTest/Program.cs` |

`MatrackSim.Core` is `netstandard2.0` and **builds on macOS too**; `MatrackSim.App` is `net8.0-windows`
(WinRT + WPF) and **only builds on Windows**.

## The BLE contract (must match exactly or the app won't connect)

- Service `7add0001-f286-4c78-adda-520c4ba3500c`; **Tx** `7add0002` (app writes commands), **Rx** `7add0003`
  (tracker notifies telemetry).
- iOS identifies by advertised **name prefix `ELD-MA`** (rename the PC to start with `ELD-MA`); Android
  identifies by the **service UUID** (name-independent).
- Frames: `$` + hex(total) + hex(current) + 1 reserved byte + payload; assembled payload ends `$$`.
- Commands the app sends: `readdata`, `readvin`, `readstr`, `readdtc`, `clrdtc`, `stopdata`, `$wdg,4327`
  (watchdog ~20–50s), `$ACK`/`$ERR` (per-frame flow control). `L*` = live, `S*` = stored packets.

## Build & run

**macOS:** `swift build` · run app: `swift run MatrackTruckSim` · self-test: `swift run MatrackTruckSim selftest`

**Windows:** open `windows/MatrackSim.slnx` in Visual Studio 2022 (17.13+) or
`windows/MatrackSim.App/MatrackSim.App.csproj`; needs **.NET 8 SDK** + Windows 10 build 19041+.
Self-test: `dotnet run --project windows/MatrackSim.SelfTest/MatrackSim.SelfTest.csproj`.
One-time PC setup + publish-to-exe steps: **`HANDOFF.md`** and **`windows/README.md`**.

## Key docs

- **`HANDOFF.md`** — developer task list + one-time Windows setup + publish command.
- **`windows/README.md`** — Windows port status, project table, peripheral-role check, build/run.
- **`SIMULATOR_FIDELITY_AUDIT.md`** — 5-repo audit vs the real tracker / iOS / Android: confirmed
  mismatches, what's fixed ($ACK/$ERR flow control, hex framing), and what needs hardware (RSSI → ESP32).
- `ARCHITECTURE.md`, `CONNECTION_AND_DISCONNECT_BEHAVIOR.md`, `PARITY-AUDIT.md` — deeper dives.

## When helping in this repo

- Match the surrounding style; keep Swift ⇄ C# changes in lockstep and re-run both self-tests.
- Don't claim BLE works from code alone — advertising depends on the adapter's peripheral role (above).
- The simulator is a **faithful tracker** for telemetry/parsing/stored-replay/reconnect; the honest gaps
  (RSSI, iOS `ELD-MA:<last4>` manual-connect name, Android GATT-133) are documented in the audit.
