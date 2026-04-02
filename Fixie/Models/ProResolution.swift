// Models/ProResolution.swift
// Carries the pro's resolution data from the Firestore listener to the UI.
// Conforms to Identifiable (used as .fullScreenCover item) and Sendable
// (crosses actor boundaries in the listener → ViewModel pipeline).

struct ProResolution: Identifiable, Equatable, Sendable {
    var id: String { leadId }
    let leadId:          String
    let proId:           String     // contractors/{proId} — needed to submit review
    let proName:         String
    let proBusinessName: String
    let deviceModel:     String
    let resolutionNotes: String
}
