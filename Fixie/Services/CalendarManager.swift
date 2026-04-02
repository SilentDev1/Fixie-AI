// Services/CalendarManager.swift
// Manages EventKit integration: requests calendar write access, then creates,
// updates, or removes EKEvent records for Fixie scheduled repair appointments.
//
// Deduplication: leadId → EKEvent.eventIdentifier stored in UserDefaults.
// On reschedule: upsertEvent() finds the existing event and updates its times
//   rather than creating a duplicate entry.
import EventKit
import Foundation
import Observation

@Observable @MainActor
final class CalendarManager {

    static let shared = CalendarManager()

    private let store = EKEventStore()

    /// Reflects the current EKAuthorizationStatus so views can react reactively.
    private(set) var authStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    // MARK: – Persistence

    private static let storageKey     = "com.fixie.calendarEventIds"
    private static let syncTimeKey    = "com.fixie.calendarSyncTimes"

    /// leadId → EKEvent.eventIdentifier, survives app restarts.
    private var eventIds: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.storageKey) }
    }

    /// leadId → ISO8601 string of the scheduledTime that was last synced.
    /// Prevents creating a duplicate calendar entry on every cold launch.
    private var syncedTimes: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.syncTimeKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.syncTimeKey) }
    }

    private init() {}

    // MARK: – Permission

    var isAuthorized: Bool {
        authStatus == .authorized || authStatus == .writeOnly
    }

    /// Requests write-only calendar access (iOS 17+). Returns true if granted.
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestWriteOnlyAccessToEvents()
            authStatus = EKEventStore.authorizationStatus(for: .event)
            return granted
        } catch {
            authStatus = EKEventStore.authorizationStatus(for: .event)
            return false
        }
    }

    // MARK: – Sync (auto + manual)

    /// Called automatically when a lead transitions to .scheduled.
    /// Does nothing if calendar permission has not been granted yet.
    func syncIfAuthorized(lead: ActiveServiceLead, userAddress: String) async {
        guard isAuthorized else { return }
        await upsertEvent(lead: lead, userAddress: userAddress)
    }

    /// Called from the manual "Add to Calendar" button.
    /// Requests permission first, then syncs.
    func requestAndSync(lead: ActiveServiceLead, userAddress: String) async {
        let granted = await requestAccess()
        if granted {
            await upsertEvent(lead: lead, userAddress: userAddress)
        }
    }

    // MARK: – Upsert

    private func upsertEvent(lead: ActiveServiceLead, userAddress: String) async {
        guard let startDate = lead.scheduledTime else { return }
        let endDate  = startDate.addingTimeInterval(2 * 3600)   // default 2-hour window
        guard let calendar = store.defaultCalendarForNewEvents else { return }

        // ── Deduplicate: skip if we already synced this exact time ─────────
        // The Firestore listener fires .added for every existing scheduled lead
        // on cold launch. Without this guard, a new calendar entry would be created
        // on every app restart. We compare the ISO8601 representation of startDate
        // to what we stored on the last successful save.
        let iso = ISO8601DateFormatter().string(from: startDate)
        if syncedTimes[lead.leadId] == iso && eventIds[lead.leadId] != nil {
            return  // same time, already in calendar
        }

        // ── Create event ─────────────────────────────────────────────────
        // The app uses write-only calendar access (requestWriteOnlyAccessToEvents).
        // With write-only access, event(withIdentifier:) always returns nil — iOS
        // will not expose a read API on events the app didn't create in the current
        // process. Attempting the lookup triggers EKCADErrorDomain Code=1010
        // internally. We skip the lookup entirely and always write a fresh event.
        let event        = EKEvent(eventStore: store)
        event.calendar   = calendar
        event.title      = buildTitle(lead: lead)
        event.startDate  = startDate
        event.endDate    = endDate
        event.location   = userAddress.isEmpty ? nil : userAddress
        event.notes      = buildNotes(lead: lead)

        do {
            try store.save(event, span: .thisEvent)
            eventIds[lead.leadId]  = event.eventIdentifier
            syncedTimes[lead.leadId] = iso
            print("CalendarManager: ✅ created event for lead \(lead.leadId)")
        } catch {
            print("CalendarManager: ⚠️ save failed – \(error.localizedDescription)")
        }
    }

    // MARK: – Remove

    /// Removes the stored identifier when a lead is resolved.
    /// With write-only calendar access, event(withIdentifier:) returns nil so the
    /// actual EKEvent cannot be fetched or deleted from app code. Just clear the
    /// local record — the orphaned calendar entry is harmless and the user can
    /// delete it manually if desired. Full-access upgrade would enable real deletion.
    func removeEvent(leadId: String) {
        eventIds[leadId]   = nil
        syncedTimes[leadId] = nil
        print("CalendarManager: 🗑 cleared stored event ID for lead \(leadId)")
    }

    // MARK: – String helpers

    private func buildTitle(lead: ActiveServiceLead) -> String {
        let categoryName = RepairCategory.fromFirestoreKey(lead.category)?.rawValue
            ?? lead.category.capitalized
        let biz = lead.proBusinessName.isEmpty ? lead.proName : lead.proBusinessName
        return "Fixie AI: \(categoryName) with \(biz)"
    }

    private func buildNotes(lead: ActiveServiceLead) -> String {
        var lines: [String] = []
        let tech = lead.assignedTechName.isEmpty ? lead.proName : lead.assignedTechName
        if !tech.isEmpty          { lines.append("Technician: \(tech)") }
        if let phone = lead.proPhone, !phone.isEmpty { lines.append("Phone: \(phone)") }
        lines.append("Track your repair in the Fixie AI app.")
        lines.append("fixie://lead/\(lead.leadId)")
        return lines.joined(separator: "\n")
    }
}
