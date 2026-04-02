// Models/VerifiedPro.swift
// Firestore contractor record from the `contractors` collection.
// Stored as lat/lng Doubles to avoid CLLocationCoordinate2D Sendable issues.
import Foundation

struct VerifiedPro: Identifiable, Sendable {
    let id:              String          // Firestore document ID
    let name:            String
    let phone:           String?
    let email:           String?
    let address:         String
    let latitude:        Double
    let longitude:       Double
    let serviceRadiusKm: Double          // how far this pro will travel
    let categories:      [String]        // RepairCategory.rawValue strings
    let distanceKm:      Double?         // distance from user's GPS fix
    let logoUrl:         String          // business logo Firebase Storage URL
    let averageRating:   Double          // aggregated by Cloud Function
    let reviewCount:     Int             // total reviews written

    /// Privacy-masked email shown in the UI (e.g. "jo••••@gmail.com").
    var maskedEmail: String? {
        guard let email, !email.isEmpty else { return nil }
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return email }
        let user   = String(parts[0])
        let domain = String(parts[1])
        guard user.count > 2 else { return "••@\(domain)" }
        let visible = String(user.prefix(2))
        let dots    = String(repeating: "•", count: min(user.count - 2, 6))
        return "\(visible)\(dots)@\(domain)"
    }

    /// Apple Maps deep-link for this contractor's address.
    var mapsURL: URL? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "maps://?q=\(q)&ll=\(latitude),\(longitude)")
    }
}
