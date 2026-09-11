// Models/ActiveServiceLead.swift
// Represents a lead that a Fixie Verified Pro has claimed.
// Persisted to UserDefaults so the "Active Service" tile survives app restarts
// and the Firestore listener can be re-subscribed after a cold launch.

import Foundation

struct ActiveServiceLead: Identifiable, Codable, Equatable, Sendable {
    var id: String { leadId }

    let leadId:          String
    let proId:           String      // Firestore contractors/{proId} — for credential lookup
    let proBusinessName: String
    let proName:         String
    let proPhone:        String?
    let proStatus:       String      // "active" → show verified badge
    let deviceModel:     String
    let symptom:         String
    let category:        String
    var logoUrl:         String = "" // contractor's business logo (Firebase Storage URL)
    var thumbnailUrl:    String = "" // first imageUrls[] from the lead — repair photo
    var proLatitude:     Double = 0  // contractor's registered latitude
    var proLongitude:    Double = 0  // contractor's registered longitude
    var proAddress:      String = "" // e.g. "310 Daniel Webster Hwy, Nashua, NH"
    var statusRaw:         String = "claimed" // Firestore status field — drives ServiceJob.Status
    var assignedTechName:  String = ""        // specific technician dispatched (may differ from owner)
    var invoiceUrl:        String = ""        // direct URL to the invoice page (set when invoiceCreated==true)
    var reschedulePending: Bool   = false     // homeowner submitted reschedule, awaiting tech confirmation
    var estimatedArrival:  Date?  = nil // set by contractor; nil = unknown ETA
    var scheduledTime:   Date? = nil  // homeowner-requested scheduled time (nil = ASAP)

    // MARK: – UserDefaults persistence

    private static let claimedKey = "com.fixie.activeServiceLead"
    private static let pendingKey = "com.fixie.pendingLead"   // leadId|proName CSV

    /// Loads all locally-cached active service leads.
    /// Handles migration from the old single-lead format automatically.
    static func loadAllLocal() -> [ActiveServiceLead] {
        guard let data = UserDefaults.standard.data(forKey: claimedKey) else { return [] }
        if let arr = try? JSONDecoder().decode([ActiveServiceLead].self, from: data) { return arr }
        // Migration: old format was a single object
        if let single = try? JSONDecoder().decode(ActiveServiceLead.self, from: data) { return [single] }
        return []
    }

    static func saveAllLocal(_ leads: [ActiveServiceLead]) {
        if let data = try? JSONEncoder().encode(leads) {
            UserDefaults.standard.set(data, forKey: claimedKey)
        }
    }

    static func clearLocal() {
        UserDefaults.standard.removeObject(forKey: claimedKey)
    }

    // MARK: – Pending lead (submitted, not yet claimed)

    /// Saves leadId + proName so HomeViewModel can restart the listener after a cold launch.
    static func savePendingLead(leadId: String, proName: String) {
        UserDefaults.standard.set("\(leadId)|\(proName)", forKey: pendingKey)
    }

    /// Returns `(leadId, proName)` if a pending (submitted but not claimed) lead exists.
    static func loadPendingLead() -> (leadId: String, proName: String)? {
        guard let raw = UserDefaults.standard.string(forKey: pendingKey) else { return nil }
        let parts = raw.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1...].joined(separator: "|"))
    }

    static func clearPendingLead() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }
}
