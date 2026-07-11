# ESP32 test — simple steps

The PC app makes the truck data. The ESP32 is just the Bluetooth radio the phone talks to.
We're checking that the board works and that the **RSSI slider actually changes the phone's signal**
(the app alone can't do that — that's why we need the board).

**You need:** the ESP32 board + USB cable · the Windows PC with the app · a phone with the ELD app
(test account only) · a Bluetooth scanner app on the phone (nRF Connect or LightBlue).

---

### 1. Put the code on the board
Open the sketch in Arduino, pick the ESP32-C3 board, click Upload.
✅ Good: the serial monitor shows `#ELD-MA advertising`.
❌ If it won't upload/compile → tell us (it's a small board-specific fix).

### 2. Check the board is showing up
Open the Bluetooth scanner near the board.
✅ Good: you see a device called **ELD-MA**.

### 3. Check the signal can change  ← most important
In the serial monitor type `#txpower -12`, then `#txpower 9`.
✅ Good: in the scanner, ELD-MA's **signal drops a lot, then comes back**.
❌ If the signal doesn't change → stop and tell us. Nothing else matters until this works.

### 4. Connect the PC app to the board
Plug the board into the PC. Open the app. In the **CONNECTION · SIGNAL** box, pick the board's port and click **LINK**.
✅ Good: it says `ESP32 on COM…`.

### 5. Connect the phone
Open the ELD app on the phone.
✅ Good: the phone connects and shows live truck data (speed, engine, GPS), same as normal.

### 6. Move the RSSI slider  ← the whole point
Drag the **RSSI** slider down and up.
✅ Good: the **phone's signal bar goes down and up** with it.

### 7. Drop and reconnect
Click **DROP** → the phone loses the device. Click **BACK** → the phone connects again by itself.

### 8. Leave it running a few minutes
✅ Good: it stays connected, no random drops.

---

**It passes if:** step 1 (uploads), step 3 (signal changes in the scanner), and step 6 (slider moves the
phone's signal) all work. If those three are good, we're done and we ship it.

**Why the board is needed:** the PC/Mac can't change real Bluetooth signal strength — only the board can.
So the real signal, real out-of-range, and real distance/range can only be tested on the board.
