# UART transport + RSSI control — implementation change-list

**Goal:** make the `.NET` (Windows) Matrack Truck Sim talk to the **ESP32‑C3** over **USB serial (UART)**, and add a
**slider + buttons that change the real Bluetooth signal strength (RSSI)** by commanding the board's BLE **TX power**.

This is the single Markdown change-list requested in [`FOR-ESP32-TEAM.md`](./FOR-ESP32-TEAM.md). It is a **spec only —
no source files are modified here.** Each section gives the file path, the exact seam (function / nearby line), and the
code to add. The Windows/C# side is the primary deliverable; the Swift mirror is listed per the repo's parity rule.

> Scope note: the request was specifically the **.NET** app + UART + RSSI UI. C# changes below are complete and precise.
> Swift changes are given as a mirror checklist (see §7) because `CLAUDE.md` requires shared-behavior changes on both
> sides — do them when the Mac build is next touched.

---

## 0. Prerequisite — flash the *right* firmware first ⚠️

There are **two** ESP32 sketches in this tree/parent. They are **not** interchangeable:

| Firmware | Advertises | GATT contract | TX‑power serial cmd | Use for |
|---|---|---|---|---|
| `../firmware/BLE_Tracker/BLE_Tracker.ino` | `Tracker-01` | none (beacon only, Eddystone UUID) | ✅ `PRESET`/`TXPOWER` | signal‑bar RSSI demo only |
| `esp32/MatrackEldAdvertiser/MatrackEldAdvertiser.ino` | `ELD-MA` | ✅ `7add0001/2/3` (what the ELD app needs) | ❌ **missing** | **this integration** |

The board must run **`MatrackEldAdvertiser`** for the ELD app to connect. That sketch currently has **no** TX‑power
control, so §3 below adds it (borrowing the already‑proven approach from `BLE_Tracker.ino`). If your board is presently
flashed with `BLE_Tracker.ino` (the `Tracker-01`/COM5 test), **re‑flash it with the enhanced `MatrackEldAdvertiser`** from §3.

---

## 1. Architecture — what changes and what doesn't

Only the **transport** moves from the PC's WinRT BLE stack to the serial port. All packet framing, the command
responder, scenarios, and the watchdog stay byte‑for‑byte identical.

```
 BLE mode (today):   Desktop sim ──WinRT GATT notify──▶ iOS/Android ELD app     (RSSI = real distance, uncontrollable)
 ESP32 mode (new):   Desktop sim ──USB serial──▶ ESP32 (ELD-MA) ──BLE notify──▶ ELD app
                     Desktop sim ◀──USB serial── ESP32          ◀──BLE write──  ELD app
                     Desktop sim ──"#txpower n"─▶ ESP32 sets BLE TX power ⇒ REAL RSSI changes on the phone
```

Confirmed safe by inspection of `MatrackSim.Core/MTPacket.cs → Frame()`: every frame is ASCII
(`"$" + hex(total) + hex(current) + "0" + payload`, payload = comma‑joined text), so **no frame contains `\n`/`\r`** and
`\n`‑delimited serial lines are lossless. **1 serial line == 1 BLE notification**, exactly as `esp32/README.md` states.

---

## 2. Serial protocol — additions (115200 baud, `\n`‑terminated)

Keep the existing protocol; **reserve a control channel** so RSSI commands don't get mistaken for telemetry.

**Rule:** telemetry payloads always begin with `$` (the frame marker). Therefore **any host→ESP32 line beginning with
`#` is a local control command** — the ESP32 consumes it and must **not** notify it over BLE.

| Direction | Line | Meaning |
|---|---|---|
| PC → ESP32 | `$…` (unchanged) | one BLE data notification, verbatim |
| PC → ESP32 | **`#txpower <dBm>`** | set BLE TX power; snap to nearest step; reply `#txpower ok <dBm>` |
| PC → ESP32 | **`#adv on` / `#adv off`** | start/stop advertising (true out‑of‑range); reply `#adv on`/`#adv off` |
| PC → ESP32 | **`#status`** | reply `#status txpower=<dBm> adv=<on\|off> conn=<0\|1>` |
| ESP32 → PC | `#connected` / `#disconnected` / `#subscribed` (unchanged) | connection events |
| ESP32 → PC | `<…` (unchanged) | a command the ELD app wrote (feed to `HandleTrackerCommand`) |
| ESP32 → PC | **`#txpower ok <dBm>`**, **`#status …`** (new) | acks for the above |

Supported TX‑power steps on ESP32‑C3 (standard set): **‑12, ‑9, ‑6, ‑3, 0, +3, +6, +9 dBm**. `#txpower` snaps to the
nearest. `‑12` = weakest (far), `+9` = strongest (near).

