# ELD app — robust MT/PT routing fix (cached-name-proof)

**The pattern:** identify the tracker by its **advertised 128-bit service UUID** — `7add0001`
(`CBUUIDs.BLEService_UUID`) = MT, `6e400001` (`CBUUIDs.ptServiceUUID`) = PT — which iOS delivers
**fresh on every scan and never caches** (unlike `peripheral.name`). Capture it at discovery,
use it at connect, and keep `name.hasPrefix("ELD-MA")` only as a last-resort fallback.

Verified against the live code (line numbers confirmed). Safe for real MT **and** PT trackers
(real MT advertise `7add0001`, real PT advertise `6e400001`) — only the broken cached-name case
changes. All constants + the concurrent `stateQueue` barrier pattern already exist in the file.

Target: `/Users/shiny/matrack_ios_eld/MatrackELD/BleClass.swift`

---

## THE line (the one thing that was wrong)
`BleClass.swift:1367`, inside `didConnect` (the single authoritative MT/PT router):
```swift
if peripheralName.hasPrefix("ELD-MA") {   // OLD: cached name → wrong on reconnect
```
becomes service-UUID-based (Edit C below). Everything downstream (`selectedDeviceName`,
persisted `deviceType`, all data/disconnect branches) then inherits the correct type.

---

## Edit A — add a stored map (next to `lastConnectedPeripheral`, ~line 72)
```swift
// Advertised service-UUID type captured fresh at didDiscover, keyed by peripheral.identifier.
// true = MT (7add0001), false = PT (6e400001). iOS never caches the advertised UUID (unlike
// peripheral.name), so this is the reliable connect-time discriminator.
private var advertisedIsMTByIdentifier: [UUID: Bool] = [:]

func advertisedIsMT(for identifier: UUID) -> Bool? {
    return stateQueue.sync { advertisedIsMTByIdentifier[identifier] }
}
```

## Edit B — capture it in `didDiscover` (~line 1096, where service UUIDs are already read)
Add this right after `let ptserviceuuid = CBUUID(string: "6e400001-…")`:
```swift
if serviceUUIDs.contains(CBUUIDs.BLEService_UUID) {
    stateQueue.async(flags: .barrier) { [weak self] in self?.advertisedIsMTByIdentifier[peripheral.identifier] = true }
} else if serviceUUIDs.contains(ptserviceuuid) {
    stateQueue.async(flags: .barrier) { [weak self] in self?.advertisedIsMTByIdentifier[peripheral.identifier] = false }
}
```
(The existing discovery filtering below stays untouched — this only records the type.)

## Edit C — the routing replacement (`BleClass.swift:1367`, in `didConnect`)
**Before:**
```swift
if let peripheralName = peripheral.name {
    if peripheralName.hasPrefix("ELD-MA") {
        handleMTDeviceConnection(peripheral)
    } else {
        handlePTDeviceConnection(peripheral)
    }
} else {
```
**After:**
```swift
// Route by the fresh advertised service UUID captured at didDiscover (iOS never caches it);
// fall back to the name only when no advertised type was recorded.
if let isMT = stateQueue.sync(execute: { advertisedIsMTByIdentifier[peripheral.identifier] }) {
    if isMT { handleMTDeviceConnection(peripheral) } else { handlePTDeviceConnection(peripheral) }
} else if let peripheralName = peripheral.name {
    if peripheralName.hasPrefix("ELD-MA") {
        handleMTDeviceConnection(peripheral)
    } else {
        handlePTDeviceConnection(peripheral)
    }
} else {
```
(The trailing `else { …name is nil audit log… }` stays unchanged.)

---

## Edit D (optional, for clean UI validation — not required for the fix)
The pre-connect "wrong device type" alerts also check the name; make them prefer the captured type:
- `DeviceListViewController+UITableView.swift:61` and `:71`
- `Step6ScanforELD.swift` (the two ontap handlers)
- `BleClass.swift:1259` / `:1272` (`handleManualConnection`)

Pattern (example for the MT-expected reject at `+UITableView.swift:71`):
```swift
// Before: if selecteddevice.name != nil && !selecteddevice.name!.hasPrefix("ELD-MA") {
let advIsMT = BLEControl.BLESingleton.advertisedIsMT(for: selecteddevice.identifier)
if advIsMT == false || (advIsMT == nil && selecteddevice.name != nil && !selecteddevice.name!.hasPrefix("ELD-MA")) {
```
**Edits A–C alone fully fix connect/reconnect routing.** D only prevents a false "wrong device" alert when the simulator's cached name is shown in the picker.

---

## Safety
| Device | Advertises | Cached map | Routes to | vs today |
|---|---|---|---|---|
| Real MT | `7add0001` | `true` | `handleMTDeviceConnection` | same ✅ |
| Real PT | `6e400001` | `false` | `handlePTDeviceConnection` | same ✅ |
| Our simulator | `7add0001` | `true` | `handleMTDeviceConnection` | **fixed** (was wrongly PT on reconnect) |
| No scan / nil name | — | miss | falls back to name logic | same ✅ |

Thread-safe (existing `stateQueue` barrier pattern). No new constants, no new queue. Do **not**
edit `newBleClass.swift` / `ClassBluetooth.swift` (dead, not in the build).
