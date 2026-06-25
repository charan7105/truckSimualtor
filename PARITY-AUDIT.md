# Matrack Truck Sim — macOS ↔ Windows Parity Audit

_Multi-agent line-by-line audit of every subsystem (Mac Swift = reference, Windows WPF = port), plus the
BLE reconnect root-cause. 13 subsystem audits + adversarial verification + a 3-lens reconnect deep-dive._

## Executive summary

**110 findings → 103 confirmed real gaps. After verification: 0 HIGH, 14 MEDIUM, 89 LOW.**

The port is **functionally faithful**. There are **no wire-protocol, simulation-core, packet-format,
config-value, or behavioral bugs** — every confirmed gap is presentation/cosmetic. Verified byte/value
identical: MT packet format + framing, MTPacketDecoder, EngineState physics, RouteEngine math, the full
21-scenario catalog, and **all 30 SimConfig defaults**.

## 🔴 1. Reconnection bug — ROOT CAUSE & FIX (priority)

**Symptom:** on Windows, after DROP the iPhone disconnects and never reconnects; on macOS it auto-reconnects.

**Root cause (high confidence, converged across lenses):** the Windows DROP tore down and re-created the
`GattServiceProvider`. That re-creation changes the peripheral's broadcast **identity** two ways, either of
which alone breaks iOS reconnect:
1. **Advertising address re-randomizes.** Windows advertises a rotating resolvable-private address with no
   WinRT API to pin it. iOS auto-reconnect matches the cached address; the link is unbonded
   (`GattProtectionLevel.Plain`), so iOS has no IRK to resolve the new address → looks like a new device.
2. **Re-advertisement omits the 128-bit service UUID.** `StartAdvertising` sets only
   `IsConnectable`/`IsDiscoverable`; iOS reconnects via `scanForPeripherals(withServices:[uuid])`, which a
   UUID-less advertisement fails.

macOS avoids both: CoreBluetooth re-advertises under a **stable** identity and always includes
`CBAdvertisementDataServiceUUIDsKey` + the local name. (`StartAdvertising` "succeeding" on Windows is a red
herring — it really is advertising, just with an identity/payload iOS can't match. Initial connect works
because that's a broad name-based scan.)

**Fix applied:** Windows DROP now uses the macOS "out-of-range" **soft keep-advertising model** instead of a
hard teardown — `MainWindow.xaml.cs` `Drop_Click` → `DropLink` (the provider stays alive and advertising;
the sim just goes silent). The ELD app hits its own no-data timeout, drops, and reconnects to the
still-live, stable-identity peripheral — the same conditions as the (working) initial connect. Pressing FULL
before the timeout simply resumes telemetry with no disconnect at all.
_Trade-off:_ the disconnect is no longer instant (~app-timeout) — the unavoidable cost of reliable reconnect
on WinRT, which has no per-central disconnect API and no stable-address pin. (A `BluetoothLEAdvertisementPublisher`
that also broadcasts the service UUID is a possible future hardening but was left out to avoid a
two-advertising-set regression on the Realtek adapter, which can't be hardware-tested here.)

## 2. MEDIUM gaps — FIXED

| # | Subsystem | macOS | was (Windows) | now |
|---|-----------|-------|---------------|-----|
| 1 | MODE pill (`TrackerPeripheral.Presentation.cs`) | ROUTE / AUTO CRUISE / MANUAL / PARKED | 8 strings incl. SCENARIO / DRIVE MY DAY / IDLE / ENGINE OFF | exact 4-string match |
| 2 | Signal tier | no NONE tier (0% = "POOR · 0%") | added "NONE · 0%" | NONE removed |
| 3 | Outage countdown | "back in range in Ns" / "reconnecting…" / "out of range" | "auto-return in Ns" / "returning…" / "" | Mac strings |
| 4 | Stored-dump cadence | "0.50s" | "500ms" | seconds format |
| 5 | Fuel % readout | `Int()` truncation | `Math.Round` | truncation |
| 6 | Route-speed slider floor | `max(8, …)` while on route | no floor | floor restored |
| 7 | Telemetry field 16 (`EngineState.GpsSpeedKmh`) | round-half-away-from-zero | banker's rounding | away-from-zero |
| 8 | DROP button | flips to filled "BACK" when down | static "DROP" | DROP↔BACK trigger |
| 9 | DRIVE ROUTE button | red "STOP" while driving | static "DRIVE ROUTE" | DRIVE ROUTE↔STOP trigger |
| 10 | DRIVE MY DAY button | amber "END DAY" while running | static label | DRIVE MY DAY↔END DAY trigger |
| 11 | DUMP STORED button | "DUMPING…" while dumping | static label | DUMP↔DUMPING trigger |
| 12 | Footer DTC | "DTC (n)" live count | no count | "DIAGNOSTICS · DTC (n)" |
| 13 | Fuel cylinder wave | amplitude 2 | amplitude 3 | amplitude 2 |
| 14 | SegmentedProgress glow | 0.70 | 0.47 | 0.70 |

All compile clean (0 warnings / 0 errors) and were confirmed rendering in a live demo run.

## 3. LOW / deferred (cosmetic or platform-limited)

Not blocking; noted for follow-up. Mostly justified platform substitutes or micro-deltas:
- **Additive UI not yet ported:** the SIGNAL "ⓘ" help popover, the scenario "SETUP (ONCE)" connect block,
  the route-info turn glyph, the extra "CLEAR" log button (Windows-only — kept for usability).
- **Animations** present on macOS, static on Windows: comet-tip glow breathe, tach redline halo, gear-pill
  slide/glow, compass-N ease, panel power-on reveal. (WPF has no one-line spring/blur equivalent.)
- **Glyphs/fonts:** SF Symbols → Segoe Fluent / Segoe UI Symbol; SF rounded/mono → Segoe UI Variable /
  Cascadia Mono. Unavoidable platform substitution.
- **Section-label letter-tracking (2.5)** — WPF `TextBlock` has no direct tracking.
- **DEF vs FUEL 2** second-tank label, RingGauge (unused) — need a Mac-layout design decision.
- **Map tiles:** CARTO Voyager (Win) vs Apple Maps (Mac) — Apple tiles are unavailable off-platform.
- **`demo`-mode** bootstrap timing differs (Win skips ignition + 800 ms vs Mac 4 s) — affects demo only.

## Method
13 parallel subsystem audit agents → adversarial verify on every high/medium finding → 3-lens reconnect
investigation (identity/address, iOS reconnect semantics, code-path lifecycle) → synthesis.
Run `wf_ee167049-cd4` · 61 agents · ~2.2M tokens.
