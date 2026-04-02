// Views/Home/ProTrackingMapView.swift
// In-app map showing route from the contractor's location to the user.
import SwiftUI
import MapKit

struct ProTrackingMapView: View {
    let job: ServiceJob
    @Environment(\.dismiss) private var dismiss

    @State private var route: MKRoute?     = nil
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.75, longitude: -71.50),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
    )

    private var userCoord: CLLocationCoordinate2D? {
        LocationService.shared.currentLocation?.coordinate
    }

    private var proCoord: CLLocationCoordinate2D? {
        guard job.proLatitude != 0 || job.proLongitude != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: job.proLatitude, longitude: job.proLongitude)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Map
            Map(coordinateRegion: $region,
                showsUserLocation: true,
                annotationItems: annotations) { pin in
                MapAnnotation(coordinate: pin.coordinate) {
                    annotationView(for: pin)
                }
            }
            .overlay(routeOverlay)
            .ignoresSafeArea()

            // Close button
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.white)
                    .shadow(radius: 4)
            }
            .buttonStyle(.plain)
            .padding(20)

            // ETA pill at bottom
            VStack {
                Spacer()
                if let mins = job.minsAway {
                    HStack(spacing: 8) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("\(mins) min\(mins == 1 ? "" : "s") away · \(job.proName)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
                } else {
                    Text("\(job.proName) is on the way")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
            }
        }
        .task { await loadRoute() }
    }

    // MARK: – Annotations

    private struct MapPin: Identifiable {
        enum Kind { case pro, user }
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let kind: Kind
        let label: String
    }

    private var annotations: [MapPin] {
        var pins: [MapPin] = []
        if let c = proCoord  { pins.append(.init(coordinate: c, kind: .pro,  label: job.proName)) }
        if let c = userCoord { pins.append(.init(coordinate: c, kind: .user, label: "You")) }
        return pins
    }

    @ViewBuilder
    private func annotationView(for pin: MapPin) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(pin.kind == .pro ? Color.green : Color.blue)
                    .frame(width: 36, height: 36)
                Image(systemName: pin.kind == .pro ? "wrench.fill" : "house.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(pin.label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
        }
    }

    // MARK: – Route overlay

    @ViewBuilder
    private var routeOverlay: some View {
        if let route {
            RoutePolylineView(polyline: route.polyline)
        }
    }

    // MARK: – Route loading

    private func loadRoute() async {
        guard let proC = proCoord, let userC = userCoord else {
            // No coords — just centre on user location
            if let userC = userCoord {
                region = MKCoordinateRegion(center: userC,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
            }
            return
        }

        // Centre map between both points
        let midLat  = (proC.latitude  + userC.latitude)  / 2
        let midLng  = (proC.longitude + userC.longitude) / 2
        let spanLat = abs(proC.latitude  - userC.latitude)  * 1.5
        let spanLng = abs(proC.longitude - userC.longitude) * 1.5
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: midLat, longitude: midLng),
            span: MKCoordinateSpan(
                latitudeDelta:  max(spanLat, 0.02),
                longitudeDelta: max(spanLng, 0.02)
            )
        )

        // Request driving directions
        let req        = MKDirections.Request()
        req.source      = MKMapItem(placemark: MKPlacemark(coordinate: proC))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: userC))
        req.transportType = .automobile

        let dirs = MKDirections(request: req)
        if let resp = try? await dirs.calculate() {
            route = resp.routes.first
        }
    }
}

// MARK: – Route polyline overlay (UIKit bridge)

private struct RoutePolylineView: UIViewRepresentable {
    let polyline: MKPolyline

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.isUserInteractionEnabled = false
        mv.delegate = context.coordinator
        mv.addOverlay(polyline)
        return mv
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = UIColor.systemGreen
                r.lineWidth   = 4
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
