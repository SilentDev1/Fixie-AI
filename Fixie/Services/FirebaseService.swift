// Services/FirebaseService.swift
// Cloud persistence layer — Firestore history sync + Firebase Storage for media.
//
// ACTIVATION (one-time setup):
//  1. Xcode → File → Add Package Dependencies → https://github.com/firebase/firebase-ios-sdk
//     Required products: FirebaseAuth, FirebaseFirestore, FirebaseStorage, FirebaseAppCheck
//  2. FirebaseApp.configure() is already called in FixieApp.swift.
//  3. Firebase Console → Auth → Sign-in methods → enable "Sign in with Apple".
//  4. Firebase Console → Storage → Create bucket (production rules, or start in test mode).
//
// FIRESTORE DATA MODEL (web-compatible for Next.js portal):
//  users/{userId}:
//    { displayName, email, createdAt }
//  users/{userId}/projects/{projectId}:
//    { id, userId, category, title, subtitle, symptom, stepsTotal, stepsCompleted,
//      isCompleted, date, thumbnailURL, videoURL, createdAt }
//
// Swift 6 compliance: all Firestore/Storage operations are async/await, @MainActor-isolated.

import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// MARK: – Cloud project document (Firestore-compatible, web-readable)

struct CloudRepairProject: Codable, Sendable {
    var id:             String
    var userId:         String
    var category:       String      // RepairCategory.rawValue — web portal groups on this
    var title:          String
    var subtitle:       String
    var symptom:        String
    var stepsTotal:     Int
    var stepsCompleted: Int
    var isCompleted:    Bool
    var date:           Date
    var thumbnailURL:   String?     // Firebase Storage download URL
    var videoURL:       String?     // Firebase Storage download URL
    var createdAt:      Date

    init(from entry: RepairHistoryEntry, userId: String) {
        self.id             = entry.id.uuidString
        self.userId         = userId
        self.category       = entry.categoryRaw
        self.title          = entry.title
        self.subtitle       = entry.subtitle
        self.symptom        = entry.symptom
        self.stepsTotal     = entry.stepsTotal
        self.stepsCompleted = entry.stepsCompleted
        self.isCompleted    = entry.isCompleted
        self.date           = entry.date
        self.thumbnailURL   = nil
        self.videoURL       = nil
        self.createdAt      = Date()
    }
}

// Firestore decoding without FirebaseFirestoreSwift dependency
extension CloudRepairProject {
    static func fromFirestore(_ data: [String: Any]) -> CloudRepairProject? {
        guard
            let id             = data["id"]             as? String,
            let userId         = data["userId"]         as? String,
            let category       = data["category"]       as? String,
            let title          = data["title"]          as? String,
            let subtitle       = data["subtitle"]       as? String,
            let symptom        = data["symptom"]        as? String,
            let stepsTotal     = data["stepsTotal"]     as? Int,
            let stepsCompleted = data["stepsCompleted"] as? Int,
            let dateTS         = data["date"]           as? Timestamp,
            let createdAtTS    = data["createdAt"]      as? Timestamp
        else { return nil }

        var project = CloudRepairProject(
            from: RepairHistoryEntry(
                categoryRaw: category, title: title, subtitle: subtitle,
                symptom: symptom, date: dateTS.dateValue(),
                stepsTotal: stepsTotal, stepsCompleted: stepsCompleted
            ),
            userId: userId
        )
        project.id          = id
        project.thumbnailURL = data["thumbnailURL"] as? String
        project.videoURL     = data["videoURL"]     as? String
        project.createdAt    = createdAtTS.dateValue()
        return project
    }
}

// MARK: – FirebaseService

@Observable @MainActor
final class FirebaseService {

    static let shared = FirebaseService()
    private init() {}

    var isSyncing = false
    var lastSyncError: String?

    // MARK: – Write user profile to Firestore
    //
    // Firestore path: users/{uid}
    // Fields: uid, fullName, email, role, createdAt
    //
    // New user  → full document with role:"customer" + server timestamp.
    // Returning → merge only identity fields (fullName, email) so a pro's role is never
    //             overwritten back to "customer" and createdAt is never clobbered.

    func writeUserProfile(_ user: FixieUser, isNewUser: Bool = false) async {
        let db  = Firestore.firestore()
        let ref = db.collection("users").document(user.id)
        let zip = LocationService.shared.postalCode  // "" until first GPS fix — fine to write

        if isNewUser {
            let profile: [String: Any] = [
                "uid":             user.id,
                "fullName":        user.displayName,
                "email":           user.email ?? "",
                "role":            "customer",
                "zipCode":         zip,
                "activeProjectID": "",
                "createdAt":       FieldValue.serverTimestamp()
            ]
            try? await ref.setData(profile)          // overwrite — doc doesn't exist yet
        } else {
            // Merge only fields that can legitimately change after signup.
            // Omits role (never demote a pro back to customer) and createdAt.
            var updates: [String: Any] = [
                "uid":   user.id,
                "email": user.email ?? ""
            ]
            // Never overwrite a real name in Firestore with the "Fixie User" fallback.
            let name = user.displayName
            if !name.isEmpty && name != "Fixie User" {
                updates["fullName"] = name
            }
            if !user.phoneNumber.isEmpty { updates["phoneNumber"] = user.phoneNumber }
            if !user.photoURL.isEmpty    { updates["photoURL"]    = user.photoURL    }
            if !zip.isEmpty { updates["zipCode"] = zip }
            try? await ref.setData(updates, merge: true)
        }

        // Flush any FCM token that arrived before auth was ready
        if let pending = UserDefaults.standard.string(forKey: "pendingFCMToken") {
            try? await ref.setData(["fcmToken": pending], merge: true)
            UserDefaults.standard.removeObject(forKey: "pendingFCMToken")
        }
    }

    // MARK: – Update user contact info + optional avatar

