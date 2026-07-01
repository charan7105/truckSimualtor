# Fuel App (Android) — make the **map** follow the truck simulator

Companion to **`FUEL_APP_SIM_LINK_SPEC.md`**. That doc covers the poller (`SimLink`), the location
override, the "Driver Simulation" settings card, and the cleartext/network setup — **build those first.**

This doc is only about the **map**: getting the **truck marker and camera to actually move** with the
simulated position. This is where the iOS build had a real bug, and where the naive "just feed the location
in" approach silently fails. Read this before touching the map screen.

---

## 1. The trap (why the marker won't move even after SimLink works)

The iOS app uses **MapLibre**; Android almost certainly does too (`org.maplibre.android`). On both, the
moving vehicle you see on the map is the **`LocationComponent`** (MapLibre's built-in location puck), and the
puck is driven by MapLibre's **own `LocationEngine`** — i.e. the device's **fused GPS**, *not* your app's
location LiveData/StateFlow.

So even after `SimLink` is polling `/pos` and pushing the simulated position into your repository:

- Fuel-station search recenters (it reads your location stream) ✅
- **The truck puck and the camera do NOT move** ❌ — they follow the phone's real GPS, which, for a tester
  sitting still in India, **emits almost no updates**. The puck just sits there.

> This is exactly what happened on iOS: the truck was tied to MapLibre's `didUpdate userLocation` (real GPS),
> which barely fires when the phone is stationary. Fix = drive the puck + camera from the sim's 1 Hz feed.

**Rule: while linked, the map's puck + camera must be fed by the sim, not by the device `LocationEngine`.**

---

## 2. The fix — pick ONE

### Option A (recommended, idiomatic): swap in a custom `LocationEngine`

Make MapLibre's own `LocationComponent` get its location from the sim. Then the puck **and** camera-tracking
**and** bearing all work through MapLibre's normal machinery — no manual marker code.

1. Activate the component with the **default engine off**:
   ```kotlin
   locationComponent.activateLocationComponentSimEngine(style)
   // LocationComponentActivationOptions.builder(context, style)
   //     .useDefaultLocationEngine(false)   // <-- critical: stop using device GPS for the puck
   //     .build()
   locationComponent.isLocationComponentEnabled = true
   locationComponent.renderMode  = RenderMode.GPS        // directional puck (uses bearing)
   locationComponent.cameraMode  = CameraMode.TRACKING_GPS // camera follows the puck; use NONE if you pan
   locationComponent.locationEngine = simLocationEngine   // our engine below
   ```
2. A tiny engine that emits whatever `SimLink` last received:
   ```kotlin
   class SimLocationEngine : LocationEngine {
       @Volatile private var last: Location? = null
       private val callbacks = CopyOnWriteArraySet<LocationEngineCallback<LocationEngineResult>>()

       /** Call this from SimLink on every /pos (1 Hz), on the main thread. */
       fun push(lat: Double, lon: Double, bearingDeg: Float, speedMph: Float) {
           val loc = Location("sim").apply {
               latitude = lat; longitude = lon; bearing = bearingDeg
               speed = speedMph * 0.44704f; time = System.currentTimeMillis()
               accuracy = 5f
           }
           last = loc
           val result = LocationEngineResult.create(loc)
           callbacks.forEach { it.onSuccess(result) }
       }
       override fun requestLocationUpdates(r: LocationEngineRequest,
           cb: LocationEngineCallback<LocationEngineResult>, looper: Looper?) { callbacks.add(cb); last?.let { cb.onSuccess(LocationEngineResult.create(it)) } }
       override fun removeLocationUpdates(cb: LocationEngineCallback<LocationEngineResult>) { callbacks.remove(cb) }
       override fun getLastLocation(cb: LocationEngineCallback<LocationEngineResult>) { last?.let { cb.onSuccess(LocationEngineResult.create(it)) } }
       override fun requestLocationUpdates(r: LocationEngineRequest, pi: PendingIntent?) {}
       override fun removeLocationUpdates(pi: PendingIntent?) {}
   }
   ```
3. In `SimLink`, after parsing each `/pos`, call `simLocationEngine.push(lat, lon, hdg, spd)` **and** update
   your existing location stream (so station search keeps working). On **unlink**, set the component's engine
   back to the real one (`useDefaultLocationEngine(true)` / your fused engine) and `cameraMode = NONE`.

### Option B (mirrors iOS exactly): drive a custom marker + camera by hand

Use this **only if the app does not use `LocationComponent`** and instead draws its own truck `Symbol`/marker
(iOS uses a custom `TruckAnnotation`). On **every** `/pos` (1 Hz), not on the fused-location callback:

```kotlin
// runs each second while linked, on the main thread
truckSymbol.latLng = LatLng(lat, lon)          // move the marker
truckSymbol.iconRotate = hdg.toFloat()         // face heading
symbolManager.update(truckSymbol)
if (!isUserPanning) {                           // don't fight a manual pan
    map.easeCamera(CameraUpdateFactory.newLatLng(LatLng(lat, lon)), 300)
}
```
Key point: **do not** gate this on `FusedLocationProviderClient`/`LocationEngine` callbacks — those don't fire
when the phone is still. The 1 Hz `/pos` poll is your clock.

> iOS reference for Option B — `Fuel App/MapView/MapLibreMapView.swift`, the `SimLink.shared.isLinked` block
> added in `updateUIView` (calls `updateTruckAnnotation(at: simLoc)` + `setCenter(simLoc)` unless the user is
> panning). That block **is** this fix; port it 1:1.

**Recommendation:** if the Android app already uses `LocationComponent` for the vehicle → **Option A**. If it
draws its own marker → **Option B**. Don't do both.

---

## 3. Must-get-right details

| Item | Requirement |
|---|---|
| **Real GPS suppression** | While linked, real GPS must not move the puck/camera. Option A: `useDefaultLocationEngine(false)` already does it. Option B: ignore real `onLocationResult` while `isLinked` (same guard SimLink uses for station search). |
| **Camera follow** | Recenter on **every** update so the truck stays on screen. Respect an `isUserPanning` flag so a manual pan isn't yanked back mid-gesture; resume following after. (iOS re-centers when the center moved > ~0.0001°.) |
| **Bearing** | Use `hdg` (degrees true, 0–359) for the marker rotation / `RenderMode.GPS` puck direction. |
| **Zoom** | On first link, set a driving zoom (~13–15) so stations are visible; don't reset it every tick. |
| **Threading** | Push to the map on the **main thread**; poll on a background coroutine (already true in SimLink). |
| **Unlink** | Restore the real `LocationEngine` / stop the manual marker loop and set `cameraMode = NONE` so the map returns to the tester's real location. |

---

## 4. Testing gotcha that looks like a bug (tell the tester)

- **Gasoline shows 0 in most of the US — this is data coverage, not a bug.** The gasoline merchant network is
  effectively **California-only** (verified: LA, SF, San Diego, Sacramento, Fresno all return results;
  Seattle, NYC, Dallas, Phoenix, Las Vegas, Houston, Chicago, Atlanta return **0**). **Diesel** uses a
  different, nationwide API and shows everywhere.
- So to test **gasoline**, drive the sim on a **California** route (e.g. `Los Angeles, CA → San Diego, CA`).
  For **diesel**, any US route is fine. Don't chase a "0 gasoline" bug when the truck is outside California.

---

## 5. Definition of done (Android map)

1. Link to a running sim; sim drives a **California** route.
2. The **truck puck/marker moves smoothly** along the route (not stuck), **camera follows**, marker faces `hdg`.
3. **Gasoline + diesel stations populate** around the moving truck; tapping the map / "fuel needed" works.
4. A manual pan lets you look around, then following resumes (or resumes on the next re-center).
5. **Unlink** → puck/camera snap back to the tester's real device location; real GPS resumes.
