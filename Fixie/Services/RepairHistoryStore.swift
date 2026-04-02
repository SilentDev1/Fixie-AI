// Services/RepairHistoryStore.swift
import SwiftData
import SwiftUI

@Observable @MainActor
final class RepairHistoryStore {

    static let shared = RepairHistoryStore()

    /// Expose the container so FixieApp can pass the same one to the SwiftUI environment.
    static let sharedContainer: ModelContainer = {
        do {
            return try ModelContainer(for: RepairHistoryEntry.self)
        } catch {
            fatalError("RepairHistoryStore: failed to create ModelContainer — \(error)")
        }
    }()

    private(set) var entries: [RepairHistoryEntry] = []
    private let context: ModelContext

    private init() {
        context = ModelContext(RepairHistoryStore.sharedContainer)
        loadEntries()
    }

    // MARK: – CRUD

    func loadEntries() {
        let descriptor = FetchDescriptor<RepairHistoryEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        entries = (try? context.fetch(descriptor)) ?? []
    }

    func save(guide: RepairGuide, capturedImage: UIImage?, stepsCompleted: Int,
              videoData: Data? = nil, proName: String? = nil, proPhone: String? = nil) {
        let thumbData = capturedImage?.jpegData(compressionQuality: 0.6)
        let d = guide.diagnosis
        let subtitle = [d?.brand ?? "", d?.model ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let entry = RepairHistoryEntry(
            categoryRaw:    guide.session.category.rawValue,
            title:          guide.session.title,
            subtitle:       subtitle,
            symptom:        d?.symptom ?? guide.session.title,
            stepsTotal:     guide.steps.count,
            stepsCompleted: stepsCompleted,
            thumbnailData:  thumbData,
            proName:        proName,
            proPhone:       proPhone
        )
        context.insert(entry)
        try? context.save()
        loadEntries()

        // Cloud sync — fires and forgets; errors are captured in FirebaseService.lastSyncError
        Task {
            await FirebaseService.shared.syncRepair(
                entry,
                thumbnailData: thumbData,
                videoData:     videoData
            )
        }
    }

    /// Returns true if a history entry already exists for the given Firestore lead doc ID.
    func hasEntry(for leadId: String) -> Bool {
        guard !leadId.isEmpty else { return false }
        return entries.contains { $0.leadId == leadId }
    }

    /// Creates a history entry from a contractor-resolved lead.
    /// Skips silently if an entry for this leadId already exists (deduplication).
    func saveFromResolvedLead(
        leadId:          String,
        categoryRaw:     String,
        deviceModel:     String,
        symptom:         String,
        proName:         String?,
        proPhone:        String?,
        proBusinessName: String,
        proLogoUrl:      String  = "",
        resolutionNotes: String,
        resolvedAt:      Date,
        thumbnailUrl:    String  = "",
        proId:           String  = ""
    ) {
        guard !hasEntry(for: leadId) else { return }   // already saved — skip
        let title = deviceModel.isEmpty ? "Service Repair" : deviceModel
        let entry = RepairHistoryEntry(
            categoryRaw:     categoryRaw,
            title:           title,
            subtitle:        proBusinessName,
            symptom:         symptom,
            date:            resolvedAt,
            stepsTotal:      1,
            stepsCompleted:  1,    // contractor completed the repair
            proName:         proName,
            proPhone:        proPhone,
            proBusinessName: proBusinessName,
            proLogoUrl:      proLogoUrl,
            resolutionNotes: resolutionNotes,
            leadId:          leadId,
            thumbnailUrl:    thumbnailUrl,
            proId:           proId
        )
        context.insert(entry)
        try? context.save()
        loadEntries()
    }

    func delete(entry: RepairHistoryEntry) {
        context.delete(entry)
        try? context.save()
        loadEntries()
    }
}
