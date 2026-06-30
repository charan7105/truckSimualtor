// MatrackEldAdvertiser — ESP32 BLE ⇄ USB-serial bridge for the Matrack truck simulator.
//
// WHY THIS EXISTS
// ----------------
// Windows (and to a lesser extent macOS) can't reliably act as a BLE *peripheral*:
//   • many Windows adapters are central-only → StartAdvertising no-ops / Aborts;
//   • Windows broadcasts the PC *name* (no per-app local name), so the ELD app's "ELD-MA" filter misses it;
//   • macOS had its own local-name quirk.
// A $5 ESP32 has none of those limits. This firmware makes the ESP32 *be* the BLE tracker — it advertises
// as "ELD-MA" with the exact Matrack GATT contract — while the desktop simulator (Mac/Windows) keeps doing
// all the smart work (route/telemetry/scenarios) and just streams the packet bytes to this board over USB.
// The rich desktop UI stays the control panel; the ESP32 is a guaranteed BLE radio. Works on every PC + Mac.
//
// GATT CONTRACT (must match the desktop app + the iOS ELD app)
//   Advertised name : ELD-MA
//   Service          7add0001-f286-4c78-adda-520c4ba3500c
//     Command char   7add0002-...  (Write | WriteNoResponse)  ← the ELD app writes commands here ($wdg, readdata, …)
//     Data char      7add0003-...  (Notify)                    ← we notify telemetry packets here
//
// SERIAL PROTOCOL (USB, 115200 baud) — 1 line = 1 BLE payload, transparent, no re-framing:
//   PC  -> ESP32 : each '\n'-terminated line is notified verbatim on the Data characteristic.
//                  (The desktop app already chunk-frames to the MTU, so one serial line == one notification.)
//   ESP32 -> PC : "#connected" / "#disconnected" / "#subscribed" events, and "<...." for every command the
//                  ELD app writes (so the PC can respond, e.g. answer readdata / reset the watchdog).
//
// FLASH: Arduino IDE → install the "esp32" boards package → pick your board → Upload. (See esp32/README.md.)

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

static const char* SERVICE_UUID = "7add0001-f286-4c78-adda-520c4ba3500c";
static const char* CMD_UUID     = "7add0002-f286-4c78-adda-520c4ba3500c";
static const char* DATA_UUID    = "7add0003-f286-4c78-adda-520c4ba3500c";
static const char* ADV_NAME     = "ELD-MA";

static BLECharacteristic* dataChar = nullptr;
static BLEAdvertising*    adv      = nullptr;
static volatile bool      connected = false;

// Re-advertise on disconnect so the app can reconnect — exactly the real out-of-range → back-in-range cycle.
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*)    override { connected = true;  Serial.println("#connected"); }
  void onDisconnect(BLEServer*) override { connected = false; Serial.println("#disconnected"); if (adv) adv->start(); }
};

// The ELD app's writes (commands) are forwarded to the PC, prefixed with '<' so it can tell them from echoes.
class CmdCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    std::string v = c->getValue();
    Serial.print('<');
    Serial.write((const uint8_t*)v.data(), v.size());
    Serial.print('\n');
  }
};

void setup() {
  Serial.begin(115200);
  delay(50);

  BLEDevice::init(ADV_NAME);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(SERVICE_UUID);

  BLECharacteristic* cmd = service->createCharacteristic(
      CMD_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  cmd->setCallbacks(new CmdCallbacks());

  dataChar = service->createCharacteristic(DATA_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  dataChar->addDescriptor(new BLE2902());          // CCCD so centrals can subscribe to notifications

  service->start();

  // Put the local name *and* the service UUID in the advertisement so the app's name filter matches and
  // a service-UUID scan finds it too. (This is exactly what Windows could not do per-app.)
  adv = BLEDevice::getAdvertising();
  BLEAdvertisementData advData;
  advData.setName(ADV_NAME);
  advData.setCompleteServices(BLEUUID(SERVICE_UUID));
  adv->setAdvertisementData(advData);
  BLEAdvertisementData scanResp;
  scanResp.setName(ADV_NAME);
  adv->setScanResponseData(scanResp);
  adv->setScanResponse(true);
  adv->start();

  Serial.println("#ELD-MA advertising");
}

// Read '\n'-terminated lines from the PC and notify each one verbatim over BLE.
static String line;
void loop() {
  while (Serial.available()) {
    char ch = (char)Serial.read();
    if (ch == '\n') {
      if (connected && dataChar && line.length()) {
        dataChar->setValue((uint8_t*)line.c_str(), line.length());
        dataChar->notify();
      }
      line = "";
    } else if (ch != '\r') {
      line += ch;
      if (line.length() > 512) line = "";          // guard against a runaway line
    }
  }
}
