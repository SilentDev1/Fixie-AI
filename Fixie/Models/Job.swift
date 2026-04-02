// Models/Job.swift
import Foundation

/// A unified model representing any active work item on the Home screen:
/// a pending lead, a claimed/en-route lead, or a completed job.
struct ServiceJob: Identifiable, Equatable {

    enum Status: String, Equatable {
        case pending    // lead submitted, waiting for pro to accept
        case claimed    // pro assigned, arriving today (ASAP or same-day)
        case scheduled  // appointment confirmed for a future date/time
        case enRoute    // pro is actively on the way (portal set "enRoute")
        case arrived    // pro has arrived on-site
        case completed  // lead resolved
    }

    let id:               String          // leadId
    let status:           Status
    let proName:          String
    let proBusinessName:  String
    let deviceModel:      String
    let symptom:          String
    let categoryRaw:      String          // Firestore category key — used for accent color
    let logoUrl:          String
    let proLatitude:      Double
    let proLongitude:     Double
    let proAddress:       String
    let estimatedArrival: Date?
    let scheduledTime:    Date?           // homeowner-requested or pro-confirmed scheduled time
    let reschedulePending: Bool           // homeowner submitted reschedule, waiting for pro to confirm
    let lead:             ActiveServiceLead?  // nil for .pending jobs

    // MARK: – Convenience init from a claimed ActiveServiceLead
    init(from lead: ActiveServiceLead) {
        self.id               = lead.leadId
        // Map the Firestore status string to our typed enum.
        // CRITICAL: only set .enRoute when status === "enRoute" — never infer from proId/proName.
        switch lead.statusRaw {
        case "enRoute":                self.status = .enRoute
        case "scheduled":              self.status = .scheduled
        case "arrived":                self.status = .arrived
        case "resolved", "completed":  self.status = .completed
        case "claimed":                self.status = .claimed
        case "available", "open":      self.status = .pending   // still searching for a pro
        default:                       self.status = .claimed
        }
        self.proName          = lead.proName
        self.proBusinessName  = lead.proBusinessName
        self.deviceModel      = lead.deviceModel
        self.symptom          = lead.symptom
        self.categoryRaw      = lead.category
        self.logoUrl          = lead.logoUrl
        self.proLatitude      = lead.proLatitude
        self.proLongitude     = lead.proLongitude
        self.proAddress       = lead.proAddress
        self.estimatedArrival  = lead.estimatedArrival
        self.scheduledTime     = lead.scheduledTime
        self.reschedulePending = lead.reschedulePending
        self.lead              = lead
    }

    // MARK: – Convenience init for a pending (not yet claimed) lead
    init(pendingLeadId: String, proName: String, deviceModel: String, symptom: String = "") {
        self.id                = pendingLeadId
        self.status            = .pending
        self.proName           = proName
        self.proBusinessName   = ""
        self.deviceModel       = deviceModel
        self.symptom           = symptom
        self.categoryRaw       = ""
        self.logoUrl           = ""
        self.proLatitude       = 0
        self.proLongitude      = 0
        self.proAddress        = ""
        self.estimatedArrival  = nil
        self.scheduledTime     = nil
        self.reschedulePending = false
        self.lead              = nil
    }

    /// True when a scheduled appointment time exists and has already passed.
    /// Used to suppress the sticky bar and show the "Was your repair done?" prompt.
    var isAppointmentPast: Bool {
        guard let t = scheduledTime else { return false }
        return t < Date()
    }

    /// Minutes until estimated arrival. nil when ETA is unknown or in the past.
    var minsAway: Int? {
        guard let eta = estimatedArrival else { return nil }
        let mins = Int(eta.timeIntervalSinceNow / 60)
        return mins > 0 ? mins : nil
    }

    /// The accent color for this job's repair category (fallback: blue).
    var categoryAccentColor: Color {
        RepairCategory.allCases.first {
            $0.firestoreKey == categoryRaw || $0.rawValue == categoryRaw
        }?.accentColor ?? Color(hex: 0x2979FF)
    }
}

import SwiftUI
