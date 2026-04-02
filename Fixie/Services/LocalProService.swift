// Services/LocalProService.swift
// MapKit-based local contractor discovery near the user's live GPS coordinates.
// Requires a valid location fix — throws LocationUnavailable if GPS has no fix yet.
import MapKit

// MARK: – Result type

struct LocalPro: Identifiable, Sendable {
    let id: UUID
    let name: String
    let phoneNumber: String?
    let address: String
    let coordinate: CLLocationCoordinate2D
    let distanceMetres: Double?

    var mapsURL: URL? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "maps://?q=\(q)&ll=\(coordinate.latitude),\(coordinate.longitude)")
    }
}

// MARK: – Service

final class LocalProService: Sendable {

    static let shared = LocalProService()
    private init() {}

    /// Search for repair professionals near the user's current GPS location.
    ///
    /// - Parameters:
    ///   - category:    RepairCategory used to derive the default query when no
    ///                  `customQuery` is supplied.
    ///   - customQuery: Diagnosis-specific MapKit query string (e.g.
    ///                  "Licensed Plumber Water Heater Repair"). When provided it
    ///                  overrides the generic category default, producing more
    ///                  targeted results for the actual diagnosed device.
    ///   - coordinate:  Explicit override for the search centre; defaults to the
    ///                  user's live GPS fix from LocationService.
    ///
    /// Throws `LocalProServiceError.locationUnavailable` if no location fix exists.
    func searchPros(for category: RepairCategory,
                    customQuery: String? = nil,
                    near coordinate: CLLocationCoordinate2D? = nil) async throws -> [LocalPro] {
        // Resolve the search centre: explicit arg → live GPS → error
        let centre: CLLocationCoordinate2D
        if let coord = coordinate, CLLocationCoordinate2DIsValid(coord) {
            centre = coord
        } else if let loc = await MainActor.run(body: { LocationService.shared.currentLocation }),
                  CLLocationCoordinate2DIsValid(loc.coordinate) {
            centre = loc.coordinate
        } else {
            throw LocalProServiceError.locationUnavailable
        }

        let request = MKLocalSearch.Request()
        // Use the caller-supplied custom query when available; fall back to the
        // generic per-category default otherwise.
        request.naturalLanguageQuery = customQuery ?? defaultQuery(for: category)
        request.region = MKCoordinateRegion(
            center: centre,
            latitudinalMeters:  24_140,   // ~15-mile radius
            longitudinalMeters: 24_140
        )

        // MKEErrorDomain / MKError code 4 = placemarkNotFound — no results for this
        // query in this region. Treat as empty (not a real error) so RescueCard shows
        // "No local pros found" instead of an error banner.
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            if (error as NSError).code == 4 { return [] }
            throw error
        }

        let centreLoc = CLLocation(latitude: centre.latitude, longitude: centre.longitude)

        return response.mapItems.map { item in
            LocalPro(
                id:             UUID(),
                name:           item.name ?? "Unknown",
                phoneNumber:    item.phoneNumber,
                address:        item.placemark.formattedAddress,
                coordinate:     item.placemark.coordinate,
                distanceMetres: item.placemark.location?.distance(from: centreLoc)
            )
        }
    }

    /// Generic per-category MapKit query used when no specific device query is available.
    func defaultQuery(for category: RepairCategory) -> String {
        switch category {
        case .majorAppliances:    return "Appliance Repair Service"
        case .homeSystems:        return "Licensed Plumber HVAC Repair"
        case .techAndElectronics: return "Certified Electronics Repair"
        case .yardAndTools:       return "Lawn Equipment Power Tool Repair"
        case .automotive:         return "Auto Mechanic Car Repair"
        case .smallHousehold:     return "Small Appliance Repair"
        case .homeAndStructure:   return "General Contractor Handyman"
        case .itAndNetworking:    return "IT Support Computer Repair"
        }
    }

    // MARK: – Errors

    enum LocalProServiceError: LocalizedError {
        case locationUnavailable

        var errorDescription: String? {
            "Location unavailable. Enable location access in Settings to find nearby pros."
        }
    }
}

// MARK: – Placemark helper

private extension MKPlacemark {
    var formattedAddress: String {
        [subThoroughfare, thoroughfare, locality, administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
