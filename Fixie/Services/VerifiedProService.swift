// Services/VerifiedProService.swift
// Fetches Tier-1 "Fixie Verified" contractors from the Firestore `contractors`
// collection. Only returns pros whose serviceRadiusKm covers the user's GPS fix.
//
// Firestore schema (contractors/{proId}):
//   { name, phone?, email?, address, latitude, longitude,
//     serviceRadiusKm, categories: [String], status: "active"|"inactive" }
//
// Firestore rules required (add to firestore.rules):
//   match /contractors/{proId} {
//     allow read: if true;   // public — no auth required for browse
//   }
//   match /leads/{leadId} {
//     allow create: if request.auth != null
//                   && request.resource.data.userId == request.auth.uid;
//   }

import CoreLocation
import FirebaseFirestore

final class VerifiedProService: Sendable {

    static let shared = VerifiedProService()
    private init() {}

    /// Fetches active Fixie-verified contractors for the given category,
    /// filtered to those whose service radius covers the user's live GPS fix.
    ///
    /// Returns an empty array (rather than throwing) when no location fix is
    /// available — verified pros are a best-effort overlay on top of MapKit results.
    func fetchPros(for category: RepairCategory,
                   near coordinate: CLLocationCoordinate2D? = nil) async -> [VerifiedPro] {
        // Resolve search centre
        let centre: CLLocationCoordinate2D
        if let coord = coordinate, CLLocationCoordinate2DIsValid(coord) {
            centre = coord
        } else if let loc = await MainActor.run(body: { LocationService.shared.currentLocation }),
                  CLLocationCoordinate2DIsValid(loc.coordinate) {
            centre = loc.coordinate
        } else {
            return []
        }

        let centreLoc = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        let db = Firestore.firestore()

        // Single-field query only — Firestore auto-indexes array-contains queries.
        // Compound queries (status + categories) require a manual composite index
        // that may not be deployed yet; filtering status client-side avoids that
        // dependency while the contractor collection stays small.
        guard let snapshot = try? await db
            .collection("contractors")
            .whereField("categories", arrayContains: category.firestoreKey)
            .getDocuments()
        else { return [] }

        return snapshot.documents.compactMap { doc -> VerifiedPro? in
            let data = doc.data()

            // ── Status filter ─────────────────────────────────────────────
            guard (data["status"] as? String) == "active" else { return nil }

            // ── Name ──────────────────────────────────────────────────────
            // Web portal writes "businessName"; canonical schema uses "name".
            guard let name = (data["businessName"] as? String)
                          ?? (data["name"]         as? String)
            else { return nil }

            // ── Categories ────────────────────────────────────────────────
            // Web portal writes "serviceCategories"; fallback to "categories".
            guard let cats = (data["serviceCategories"] as? [String])
                          ?? (data["categories"]        as? [String])
            else { return nil }

            // ── Service radius ────────────────────────────────────────────
            // Canonical: "serviceRadiusKm" (Double, km).
            // Web portal: "serviceRadius" (Int64 or Double, miles) → convert.
            let radKm: Double
            if let rkm = data["serviceRadiusKm"] as? Double {
                radKm = rkm
            } else if let rm = data["serviceRadius"] as? Double {
                radKm = rm * 1.60934
            } else if let rm = data["serviceRadius"] as? Int64 {
                radKm = Double(rm) * 1.60934
            } else {
                radKm = 40.0    // fallback ≈ 25 mi when no radius is stored
            }

            // ── Coordinates & distance ────────────────────────────────────
            // Web portal may not store lat/lng yet. When absent, include the
            // contractor without a distance check (shown without "X mi away").
            let lat    = data["latitude"]  as? Double
            let lng    = data["longitude"] as? Double
            var distKm: Double? = nil

            if let lat, let lng {
                distKm = CLLocation(latitude: lat, longitude: lng)
                    .distance(from: centreLoc) / 1_000.0
                guard distKm! <= radKm else { return nil }
            }

            // ── Address ───────────────────────────────────────────────────
            // Web portal stores address parts separately; compose a readable string.
            let address: String = {
                let parts = [data["address"] as? String,
                             data["city"]    as? String,
                             data["state"]   as? String]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                return parts.isEmpty
                    ? (data["serviceZip"] as? String ?? "")
                    : parts.joined(separator: ", ")
            }()

            // ── Rating ────────────────────────────────────────────────────
            // Cloud Functions write Int64 → use NSNumber bridging
            let avgRating   = (data["averageRating"] as? NSNumber)?.doubleValue ?? 0
            let reviewCount = (data["reviewCount"]   as? NSNumber)?.intValue   ?? 0

            return VerifiedPro(
                id:              doc.documentID,
                name:            name,
                phone:           data["phone"]   as? String,
                email:           data["email"]   as? String,
                address:         address,
                latitude:        lat ?? 0,
                longitude:       lng ?? 0,
                serviceRadiusKm: radKm,
                categories:      cats,
                distanceKm:      distKm,
                logoUrl:         data["logoUrl"] as? String ?? "",
                averageRating:   avgRating,
                reviewCount:     reviewCount
            )
        }
        .sorted { ($0.distanceKm ?? .infinity) < ($1.distanceKm ?? .infinity) }
    }
}
