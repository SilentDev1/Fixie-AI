// ViewModels/HomeViewModel.swift
import SwiftUI
import PhotosUI
import FirebaseFirestore

@Observable @MainActor
final class HomeViewModel {
    var isDiagnoseSheetPresented = false
    var selectedCategory: RepairCategory?
    var searchText = ""
    var isLoading  = true

    // MARK: – Chat First flow
    var chatFirstText     = ""
    var chatFirstCategory: RepairCategory? = nil
    var chatFirstGuide:    RepairGuide?    = nil   // non-nil → triggers navigation

    // MARK: – Media upload flow
    var mediaGuide:        RepairGuide?    = nil   // non-nil → triggers navigation
    var isAnalyzingMedia   = false
    var mediaError:        String?         = nil

    private let engine = DiagnosisEngine()

    // Live data from the persistent store
    var historyStore = RepairHistoryStore.shared

    // MARK: – Save & Resume (supports multiple concurrent paused repairs)
    var activeSessions: [ActiveSession] = []
    /// Backward-compat: first session, used for pending job device model.
    var activeSession: ActiveSession? { activeSessions.first }

    // MARK: – Active Service (claimed by a Fixie Verified Pro)
    var activeServiceLeads: [ActiveServiceLead] = []  // supports multiple concurrent leads
    var lastClaimedLead:    ActiveServiceLead?  = nil // consumed by HomeView to auto-open sheet
    var pendingProName:     String?             = nil // lead submitted, awaiting claim
    private var serviceListenerRegistered = false

    /// All active work items merged into a unified [ServiceJob] array.
    var jobs: [ServiceJob] {
        var result: [ServiceJob] = activeServiceLeads.map { ServiceJob(from: $0) }
        // Append pending tile if no claimed lead exists and a pending name is set.
        // Suppress if a session with pendingLeadId already covers it — the ContinueRepairCard
        // will show "Waiting for Pro" for that session instead, avoiding a duplicate card.
        if activeServiceLeads.isEmpty, let name = pendingProName {
            let hasCoveredSession = activeSessions.contains { $0.pendingLeadId != nil }
            if !hasCoveredSession {
                let device = activeSession?.deviceModel ?? ""
                result.append(ServiceJob(pendingLeadId: "pending", proName: name, deviceModel: device))
            }
        }
        return result
    }

    /// All en-route jobs — drives LiveStatusOverlay (one bar per active dispatch).
    var enRouteJobs: [ServiceJob] { jobs.filter { $0.status == .enRoute } }

    /// All scheduled jobs with a FUTURE appointment — drives ScheduledStatusBar.
    /// Past appointments are hidden from the top bar; they show a "Was it repaired?" prompt on the card instead.
    var scheduledJobs: [ServiceJob] { jobs.filter { $0.status == .scheduled && !$0.isAppointmentPast } }

    /// Lead IDs where the pro changed the appointment time (drives "Rescheduled" card state).
    /// Populated by HomeView when a `rescheduleTappedNotification` arrives; cleared on card tap.
    var proRescheduledLeadIds: Set<String> = []

    /// Optimistically marks a lead's reschedulePending flag before the Firestore listener fires.
    /// Called immediately when the homeowner confirms a reschedule request in ProServiceCardView.
    func markReschedulePending(leadId: String) {
        guard let idx = activeServiceLeads.firstIndex(where: { $0.leadId == leadId }) else { return }
        activeServiceLeads[idx].reschedulePending = true
        ActiveServiceLead.saveAllLocal(activeServiceLeads)
    }

    /// Clears the reschedulePending flag (called when pro accepts or declines).
    func clearReschedulePending(leadId: String) {
        guard let idx = activeServiceLeads.firstIndex(where: { $0.leadId == leadId }) else { return }
        activeServiceLeads[idx].reschedulePending = false
        ActiveServiceLead.saveAllLocal(activeServiceLeads)
    }

