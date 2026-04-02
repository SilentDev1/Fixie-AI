// Models/RepairHistoryEntry.swift
import SwiftData
import Foundation

@Model
final class RepairHistoryEntry {
    var id: UUID
    var categoryRaw: String          // RepairCategory.rawValue
    var title: String
    var subtitle: String             // "Brand Model"
    var symptom: String
    var date: Date
    var stepsTotal: Int
    var stepsCompleted: Int
    @Attribute(.externalStorage) var thumbnailData: Data?
    var proName:         String?     // Set when a contractor fixed this repair
    var proPhone:        String?     // Optional phone of the contractor
    var proBusinessName: String = "" // Contractor's business name
    var proLogoUrl:      String = "" // Contractor's logo (Firebase Storage URL)
    var resolutionNotes: String = "" // What the contractor did to fix it
    var leadId:          String = "" // Firestore lead doc ID — used to prevent duplicate history entries
    var thumbnailUrl:    String = "" // Remote image URL for contractor-resolved repairs (lead imageUrls[0])
    var proId:           String = "" // contractors/{proId} — for submitting a review
    var hasReviewed:     Bool   = false // true once user submits a rating for this repair

    init(
        id: UUID = UUID(),
        categoryRaw: String,
        title: String,
        subtitle: String,
        symptom: String,
        date: Date = .now,
        stepsTotal: Int,
        stepsCompleted: Int,
        thumbnailData:   Data?   = nil,
        proName:         String? = nil,
        proPhone:        String? = nil,
        proBusinessName: String  = "",
        proLogoUrl:      String  = "",
        resolutionNotes: String  = "",
        leadId:          String  = "",
        thumbnailUrl:    String  = "",
        proId:           String  = "",
        hasReviewed:     Bool    = false
    ) {
        self.id              = id
        self.categoryRaw     = categoryRaw
        self.title           = title
        self.subtitle        = subtitle
        self.symptom         = symptom
        self.date            = date
        self.stepsTotal      = stepsTotal
        self.stepsCompleted  = stepsCompleted
        self.thumbnailData   = thumbnailData
        self.proName         = proName
        self.proPhone        = proPhone
        self.proBusinessName = proBusinessName
        self.proLogoUrl      = proLogoUrl
        self.resolutionNotes = resolutionNotes
        self.leadId          = leadId
        self.thumbnailUrl    = thumbnailUrl
        self.proId           = proId
        self.hasReviewed     = hasReviewed
    }

    // MARK: – Computed

    var category: RepairCategory {
        RepairCategory(rawValue: categoryRaw) ?? .majorAppliances
    }

    var completionPercent: Int {
        guard stepsTotal > 0 else { return 0 }
        return Int(Double(stepsCompleted) / Double(stepsTotal) * 100)
    }

    var isCompleted: Bool {
        stepsCompleted >= stepsTotal && stepsTotal > 0
    }
}