    func updateUserProfile(
        name:       String,
        phone:      String,
        address:    String    = "",
        city:       String    = "",
        state:      String    = "",
        zip:        String    = "",
        avatarData: Data?     = nil
    ) async throws {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let db  = Firestore.firestore()
        let ref = db.collection("users").document(userId)
        var updates: [String: Any] = [:]

        if !name.isEmpty && name != "Fixie User" { updates["fullName"]    = name  }
        updates["phoneNumber"] = phone
        updates["address"]     = address
        updates["city"]        = city
        updates["state"]       = state
        updates["zip"]         = zip

        // Upload avatar to Storage if provided
        if let jpeg = avatarData {
            let path    = "users/\(userId)/profile/avatar.jpg"
            let storRef = Storage.storage().reference(withPath: path)
            var meta    = StorageMetadata()
            meta.contentType = "image/jpeg"
            do {
                try await storRef.putDataAsync(jpeg, metadata: meta)
                let url = try await storRef.downloadURL()
                updates["photoURL"] = url.absoluteString
                print("[Fixie] ✅ Avatar uploaded: \(url.absoluteString)")
            } catch {
                print("[Fixie] ⚠️ Avatar upload failed: \(error.localizedDescription)")
            }
        }

        guard !updates.isEmpty else { return }
        try await ref.setData(updates, merge: true)

        // Immediately reflect changes in AuthService without waiting for the Firestore listener
        if var user = AuthService.shared.currentUser {
            if let n = updates["fullName"]    as? String { user.displayName  = n }
            if let p = updates["phoneNumber"] as? String { user.phoneNumber  = p }
            if let u = updates["photoURL"]    as? String { user.photoURL     = u }
            if let a = updates["address"]     as? String { user.address      = a }
            if let c = updates["city"]        as? String { user.city         = c }
            if let s = updates["state"]       as? String { user.state        = s }
            if let z = updates["zip"]         as? String { user.zip          = z }
            AuthService.shared.currentUser = user
            if let encoded = try? JSONEncoder().encode(user) {
                UserDefaults.standard.set(encoded, forKey: "fixieUser")
            }
        }
    }

    // MARK: – Active Project link on user profile
    //
    // Called after a lead is created (sets the docId) and after it is resolved (clears it).
    // Stored in users/{uid}.activeProjectID so the app can resume tracking after cold launch.

