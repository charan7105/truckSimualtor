import Foundation

/// Builds legacy MT tracker ASCII packets and the BLE chunk framing the ELD app reassembles.
///
/// Telemetry packets (LP/SP/LI/SI/LS/SS/LE/SE) all share ONE 17-field layout
/// (confirmed from UtilParser.parsePacketGeneric, indices 0–16):
///   type,ign,rpm,speed(km/h),odo(×10 km),engHrs(×100),lat,lon,gpsLock(2|3),heading,HHMMSS,DDMMYY,ecm,fuel1,fuel2,sats,gpsSpeed
/// The app converts: speed ÷1.60934 → mph, odometer ×0.0621371 → miles, engineHours ÷100.
enum MTPacket {

    private static let kmhPerMph = 1.60934
    private static let milesPerRawOdo = 0.0621371   // miles = rawOdo * this  ⇒  rawOdo = miles / this

    static func livePosition(_ e: EngineState, date: Date = Date()) -> String { telemetry("LP", e, date) }
    static func speedChange(_ e: EngineState, date: Date = Date()) -> String { telemetry("LS", e, date) }
    static func engineEvent(_ e: EngineState, date: Date = Date()) -> String { telemetry("LE", e, date) }

    /// Ignition packet ("LI"): on == power-up (ign 1), off == shutdown (ign 0).
    static func ignition(_ e: EngineState, on: Bool, date: Date = Date()) -> String {
        telemetry("LI", e, date, ignitionOverride: on ? 1 : 0)
    }

    private static func telemetry(_ prefix: String, _ e: EngineState, _ date: Date, ignitionOverride: Int? = nil) -> String {
        let ign = ignitionOverride ?? (e.ignitionOn ? 1 : 0)
        let speedKmh = Int((e.speedMph * kmhPerMph).rounded())
        let rawOdo = Int((e.odometerMiles / milesPerRawOdo).rounded())
        let engHrsX100 = Int((e.engineHours * 100).rounded())
        let (hhmmss, ddmmyy) = utcTokens(date)
        let fields = [
            prefix,                                       // 0  type
            "\(ign)",                                     // 1  ignition
            "\(e.rpm)",                                   // 2  rpm
            "\(speedKmh)",                                // 3  speed km/h
            "\(rawOdo)",                                  // 4  odometer ×10 km
            "\(engHrsX100)",                              // 5  engine hours ×100
            String(format: "%.6f", e.latitude),          // 6  latitude
            String(format: "%.6f", e.longitude),         // 7  longitude
            "3",                                          // 8  GPS lock (2|3 = locked)
            "\(e.headingDeg)",                            // 9  heading
            hhmmss,                                       // 10 HHMMSS utc
            ddmmyy,                                       // 11 DDMMYY utc
            e.ecmActive ? "1" : "0",                      // 12 ecm
            String(format: "%.1f", e.fuelLevelPct),       // 13 fuel tank 1 (%)
            String(format: "%.1f", e.fuelLevel2Pct),      // 14 fuel tank 2 (%)
            "\(e.satellites)",                            // 15 satellites
            "\(e.gpsSpeedKmh)"                            // 16 gps speed
        ]
        return fields.joined(separator: ",")
    }

    /// Version/VIN packet: LV,VIN,mcuHW,mcuFW,bleHW,bleFW,canMode,canMask,deviceMAC
    static func version(_ d: DeviceInfo) -> String {
        ["LV", d.vin, d.mcuHW, d.mcuFW, d.bleHW, d.bleFW, d.canMode, d.canMask, d.deviceMAC].joined(separator: ",")
    }

    /// DTC packet (OBD-II path): LD,ign,rpm,canMode(0),count,spare(0),hexBlob
    static func dtc(_ codes: [String], ignition: Int, rpm: Int) -> String {
        let blob = codes.map(encodeObd2).joined()
        return ["LD", "\(ignition)", "\(rpm)", "0", "\(codes.count)", "0", blob].joined(separator: ",")
    }

    /// Encode an OBD-II code (e.g. "P0143") into its 4 hex chars.
    /// High 2 bits of nibble 0 = system (P=0,C=1,B=2,U=3), next 2 bits = first digit, then 3 hex digits.
    private static func encodeObd2(_ code: String) -> String {
        let sys: [Character: Int] = ["P": 0, "C": 1, "B": 2, "U": 3]
        let c = Array(code.uppercased())
        guard c.count == 5, let s = sys[c[0]], let d0 = c[1].hexDigitValue, d0 <= 3 else { return "0000" }
        let firstNibble = s * 4 + d0
        return String(firstNibble, radix: 16).uppercased() + String(c[2 ... 4])
    }

    private static func utcTokens(_ date: Date) -> (String, String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hhmmss = String(format: "%02d%02d%02d", c.hour!, c.minute!, c.second!)
        let ddmmyy = String(format: "%02d%02d%02d", c.day!, c.month!, c.year! % 100)
        return (hhmmss, ddmmyy)
    }

    /// Split a payload into the app's BLE chunk frames.
    /// Each frame = "$" + <total digit> + <current digit> + <1 reserved char> + <payload slice>;
    /// the assembled payload ends with "$$"; total/current are single HEX digits — the iOS/Android
    /// parsers both read them with radix 16, so we emit hex to match byte-exactly (≤9 chunks here).
    static func frame(_ payload: String) -> [Data] {
        let body = Array(payload + "$$")
        let size = max(16, Int((Double(body.count) / 9.0).rounded(.up)))
        let slices = stride(from: 0, to: body.count, by: size).map {
            Array(body[$0 ..< min($0 + size, body.count)])
        }
        let total = slices.count
        return slices.enumerated().map { (i, slice) in
            // reserved char = '0' (app ignores index 3); hex digits match the apps' radix-16 parse
            Data(("$\(String(total, radix: 16))\(String(i, radix: 16))0" + String(slice)).utf8)
        }
    }
}
