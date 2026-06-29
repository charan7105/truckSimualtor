import SwiftUI
import MapKit
import CoreLocation
import AppKit
import QuartzCore

/// The center navigation map: the route polyline + a smoothly-eased truck pin with a continuous
/// pan, with a floating compass. Route controls live in the Flight Deck drawer.
struct ClusterMap: View {
    @ObservedObject var sim: SimController
    var body: some View {
        ZStack {
            RouteMapView(sim: sim)
            // edge vignette so the bright map recedes into the dark chrome (centre stays clear)
            RadialGradient(colors: [.clear, Theme.bg0.opacity(0.5)], center: .center, startRadius: 200, endRadius: 620)
                .allowsHitTesting(false)
            // top scrim so the distance / "mi left" pills always sit on darkness
            LinearGradient(colors: [Color.black.opacity(0.38), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 88).frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            CompassRose().frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(   // 2px glass bezel (diagonal light → dark)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.02)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
        )
        .overlay(alignment: .topLeading) {   // accent tab — same language as the Card top-bars
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.ice)
                .frame(width: 38, height: 3).padding(.leading, 14)
                .shadow(color: Theme.ice.opacity(0.6), radius: 4)
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
    }
}

/// MKMapView wrapper. All dynamic updates are driven by the Coordinator's own render loop reading the
/// sim directly, so SwiftUI's telemetry re-renders never disturb the map (which blanked the tiles).
struct RouteMapView: NSViewRepresentable {
    let sim: SimController

    func makeCoordinator() -> Coordinator { Coordinator(sim: sim) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.mapType = .mutedStandard
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: sim.currentLat, longitude: sim.currentLon),
                                         span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6)),
                      animated: false)
        context.coordinator.start(map: map)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {}   // Coordinator render loop owns updates

    static func dismantleNSView(_ nsView: MKMapView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let sim: SimController
        private weak var map: MKMapView?
        private var timer: Timer?
        private var anno: MKPointAnnotation?
        private var routePoly: MKPolyline?
        private var lastRouteVersion = -1
        private var dispLat = 0.0, dispLon = 0.0
        private var wasDriving = false

        init(sim: SimController) { self.sim = sim; super.init() }

        func start(map: MKMapView) {
            self.map = map
            dispLat = sim.currentLat; dispLon = sim.currentLon
            timer?.invalidate()                                   // idempotent
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.render() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        func stop() { timer?.invalidate(); timer = nil }

        private func redrawRoute() {
            guard let map else { return }
            if let p = routePoly { map.removeOverlay(p); routePoly = nil }
            let coords = sim.routeCoords
            if coords.count >= 2 {
                let poly = MKPolyline(coordinates: coords, count: coords.count)
                map.addOverlay(poly)
                routePoly = poly
                if !sim.drivingRoute {
                    map.setVisibleMapRect(poly.boundingMapRect,
                                          edgePadding: NSEdgeInsets(top: 44, left: 44, bottom: 44, right: 44),
                                          animated: true)
                }
            }
        }

        private func render() {
            guard let map else { return }
            if sim.routeVersion != lastRouteVersion {
                lastRouteVersion = sim.routeVersion
                redrawRoute()
            }
            let driving = sim.drivingRoute
            let show = driving || sim.routeProgress > 0

            let bigJump = abs(sim.currentLat - dispLat) > 0.05 || abs(sim.currentLon - dispLon) > 0.05
            if (driving && !wasDriving) || (driving && bigJump) {
                dispLat = sim.currentLat; dispLon = sim.currentLon
                map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: dispLat, longitude: dispLon),
                                                 span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22)),
                              animated: false)
            } else if driving {
                let f = 1 - exp(-(1.0 / 30.0) / 0.20)
                dispLat += (sim.currentLat - dispLat) * f
                dispLon += (sim.currentLon - dispLon) * f
            }

            let coord = CLLocationCoordinate2D(latitude: dispLat, longitude: dispLon)
            if show {
                if anno == nil { let a = MKPointAnnotation(); map.addAnnotation(a); anno = a }
                anno?.coordinate = coord
            } else if let a = anno { map.removeAnnotation(a); anno = nil }

            if driving {
                map.setCenter(coord, animated: false)            // continuous smooth pan; truck centred
            } else if wasDriving {
                redrawRoute()
            }
            wasDriving = driving
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let p = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: p)
                r.strokeColor = NSColor(red: 0.43, green: 0.83, blue: 1.0, alpha: 0.95)
                r.lineWidth = 6
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let id = "truck"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            v.markerTintColor = NSColor.systemRed
            v.glyphImage = NSImage(systemSymbolName: "truck.box.fill", accessibilityDescription: "truck")
            v.animatesWhenAdded = false
            v.annotation = annotation
            return v
        }
    }
}