    func setActiveProject(_ leadId: String?) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let db  = Firestore.firestore()
        let val: Any = leadId ?? FieldValue.delete()
        try? await db.collection("users").document(userId)
            .setData(["activeProjectID": val], merge: true)
    }

    // MARK: – Sync a local RepairHistoryEntry to Firestore + Storage

    func syncRepair(_ entry: RepairHistoryEntry,
                    thumbnailData: Data? = nil,
                    videoData: Data? = nil) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            var project = CloudRepairProject(from: entry, userId: userId)

            // Delegate media uploads to MediaService (path: users/{uid}/projects/{id}/*)
            if thumbnailData != nil || videoData != nil {
                let result = await MediaService.shared.uploadRepairMedia(
                    projectId: project.id,
                    userId:    userId,
                    photoData: thumbnailData,
                    videoData: videoData
                )
                project.thumbnailURL = result.thumbnailURL
                project.videoURL     = result.videoURL
            }

            try await writeProject(project, userId: userId)
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    // MARK: – Fetch all cloud repairs for the signed-in user

    func fetchRepairs() async throws -> [CloudRepairProject] {
        guard let userId = AuthService.shared.currentUser?.id else { return [] }

        let db = Firestore.firestore()
        let snapshot = try await db
            .collection("users").document(userId)
            .collection("projects")
            .order(by: "date", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { CloudRepairProject.fromFirestore($0.data()) }
    }

    // MARK: – Private helpers

    private func writeProject(_ project: CloudRepairProject, userId: String) async throws {
        let db = Firestore.firestore()
        try await db
            .collection("users").document(userId)
            .collection("projects").document(project.id)
            .setData(projectDictionary(project), merge: true)
    }

    /// Manual Firestore-compatible dictionary (avoids FirebaseFirestoreSwift dependency).
    /// Dates are converted to Timestamp so the web portal can query by date.
    private func projectDictionary(_ p: CloudRepairProject) -> [String: Any] {
        var dict: [String: Any] = [
            "id":             p.id,
            "userId":         p.userId,
            "category":       p.category,
            "title":          p.title,
            "subtitle":       p.subtitle,
            "symptom":        p.symptom,
            "stepsTotal":     p.stepsTotal,
            "stepsCompleted": p.stepsCompleted,
            "isCompleted":    p.isCompleted,
            "date":           Timestamp(date: p.date),
            "createdAt":      Timestamp(date: p.createdAt)
        ]
        if let url = p.thumbnailURL { dict["thumbnailURL"] = url }
        if let url = p.videoURL     { dict["videoURL"]     = url }
        return dict
    }

    // MARK: – Failed Diagnostics (Learning Loop)
    //
    // Firestore path: users/{userId}/failed_diagnostics/{autoId}
    // (Subcollection under the user document — path-enforced security, no
    //  resource.data checks needed, no compound-query permission issues.)
    // Schema: { category, deviceModel, symptom, failedSteps[], timestamp }
    //
    // Used by the "Not the Issue" button to log repairs that completed all steps
    // but didn't fix the device. AIManager queries this before starting a new
    // repair to inject "don't suggest these steps" constraints into the AI prompt.

    func logFailedDiagnostic(
        category:    RepairCategory,
        deviceModel: String,
        symptom:     String,
        failedSteps: [String]
    ) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let db   = Firestore.firestore()
        let data: [String: Any] = [
            "category":    category.rawValue,
            "deviceModel": deviceModel,
            "symptom":     symptom,
            "failedSteps": failedSteps,
            "timestamp":   Timestamp(date: Date())
        ]
        try? await db
            .collection("users").document(userId)
            .collection("failed_diagnostics")
            .addDocument(data: data)
    }

    /// Returns the unique failed-step descriptions logged for a given device+symptom.
    /// Returns an empty array if the user is not signed in or no failures exist.
    func fetchPriorFailures(
        category:    RepairCategory,
        deviceModel: String,
        symptom:     String
    ) async -> [String] {
        guard let userId = AuthService.shared.currentUser?.id else { return [] }
        let db = Firestore.firestore()
        do {
            // Scoped to the user's subcollection — no userId filter needed
            var query = db
                .collection("users").document(userId)
                .collection("failed_diagnostics")
                .whereField("category", isEqualTo: category.rawValue)

            // Only filter by deviceModel when we actually know it
            if !deviceModel.trimmingCharacters(in: .whitespaces).isEmpty {
                query = query.whereField("deviceModel", isEqualTo: deviceModel)
            }

            let snapshot = try await query.getDocuments()
            // Collect all failed steps across documents, deduplicated
            var seen = Set<String>()
            return snapshot.documents.flatMap {
                ($0.data()["failedSteps"] as? [String]) ?? []
            }.filter { seen.insert($0).inserted }
        } catch {
            return []
        }
    }

    // MARK: – Active Repairs (Save & Resume)
    //
    // Firestore path: active_repairs/{userId}
    // Schema: { userId, currentStepIndex, status, pauseReason?, missingTools[],
    //           deviceModel, symptom, categoryRaw, stepsTotal, snapshotJSON, updatedAt }
    //
    // Snapshot is JSON-encoded so the full RepairGuide can be reconstructed on resume
    // without re-calling the AI. snapshotJSON is opaque to the web portal.

    func saveActiveSession(
        guide:         RepairGuide,
        stepIndex:     Int,
        status:        String,           // "in_progress" | "paused"
        pauseReason:   String? = nil,    // "missing_tools" | "stepped_away"
        missingTools:  [String] = [],
        stepsTotal:    Int? = nil,       // pass effectiveStepsTotal; defaults to guide.steps.count
        savedMessages: [SavedChatMessage]? = nil   // full chat history for cross-device resume
    ) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let snapshot = RepairGuideSnapshot(from: guide)
        guard let snapshotData = try? JSONEncoder().encode(snapshot),
              let snapshotJSON = String(data: snapshotData, encoding: .utf8) else { return }

        let effectiveTotal = stepsTotal ?? guide.steps.count
        var data: [String: Any] = [
            "userId":           userId,
            "currentStepIndex": stepIndex,
            "status":           status,
            "missingTools":     missingTools,
            "deviceModel":      guide.diagnosis?.model    ?? "",
            "symptom":          guide.diagnosis?.symptom  ?? guide.session.title,
            "categoryRaw":      guide.session.category.rawValue,
            "stepsTotal":       effectiveTotal,
            "snapshotJSON":     snapshotJSON,
            "updatedAt":        Timestamp(date: Date())
        ]
        if let reason = pauseReason { data["pauseReason"] = reason }
        // Embed chat history in the document so it survives device switches.
        if let msgs = savedMessages,
           let msgsData = try? JSONEncoder().encode(msgs),
           let msgsJSON  = String(data: msgsData, encoding: .utf8) {
            data["savedMessagesJSON"] = msgsJSON
        }

        let db = Firestore.firestore()
        try? await db.collection("active_repairs").document(userId).setData(data)
    }

    func fetchActiveSession() async -> ActiveSession? {
        guard let userId = AuthService.shared.currentUser?.id else { return nil }
        let db = Firestore.firestore()
        guard
            let doc  = try? await db.collection("active_repairs").document(userId).getDocument(),
            doc.exists,
            let data = doc.data()
        else { return nil }

        guard
            let snapshotJSON  = data["snapshotJSON"]     as? String,
            let snapshotData  = snapshotJSON.data(using: .utf8),
            let snapshot      = try? JSONDecoder().decode(RepairGuideSnapshot.self, from: snapshotData),
            let stepIndex     = data["currentStepIndex"] as? Int,
            let status        = data["status"]           as? String,
            let deviceModel   = data["deviceModel"]      as? String,
            let symptom       = data["symptom"]          as? String,
            let categoryRaw   = data["categoryRaw"]      as? String,
            let stepsTotal    = data["stepsTotal"]       as? Int,
            let updatedAtTS   = data["updatedAt"]        as? Timestamp
        else { return nil }

        // Restore chat history if it was embedded in the document (cross-device resume)
        var restoredMessages: [SavedChatMessage]? = nil
        if let msgsJSON = data["savedMessagesJSON"] as? String,
           let msgsData = msgsJSON.data(using: .utf8),
           let msgs = try? JSONDecoder().decode([SavedChatMessage].self, from: msgsData),
           !msgs.isEmpty {
            restoredMessages = msgs
        }

        return ActiveSession(
            userId:           userId,
            currentStepIndex: stepIndex,
            status:           status,
            pauseReason:      data["pauseReason"]  as? String,
            missingTools:     data["missingTools"] as? [String] ?? [],
            deviceModel:      deviceModel,
            symptom:          symptom,
            categoryRaw:      categoryRaw,
            stepsTotal:       stepsTotal,
            snapshot:         snapshot,
            updatedAt:        updatedAtTS.dateValue(),
            savedMessages:    restoredMessages
        )
    }

    func clearActiveSession() async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let db = Firestore.firestore()
        try? await db.collection("active_repairs").document(userId).delete()
    }

    // MARK: – Repair log archive (permanent chat history + AI learning)

    /// Archives a completed repair's full conversation to `users/{userId}/repair_logs/{repairId}`.
    /// Stored permanently so the user can look back and the AI can reference past solutions.
    func archiveRepairLog(guide: RepairGuide, messages: [ChatMessage]) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let db = Firestore.firestore()
        let d  = guide.diagnosis
        let deviceName = [d?.brand, d?.model]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0.lowercased() != "unknown" }
            .joined(separator: " ")

        // Text-only — drop image data and empty lines
        let serialized: [[String: Any]] = messages
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ["role": $0.role == .user ? "user" : "assistant", "text": $0.text] }

        guard !serialized.isEmpty else { return }

        let data: [String: Any] = [
            "repairId":       guide.id.uuidString,
            "deviceName":     deviceName,
            "category":       guide.session.category.firestoreKey,
            "symptom":        d?.symptom ?? guide.session.title,
            "completedAt":    Timestamp(date: Date()),
            "stepsCompleted": guide.steps.count,
            "messages":       serialized
        ]

        try? await db.collection("users").document(userId)
            .collection("repair_logs").document(guide.id.uuidString)
            .setData(data)
        print("[Fixie] 📚 Repair log archived: \(deviceName)")
    }

    /// Fetches recent repair logs for the same category, formatted as a concise AI context block.
    /// Injected into `chatSystemPrompt` so the AI knows what worked (or didn't) before.
    func fetchRepairContext(category: String, deviceName: String = "") async -> String {
        guard let userId = AuthService.shared.currentUser?.id else { return "" }
        let db = Firestore.firestore()

        do {
            let snapshot = try await db.collection("users").document(userId)
                .collection("repair_logs")
                .whereField("category", isEqualTo: category)
                .order(by: "completedAt", descending: true)
                .limit(to: 5)
                .getDocuments()

            guard !snapshot.documents.isEmpty else { return "" }

            let deviceWords = Set(deviceName.lowercased()
                .components(separatedBy: " ").filter { $0.count >= 4 })

            // Sort: logs for the same device first, then by recency (already ordered)
            let sorted = snapshot.documents.sorted { a, b in
                let aName = (a.data()["deviceName"] as? String ?? "").lowercased()
                let bName = (b.data()["deviceName"] as? String ?? "").lowercased()
                let aScore = deviceWords.filter { aName.contains($0) }.count
                let bScore = deviceWords.filter { bName.contains($0) }.count
                return aScore > bScore
            }

            var sections: [String] = []
            for doc in sorted.prefix(3) {
                let data    = doc.data()
                let device  = (data["deviceName"] as? String) ?? "Device"
                let symptom = (data["symptom"]    as? String) ?? ""
                guard let msgs = data["messages"] as? [[String: Any]] else { continue }

                // First 6 exchanges (3 user + 3 AI) — enough to show the solution approach
                let preview = msgs.prefix(6).compactMap { m -> String? in
                    guard let role = m["role"] as? String,
                          let text = m["text"] as? String,
                          !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    let label   = role == "user" ? "User" : "Fixie"
                    let snippet = text.count > 150 ? String(text.prefix(150)) + "…" : text
                    return "  \(label): \(snippet)"
                }.joined(separator: "\n")

                if !preview.isEmpty {
                    sections.append("[\(device) — \"\(symptom)\"]\n\(preview)")
                }
            }

            guard !sections.isEmpty else { return "" }
            return "PAST REPAIRS (reference only — apply what worked, skip what didn't):\n"
                + sections.joined(separator: "\n\n")
        } catch {
            return ""
        }
    }

    // MARK: – Progress tracking

    /// Atomically appends one completed step text to the `completedSteps` array on
    /// `active_repairs/{userId}`. Uses arrayUnion so concurrent writes are safe and
    /// duplicates are never introduced.
    func appendCompletedStep(stepText: String) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let db  = Firestore.firestore()
        let doc = db.collection("active_repairs").document(userId)
        try? await doc.updateData([
            "completedSteps": FieldValue.arrayUnion([stepText])
        ])
    }

    // MARK: – Chat history sync

    /// Writes the full conversation to `active_repairs/{userId}/chatHistory/{guideId}`.
    /// Called after every AI reply so both user and assistant turns are captured.
    /// `imageData` blobs are excluded — text only.
    func syncChatHistory(guideId: String, messages: [ChatMessage]) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        let db      = Firestore.firestore()
        let docRef  = db.collection("active_repairs")
                        .document(userId)
                        .collection("chatHistory")
                        .document(guideId)

        let serialized: [[String: Any]] = messages.map { msg in
            [
                "id":        msg.id.uuidString,
                "role":      msg.role == .user ? "user" : "assistant",
                "text":      msg.text,
                "timestamp": Timestamp(date: msg.timestamp)
            ]
        }
        try? await docRef.setData(["messages": serialized, "updatedAt": Timestamp(date: Date())])
    }

    // MARK: – Leads (Verified Pro "Request Service" flow)
    //
    // Firestore path: leads/{autoId}
    // Schema: { proId, userId, customerName, customerContact, category,
    //           deviceModel, symptom, issueSummary, failedSteps[], imageUrls[],
    //           status: "available", timestamp }
    //
    // The document is written immediately so the user sees instant confirmation,
    // then imageUrls is patched in the background after the Storage upload finishes.
    // Returns true if the document was written, false on auth failure or Firestore error.

    @discardableResult
    func createLead(
        proId:            String,
        proName:          String,
        guide:            RepairGuide?,
        capturedImage:    UIImage?,
        currentStepIndex: Int     = 0,
        chatSummary:      String? = nil,
        chatTranscript:   String  = "",
        isASAP:           Bool    = true,
        requestedTime:    Date?   = nil
    ) async -> String? {
        guard let userId = AuthService.shared.currentUser?.id else { return nil }
        let user        = AuthService.shared.currentUser
        let db          = Firestore.firestore()
        let category    = guide?.session.category
        let deviceModel = guide?.diagnosis?.model   ?? ""
        let symptom     = guide?.diagnosis?.symptom ?? guide?.session.title ?? ""

        // Steps the user already attempted (indices 0 ..< currentStepIndex)
        let failedSteps: [String] = guide.map { g in
            g.steps.prefix(currentStepIndex).map { $0.title }
        } ?? []

        // Build the issue summary: prefer the last AI message; fall back to diagnosis fields
        let issueSummary: String
        if let summary = chatSummary, !summary.isEmpty {
            issueSummary = summary
        } else {
            var parts: [String] = []
            if !deviceModel.isEmpty { parts.append(deviceModel) }
            if !symptom.isEmpty     { parts.append(symptom) }
            if let failures = guide?.diagnosis?.possibleFailures, !failures.isEmpty {
                parts.append("Possible causes: " + failures.joined(separator: ", "))
            }
            issueSummary = parts.joined(separator: " — ")
        }


        // Fetch the user's address from their profile doc so it's included in the lead.
        var userAddress = ""
        var userCity    = ""
        var userState   = ""
        var userZip     = ""
        if let profileData = try? await db.collection("users").document(userId).getDocument().data() {
            userAddress = profileData["address"] as? String ?? ""
            userCity    = profileData["city"]    as? String ?? ""
            userState   = profileData["state"]   as? String ?? ""
            userZip     = profileData["zip"]     as? String ?? ""
        }

        // Reserve the Firestore document ID upfront so the Storage path matches.
        let docRef = db.collection("leads").document()

        // Sequential upload: image stored in the user's own Storage namespace so
        // the existing users/{uid}/projects/{id} rules grant access without new rules.
        // Path: users/{uid}/projects/{leadDocId}/thumbnail.jpg
        var imageUrls: [String] = []
        if let img = capturedImage, let jpeg = img.jpegData(compressionQuality: 0.78) {
            let path = "users/\(userId)/projects/\(docRef.documentID)/thumbnail.jpg"
            let ref  = Storage.storage().reference(withPath: path)
            var meta = StorageMetadata()
            meta.contentType = "image/jpeg"
            do {
                // Step 1 — upload bytes; throws on auth/rules/network failure
                try await ref.putDataAsync(jpeg, metadata: meta)
                // Step 2 — fetch the download token URL; must complete before setData
                let downloadURL = try await ref.downloadURL()
                imageUrls = [downloadURL.absoluteString]
                print("[Fixie] ✅ Lead image uploaded: \(downloadURL.absoluteString)")
            } catch {
                // Upload or URL fetch failed — log and continue without image.
                // The lead is still created so the user's request isn't lost.
                print("[Fixie] ⚠️ Lead image upload failed: \(error.localizedDescription)")
            }
        }

        let data: [String: Any] = [
            "proId":           proId,
            "userId":          userId,
            "customerName":     user?.displayName ?? "",
            "customerContact":  user?.email ?? "",       // Apple Relay forwards to real email
            "customerPhone":    user?.phoneNumber ?? "",
            "customerPhotoURL": user?.photoURL ?? "",
            "category":        category?.firestoreKey ?? "",
            "deviceModel":     deviceModel,
            "symptom":         symptom,
            "issueSummary":    issueSummary,
            "chatTranscript":  chatTranscript,
            "failedSteps":     failedSteps,
            "imageUrls":       imageUrls,               // populated before write — never empty on arrival
            "address":         userAddress,
            "city":            userCity,
            "state":           userState,
            "zip":             userZip,
            "status":          "available",
            "isASAP":          isASAP,
            "requestedTime":   requestedTime.map { Timestamp(date: $0) } as Any,
            "timestamp":       FieldValue.serverTimestamp()
        ]

        do {
            try await docRef.setData(data)
            // Link lead to user profile so cold-launch can restore the listener
            await setActiveProject(docRef.documentID)
            return docRef.documentID
        } catch {
            return nil
        }
    }

    // MARK: – Lead Status Listener
    //
    // Watches leads/{leadId} for two terminal status transitions:
    //   "claimed"  → pro picked up the job; fires onClaimed, listener stays active
    //   "resolved" → repair complete; fires onResolved, listener removed
    //
    // The registration lives on @MainActor because FirebaseService is @MainActor
    // and Firestore delivers snapshot callbacks on the main thread by default.

    private var leadListener: ListenerRegistration?

    func startLeadStatusListener(
        leadId:     String,
        proName:    String,
        onClaimed:  @escaping (ActiveServiceLead) -> Void,
        onResolved: @escaping (ProResolution)     -> Void
    ) {
        stopLeadStatusListener()
        let db = Firestore.firestore()
        leadListener = db.collection("leads").document(leadId)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let data = snapshot?.data(),
                      let status = data["status"] as? String
                else { return }

                switch status {
                case "claimed":
                    // Build the service lead from whatever the contractor's portal wrote
                    let biz   = data["proBusinessName"] as? String ?? proName
                    let pn    = data["proName"]         as? String ?? proName
                    let proId = data["proId"]           as? String ?? ""
                    Task {
                        var logoUrl   = ""
                        var proLat    = 0.0
                        var proLng    = 0.0
                        var proAddr   = ""
                        if !proId.isEmpty,
                           let doc = try? await Firestore.firestore()
                               .collection("contractors").document(proId).getDocument() {
                            if let url = doc.data()?["logoUrl"] as? String { logoUrl = url }
                            proLat = doc.data()?["latitude"]  as? Double ?? 0
                            proLng = doc.data()?["longitude"] as? Double ?? 0
                            let addrParts = [doc.data()?["address"] as? String,
                                             doc.data()?["city"]    as? String,
                                             doc.data()?["state"]   as? String]
                                .compactMap { $0 }.filter { !$0.isEmpty }
                            proAddr = addrParts.joined(separator: ", ")
                        }
                        let eta           = (data["estimatedArrival"] as? Timestamp)?.dateValue()
                        let thumbUrl      = (data["imageUrls"] as? [String])?.first ?? ""
                        let scheduledTime = (data["scheduledTime"] as? Timestamp)?.dateValue()
                        var lead = ActiveServiceLead(
                            leadId:           leadId,
                            proId:            proId,
                            proBusinessName:  biz,
                            proName:          pn,
                            proPhone:         data["proPhone"]    as? String,
                            proStatus:        data["proStatus"]   as? String ?? "active",
                            deviceModel:      data["deviceModel"] as? String ?? "",
                            symptom:          data["symptom"]     as? String ?? "",
                            category:         data["category"]    as? String ?? "",
                            logoUrl:          logoUrl,
                            thumbnailUrl:     thumbUrl,
                            proLatitude:      proLat,
                            proLongitude:     proLng,
                            proAddress:       proAddr,
                            estimatedArrival: eta,
                            scheduledTime:    scheduledTime
                        )
                        lead.statusRaw        = status
                        lead.assignedTechName = data["assignedTechName"] as? String ?? ""
                        lead.invoiceUrl       = data["invoiceUrl"]       as? String ?? ""
                        // Derive pending state from rescheduleRequest.status (new schema);
                        // fall back to reschedulePending bool for legacy docs.
                        if let reqDict = data["rescheduleRequest"] as? [String: Any] {
                            lead.reschedulePending = (reqDict["status"] as? String) == "pending"
                        } else {
                            lead.reschedulePending = data["reschedulePending"] as? Bool ?? false
                        }
                        onClaimed(lead)
                    }

                case "resolved":
                    let notes = data["resolutionNotes"] as? String ?? ""
                    let pn    = data["proName"]         as? String ?? proName
                    let biz   = data["proBusinessName"] as? String ?? proName
                    let dev   = data["deviceModel"]     as? String ?? ""
                    let pId   = data["proId"]           as? String ?? ""
                    let res   = ProResolution(leadId:          leadId,
                                              proId:           pId,
                                              proName:         pn,
                                              proBusinessName: biz,
                                              deviceModel:     dev,
                                              resolutionNotes: notes)
                    self?.stopLeadStatusListener()   // single-fire; listener no longer needed
                    Task { [weak self] in await self?.setActiveProject(nil) }
                    onResolved(res)

                default:
                    break
                }
            }
    }

    func stopLeadStatusListener() {
        leadListener?.remove()
        leadListener = nil
        // NOTE: setActiveProject(nil) is NOT called here because stopLeadStatusListener
        // is also invoked at the start of startLeadStatusListener (to clean up the old
        // listener before re-registering). Calling setActiveProject(nil) there would
        // wrongly erase the activeProjectID while the lead is still active.
        // It is called explicitly in the "resolved" branch of the snapshot listener.
    }

    // MARK: – Leads Query Listener (Task 2: real-time status for any lead of this user)
    //
    // Watches the entire leads collection filtered by userId so status transitions
    // are caught without knowing the leadId ahead of time (survives cleared UserDefaults).
    //
    // On initial attachment:
    //   .added  + "claimed"  → fires onClaimed   (lead was already claimed before launch)
    //   .added  + other      → ignored
    // On subsequent changes:
    //   .modified + "claimed"  → fires onClaimed   (just claimed)
    //   .modified + "resolved" → fires onResolved  (pro marked job done)

    private var leadsQueryListener: ListenerRegistration?

    func startLeadsQueryListener(
        userId:     String,
        onClaimed:  @escaping (ActiveServiceLead) -> Void,
        onResolved: @escaping (String) -> Void          // passes leadId
    ) {
        leadsQueryListener?.remove()
        print("[Fixie] Starting leads query listener for userId: \(userId)")
        let db = Firestore.firestore()
        leadsQueryListener = db.collection("leads")
            .whereField("userId", isEqualTo: userId)
            .addSnapshotListener { snapshot, error in
                if let error = error {
                    print("[Fixie] leadsQueryListener error: \(error.localizedDescription)")
                    return
                }
                guard let changes = snapshot?.documentChanges else { return }

                for change in changes {
                    guard change.type == .added || change.type == .modified else { continue }
                    let data   = change.document.data()
                    let leadId = change.document.documentID

                    // Homeowner confirmed resolution — treat as resolved regardless of status field
                    if data["homeownerResolved"] as? Bool == true {
                        onResolved(leadId)
                        continue
                    }

                    guard let status = data["status"] as? String else { continue }

                    let pn    = data["proName"]         as? String ?? ""
                    let biz   = data["proBusinessName"] as? String ?? pn
                    let proId = data["proId"]           as? String ?? ""

                    switch status {
                    case "claimed", "enRoute", "scheduled":
                        // All three transitions refresh the stored lead so proName/ETA/scheduledTime
                        // stay current. "enRoute" can carry a new proName (dispatched tech differs
                        // from owner). onClaimed upserts by leadId in HomeViewModel.
                        Task {
                            var logoUrl  = ""
                            var proLat   = 0.0
                            var proLng   = 0.0
                            var proAddr  = ""
                            if !proId.isEmpty,
                               let doc = try? await Firestore.firestore()
                                   .collection("contractors").document(proId).getDocument() {
                                if let url = doc.data()?["logoUrl"] as? String { logoUrl = url }
                                proLat = doc.data()?["latitude"]  as? Double ?? 0
                                proLng = doc.data()?["longitude"] as? Double ?? 0
                                let addrParts = [doc.data()?["address"] as? String,
                                                 doc.data()?["city"]    as? String,
                                                 doc.data()?["state"]   as? String]
                                    .compactMap { $0 }.filter { !$0.isEmpty }
                                proAddr = addrParts.joined(separator: ", ")
                            }
                            let eta           = (data["estimatedArrival"] as? Timestamp)?.dateValue()
                            let thumbUrl      = (data["imageUrls"] as? [String])?.first ?? ""
                            let scheduledTime = (data["scheduledTime"] as? Timestamp)?.dateValue()
                            var lead = ActiveServiceLead(
                                leadId:           leadId,
                                proId:            proId,
                                proBusinessName:  biz,
                                proName:          pn,
                                proPhone:         data["proPhone"]    as? String,
                                proStatus:        data["proStatus"]   as? String ?? "active",
                                deviceModel:      data["deviceModel"] as? String ?? "",
                                symptom:          data["symptom"]     as? String ?? "",
                                category:         data["category"]    as? String ?? "",
                                logoUrl:          logoUrl,
                                thumbnailUrl:     thumbUrl,
                                proLatitude:      proLat,
                                proLongitude:     proLng,
                                proAddress:       proAddr,
                                estimatedArrival: eta,
                                scheduledTime:    scheduledTime
                            )
                            lead.statusRaw        = status
                            lead.assignedTechName = data["assignedTechName"] as? String ?? ""
                        lead.invoiceUrl       = data["invoiceUrl"]       as? String ?? ""
                            if let reqDict = data["rescheduleRequest"] as? [String: Any] {
                                lead.reschedulePending = (reqDict["status"] as? String) == "pending"
                            } else {
                                lead.reschedulePending = data["reschedulePending"] as? Bool ?? false
                            }
                            onClaimed(lead)
                        }

                    case "resolved", "completed":
                        // Fire for both .modified (live transition) and .added (cold launch —
                        // lead was resolved while the app was not running). Deduplication
                        // is handled in RepairHistoryStore.saveFromResolvedLead(leadId:).
                        onResolved(leadId)

                    default:
                        break
                    }
                }
            }
    }

    func stopLeadsQueryListener() {
        leadsQueryListener?.remove()
        leadsQueryListener = nil
    }

    // MARK: – Fetch resolved lead data (for history migration on resolution)

    func fetchResolvedLead(_ leadId: String) async -> [String: Any]? {
        let doc = try? await Firestore.firestore().collection("leads").document(leadId).getDocument()
        return doc?.data()
    }

    // MARK: – Fetch contractor logo URL from contractors/{proId}

    func fetchContractorLogoUrl(proId: String) async -> String {
        guard !proId.isEmpty else { return "" }
        let doc = try? await Firestore.firestore()
            .collection("contractors").document(proId).getDocument()
        return doc?.data()?["logoUrl"] as? String ?? ""
    }

    // MARK: – Direct lead read (cold-launch fallback)
    //
    // Returns an ActiveServiceLead if the lead document already has status "claimed".
    // Used by refreshActiveSession() to catch leads that were claimed while the app
    // was backgrounded — avoids a transient "pending" flash before the listener fires.

    func fetchClaimedLead(leadId: String, proName: String) async -> ActiveServiceLead? {
        let db = Firestore.firestore()
        do {
            let doc = try await db.collection("leads").document(leadId).getDocument()
            guard let data = doc.data(), let status = data["status"] as? String else {
                print("[Fixie] fetchClaimedLead: no data for lead \(leadId)")
                return nil
            }
            print("[Fixie] fetchClaimedLead: status=\(status) for lead \(leadId)")
            guard status == "claimed" else { return nil }
            let biz   = data["proBusinessName"] as? String ?? proName
            let pn    = data["proName"]         as? String ?? proName
            let proId = data["proId"]           as? String ?? ""
            var logoUrl = ""
            var proLat  = 0.0
            var proLng  = 0.0
            var proAddr = ""
            if !proId.isEmpty,
               let contractorDoc = try? await db.collection("contractors").document(proId).getDocument() {
                if let url = contractorDoc.data()?["logoUrl"] as? String { logoUrl = url }
                proLat = contractorDoc.data()?["latitude"]  as? Double ?? 0
                proLng = contractorDoc.data()?["longitude"] as? Double ?? 0
                let addrParts = [contractorDoc.data()?["address"] as? String,
                                 contractorDoc.data()?["city"]    as? String,
                                 contractorDoc.data()?["state"]   as? String]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                proAddr = addrParts.joined(separator: ", ")
            }
            let eta           = (data["estimatedArrival"] as? Timestamp)?.dateValue()
            let thumbUrl      = (data["imageUrls"] as? [String])?.first ?? ""
            let scheduledTime = (data["scheduledTime"] as? Timestamp)?.dateValue()
            let rawStatus     = data["status"] as? String ?? "claimed"
            var lead = ActiveServiceLead(
                leadId:           leadId,
                proId:            proId,
                proBusinessName:  biz,
                proName:          pn,
                proPhone:         data["proPhone"]    as? String,
                proStatus:        data["proStatus"]   as? String ?? "active",
                deviceModel:      data["deviceModel"] as? String ?? "",
                symptom:          data["symptom"]     as? String ?? "",
                category:         data["category"]    as? String ?? "",
                logoUrl:          logoUrl,
                thumbnailUrl:     thumbUrl,
                proLatitude:      proLat,
                proLongitude:     proLng,
                proAddress:       proAddr,
                estimatedArrival: eta,
                scheduledTime:    scheduledTime
            )
            lead.statusRaw        = rawStatus
            lead.assignedTechName = data["assignedTechName"] as? String ?? ""
            if let reqDict = data["rescheduleRequest"] as? [String: Any] {
                lead.reschedulePending = (reqDict["status"] as? String) == "pending"
            } else {
                lead.reschedulePending = data["reschedulePending"] as? Bool ?? false
            }
            return lead
        } catch {
            print("[Fixie] fetchClaimedLead error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: – Reschedule Job
    //
    // POSTs to the backend API which writes rescheduleRequest: { requestedTime, status: "pending" }
    // to the lead doc. The backend also sends an FCM push to the pro.
    // The homeowner's UI transitions to "Waiting for Reschedule Confirmation" immediately;
    // the Firestore listener on the lead doc clears that state when the pro accepts/declines.
    //
    // Fallback: if the API call fails, writes reschedulePending:true directly to Firestore
    // (same observable state for the pro's web portal until backend is deployed).

    // MARK: – Reschedule Job (API-only — no direct Firestore writes from the homeowner)
    //
    // POST /api/leads/{leadId}/reschedule
    // Authorization: Bearer {idToken}
    // Body: { "scheduledTimeIso": "2026-04-15T08:03:00.000Z" }
    //
    // The API decides homeowner vs contractor by looking up the lead's proId, then:
    //  Homeowner path → writes rescheduleRequest: { requestedTime, requestedAt,
    //                    requestedBy:"homeowner", status:"pending" } to the lead doc
    //                    (scheduledTime is NOT changed yet) and pushes to the contractor.
    //  Contractor path → applies scheduledTime immediately and pushes to the homeowner.
    //
    // Returns true on HTTP 200/201; false on network error or non-2xx response.
    // The caller shows optimistic UI immediately; on false the UI should revert.

    @discardableResult
    func rescheduleJob(leadId: String, newTime: Date) async -> Bool {
        guard let idToken = try? await Auth.auth().currentUser?.getIDToken(forcingRefresh: false) else {
            print("[Fixie] ⚠️ Reschedule: could not obtain auth token")
            return false
        }
        let iso = ISO8601DateFormatter().string(from: newTime)
        let url = Config.backendBaseURL.appendingPathComponent("leads/\(leadId)/reschedule")
        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.httpBody    = try? JSONSerialization.data(withJSONObject: ["scheduledTimeIso": iso])
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 || code == 201 {
                print("[Fixie] ✅ Reschedule request submitted for lead \(leadId)")
                return true
            }
            print("[Fixie] ⚠️ Reschedule API HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")")
            return false
        } catch {
            print("[Fixie] ⚠️ Reschedule API error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: – Homeowner-initiated resolution

    /// Called when the homeowner taps "Yes, it's fixed" on a past-appointment card.
    /// Writes homeownerResolved fields + invoiceRequested flag to the lead doc so the
    /// pro portal can see the confirmation, fill in resolution notes, and create an invoice.
    /// Also notifies the pro by writing a proNotification field the portal polls.
    func submitHomeownerResolution(leadId: String, resolutionNotes: String) async {
        let db = Firestore.firestore()
        var data: [String: Any] = [
            "homeownerResolved":        true,
            "homeownerResolvedAt":      FieldValue.serverTimestamp(),
            "resolutionNotes":          resolutionNotes,
            "invoiceRequested":         true,
            "proNotification": [
                "type":      "homeowner_resolved",
                "message":   "The homeowner confirmed the repair is complete. Please review and create an invoice.",
                "notes":     resolutionNotes,
                "sentAt":    Timestamp(date: Date())
            ]
        ]
        // Only update status if the rules permit it (best-effort — pro portal handles final status).
        do {
            try await db.collection("leads").document(leadId).updateData(data)
            print("[Fixie] ✅ Homeowner resolution submitted for lead \(leadId)")
        } catch {
            print("[Fixie] ⚠️ submitHomeownerResolution: \(error.localizedDescription)")
        }
    }

    // MARK: – History Migration
    //
    // Writes a resolved repair record to users/{userId}/history/{autoId}.
    // Called after a pro marks the lead "resolved" so the web portal and
    // future app sessions can surface completed contractor repairs.
    // Returns true on success; the caller should fall back to RepairHistoryStore on failure.

    func migrateLeadToHistory(
        guide:      RepairGuide,
        proName:    String,
        proPhone:   String?,
        resolution: ProResolution
    ) async -> Bool {
        guard let userId = AuthService.shared.currentUser?.id else { return false }
        let db = Firestore.firestore()
        let data: [String: Any] = [
            "leadId":          resolution.leadId,
            "userId":          userId,
            "category":        guide.session.category.rawValue,
            "title":           guide.session.title,
            "deviceModel":     guide.diagnosis?.model   ?? "",
            "symptom":         guide.diagnosis?.symptom ?? guide.session.title,
            "proName":         proName,
            "proPhone":        proPhone ?? "",
            "resolutionNotes": resolution.resolutionNotes,
            "resolvedAt":      Timestamp(date: Date())
        ]
        do {
            try await db.collection("users").document(userId)
                .collection("history").addDocument(data: data)
            return true
        } catch {
            return false
        }
    }

    // MARK: – Contractor Reviews
    //
    // Firestore path: contractors/{proId}/reviews/{autoId}
    // Schema: { leadId, userId, proId, rating, comment, customerName, deviceModel, createdAt }
    //
    // averageRating + reviewCount on the contractor doc are updated by the
    // aggregateReview Cloud Function triggered on each new review document.

    func submitReview(
        proId:       String,
        leadId:      String,
        rating:      Int,
        comment:     String,
        proName:     String,
        deviceModel: String
    ) async {
        guard !proId.isEmpty, let userId = AuthService.shared.currentUser?.id else { return }
        let db   = Firestore.firestore()
        let data: [String: Any] = [
            "leadId":       leadId,
            "userId":       userId,
            "proId":        proId,
            "rating":       rating,
            "comment":      comment,
            "proName":      proName,
            "deviceModel":  deviceModel,
            "customerName": AuthService.shared.currentUser?.displayName ?? "",
            "createdAt":    FieldValue.serverTimestamp()
        ]
        try? await db.collection("contractors").document(proId)
            .collection("reviews").addDocument(data: data)
    }

    /// Returns (averageRating, reviewCount) from the contractor document.
    /// Uses NSNumber bridging because Cloud Functions write Firestore integers as Int64,
    /// which cannot be cast directly to Swift Int or Double with `as?`.
    func fetchContractorRating(proId: String) async -> (rating: Double, count: Int) {
        guard !proId.isEmpty else { return (0, 0) }
        let doc = try? await Firestore.firestore()
            .collection("contractors").document(proId).getDocument()
        let d = doc?.data()
        let rating = (d?["averageRating"] as? NSNumber)?.doubleValue ?? 0
        let count  = (d?["reviewCount"]   as? NSNumber)?.intValue   ?? 0
        return (rating, count)
    }

    /// Returns the most recent reviews (up to 50) for a contractor, newest first.
    func fetchContractorReviews(proId: String) async -> [ContractorReview] {
        guard !proId.isEmpty else { return [] }
        let snap = try? await Firestore.firestore()
            .collection("contractors").document(proId)
            .collection("reviews")
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .getDocuments()
        return snap?.documents.compactMap { doc -> ContractorReview? in
            let d = doc.data()
            // rating is written as a JS integer → stored as Int64 in Firestore
            guard let rating = (d["rating"] as? NSNumber)?.intValue, rating >= 1 else { return nil }
            return ContractorReview(
                id:           doc.documentID,
                rating:       rating,
                comment:      d["comment"]      as? String ?? "",
                customerName: d["customerName"] as? String ?? "Customer",
                deviceModel:  d["deviceModel"]  as? String ?? "",
                date:         (d["createdAt"]   as? Timestamp)?.dateValue() ?? Date()
            )
        } ?? []
    }

    // MARK: – FCM Token
    //
    // Saves the device's FCM token to users/{uid}.fcmToken so Cloud Functions
    // can address push notifications to this device.
    //
    // If the user isn't signed in yet (cold launch before auth restores),
    // the token is cached in UserDefaults under "pendingFCMToken" and written
    // as soon as writeUserProfile() is called after successful sign-in.

    func saveFCMToken(_ token: String) async {
        guard let userId = AuthService.shared.currentUser?.id else {
            UserDefaults.standard.set(token, forKey: "pendingFCMToken")
            return
        }
        let db = Firestore.firestore()
        // Write to users/{uid}.fcmToken (existing — used by internal Cloud Functions)
        try? await db.collection("users").document(userId)
            .setData(["fcmToken": token], merge: true)
        // Write to fcmTokens/{uid}.tokens[] (web portal dispatch reads this path)
        try? await db.collection("fcmTokens").document(userId)
            .setData(["tokens": FieldValue.arrayUnion([token])], merge: true)
        UserDefaults.standard.removeObject(forKey: "pendingFCMToken")
    }

    // MARK: – Invoices

    /// Fetches invoices linked to a specific job/lead.
    /// Schema: invoices/{id} with fields jobId, businessName, finalTotal,
    /// lineItems[]{description, amount}, invoiceNumber, status, createdAt.
    func fetchInvoices(leadId: String) async -> [Invoice] {
        let db = Firestore.firestore()
        // Try ordered query first; fall back to unordered if index isn't ready yet
        let snap: QuerySnapshot?
        if let ordered = try? await db.collection("invoices")
            .whereField("jobId", isEqualTo: leadId)
            .order(by: "createdAt", descending: false)
            .getDocuments() {
            snap = ordered
        } else {
            snap = try? await db.collection("invoices")
                .whereField("jobId", isEqualTo: leadId)
                .getDocuments()
        }
        guard let snap else { return [] }

        return snap.documents.compactMap { doc -> Invoice? in
            let d = doc.data()
            guard let total = (d["finalTotal"] as? NSNumber)?.doubleValue else { return nil }
            let rawItems = d["lineItems"] as? [[String: Any]] ?? []
            let items: [Invoice.LineItem] = rawItems.enumerated().map { idx, item in
                Invoice.LineItem(
                    id:          item["id"] as? String ?? "\(doc.documentID)_\(idx)",
                    description: item["description"] as? String ?? "",
                    amount:      (item["amount"] as? NSNumber)?.doubleValue ?? 0
                )
            }
            let ts = d["createdAt"] as? Timestamp
            return Invoice(
                id:            doc.documentID,
                invoiceNumber: d["invoiceNumber"] as? String ?? "",
                jobId:         d["jobId"]         as? String ?? leadId,
                businessName:  d["businessName"]  as? String ?? "",
                lineItems:     items,
                finalTotal:    total,
                notes:         d["resolutionNotes"] as? String ?? "",
                status:        d["status"]          as? String ?? "",
                issuedAt:      ts?.dateValue() ?? Date()
            )
        }
    }

    // MARK: – Auth token helper (used by FixieBackendService)

    /// Returns the current user's Firebase ID token, or nil when not signed in.
    /// Best-effort: never throws — callers treat nil as "proceed without auth".
    func currentUserIDToken() async -> String? {
        try? await Auth.auth().currentUser?.getIDToken(forcingRefresh: false)
    }

    // MARK: – Errors

    enum FirebaseServiceError: LocalizedError {
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "User is not signed in."
            }
        }
    }
}