---

## 3. Firmware change — `esp32/MatrackEldAdvertiser/MatrackEldAdvertiser.ino`

Add TX‑power control + the `#`‑command parser. Three edits.

**3a. Add the include + power table (after the existing `#include <BLE2902.h>` block, near line 31):**

```cpp
#include <esp_bt.h>   // ESP_PWR_LVL_* / ESP_BLE_PWR_TYPE_* enums (C3 core 3.x)

// Standard ESP32-C3 TX-power steps. On core 3.x use BLEDevice::setPower (NOT esp_ble_tx_power_set);
// the enums come from <esp_bt.h>; the standard set tops out at ESP_PWR_LVL_P9 (+9 dBm).
struct PowerStep { int dbm; esp_power_level_t level; };
static const PowerStep POWER_STEPS[] = {
  { -12, ESP_PWR_LVL_N12 }, { -9, ESP_PWR_LVL_N9 }, { -6, ESP_PWR_LVL_N6 }, { -3, ESP_PWR_LVL_N3 },
  {   0, ESP_PWR_LVL_N0  }, {  3, ESP_PWR_LVL_P3 }, {  6, ESP_PWR_LVL_P6 }, {  9, ESP_PWR_LVL_P9 },
};
static const int NUM_STEPS = sizeof(POWER_STEPS) / sizeof(POWER_STEPS[0]);
static int gTxDbm = 9;   // report the applied value back to the PC

static void applyTxPower(int requestedDbm) {
  int nearest = 0, bestDiff = 1000;
  for (int i = 0; i < NUM_STEPS; i++) {
    int diff = abs(requestedDbm - POWER_STEPS[i].dbm);
    if (diff < bestDiff) { bestDiff = diff; nearest = i; }
  }
  esp_power_level_t lvl = POWER_STEPS[nearest].level;
  BLEDevice::setPower(lvl, ESP_BLE_PWR_TYPE_ADV);      // advertising power (drives scan RSSI)
  BLEDevice::setPower(lvl, ESP_BLE_PWR_TYPE_DEFAULT);  // connection power (drives connected RSSI)
  gTxDbm = POWER_STEPS[nearest].dbm;
}
```

**3b. Apply a default power in `setup()` (right after `adv->start();`, ~line 88):**

```cpp
  applyTxPower(9);   // start at full power; the PC overrides via #txpower
```

**3c. Branch the serial reader in `loop()` so `#` lines are control, not telemetry.**
Replace the body of the `if (ch == '\n') { … }` block (currently lines ~98–103):

```cpp
    if (ch == '\n') {
      if (line.length() && line[0] == '#') {
        handleControl(line);                 // NEW: local control command, not forwarded to BLE
      } else if (connected && dataChar && line.length()) {
        dataChar->setValue((uint8_t*)line.c_str(), line.length());
        dataChar->notify();                  // unchanged: telemetry → BLE notification
      }
      line = "";
    } else if (ch != '\r') {
```

**3d. Add the control handler (above `loop()`):**

```cpp
static void handleControl(const String& cmd) {
  if (cmd.startsWith("#txpower")) {
    int sp = cmd.indexOf(' ');
    if (sp > 0) { applyTxPower(cmd.substring(sp + 1).toInt()); Serial.printf("#txpower ok %d\n", gTxDbm); }
  } else if (cmd == "#adv on") {
    if (adv) adv->start();  Serial.println("#adv on");
  } else if (cmd == "#adv off") {
    if (adv) adv->stop();   Serial.println("#adv off");
  } else if (cmd == "#status") {
    Serial.printf("#status txpower=%d adv=on conn=%d\n", gTxDbm, connected ? 1 : 0);
  }
}
```

> No other firmware change is required; the GATT contract and BLE↔serial bridge are untouched.

---

## 4. Desktop change — `MatrackSim.Core/SimConfig.cs`

Add transport + TX‑power tunables and the signal→dBm mapping. Append inside `class SimConfig`:

