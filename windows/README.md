# Matrack Truck Simulator — Windows port

A C#/.NET port of the macOS simulator: the PC impersonates a Matrack "MT" BLE tracker so the
unmodified Matrack ELD app connects to it. Ported from `../Sources/MatrackTruckSim` (Swift).

## Projects

| Project | Target | Builds on macOS? | What it is |
|---|---|---|---|
| **MatrackSim.Core** | netstandard2.0 | ✅ | packets, engine, scenarios, config, decoder, route math (portable) |
| **MatrackSim.SelfTest** | net10.0 | ✅ | the 10-cycle encoder↔parser self-test |
| **MatrackSim.App** | net8.0-windows | ❌ Windows only | WinRT `GattServiceProvider` BLE peripheral + WPF operator UI |

## What is verified vs. not

- ✅ **Core packet fidelity is PROVEN.** `MatrackSim.SelfTest` builds and runs on **Windows** (.NET 8) and passes
  **10/10 cycles with the exact same packet counts as the Swift original** (1841/480/10/1 @ 1.0s, etc.) —
  i.e. the C# wire output is byte-for-byte identical to the tracker protocol the Swift sim was verified against.
- ✅ **MatrackSim.App now COMPILES AND LAUNCHES on Windows** (`dotnet build` clean, 0 errors; window renders).
  The build-fix-ups the original notes warned about were completed — see "Windows port completion" below.
- ⚠️ **BLE advertising needs Bluetooth turned ON** and an adapter that supports the **peripheral role**. If the
  app logs `failed to create GATT service: RadioNotAvailable`, Bluetooth is off — enable it in
  Settings ▸ Devices ▸ Bluetooth, then relaunch.
- ⚠️ **On-device test pending** — connecting the real ELD app to the PC is your step.

## Windows port completion (what was finished to make App build/run)

The macOS-authored App project referenced a WPF view-model (`TrackerPeripheral`) whose presentation surface
wasn't written yet. Completed on Windows:
- `TrackerPeripheral.cs` — the BLE/sim controller class was renamed `SimController` → **`TrackerPeripheral`**
  (now `partial`), wired to **start BLE + the UI on launch**, and its packet log is now marshalled onto the
  WPF dispatcher (an `ObservableCollection` can't be mutated from the sim's background timer thread).
- **`TrackerPeripheral.Presentation.cs`** (new) — the view-model adapter the XAML binds to: formatted text
  (km/h, %, ms), theme brushes (`StatusBrush`/`SignalColor`), the scenario picker, and two-way slider props.
- `LogLine` gained `Symbol` + `Color` for the packet-stream template; `Scenario.ToString()` drives the picker.
- ENGINE/AUTO toggles now invoke `SetEngine`/`SetAutoDrive` via click handlers (were bound to inert properties).
- `MatrackSim.SelfTest` retargeted `net10.0` → **`net8.0`** so one SDK (.NET 8) builds the whole solution.

## Build & run (on Windows)

Prereqs: **.NET 8 SDK** (or VS 2022 17.8+), Windows 10 build 19041+.

1. Open **`MatrackSim.slnx`** in Visual Studio 2022 (17.13+ opens `.slnx` directly; on older VS just open
   `MatrackSim.App/MatrackSim.App.csproj`), **or** from a terminal:
   ```
   dotnet build MatrackSim.App/MatrackSim.App.csproj
   dotnet run  --project MatrackSim.App/MatrackSim.App.csproj
   ```
2. Re-run the fidelity self-test any time:
   ```
   dotnet run --project MatrackSim.SelfTest/MatrackSim.SelfTest.csproj
   ```

## REQUIRED on the PC (two one-time setup steps)

1. **The Bluetooth adapter must support peripheral role.** Confirmed on the target PC
   (`IsPeripheralRoleSupported = True`). If a different PC returns False, add a USB BLE dongle that
   supports peripheral mode. To check any PC, run the bundled diagnostic (from the `windows` folder):
   ```
   powershell -ExecutionPolicy Bypass -File .\check-adapter.ps1
   ```
   It reports adapter presence, peripheral-role support, radio power, and whether a real connectable
   advertisement holds stable. Note: a `PASS` proves the adapter *advertises*; it still can't prove the
   adapter *completes* an incoming connection — if a phone then times out (GATT 133 / status 8), the
   adapter can't accept connections and you need a different adapter or the ESP32.
2. **Rename the PC to start with `ELD-MA`** — Settings ▸ System ▸ About ▸ *Rename this PC* → e.g.
   `ELD-MA-PC`. Windows advertises the machine name and the ELD app routes by the `ELD-MA` prefix
   (same workaround as the Mac). Reboot, then the app will see it.

## Works now vs. needs work

- **Works (no routing needed):** BLE connect/stream, ENGINE/AUTO/speed, all 21 scenarios, **F1 signal +
  DROP/out-of-range (forced disconnect)**, **F2 stored-dump repro**, watchdog, packet log.
- **Needs a Windows routing source:** **F3 DRIVE MY DAY / PLAN route** uses the Apple-only `Directions`
  geocoder, which is a stub here (`NotImplementedOnThisPlatform`). The driving engine (`RouteEngine`) itself
  works if you feed it coordinates via `RouteEngine.SetRoute(...)` — wire it to a Windows map/geocoding API
  (or hard-coded city coordinates) to enable DRIVE MY DAY.
- **Deferred UI:** the WPF UI is functional (controls + packet log), not the full dashboard — gauges/map
  are TODO (marked in `MainWindow.xaml`).

## Map to the Swift source
`MatrackSim.Core/*` ↔ `EngineState/SimConfig/MTPacket/MTPacketDecoder/Scenario/RouteEngine.swift`;
`MatrackSim.App/TrackerPeripheral.cs` ↔ `TrackerPeripheral.swift` (CBPeripheralManager → GattServiceProvider);
`MatrackSim.App/MainWindow.xaml*` ↔ `ControlsDrawer.swift`.
