# Handoff — Matrack Truck Simulator (Windows build)

## What this project is
A software **BLE tracker simulator**: a computer impersonates a Matrack "MT" J1939 tracker over Bluetooth
so the **unmodified Matrack ELD app** (iOS/Android) connects to it and receives realistic engine/GPS
packets — for bench/QA testing without the physical tracker.

- **macOS app** (`Sources/MatrackTruckSim/`, Swift/SwiftUI) — **working**, used on a Mac today.
- **Windows port** (`windows/`, C#/.NET) — **what you're building.**

## ⚠️ Hard rule
Use a **TEST account on the TEST server only** — never a real driver's account/production data, and never
trigger a DOT/FMCSA data transfer.

## Your task (Windows)
1. Open **`windows/MatrackSim.slnx`** in **Visual Studio 2022** (17.13+ opens `.slnx`; otherwise open
   `windows/MatrackSim.App/MatrackSim.App.csproj`). Requires the **.NET 8 SDK** + Windows 10 build 19041+.
2. **Build `MatrackSim.App`.** It was authored on macOS and has **not been compiled against the Windows
   SDK**, so expect a few small WinRT/WPF fix-ups the first time. The logic mirrors the verified Swift 1:1.
3. **Set up the PC (one-time):**
   - **Rename the PC to start with `ELD-MA`** (Settings ▸ System ▸ About ▸ Rename this PC), then reboot —
     the ELD app routes by the `ELD-MA` name prefix.
   - **Bluetooth must support peripheral role.** Confirmed `True` on the original test PC. To check any PC,
     run the one-liner in `windows/README.md`. If `False`, add a USB BLE dongle that supports peripheral mode.
4. **Run it** → it should advertise as `ELD-MA`. Connect the ELD app (test account) over Bluetooth.
5. **To deploy to other PCs**, publish a self-contained single exe:
   ```
   dotnet publish windows/MatrackSim.App/MatrackSim.App.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
   ```

## What's verified vs. not
- ✅ **Packet/protocol fidelity is PROVEN.** `windows/MatrackSim.SelfTest` was built + run on macOS and passes
  **10/10 with the exact same packet counts as the Swift original** → the C# wire output is byte-for-byte the
  tracker protocol. Re-run any time: `dotnet run --project windows/MatrackSim.SelfTest`.
- ⚠️ **`MatrackSim.App` is uncompiled** (no Windows SDK on the authoring Mac) — minor build fixes expected.
- ⚠️ **On-device test pending** (connect the real ELD app on the bench).

## Known gaps / TODO
- **DRIVE MY DAY (F3) routing** uses an Apple geocoder that is **stubbed** on Windows
  (`RouteEngine` → `Directions` throws `NotImplementedOnThisPlatform`). The driving engine works if fed
  coordinates via `RouteEngine.SetRoute(...)`; wire it to a Windows map/geocoding API or hard-coded city
  coords to enable F3. **F1 (signal/out-of-range disconnect), F2 (stored-dump), scenarios, streaming all
  work without routing.**
- **UI is functional, not the full dashboard** — gauges/map are deferred (TODO in `MainWindow.xaml`).

## File map (Windows ↔ Swift source)
| Windows | Swift original | Notes |
|---|---|---|
| `windows/MatrackSim.Core/*` | `Sources/MatrackTruckSim/{EngineState,SimConfig,MTPacket,MTPacketDecoder,Scenario,RouteEngine}.swift` | portable, verified |
| `windows/MatrackSim.App/TrackerPeripheral.cs` | `TrackerPeripheral.swift` | CBPeripheralManager → WinRT `GattServiceProvider` |
| `windows/MatrackSim.App/MainWindow.xaml*` | `ControlsDrawer.swift` | functional WPF UI |

## Reference docs in the repo
- `windows/README.md` — Windows build details + the peripheral-role check command.
- `CONNECTION_AND_DISCONNECT_BEHAVIOR.md` — how DROP/signal/stored-dump work and which real-world disconnects they reproduce.
- `VERIFY_WITH_REAL_TRACKER.md` — one-time capture to confirm byte-exact vs a physical tracker.

Branch: `feature/vijay-disconnect-driveday`.