    var recentSessions: [RepairSession] {
        historyStore.entries.map { entry in
            RepairSession(
                id:            entry.id,
                category:      entry.category,
                title:         entry.title,
                subtitle:      entry.subtitle,
                date:          entry.date,
                isCompleted:   entry.isCompleted,
                thumbnailName: nil
            )
        }
    }

    var filteredSessions: [RepairSession] {
        guard !searchText.isEmpty else { return recentSessions }
        return recentSessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.subtitle.localizedCaseInsensitiveContains(searchText) ||
            $0.category.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    init() {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            isLoading = false
        }
        Task { await refreshActiveSession() }

        // Retry Firestore operations once Firebase Auth confirms a valid session.
        // On cold launch, auth is restored asynchronously; without this the listener
        // registration returns "Missing or insufficient permissions".
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AuthService.authReadyNotification) {
                guard let self else { return }
                if self.activeServiceLeads.isEmpty {
                    await self.refreshActiveSession()
                }
            }
        }

        // Clear all transient repair/lead state the moment the user signs out.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AuthService.authSignedOutNotification) {
                guard let self else { return }
                self.clearAllData()
            }
        }
    }

    func refreshActiveSession() async {
        // 1. Resume in-progress DIY repairs.
        // Firebase is the authoritative source so sessions survive device switches.
        // Local UserDefaults is a fast-path cache; Firebase wins on conflict.
        let activeLeadIds = Set(activeServiceLeads.map { $0.leadId })

        // Fetch remote first so a session started on another device is immediately visible.
        let remote = await FirebaseService.shared.fetchActiveSession()

        var localSessions = ActiveSession.loadAllLocal()
        // Prune orphaned local sessions (pro resolved while app was backgrounded)
        let orphaned = localSessions.filter { s in
            guard let lid = s.pendingLeadId else { return false }
            return !activeLeadIds.contains(lid)
        }
        if !orphaned.isEmpty {
            localSessions.removeAll { s in orphaned.contains(where: { $0.id == s.id }) }
            for s in orphaned { ActiveSession.removeLocal(guideId: s.id) }
        }

        if let remote {
            // Merge: start with Firebase session, then add any local sessions for
            // different guides (e.g. user started a second repair offline).
            var merged = [remote]
            for local in localSessions where local.id != remote.id {
                merged.append(local)
            }
            // Keep local cache in sync
            remote.saveLocal()
            activeSessions = merged
        } else if !localSessions.isEmpty {
            // Firebase empty (new account / offline) — fall back to local cache
            activeSessions = localSessions
        }

        // 2. Resume active service leads from local cache (fast path)
        let cached = ActiveServiceLead.loadAllLocal()
        if !cached.isEmpty {
            activeServiceLeads = cached
        } else if let pending = ActiveServiceLead.loadPendingLead() {
            if activeServiceLeads.isEmpty {
                pendingProName = pending.proName   // show pending tile while listener catches up
            }
        }

        // 3. Start the real-time leads query listener (catches claimed/resolved in one shot)
        //    Requires Firebase Auth to be ready; guarded by the authReadyNotification retry above.
        if !serviceListenerRegistered, let userId = AuthService.shared.currentUser?.id {
            startLeadsQueryListener(userId: userId)
        }
    }

    // MARK: – Leads Query Listener (Task 2)

    private func startLeadsQueryListener(userId: String) {
        guard !serviceListenerRegistered else { return }
        serviceListenerRegistered = true
        FirebaseService.shared.startLeadsQueryListener(
            userId: userId,
            onClaimed: { [weak self] lead in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingProName = nil
                    ActiveServiceLead.clearPendingLead()
                    // Add or update by leadId — prevent duplicates
                    if let idx = self.activeServiceLeads.firstIndex(where: { $0.leadId == lead.leadId }) {
                        self.activeServiceLeads[idx] = lead
                    } else {
                        self.activeServiceLeads.append(lead)
                        self.lastClaimedLead = lead   // triggers HomeView sheet
                    }
                    ActiveServiceLead.saveAllLocal(self.activeServiceLeads)
                    // Auto-sync to Apple Calendar when appointment is confirmed.
                    if lead.statusRaw == "scheduled" {
                        await CalendarManager.shared.syncIfAuthorized(
                            lead: lead,
                            userAddress: self.homeAddress
                        )
                    }
                }
            },
            onResolved: { [weak self] leadId in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Track whether this lead was actively tracked (vs cold-launch historical)
                    let wasActive = self.activeServiceLeads.contains { $0.leadId == leadId }
                    let resolvedLead = self.activeServiceLeads.first { $0.leadId == leadId }
                    self.activeServiceLeads.removeAll { $0.leadId == leadId }
                    ActiveServiceLead.saveAllLocal(self.activeServiceLeads)
                    // Remove the calendar event now that the job is done.
                    CalendarManager.shared.removeEvent(leadId: leadId)

                    // Remove any paused session that was waiting for this lead.
                    // Without this, the ContinueRepairCard reappears after the pro resolves
                    // because the carousel filter (pendingLeadId not in activeServiceLeads) flips back.
                    let orphaned = self.activeSessions.filter { $0.pendingLeadId == leadId }
                    self.activeSessions.removeAll { $0.pendingLeadId == leadId }
                    for session in orphaned {
                        ActiveSession.removeLocal(guideId: session.id)
                    }
                    // Only reset listener state if the lead was actually in our active list
                    if wasActive && self.activeServiceLeads.isEmpty {
                        self.pendingProName = nil
                        ActiveServiceLead.clearPendingLead()
                        self.serviceListenerRegistered = false
                        Task { await FirebaseService.shared.setActiveProject(nil) }
                    }
                    // Save to history (saveFromResolvedLead deduplicates by leadId)
                    if let data = await FirebaseService.shared.fetchResolvedLead(leadId) {
                        let notes    = data["resolutionNotes"] as? String ?? ""
                        let category = data["category"]        as? String ?? resolvedLead?.category ?? ""
                        let device   = data["deviceModel"]     as? String ?? resolvedLead?.deviceModel ?? ""
                        let symptom  = data["symptom"]         as? String ?? resolvedLead?.symptom ?? ""
                        let pName    = data["proName"]         as? String ?? resolvedLead?.proName
                        let pPhone   = data["proPhone"]        as? String ?? resolvedLead?.proPhone
                        let pBiz     = data["proBusinessName"] as? String ?? resolvedLead?.proBusinessName ?? ""
                        let proId    = data["proId"]           as? String ?? resolvedLead?.proId ?? ""
                        let resolvedAt = (data["resolvedAt"] as? Timestamp)?.dateValue() ?? Date()

                        // Logo: prefer in-memory lead (already fetched), fall back to Firestore
                        var logoUrl = resolvedLead?.logoUrl ?? ""
                        if logoUrl.isEmpty {
                            logoUrl = await FirebaseService.shared.fetchContractorLogoUrl(proId: proId)
                        }

                        // Thumbnail: first image from the lead's imageUrls array
                        let thumbnailUrl = (data["imageUrls"] as? [String])?.first ?? ""

                        RepairHistoryStore.shared.saveFromResolvedLead(
                            leadId:          leadId,
                            categoryRaw:     category,
                            deviceModel:     device,
                            symptom:         symptom,
                            proName:         pName,
                            proPhone:        pPhone,
                            proBusinessName: pBiz,
                            proLogoUrl:      logoUrl,
                            resolutionNotes: notes,
                            resolvedAt:      resolvedAt,
                            thumbnailUrl:    thumbnailUrl,
                            proId:           proId
                        )
                    }
                    if wasActive { await self.refreshActiveSession() }
                }
            }
        )
    }

    // MARK: – Calendar helpers

    /// Builds a single address string from the user's Firestore profile fields.
    /// Used as the EKEvent location when syncing to Apple Calendar.
    var homeAddress: String {
        guard let user = AuthService.shared.currentUser else { return "" }
        let parts = [user.address, user.city, user.state, user.zip].filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    // MARK: – Clear all transient state on sign-out (Task 3)

    func clearAllData() {
        activeSessions            = []
        activeServiceLeads        = []
        lastClaimedLead           = nil
        pendingProName            = nil
        serviceListenerRegistered = false
        FirebaseService.shared.stopLeadsQueryListener()
        FirebaseService.shared.stopLeadStatusListener()
    }

    func startNewRepair(category: RepairCategory) {
        selectedCategory = category
        isDiagnoseSheetPresented = true
    }

    // MARK: – Delete paused session

    /// Removes a paused DIY repair card from the carousel and clears its persistence.
    func deletePausedSession(_ session: ActiveSession) {
        activeSessions.removeAll { $0.id == session.id }
        ActiveSession.removeLocal(guideId: session.id)
        // If no sessions remain, also clear the Firestore active_repairs doc.
        if activeSessions.isEmpty {
            Task { await FirebaseService.shared.clearActiveSession() }
        }
    }

    // MARK: – Confirm past appointment was repaired

    /// Called when the user taps "Yes, it's fixed!" on a past-appointment card.
    /// Removes the card locally and cleans up, same as a cancel but semantically a completion acknowledgement.
    func confirmRepairCompleted(leadId: String) {
        cancelServiceLead(leadId: leadId)
    }

    // MARK: – Cancel service lead

    /// Removes a pending/scheduled service lead card from the carousel.
    /// Does NOT call into Firestore — the contractor's web portal manages status.
    func cancelServiceLead(leadId: String) {
        activeServiceLeads.removeAll { $0.leadId == leadId }
        ActiveServiceLead.saveAllLocal(activeServiceLeads)
        // Clear pendingProName if it was the only lead and nothing remains.
        if activeServiceLeads.isEmpty {
            pendingProName = nil
            ActiveServiceLead.clearPendingLead()
        }
        // Remove any paused session that was waiting for this lead.
        let orphaned = activeSessions.filter { $0.pendingLeadId == leadId }
        activeSessions.removeAll { $0.pendingLeadId == leadId }
        for s in orphaned { ActiveSession.removeLocal(guideId: s.id) }
    }

    // MARK: – Media upload analysis

    /// Called when the user picks a video from Photos library.
    /// Loads the video file as Data and sends it to the backend /diagnose-video endpoint.
    func analyzeVideo(pickerItem: PhotosPickerItem) async {
        isAnalyzingMedia = true
        mediaError = nil
        defer { isAnalyzingMedia = false }

        guard let fileTransferable = try? await pickerItem.loadTransferable(type: VideoFileTransferable.self) else {
            mediaError = "Could not load video file."; return
        }
        guard let videoData = try? Data(contentsOf: fileTransferable.url) else {
            mediaError = "Could not read video data."; return
        }
        do {
            mediaGuide = try await engine.diagnoseVideo(
                videoData:       videoData,
                category:        chatFirstCategory,
                userDescription: chatFirstText
            )
        } catch {
            mediaError = error.localizedDescription
        }
    }

    // MARK: – Submit chat-first text

    func submitChatFirst() {
        let text = chatFirstText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let category = chatFirstCategory ?? .majorAppliances
        let session  = RepairSession(category: category, title: text)
        chatFirstGuide = RepairGuide(session: session)
    }
}

// MARK: – Video transferable (PhotosPicker bridge)

struct VideoFileTransferable: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: tmp)
            return VideoFileTransferable(url: tmp)
        }
    }
}

// MARK: – RepairGuide Hashable (needed for navigationDestination(item:))

extension RepairGuide: Hashable {
    static func == (lhs: RepairGuide, rhs: RepairGuide) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
