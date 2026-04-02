// Models/ActiveSession.swift
// Snapshot types for Save & Resume — stored as JSON in Firestore current_sessions/{userId}.
import Foundation

// MARK: – Repair Guide Snapshot (fully Codable, reconstructs a RepairGuide)

struct RepairGuideSnapshot: Codable, Hashable, Sendable {

    let guideId:             String
    let categoryRaw:         String
    let title:               String
    let brand:               String
    let model:               String
    let symptom:             String
    let possibleFailures:    [String]
    let verificationStep:    String
    let confidenceScore:     Double
    let isSafeToProcceed:    Bool
    let youtubeSearchQuery:  String
    let steps:               [StepSnap]
    let parts:               [PartSnap]

    struct StepSnap: Codable, Hashable, Sendable {
        let order:              Int
        let title:              String
        let detail:             String
        let arAnchorDescription: String?
        let toolsRequired:      [String]
        let warningNote:        String?
    }

    struct PartSnap: Codable, Hashable, Sendable {
        let name:           String
        let partNumber:     String
        let estimatedPrice: Double
    }

    // MARK: – Init from live guide

    init(from guide: RepairGuide) {
        guideId             = guide.id.uuidString
        categoryRaw         = guide.session.category.rawValue
        title               = guide.session.title
        brand               = guide.diagnosis?.brand               ?? ""
        model               = guide.diagnosis?.model               ?? ""
        symptom             = guide.diagnosis?.symptom             ?? guide.session.title
        possibleFailures    = guide.diagnosis?.possibleFailures    ?? []
        verificationStep    = guide.diagnosis?.verificationStep    ?? ""
        confidenceScore     = guide.diagnosis?.confidenceScore     ?? 0
        isSafeToProcceed    = guide.diagnosis?.isSafeToProcceed    ?? true
        youtubeSearchQuery  = guide.diagnosis?.youtubeSearchQuery  ??
            DiagnosisResult.buildQuery(
                brand: guide.diagnosis?.brand ?? "",
                model: guide.diagnosis?.model ?? "",
                symptom: guide.diagnosis?.symptom ?? guide.session.title
            )
        steps = guide.steps.map { s in
            StepSnap(order: s.order, title: s.title, detail: s.detail,
                     arAnchorDescription: s.arAnchorDescription,
                     toolsRequired: s.toolsRequired, warningNote: s.warningNote)
        }
        parts = guide.requiredParts.map { p in
            PartSnap(name: p.name, partNumber: p.partNumber, estimatedPrice: p.estimatedPrice)
        }
    }

    // MARK: – Reconstruct live guide

    func toRepairGuide() -> RepairGuide {
        let session = RepairSession(
            category: RepairCategory(rawValue: categoryRaw) ?? .majorAppliances,
            title:    title
        )
        let resolvedQuery = youtubeSearchQuery.isEmpty
            ? DiagnosisResult.buildQuery(brand: brand, model: model, symptom: symptom)
            : youtubeSearchQuery
        let diagnosis = DiagnosisResult(
            brand:              brand,
            model:              model,
            symptom:            symptom,
            possibleFailures:   possibleFailures,
            verificationStep:   verificationStep,
            confidenceScore:    confidenceScore,
            isSafeToProcceed:   isSafeToProcceed,
            youtubeSearchQuery:        resolvedQuery,
            needsModelVerification:    false,
            suggestedModel:            nil
        )
        let repairSteps = steps.map { s in
            RepairStep(order: s.order, title: s.title, detail: s.detail,
                       arAnchorDescription: s.arAnchorDescription,
                       toolsRequired: s.toolsRequired, warningNote: s.warningNote)
        }
        let repairParts = parts.map { p in
            RepairPart(name: p.name, partNumber: p.partNumber, estimatedPrice: p.estimatedPrice)
        }
        return RepairGuide(
            id:       UUID(uuidString: guideId) ?? UUID(),
            session:  session,
            diagnosis: diagnosis,
            steps:    repairSteps,
            requiredParts: repairParts
        )
    }
}

// MARK: – Saved chat message (Codable snapshot of ChatMessage for persistence)

struct SavedChatMessage: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

// MARK: – Active Session (Firestore document model)

struct ActiveSession: Identifiable, Hashable, Codable, Sendable {
    /// Unique per repair — uses the guide's UUID so multiple sessions co-exist.
    var id: String { snapshot.guideId }

    static func == (lhs: ActiveSession, rhs: ActiveSession) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var userId:           String
    var currentStepIndex: Int
    var status:           String          // "in_progress" | "paused"
    var pauseReason:      String?         // "missing_tools" | "stepped_away"
    var missingTools:     [String]
    var deviceModel:      String          // for display on Home screen
    var symptom:          String
    var categoryRaw:      String
    var stepsTotal:       Int
    var snapshot:         RepairGuideSnapshot
    var updatedAt:        Date
    var imagePath:        String?         // Caches-dir JPEG path, restored on resume
    var savedMessages:    [SavedChatMessage]? = nil // full chat history; nil in legacy sessions
    var pendingLeadId:    String?         = nil     // set when a pro lead was submitted for this repair

    /// Reconstructs a live RepairGuide for navigation.
    var guide: RepairGuide { snapshot.toRepairGuide() }

    /// Human-readable progress label, e.g. "Step 3 of 7"
    var progressLabel: String { "Step \(currentStepIndex + 1) of \(stepsTotal)" }
    var displayName:   String { deviceModel.isEmpty ? symptom : deviceModel }

    // MARK: – UserDefaults local persistence (works before Firebase SDK is installed)

    private static let udKey = "com.fixie.activeSession"

    /// Loads all locally-saved repair sessions.
    /// Automatically migrates from the old single-session format.
    static func loadAllLocal() -> [ActiveSession] {
        guard let data = UserDefaults.standard.data(forKey: udKey) else { return [] }
        if let arr = try? JSONDecoder().decode([ActiveSession].self, from: data) { return arr }
        // Migration: old format stored a single ActiveSession object
        if let single = try? JSONDecoder().decode(ActiveSession.self, from: data) { return [single] }
        return []
    }

    /// Backward-compat: returns the first paused session (used by code that only expects one).
    static func loadLocal() -> ActiveSession? { loadAllLocal().first }

    /// Upserts this session into the local store (keyed by guide UUID).
    func saveLocal() {
        var all = ActiveSession.loadAllLocal()
        if let idx = all.firstIndex(where: { $0.id == self.id }) {
            all[idx] = self
        } else {
            all.append(self)
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: ActiveSession.udKey)
        }
    }

    /// Removes only this session from the local store.
    func removeLocal() {
        var all = ActiveSession.loadAllLocal()
        all.removeAll { $0.id == self.id }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: ActiveSession.udKey)
        }
    }

    /// Removes a specific session by its guide UUID (used when RepairChatViewModel finishes).
    static func removeLocal(guideId: String) {
        var all = loadAllLocal()
        all.removeAll { $0.id == guideId }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    /// Clears ALL sessions — used only on sign-out or account deletion.
    static func clearLocal() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }
}
