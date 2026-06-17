import Foundation
import CoreLocation
import MapKit

// MARK: - Geo math

enum Geo {
    static let earthRadiusM = 6_371_000.0

    /// Great-circle distance in meters between two coordinates.
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusM * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Initial bearing (degrees 0–359) from a → b.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Int {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return Int((deg + 360).truncatingRemainder(dividingBy: 360))
    }

    /// Linearly interpolate between a and b at fraction t (0–1).
    static func interp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}

// MARK: - Route engine: drives a polyline, producing position/heading/distance

/// Holds a route as a list of coordinates and advances a "vehicle" along it by distance.
final class RouteEngine {
    private(set) var coords: [CLLocationCoordinate2D] = []
    private var cumMeters: [Double] = []     // cumulative distance to each coord
    private(set) var traveledMeters: Double = 0

    var totalMeters: Double { cumMeters.last ?? 0 }
    var totalMiles: Double { totalMeters * 0.000621371 }
    var hasRoute: Bool { coords.count >= 2 }
    var isComplete: Bool { hasRoute && traveledMeters >= totalMeters }
    var progressFraction: Double { totalMeters > 0 ? min(1, traveledMeters / totalMeters) : 0 }

    func setRoute(_ c: [CLLocationCoordinate2D]) {
        coords = c
        cumMeters = []
        var sum = 0.0
        for i in c.indices {
            if i == 0 { cumMeters.append(0) }
            else { sum += Geo.meters(c[i - 1], c[i]); cumMeters.append(sum) }
        }
        traveledMeters = 0
    }

    func reset() { traveledMeters = 0 }

    /// Advance by `meters` along the route. Returns the new position + heading, or nil if no route.
    @discardableResult
    func advance(meters: Double) -> (coord: CLLocationCoordinate2D, headingDeg: Int)? {
        guard hasRoute else { return nil }
        traveledMeters = min(totalMeters, traveledMeters + max(0, meters))
        return positionAt(traveledMeters)
    }

    /// Position + heading at a given distance along the route.
    func positionAt(_ dist: Double) -> (coord: CLLocationCoordinate2D, headingDeg: Int) {
        guard hasRoute else {
            return (coords.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0), 0)
        }
        if dist <= 0 { return (coords[0], Geo.bearing(coords[0], coords[1])) }
        if dist >= totalMeters {
            let n = coords.count
            return (coords[n - 1], Geo.bearing(coords[n - 2], coords[n - 1]))
        }
        // find the segment containing `dist`
        var seg = 1
        while seg < cumMeters.count && cumMeters[seg] < dist { seg += 1 }
        let a = coords[seg - 1], b = coords[seg]
        let segStart = cumMeters[seg - 1], segLen = cumMeters[seg] - segStart
        let t = segLen > 0 ? (dist - segStart) / segLen : 0
        return (Geo.interp(a, b, t), Geo.bearing(a, b))
    }
}

// MARK: - Directions: resolve "from → to" into a drivable route

enum Directions {
    enum DirError: Error, LocalizedError {
        case notFound(String)
        case noRoute
        var errorDescription: String? {
            switch self {
            case .notFound(let q): return "Could not find a place for \"\(q)\""
            case .noRoute: return "No driving route found between those points"
            }
        }
    }

    /// Geocode a free-text place ("Dallas, TX" / an address) to a coordinate.
    static func geocode(_ query: String) async throws -> CLLocationCoordinate2D {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        let resp = try await MKLocalSearch(request: req).start()
        guard let item = resp.mapItems.first else { throw DirError.notFound(query) }
        return item.placemark.coordinate
    }

    /// Compute a driving route (array of coordinates) between two place strings.
    static func route(from: String, to: String) async throws -> [CLLocationCoordinate2D] {
        async let o = geocode(from)
        async let d = geocode(to)
        let (origin, dest) = try await (o, d)
        return try await route(from: origin, to: dest)
    }

    static func route(from origin: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D] {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        req.transportType = .automobile
        let resp = try await MKDirections(request: req).calculate()
        guard let poly = resp.routes.first?.polyline else { throw DirError.noRoute }
        var pts = [CLLocationCoordinate2D](repeating: .init(), count: poly.pointCount)
        poly.getCoordinates(&pts, range: NSRange(location: 0, length: poly.pointCount))
        return pts
    }
}
