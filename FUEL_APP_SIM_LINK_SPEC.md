# Fuel App ⇄ Truck Simulator — "Driver Simulation" link (Android spec)

Hand-off spec for the **Android Fuel App** developer. The iOS Fuel App already implements this
(branch `feature/sim-link-driver-simulation`); this doc is what Android needs to mirror so both
platforms behave the same. Once both are done, please produce a special test build.

---

## 1. Why
The Fuel App shows fuel stations/prices **near the phone's GPS**, and that data is **US-only**. Testers
physically in **India** therefore see an empty map. We can't change the data, so instead we let the app
**follow a running truck simulator's position** over the local network — the phone "drives" a US route, so
US stations appear and the whole app (map, search, "fuel needed") works. Testers don't manage GPS or GPX.

```
Truck simulator (PC/Mac)  ──HTTP over LAN──▶  Fuel App (phone)
  drives a US route                            copies the position into its location
  serves GET /pos                              → US fuel stations appear around the moving truck
```

**Tester setup (same as iOS):** phone + computer on the **same network** — easiest is the **phone's own
hotspot** with the computer joined to it. The sim shows a green pill **`FUEL LINK <ip>:8723`**; the tester
enters that `<ip>` in the app. No cloud, no account, no Bluetooth.

---

## 2. The protocol (already live in the simulator — do not change)
The simulator hosts a tiny HTTP server on **port `8723`**:

```
GET http://<ip>:8723/pos
→ 200 OK, application/json, Access-Control-Allow-Origin: *
{
  "lat":   31.769,        // double — latitude
  "lon":   -96.123,       // double — longitude
  "hdg":   103,           // int    — heading degrees (0..359)
  "spd":   62.5,          // double — speed (mph)
  "route": "Dallas, TX → Houston, TX",   // string — for the SIM badge label
  "ts":    1782770000     // unix seconds (server time)
}
```
**Poll once per second.** It's a plain one-shot HTTP response (connection closes each time). Cleartext HTTP
on purpose (LAN only) — see §4 for the Android cleartext requirement.

---

## 3. What to build on Android (mirror the iOS feature)

### 3a. `SimLink` (the poller) — mirrors `Fuel App/Services/SimLink.swift`
A singleton/ViewModel with:
- `address: String` (the sim IP, persisted), `isLinked: Bool`, `connected: Bool`, `routeName: String`.
- `link(address)`: persist the IP, set `isLinked = true`, enable the app's **dev/test-location override**
  (see 3b), start a **1 Hz poll** of `http://<address>:8723/pos`.
- `unlink()`: stop polling, `isLinked = false`, restore normal GPS.
- On each successful poll: parse the JSON and **push `{lat, lon}` + `hdg`** into the app's location source on
  the main thread; set `connected = true`, `routeName = route`. On failure/timeout (2.5s): `connected = false`.

Use OkHttp/HttpURLConnection + Kotlin coroutines (a `while (isLinked) { fetch(); delay(1000) }` loop) or a
Handler. Keep it simple; one in-flight request at a time is fine.

