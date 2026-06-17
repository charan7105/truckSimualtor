import SwiftUI
import MapKit
import CoreLocation
import AppKit
import QuartzCore

/// Center-stage navigation map. Set a route (From → To or Random), then drive it.
///
/// Everything dynamic (polyline redraw, truck marker, camera follow) is driven by the Coordinator's
/// own render loop reading the sim directly — so SwiftUI's frequent telemetry re-renders never touch
/// the map (which was blanking the tiles). The camera is kept still and only recentred when the truck
/// drifts off-centre, giving MapKit the idle moments it needs to actually load tiles.
struct MapPanel: View {
    @EnvironmentObject var sim: SimController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ROUTE · NAVIGATION").sectionLabel()
                Spacer()
                Text(sim.routeInfo.isEmpty ? "No route set" : sim.routeInfo)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.dim).lineLimit(1)
            }

            HStack(spacing: 6) {
                TextField("From — e.g. Dallas, TX", text: $sim.routeFrom).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.dim)
                TextField("To — e.g. Houston, TX", text: $sim.routeTo).textFieldStyle(.roundedBorder)
                NeonButton(title: sim.routeBusy ? "…" : "PLAN", icon: "map", tint: Theme.ice) {
                    Task { await sim.loadRoute(from: sim.routeFrom, to: sim.routeTo) }
                }.frame(width: 96)
                NeonButton(title: "RANDOM", icon: "shuffle", tint: Theme.amber) {
                    Task { await sim.loadRandomRoute() }
                }.frame(width: 124)
            }

            RouteMapView(sim: sim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))

            HStack(spacing: 12) {
                if sim.drivingRoute {
                    NeonButton(title: "STOP", icon: "stop.fill", tint: Theme.red) { sim.stopRouteDrive() }.frame(width: 130)
                } else {
                    NeonButton(title: "DRIVE ROUTE", icon: "play.fill", tint: Theme.green, filled: sim.route.hasRoute) {
                        sim.startRouteDrive()
                    }.frame(width: 170)
                }
                if sim.drivingRoute || sim.routeProgress > 0 {
                    ProgressView(value: sim.routeProgress).tint(Theme.green)
                    Text("\(Int(sim.routeProgress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.green)
                        .frame(width: 40, alignment: .trailing)
                } else {
                    Spacer()
                }
            }
        }
        .padding(16)
        .glassPanel(Theme.ice)
    }
}

struct RouteMapView: NSViewRepresentable {
    let sim: SimController

    func makeCoordinator() -> Coordinator { Coordinator(sim: sim) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.mapType = .mutedStandard
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: sim.currentLat, longitude: sim.currentLon),
                                         span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6)),
                      animated: false)
        context.coordinator.start(map: map)
        return map
    }

    // No-op: the Coordinator's render loop owns all dynamic updates, so SwiftUI re-renders never
    // disturb the map (doing work here on every telemetry tick was blanking the tiles).
    func updateNSView(_ map: MKMapView, context: Context) {}

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
        private var lastTick: CFTimeInterval = 0

        init(sim: SimController) { self.sim = sim; super.init() }

        func start(map: MKMapView) {
            self.map = map
            dispLat = sim.currentLat; dispLon = sim.currentLon
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
                                          edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                                          animated: true)
                }
            }
        }

        /// 30 Hz: redraw the route when it changes, glide the marker, and recenter only on drift.
        private func render() {
            guard let map else { return }

            if sim.routeVersion != lastRouteVersion {
                lastRouteVersion = sim.routeVersion
                redrawRoute()
            }

            let now = CACurrentMediaTime()
            let dt = lastTick == 0 ? 1.0 / 30.0 : min(0.1, now - lastTick); lastTick = now
            let driving = sim.drivingRoute
            let show = driving || sim.routeProgress > 0

            // Snap on drive start / autopilot teleport to a new route; otherwise ease smoothly.
            let bigJump = abs(sim.currentLat - dispLat) > 0.05 || abs(sim.currentLon - dispLon) > 0.05
            if (driving && !wasDriving) || (driving && bigJump) {
                dispLat = sim.currentLat; dispLon = sim.currentLon
                map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: dispLat, longitude: dispLon),
                                                 span: MKCoordinateSpan(latitudeDelta: 0.14, longitudeDelta: 0.14)),
                              animated: false)
            } else if driving {
                let f = 1 - exp(-dt / 0.20)
                dispLat += (sim.currentLat - dispLat) * f
                dispLon += (sim.currentLon - dispLon) * f
            }

            let coord = CLLocationCoordinate2D(latitude: dispLat, longitude: dispLon)
            if show {
                if anno == nil { let a = MKPointAnnotation(); map.addAnnotation(a); anno = a }
                anno?.coordinate = coord
            } else if let a = anno { map.removeAnnotation(a); anno = nil }

            if driving {
                map.setCenter(coord, animated: false)   // continuous smooth pan; truck stays centred
            } else if wasDriving {
                redrawRoute()        // back to overview when stopped/arrived
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
