import Foundation
import CoreBluetooth

/// Mac BLE CENTRAL that connects to a REAL MT tracker and logs its raw packets.
/// `swift run MatrackTruckSim capture` — the Mac plays the role the iPhone app plays
/// (this direction works fine on macOS), so we can capture the true wire format.
final class MTCapture: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: "7add0001-f286-4c78-adda-520c4ba3500c")
    private let txUUID = CBUUID(string: "7add0002-f286-4c78-adda-520c4ba3500c") // app writes commands here
    private let rxUUID = CBUUID(string: "7add0003-f286-4c78-adda-520c4ba3500c") // tracker notifies data here

    private var central: CBCentralManager!
    private var tracker: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var wdgTimer: Timer?
    private var packetCount = 0

    func start() { central = CBCentralManager(delegate: self, queue: nil) }

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        print("[\(f.string(from: Date()))] \(s)")
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            log("Bluetooth on — scanning ALL devices (incl. overflow service UUIDs)…")
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized:
            log("Bluetooth permission denied — allow it for Terminal in System Settings ▸ Privacy & Security ▸ Bluetooth")
        case .poweredOff: log("Bluetooth is OFF")
        default: log("Bluetooth state \(c.state.rawValue)")
        }
    }

    private var seen = Set<UUID>()

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let advName = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflow = (ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        var mfg = ""
        if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data {
            mfg = m.map { String(format: "%02x", $0) }.joined()
        }
        // Log every distinct nearby device once, with FULL advertisement (incl. overflow + manufacturer).
        if seen.insert(p.identifier).inserted, RSSI.intValue > -75 {   // only close-by devices, reduce noise
            let svc = (services + overflow).map { $0.uuidString }.joined(separator: ",")
            log("  · name='\(advName.isEmpty ? "(none)" : advName)' rssi=\(RSSI) services=[\(svc)] mfg=\(mfg.isEmpty ? "-" : mfg)")
        }
        let isTracker = advName.uppercased().hasPrefix("ELD-MA")
            || advName.uppercased().hasPrefix("ELD_MA")
            || services.contains(serviceUUID)
            || overflow.contains(serviceUUID)
        guard isTracker, tracker == nil else { return }
        log("✓ found tracker: name='\(advName)'  rssi=\(RSSI)  services=\(services.map { $0.uuidString })")
        log("   id=\(p.identifier.uuidString)")
        tracker = p
        p.delegate = self
        c.stopScan()
        c.connect(p, options: nil)
        log("connecting…")
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected — discovering services")
        p.discoverServices([serviceUUID])
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "?") — rescanning")
        tracker = nil; c.scanForPeripherals(withServices: nil)
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("disconnected (\(error?.localizedDescription ?? "clean")) after \(packetCount) packets — rescanning")
        tracker = nil; txChar = nil; wdgTimer?.invalidate(); c.scanForPeripherals(withServices: nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics([txUUID, rxUUID], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == rxUUID { p.setNotifyValue(true, for: ch); log("subscribed to data characteristic (Rx 7add0003)") }
            if ch.uuid == txUUID { txChar = ch; log("found command characteristic (Tx 7add0002)") }
        }
        if let tx = txChar {
            send("readdata", to: p, tx)
            wdgTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.send("$wdg,4327", to: p, tx) }
        }
    }
    private func send(_ s: String, to p: CBPeripheral, _ ch: CBCharacteristic) {
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(s.utf8), for: ch, type: type)
        log("→ sent command: \(s)")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        packetCount += 1
        let hex = d.map { String(format: "%02x", $0) }.joined()
        let ascii = String(data: d, encoding: .ascii) ?? "<non-ascii>"
        log("📦 RX #\(packetCount) [\(d.count)B]  ascii='\(ascii)'  hex=\(hex)")
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { log("write error: \(e.localizedDescription)") }
    }
}