```csharp
        // ── ESP32 serial transport (new) ─────────────────────────────────────
        public enum Transport { Ble, Esp32Serial }
        /// <summary>Which radio the sim uses: built-in WinRT BLE, or the ESP32 over USB serial.</summary>
        public Transport Link = Transport.Ble;
        /// <summary>COM port of the ESP32 (e.g. "COM5"). Chosen in the UI.</summary>
        public string SerialPortName = "";
        /// <summary>Currently-applied ESP32 TX power in dBm (echoed by "#txpower ok").</summary>
        public int TxPowerDbm = 9;

        // Signal% (0–100) → TX power (dBm). Linear across the C3 step range, snapped by the firmware.
        //   100% → +9 (near/full) · 25% (POOR) → ~-6 · 0% → -12 (out of range).
        public static int SignalPctToDbm(double pct)
        {
            double dbm = -12 + (Math.Max(0, Math.Min(100, pct)) / 100.0) * 21.0;   // -12..+9
            return (int)Math.Round(dbm / 3.0, MidpointRounding.AwayFromZero) * 3;   // snap to 3-dBm grid
        }
```

(`netstandard2.0`‑safe; no new usings.) **Mirror in `Sources/MatrackTruckSim/SimConfig.swift`.**

---

## 5. Desktop change — `MatrackSim.App/TrackerPeripheral.cs`

This is the core wiring. Five edits; all additive.

**5a. Add the package reference** in `windows/MatrackSim.App/MatrackSim.App.csproj`:

```xml
    <PackageReference Include="System.IO.Ports" Version="8.0.0" />
```

**5b. Fields** (near the other transport fields, ~line 256, add):

```csharp
        private System.IO.Ports.SerialPort serialPort;         // ESP32 transport
        private System.Threading.Thread serialReader;
        private volatile bool serialRunning;
```

**5c. Choose transport in `StartBLE()` (line 293).** Wrap the existing body:

```csharp
        public void StartBLE()
        {
            if (Config.Link == SimConfig.Transport.Esp32Serial) { StartSerial(); return; }
            if (serviceProvider != null) return;
            _ = SetupBLEAsync();
        }
```

**5d. Add the serial transport** (new region — mirrors the BLE connect/notify/command paths, reusing the exact
same handlers so behavior is identical):

```csharp
        // MARK: - ESP32 serial transport (alternative to WinRT BLE)
        public void StartSerial()
        {
            StopSerial();
            if (string.IsNullOrWhiteSpace(Config.SerialPortName))
            { Status = "No COM port selected"; StatusColorValue = StatusColor.Red; return; }
            try
            {
                serialPort = new System.IO.Ports.SerialPort(Config.SerialPortName, 115200)
                { NewLine = "\n", Encoding = Encoding.UTF8, DtrEnable = false, RtsEnable = false, WriteTimeout = 500 };
                serialPort.Open();
                serialRunning = true;
                serialReader = new System.Threading.Thread(SerialReadLoop) { IsBackground = true };
                serialReader.Start();
                Status = $"ESP32 on {Config.SerialPortName}"; StatusColorValue = StatusColor.Amber;
                Info($"serial transport open on {Config.SerialPortName} @115200");
                SetTxPower(Config.TxPowerDbm);                 // push current signal level to the board
            }
            catch (Exception ex)
            { Status = "Serial open failed"; StatusColorValue = StatusColor.Red; Info($"✗ {Config.SerialPortName}: {ex.Message}"); }
        }

        public void StopSerial()
        {
            serialRunning = false;
            try { serialPort?.Close(); } catch { }
            serialPort = null;
        }

        private void SerialReadLoop()
        {
            while (serialRunning && serialPort != null)
            {
                string line;
                try { line = serialPort.ReadLine(); } catch { break; }        // closed / unplugged
                if (string.IsNullOrEmpty(line)) continue;
                line = line.TrimEnd('\r');
                PostToUi(() => OnSerialLine(line));                            // marshal to the sim/UI thread
            }
        }

        // Map ESP32 events onto the SAME state the BLE path drives (Connected/Streaming, command responder).
        private void OnSerialLine(string line)
        {
            if (line.StartsWith("<"))                                          // a command the ELD app wrote
            { string c = line.Substring(1); Push(new LogLine(Stamp(), c, LogLine.Kind.Inbound)); HandleTrackerCommand(c); }
            else if (line.StartsWith("#connected") || line.StartsWith("#subscribed"))
            { Connected = true; Status = "Device connected (ESP32)"; StatusColorValue = StatusColor.Green; Info("✓ ELD app connected via ESP32"); }
            else if (line.StartsWith("#disconnected"))
            { Connected = false; Streaming = false; heldPacket = null; pending.Clear(); Status = $"Advertising as {AdvertisedName} (ESP32)"; StatusColorValue = StatusColor.Amber; Info("ELD app disconnected"); }
            else { Info(line); }                                              // #txpower ok / #status / banner
        }
```

**5e. Send path — mirror `Drain()` to the serial port.** In `Drain()` (line 987) each queued frame is currently sent
via `ch.NotifyValueAsync`. Add the serial branch **at the top of the method**, before the `serviceProvider == null` guard:

```csharp
        private void Drain()
        {
            if (Config.Link == SimConfig.Transport.Esp32Serial)
            {
                var sp = serialPort;
                if (sp == null || !sp.IsOpen) { lock (pending) pending.Clear(); return; }
                List<byte[]> toSend;
                lock (pending) { if (pending.Count == 0) return; toSend = new List<byte[]>(pending); pending.Clear(); }
                foreach (var frame in toSend)
                { try { sp.Write(Encoding.UTF8.GetString(frame) + "\n"); } catch { } }   // 1 frame = 1 line = 1 BLE notify
                return;
            }
            // ── unchanged WinRT BLE path below ──
            var ch = dataChar;
            ...
        }
```

**5f. RSSI command + hook into the existing signal control.** Add a helper and call it from `SetSignal`:

```csharp
        /// <summary>Command the ESP32's real BLE TX power (no-op in BLE mode — Windows has no TX-power API).</summary>
        public void SetTxPower(int dbm)
        {
            Config.TxPowerDbm = dbm;
            var sp = serialPort;
            if (Config.Link == SimConfig.Transport.Esp32Serial && sp != null && sp.IsOpen)
            { try { sp.Write($"#txpower {dbm}\n"); } catch { } }
        }
```

Then in `SetSignal(double pct)` (line 511), **add one line** so the slider/buttons drive real RSSI:

```csharp
        public void SetSignal(double pct)
        {
            Config.SignalPct = pct;
            SetTxPower(SimConfig.SignalPctToDbm(pct));            // NEW: ESP32 mode → real RSSI; BLE mode → no-op
            Config.ExtraDelayMs = LatencyMsFor(pct);
            Config.PacketLossPct = 0;
            if (pct <= 0) { if (!LinkDown) DropLink(Config.RangeOutageSec); }
            else if (LinkDown) ResumeLink();
        }
```

Optional (truer out‑of‑range in ESP32 mode): in `DropLink`/`ForceDisconnect`, also send `#adv off`, and `#adv on` in
`ResumeLink`, so the phone actually loses the advertiser instead of just going silent.

> `HandleTrackerCommand`, `StartStreaming`, `SendReliable`, the watchdog, and scenarios are **unchanged** — the serial
> path feeds them the same strings the BLE path did.
> **Mirror in `Sources/MatrackTruckSim/TrackerPeripheral.swift`** using `ORSSerialPort`/`FileHandle` (same seams:
> `Drain`/`transmit`, `SetSignal`, connect/disconnect events).

---

## 6. Desktop change — the RSSI UI

### 6a. `MatrackSim.App/MainWindow.xaml` — add a slider next to the existing signal buttons

The signal panel lives around **lines 675–706** (`SignalState` text + `FULL`/`AUTO`/`POOR`/`DROP` toggles). Add an RSSI
slider + live dBm readout directly under the toggle row:

```xml
<!-- RSSI (ESP32 real TX power). 0% = out of range (-12 dBm), 100% = full (+9 dBm). -->
<StackPanel Margin="0,10,0,0">
  <DockPanel>
    <TextBlock Text="RSSI / TX POWER" FontSize="11" FontWeight="Black" Opacity="0.7"/>
    <TextBlock Text="{Binding SignalDbmLabel}" HorizontalAlignment="Right" FontSize="11" FontWeight="Black"/>
  </DockPanel>
  <Slider Minimum="0" Maximum="100" Value="{Binding SignalSlider, Mode=TwoWay}"
          ToolTip="Bluetooth signal strength → ESP32 BLE TX power"/>
</StackPanel>
```

(If you prefer buttons over a slider, the existing `FULL/POOR` toggles already call `Signal_Click`; just add
`+9`/`0`/`-6`/`-12` presets the same way. The slider is the more expressive control the request asked for.)

### 6b. `MatrackSim.App/TrackerPeripheral.Presentation.cs` — bindable properties

Add a two‑way `SignalSlider` and a `SignalDbmLabel` readout (raise `PropertyChanged` for the label when the slider or
`TxPowerDbm` changes):

```csharp
        public double SignalSlider
        {
            get => Config.SignalPct;
            set { AutoSignal = false; SetSignal(value); Raise(nameof(SignalSlider)); Raise(nameof(SignalDbmLabel)); }
        }
        public string SignalDbmLabel =>
            Config.Link == SimConfig.Transport.Esp32Serial ? $"{Config.TxPowerDbm:+0;-0;0} dBm" : "n/a (BLE)";
```

