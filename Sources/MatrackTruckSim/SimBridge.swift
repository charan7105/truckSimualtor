import Foundation
import Network

/// Tiny LAN position broadcaster. A phone on the SAME network (shared WiFi, or — easiest — the phone's own
/// hotspot with the computer joined to it) can follow the simulated drive: the Matrack Fuel App's "Link to
/// sim" polls `GET /pos` and copies the position into its location, so US fuel stations appear around the
/// moving truck even for testers physically in India.
///
/// Protocol: HTTP, port 8723.
///   GET /pos  →  {"lat":..,"lon":..,"hdg":..,"spd":..,"route":"..","ts":..}
final class SimBridge: ObservableObject {
    static let shared = SimBridge()

    /// Supplied by the app each tick — the live truck position to serve.
    var position: () -> (lat: Double, lon: Double, hdg: Int, spd: Double, route: String) = { (0, 0, 0, 0, "") }

    @Published private(set) var linkIP: String = "—"      // e.g. "172.20.10.2"  (shown in the UI)
    @Published private(set) var linkCode: String = "—"    // last octet, the short "type this" code
    @Published private(set) var running = false

    private var listener: NWListener?
    private let portNumber: UInt16 = 8723

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: portNumber)!)
            l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case .ready = state { DispatchQueue.main.async { self?.running = true; self?.refreshAddress() } }
            }
            l.start(queue: .global(qos: .utility))
            listener = l
        } catch {
            DispatchQueue.main.async { self.running = false }
        }
    }

    /// Respond to one connection with the current position, then close (simple one-shot HTTP).
    private func serve(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] _, _, _, _ in
            guard let self else { conn.cancel(); return }
            let p = self.position()
            let body = "{\"lat\":\(p.lat),\"lon\":\(p.lon),\"hdg\":\(p.hdg),\"spd\":\(p.spd)," +
                       "\"route\":\"\(p.route)\",\"ts\":\(Date().timeIntervalSince1970)}"
            let resp = "HTTP/1.1 200 OK\r\n" +
                       "Content-Type: application/json\r\n" +
                       "Access-Control-Allow-Origin: *\r\n" +
                       "Connection: close\r\n" +
                       "Content-Length: \(body.utf8.count)\r\n\r\n" + body
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    var port: UInt16 { portNumber }

    /// Find this machine's LAN IPv4 (Wi-Fi / hotspot), preferring en0, and derive the short link code.
    private func refreshAddress() {
        let ip = Self.localIPv4() ?? "—"
        let code = ip.split(separator: ".").last.map(String.init) ?? "—"
        DispatchQueue.main.async { self.linkIP = ip; self.linkCode = code }
    }

    static func localIPv4() -> String? {
        var best: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if name == "en0" { return ip }          // Wi-Fi / hotspot on most Macs → prefer it
            if best == nil { best = ip }
        }
        return best
    }
}
