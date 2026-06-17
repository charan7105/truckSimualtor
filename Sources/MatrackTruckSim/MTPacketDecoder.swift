import Foundation

/// Mirrors the Matrack ELD app's actual receive pipeline (BleClass.PacketValidator +
/// processMultiPartPacketImproved reassembly + UtilParser.parsePacketGeneric field decode).
///
/// This lets the self-test prove that packets the simulator produces are (a) accepted by the
/// app's validator, (b) reassembled correctly from chunks, and (c) decode back to the values we
/// encoded (round-trip). It is a faithful port of the logic extracted from the app source.
enum MTDecoder {

    static let validPrefixes = ["LP","SP","LI","SI","LS","SS","LE","SE","LV","SV","LD","SD","SX","LX","LH","SH"]
    static let validResponses = ["ERR_MCU","ACK,PGN","ACK,STOP","ACK,DATA","$OTA_OK","DATA","SAVED",
                                 "DEBUG","LAST PGN","$START","$STOP","ACK,","CAN MODE","CANMASK",
                                 "LAST_STORED_PACKET","SAVED PACKET COUNT"]

    /// Faithful port of BleClass.PacketValidator.isValidPacketFormat.
    static func isValid(_ packet: String) -> Bool {
        if validResponses.contains(where: { packet.uppercased().hasPrefix($0) }) { return true }
        if validPrefixes.contains(where: { packet.hasPrefix($0) }) { return packet.hasSuffix("$$") }
        if packet.hasPrefix("$"), packet.count >= 4 {
            let two = Array(packet)[1...2]
            return two.allSatisfy { $0.isHexDigit }
        }
        let l = packet.lowercased()
        return l.hasPrefix("d") || l.hasPrefix("v") || l.hasPrefix("e")
    }

    /// Reassemble chunk frames ("$"+total+current+reserved+payload) into the inner payload,
    /// mirroring processMultiPartPacketImproved + processCompletePacketImproved. Returns the
    /// "$"-stripped packet, or nil if the chunk sequence is malformed.
    static func reassemble(_ frames: [Data]) -> String? {
        var packetT = ""
        var expectedTotal = -1
        for (idx, f) in frames.enumerated() {
            guard let v = String(data: f, encoding: .ascii), v.hasPrefix("$"), v.count >= 4 else { return nil }
            let chars = Array(v)
            guard let total = Int(String(chars[1]), radix: 16),
                  let current = Int(String(chars[2]), radix: 16) else { return nil }
            if current == 0 { packetT = ""; expectedTotal = total }
            guard current == idx, total == expectedTotal else { return nil }   // ordering check
            packetT += String(chars[4...])
            if total - 1 == current {                                          // last chunk
                guard v.hasSuffix("$") else { return nil }
                return packetT.replacingOccurrences(of: "$", with: "")
            }
        }
        return nil   // never saw the terminating chunk
    }

    struct Decoded: Equatable {
        var type = ""
        var ignition: Int?
        var rpm: Int?
        var speedMph: Double?
        var odometerMiles: Double?
        var engineHours: Double?
        var lat: Double?, lon: Double?
        var gpsLocked: Bool?
        var heading: String?
        var utctime: String?, utcdate: String?
        var ecm: Int?
        var fuel1: String?, fuel2: String?
        var sats: Int?
        var gpsSpeed: Int?
        // LV
        var vin: String?, mcuFW: String?, bleFW: String?, deviceMAC: String?
        // LD
        var canMode: Int?, dtcCount: Int?, dtcBlob: String?
    }

    /// Faithful port of UtilParser.parsePacketGeneric / parseVin / DTC decode (same sentinels + scaling).
    static func decode(_ packet: String) -> Decoded? {
        let v = packet.components(separatedBy: ",")
        guard let type = v.first, !type.isEmpty else { return nil }
        var d = Decoded(); d.type = type

        if type == "LV" || type == "SV" {
            if v.count > 1 { d.vin = v[1] }
            if v.count > 3 { d.mcuFW = v[3] }
            if v.count > 5 { d.bleFW = v[5] }
            if v.count > 8 { d.deviceMAC = v[8] }
            return d
        }
        if type == "LD" || type == "SD" {
            if v.count > 3 { d.canMode = Int(v[3]) }
            if v.count > 4 { d.dtcCount = Int(v[4]) }
            if v.count > 6 { d.dtcBlob = v[6] }
            return d
        }
        // telemetry packets (LP/SP/LI/SI/LS/SS/LE/SE) — 17-field layout
        guard v.count >= 13 else { return nil }
        d.ignition = Int(v[1])
        if !v[2].hasPrefix("8191") { d.rpm = Int(v[2]) }                       // 8191 = invalid rpm
        d.speedMph = (Double(v[3]) ?? 0) / 1.60934
        if !v[4].hasPrefix("4294967295") { d.odometerMiles = (Double(v[4]) ?? 0) * 0.0621371 }
        if !v[5].hasPrefix("4294967295") { d.engineHours = (Double(v[5]) ?? 0) / 100 }
        d.lat = Double(v[6]); d.lon = Double(v[7])
        d.gpsLocked = (v[8] == "2" || v[8] == "3")
        d.heading = v[9]
        d.utctime = v[10]; d.utcdate = v[11]
        d.ecm = Int(v[12])
        if v.count > 13 { d.fuel1 = v[13] }
        if v.count > 14 { d.fuel2 = v[14] }
        if v.count > 15 { d.sats = Int(v[15]) }
        if v.count > 16 { d.gpsSpeed = Int(v[16]) }
        return d
    }
}
