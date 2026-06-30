# ESP32 `ELD-MA` advertiser (BLE ⇄ USB-serial bridge)

A ~$5 ESP32 that **is** the BLE tracker the iOS ELD app connects to — advertising as `ELD-MA` with the exact
Matrack GATT contract — while the desktop simulator (Mac/Windows) keeps generating all the telemetry and just
streams the packet bytes to the board over USB.

## Why
Windows can't reliably be a BLE peripheral (central-only adapters → `StartAdvertising` no-ops/Aborts; it
broadcasts the *PC name*, not a per-app name). macOS had its own local-name quirk. The ESP32 has none of
those limits, so it's the bullet-proof, works-on-every-machine path.

```
 ┌─────────────────────┐   USB serial    ┌──────────────┐    BLE (ELD-MA)    ┌──────────────┐
 │ Desktop simulator   │ ───packets────▶ │   ESP32      │ ─────notify──────▶ │  iOS ELD app │
 │ (route/telemetry/UI)│ ◀──commands──── │ (this sketch)│ ◀────write──────── │              │
 └─────────────────────┘                 └──────────────┘                    └──────────────┘
```

## Status
**Scaffold only — not yet wired to the desktop app, untested (no hardware yet).** The firmware is complete;
the desktop side still needs a small "serial transport" that mirrors its BLE send path to the COM/tty port
(see *PC integration* below). Pick this up when a board is in hand.

## Hardware
Any ESP32 dev board (ESP32-WROOM / -S3 / -C3, e.g. DevKitC, a generic "ESP32 DevKit"). USB cable. That's it.

## Flash it
**Arduino IDE**
1. File ▸ Preferences ▸ *Additional Boards Manager URLs*: `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
2. Tools ▸ Board ▸ Boards Manager → install **esp32**.
3. Open `esp32/MatrackEldAdvertiser/MatrackEldAdvertiser.ino`, select your board + port, **Upload**.

**arduino-cli**
```bash
arduino-cli core install esp32:esp32
arduino-cli compile -b esp32:esp32:esp32 esp32/MatrackEldAdvertiser
arduino-cli upload  -b esp32:esp32:esp32 -p /dev/cu.SLAB_USBtoUART esp32/MatrackEldAdvertiser
```

## Verify (before any PC wiring)
Power the board, open a BLE scanner (nRF Connect / LightBlue) → you should see **`ELD-MA`** advertising the
`7add0001…` service. That alone proves the radio works where Windows couldn't.

## Serial protocol (115200 baud)
- **PC → ESP32:** each `\n`-terminated line is notified verbatim on the Data char `7add0003` (the desktop app
  already chunk-frames to the MTU, so 1 line == 1 notification).
- **ESP32 → PC:** `#connected` / `#disconnected` events, and `<…` for every command the ELD app writes to
  `7add0002` (so the PC can answer `readdata`, reset the watchdog, etc.).

## PC integration (the remaining work)
Add a serial transport alongside the existing BLE one:
- **macOS** (`Sources/MatrackTruckSim/TrackerPeripheral.swift`): where it calls `transmit()`/`emitNow()` for BLE,
  also write the framed bytes to the serial port; read the port for `<…` lines and feed them to
  `handleTrackerCommand`.
- **Windows** (`windows/MatrackSim.App/TrackerPeripheral.cs`): same idea using `System.IO.Ports.SerialPort`.
- A small UI toggle: **BLE (built-in)** vs **ESP32 (serial)**.

The packet framing, command handling, scenarios and watchdog are all unchanged — only the *transport* moves
from the OS BLE stack to the serial port.