### 3b. Location override — the key integration point
Find where the Android app gets the device location for **fuel-station search + map camera + the truck/user
marker** (likely `FusedLocationProviderClient` or a `LocationManager`/repository exposing a `currentLocation`
`LiveData`/`StateFlow`). While linked:
- **Feed the simulated coordinate** into that same location stream (so the existing "location changed → fetch
  stations / move marker / center map" logic fires unchanged).
- **Suppress real GPS** so the device's real (India) location does **not** overwrite the simulated one.
  (iOS does this with a guard: while linked, ignore real `onLocationResult`.)
- If the Android app already has a **dev/test-location** flag (iOS had `NetworkManager.devMode` that overrode
  to a fixed San Francisco point), **reuse it** — just make it follow the polled position instead of a static
  point.

> Net effect must match iOS: the station search + map + marker all use the **sim's moving position**.

### 3c. UI — "Driver Simulation" in Settings/Menu (mirror `MenuView.swift` driverSimSection)
A card in the menu/settings with:
- A **text field** for the sim address (hint `e.g. 172.20.10.2`), numeric/punctuation keyboard.
- A **Link / Unlink** button.
- A **status line**: `Off` / `Linking…` / `Following sim` + the `route` when connected.
- Short helper text: *"Follow a running truck simulator on the same WiFi / hotspot so US fuel stations appear.
  Enter the FUEL LINK address shown in the sim."*

### 3d. Map **SIM badge** — always visible while linked (mirror the iOS map overlay)
A pill pinned **top-left** over the map, shown whenever `isLinked`:
- `SIM · <route>` (green when `connected`, orange/"linking…" before the first response).
- Purpose: it must be obvious the location is **simulated**, not the tester's real position.

### 3e. Persistence & default
- Persist the entered IP and the linked flag (SharedPreferences).
- Optional: default the feature **on for debug/internal build flavors** so testers are auto-unblocked; **off**
  in release. (iOS keys this off a dev flag — match your build-flavor convention.)

---

## 4. Android-specific gotchas (important)
1. **Cleartext HTTP to a LAN IP is blocked by default on Android 9+.** Allow it *scoped to local addresses*
   via a network security config rather than a blanket `usesCleartextTraffic="true"`. Example
   `res/xml/network_security_config.xml`:
   ```xml
   <network-security-config>
     <domain-config cleartextTrafficPermitted="true">
       <domain includeSubdomains="true">172.20.10.0</domain> <!-- iOS hotspot range -->
       <domain includeSubdomains="true">192.168.0.0</domain>  <!-- common WiFi/Android-hotspot -->
       <domain includeSubdomains="true">10.0.0.0</domain>
     </domain-config>
   </network-security-config>
   ```
   …referenced from `AndroidManifest.xml` `<application android:networkSecurityConfig="@xml/network_security_config" ...>`.
   (Domain-matching is exact-host; if scoping by subnet is awkward, gate a build-flavor that simply sets
   `cleartextTrafficPermitted="true"` for the **test** flavor only.)
2. **Permissions:** only `android.permission.INTERNET` is needed for the LAN HTTP call. No special local-network
   permission (unlike iOS). You still need the app's existing location permission for the marker/camera paths.
3. **Same network:** the phone and computer must share the network (hotspot is easiest). If a phone hotspot has
   "isolate clients" on, turn it off (rare).
4. **Threading:** push location updates on the main thread; the HTTP poll on a background thread/coroutine.
5. **Heading:** `hdg` is degrees true; feed it to whatever the marker uses for bearing.

---

## 5. Reference (iOS implementation to mirror)
In the **Fuel App** repo, branch `feature/sim-link-driver-simulation`:
- `Fuel App/Services/SimLink.swift` — the poller + override logic (the canonical reference).
- `Fuel App/MapView/LocationManager.swift` — the "while linked, ignore real GPS" guard.
- `Fuel App/Menu/MenuView.swift` — the "Driver Simulation" card UI.
- `Fuel App/MapView/MapView.swift` — the SIM badge overlay.

In the **simulator** repo (`charan7105/truckSimualtor`):
- `Sources/MatrackTruckSim/SimBridge.swift` (macOS) and `windows/MatrackSim.App/SimBridge.cs` (Windows) — the
  server side; identical `/pos` JSON on port 8723. Nothing to change there.

---

## 6. Test checklist (both platforms)
1. Run the truck sim on a computer; join the computer to the **phone's hotspot**.
2. Read the `FUEL LINK <ip>:8723` pill in the sim.
3. In the Fuel App → Settings → Driver Simulation → enter `<ip>` → **Link**.
4. Status → **Following sim**; the **SIM badge** appears on the map.
5. In the sim, load a route (e.g. Dallas→Houston) and **Drive**.
6. Confirm in the app: the map centers in the US and the **truck moves**; **fuel stations + prices populate**;
   the "fuel needed" estimate works. Unlink → returns to the real device location.
