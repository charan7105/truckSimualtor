import Foundation

/// Tiny LAN position broadcaster. A phone on the SAME network (shared WiFi, or — easiest — the phone's own
/// hotspot with the computer joined to it) can follow the simulated drive: the Matrack Fuel App's "Link to
/// sim" polls `GET /pos` and copies the position into its location, so US fuel stations appear around the
/// moving truck even for testers physically in India.
///
/// Protocol: HTTP, port 8723.  GET /pos → {"lat":..,"lon":..,"hdg":..,"spd":..,"route":"..","ts":..}
///
/// Uses a plain POSIX TCP socket bound to INADDR_ANY so it listens reliably regardless of the machine's
/// network state (an NWListener can sit in `.waiting` on a constrained/half-up interface and never bind).
final class SimBridge: ObservableObject {
    static let shared = SimBridge()

    /// Supplied by the app each tick — the live truck position to serve.
    var position: () -> (lat: Double, lon: Double, hdg: Int, spd: Double, route: String) = { (0, 0, 0, 0, "") }

    @Published private(set) var linkIP: String = "—"      // e.g. "172.20.10.2"  (shown in the UI)
    @Published private(set) var linkCode: String = "—"    // last octet, the short "type this" code
    @Published private(set) var running = false

    private let portNumber: UInt16 = 8723
    private var serverFD: Int32 = -1

    var port: UInt16 { portNumber }

    func start() {
        guard serverFD < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)   // macOS REQUIRES sin_len or bind() fails
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = in_addr_t(0)                    // INADDR_ANY → all interfaces (loopback + hotspot)
        addr.sin_port = portNumber.bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { NSLog("SimBridge bind failed errno=%d", errno); close(fd); return }
        guard listen(fd, 8) == 0 else { NSLog("SimBridge listen failed errno=%d", errno); close(fd); return }

        serverFD = fd
        NSLog("SimBridge listening on :%d", Int(portNumber))
        DispatchQueue.main.async { self.running = true; self.refreshAddress() }
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var buf = [UInt8](repeating: 0, count: 1024)
            _ = recv(client, &buf, buf.count, 0)           // drain the request line (best effort)

            let p = position()
            let body = "{\"lat\":\(p.lat),\"lon\":\(p.lon),\"hdg\":\(p.hdg),\"spd\":\(p.spd)," +
                       "\"route\":\"\(p.route)\",\"ts\":\(Date().timeIntervalSince1970)}"
            let resp = "HTTP/1.1 200 OK\r\n" +
                       "Content-Type: application/json\r\n" +
                       "Access-Control-Allow-Origin: *\r\n" +
                       "Connection: close\r\n" +
                       "Content-Length: \(body.utf8.count)\r\n\r\n" + body
            let bytes = Array(resp.utf8)
            _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, bytes.count, 0) }
            close(client)
        }
        close(fd)
    }

    /// This machine's LAN IPv4 (Wi-Fi / hotspot), preferring en0, and the short link code (last octet).
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
            if ip.hasPrefix("169.254") { continue }      // skip APIPA / link-local
            if name == "en0" { return ip }               // Wi-Fi / hotspot on most Macs → prefer it
            if best == nil { best = ip }
        }
        return best
    }
}