(Use the file's existing change‑notify helper — `Raise`/`Set`/`OnPropertyChanged`, whichever this partial already uses.)

### 6c. `MatrackSim.App/MainWindow.xaml` + `.xaml.cs` — transport toggle + COM port picker

Per `esp32/README.md` ("a small UI toggle: BLE (built-in) vs ESP32 (serial)"). Add near the status area:

```xml
<StackPanel Orientation="Horizontal" Margin="0,8,0,0">
  <ComboBox x:Name="PortBox" Width="110" ToolTip="ESP32 COM port"/>
  <ToggleButton Content="ESP32" Margin="6,0,0,0" Click="Esp32Toggle_Click"
                IsChecked="{Binding UseEsp32, Mode=OneWay}"/>
</StackPanel>
```

`MainWindow.xaml.cs` handlers (mirror the style of the existing `Signal_Click` at line 243):

```csharp
        private void RefreshPorts() { PortBox.ItemsSource = System.IO.Ports.SerialPort.GetPortNames(); }

        private void Esp32Toggle_Click(object sender, RoutedEventArgs e)
        {
            bool on = ((System.Windows.Controls.Primitives.ToggleButton)sender).IsChecked == true;
            Sim.Config.SerialPortName = PortBox.SelectedItem as string ?? "";
            Sim.SwitchTransport(on ? SimConfig.Transport.Esp32Serial : SimConfig.Transport.Ble);
        }
```

Add a small `SwitchTransport` to `TrackerPeripheral.cs` that tears down the current transport and starts the other:

```csharp
        public void SwitchTransport(SimConfig.Transport t)
        {
            if (Config.Link == t) return;
            if (Config.Link == SimConfig.Transport.Ble) TeardownBLE(); else StopSerial();
            Config.Link = t;
            StartBLE();   // routes to StartSerial() when t == Esp32Serial (see 5c)
            Raise(nameof(SignalDbmLabel));
        }
```

Call `RefreshPorts()` once in the window constructor. **Mirror the toggle/slider in the SwiftUI `ContentView`/controls.**

---

## 7. Swift parity checklist (required by `CLAUDE.md`)

Do these when the macOS build is next touched so the two stay 1:1:

- `SimConfig.swift` — add `Transport` enum, `serialPortName`, `txPowerDbm`, `signalPctToDbm()` (§4).
- `TrackerPeripheral.swift` — serial open/read loop; branch `drain()`/`transmit()` to the port; map
  `#connected`/`#disconnected`/`<cmd` to the same handlers; `setTxPower()` + one line in `setSignal()` (§5d–5f).
- SwiftUI controls — RSSI slider + transport toggle + port picker (§6).
- Re‑run **both** self‑tests (`swift run MatrackTruckSim selftest` and the C# `MatrackSim.SelfTest`).

---

## 8. Test / acceptance

1. **Flash** `MatrackEldAdvertiser` (with §3). In a BLE scanner (nRF Connect) confirm `ELD-MA` advertising `7add0001…`.
2. **Serial smoke test** (before the app): open the COM port at 115200 and send `#txpower -12` then `#txpower 9` —
   watch `ELD-MA`'s RSSI drop ~21 dB and recover in the scanner. (`#status` should echo the applied dBm.)
3. **App path:** in the sim pick the COM port, toggle **ESP32**, connect the phone's ELD app → it should receive live
   `LP`/`LI`/`LV` telemetry exactly as in BLE mode (the transport is the only difference).
4. **RSSI control:** drag the RSSI slider 100 → 0; the phone's signal bar / measured RSSI must fall smoothly and the
   readout show the snapped dBm. `POOR`/`FULL` buttons hit ‑6 / +9.
5. **Out of range:** `DROP` (with the optional `#adv off`) → phone loses the device, then reconnects on return.
6. **Parity:** C# and Swift self‑tests still pass; captured packets remain byte‑identical (transport didn't touch framing).

---

## 9. Open questions to confirm

- **Signal%→dBm curve:** the linear ‑12…+9 map (§4) is a starting point; calibrate the button presets (`POOR`, `FULL`)
  against the phone's actual bar thresholds, same as the tracker calibration procedure.
- **Out‑of‑range method:** `#adv off` (device vanishes) vs just going silent (app times out ~75 s). Pick per the
  scenario you want to reproduce; both are supported.
- **Port auto‑detect:** optional — filter `SerialPort.GetPortNames()` to the CP210x by VID/PID so the ESP32 is
  preselected.
- **Board model:** the TX‑power step table is the ESP32‑C3 standard set (max +9 dBm). If a different module is used,
  confirm its supported steps and adjust `POWER_STEPS`.
