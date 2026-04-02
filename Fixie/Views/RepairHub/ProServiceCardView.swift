// Views/RepairHub/ProServiceCardView.swift
// Shown when a Fixie Verified Pro claims the user's service lead.
// Used as both a sheet (from RepairHubView) and a full tile destination (from HomeView).
import SwiftUI
import FirebaseFirestore
import UserNotifications

// Contractor credentials fetched lazily when the card opens.
private struct ContractorCredentials {
    var licenseNumber:        String = ""
    var licenseExpiry:        String = ""
    var licenseState:         String = ""
    var licenseCertificateUrl: String = ""
    var insurancePolicyNumber: String = ""
    var insuranceExpiry:      String = ""
    var website:              String = ""
    var email:                String = ""
    var averageRating:        Double = 0
    var reviewCount:          Int    = 0
}

struct ProServiceCardView: View {
    let lead: ActiveServiceLead
    var onDismiss: (() -> Void)? = nil     // non-nil when presented as a sheet

    @State private var credentials: ContractorCredentials? = nil
    @State private var showReviewsSheet  = false
    @State private var showCertSheet     = false

    // Inline reschedule picker state (avoids nested sheet issues in iOS 26)
    @State private var isRescheduling    = false
    @State private var rescheduleDate    = Date().addingTimeInterval(3600)
    @State private var reschedulePending = false  // true after homeowner submits; cleared on accept/decline

    // Fetched fresh from the lead doc on open — avoids stale UserDefaults snapshot
    @State private var assignedTechName: String = ""
    @State private var liveScheduledTime: Date? = nil

    // MARK: – Real-time dispatch state
    @State private var isEnRoute    = false
    @State private var dispatchETA: Date? = nil
    @State private var leadListener: ListenerRegistration? = nil

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle (sheet mode only)
                if onDismiss != nil {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 36, height: 5)
                        .padding(.top, Theme.spacingM)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Theme.spacingL) {
                        // Dispatch banner — shown instantly when web portal marks lead enRoute
                        if isEnRoute {
                            dispatchBanner
                        }
                        headerSection
                        // Scheduled appointment card — shown whenever a time is confirmed
                        if isScheduled {
                            scheduledAppointmentSection
                        }
                        if !lead.thumbnailUrl.isEmpty, let url = URL(string: lead.thumbnailUrl) {
                            repairImageSection(url: url)
                        }
                        proIdentityCard
                        actionRow
                        if let creds = credentials {
                            credentialsSection(creds)
                        }
                        subtext
                        addressSharedNote
                        Spacer(minLength: Theme.spacingXL)
                    }
                    .padding(Theme.spacingM)
                }
            }
        }
        .onAppear  { startDispatchListener() }
        .onDisappear { leadListener?.remove(); leadListener = nil }
        // Contractor accepted → clear pending flag and apply the confirmed new time.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.rescheduleAcceptedNotification)) { note in
            reschedulePending = false
            if let epoch = note.userInfo?["scheduledTime"] as? Date {
                liveScheduledTime = epoch
            }
        }
        // Contractor declined → clear pending flag; displayed time stays unchanged.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.rescheduleDeclinedNotification)) { _ in
            reschedulePending = false
        }
        .task {
            // Always fetch the latest lead fields — the `lead` passed in may be a stale
            // UserDefaults snapshot that predates assignedTechName / scheduledTime writes.
            if let leadData = try? await Firestore.firestore()
                .collection("leads").document(lead.leadId).getDocument().data() {
                assignedTechName  = leadData["assignedTechName"] as? String ?? lead.assignedTechName
                // scheduledTime = confirmed appointment (set by API on accept, or original booking)
                liveScheduledTime = (leadData["scheduledTime"] as? Timestamp)?.dateValue()
                    ?? lead.scheduledTime
                // rescheduleRequest.status is authoritative. "pending" means homeowner is waiting.
                // Fall back to reschedulePending bool for legacy lead docs.
                if let reqDict = leadData["rescheduleRequest"] as? [String: Any] {
                    let reqStatus = reqDict["status"] as? String ?? ""
                    reschedulePending = (reqStatus == "pending")
                } else {
                    reschedulePending = leadData["reschedulePending"] as? Bool ?? lead.reschedulePending
                }
            } else {
                assignedTechName  = lead.assignedTechName
                liveScheduledTime = lead.scheduledTime
                reschedulePending = lead.reschedulePending
            }

            guard !lead.proId.isEmpty, credentials == nil else { return }
            let doc = try? await Firestore.firestore()
                .collection("contractors").document(lead.proId).getDocument()
            let d = doc?.data() ?? [:]
            let (avg, count) = await FirebaseService.shared.fetchContractorRating(proId: lead.proId)
            credentials = ContractorCredentials(
                licenseNumber:         d["licenseNumber"]          as? String ?? "",
                licenseExpiry:         d["licenseExpirationDate"]  as? String ?? "",
                licenseState:          d["licenseState"]           as? String ?? "",
                licenseCertificateUrl: d["licenseCertificateUrl"]  as? String ?? "",
                insurancePolicyNumber: d["insurancePolicyNumber"]  as? String ?? "",
                insuranceExpiry:       d["insuranceExpirationDate"] as? String ?? "",
                website:               d["website"]                as? String ?? "",
                email:                 d["email"]                  as? String ?? "",
                averageRating:         avg,
                reviewCount:           count
            )
        }
        .sheet(isPresented: $showCertSheet) {
            if let urlStr = credentials?.licenseCertificateUrl,
               let url = URL(string: urlStr) {
                InAppDocumentViewer(url: url, title: "License Certificate")
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showReviewsSheet) {
            ProReviewsSheet(
                proId:          lead.proId,
                businessName:   lead.proBusinessName,
                averageRating:  credentials?.averageRating ?? 0,
                reviewCount:    credentials?.reviewCount ?? 0
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(hex: 0x0D0D0F))
        }
    }

    // MARK: – Repair photo

    private func repairImageSection(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable()
                   .scaledToFill()
                   .frame(maxWidth: .infinity)
                   .frame(height: 180)
                   .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS))
            case .failure:
                EmptyView()
            default:
                RoundedRectangle(cornerRadius: Theme.radiusS)
                    .fill(.ultraThinMaterial)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .overlay(ProgressView())
            }
        }
    }

    // MARK: – Header

    private var isScheduled: Bool { lead.statusRaw == "scheduled" || liveScheduledTime != nil }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                HStack(spacing: Theme.spacingS) {
                    Image(systemName: reschedulePending
                          ? "clock.badge.questionmark"
                          : (isScheduled ? "calendar.badge.checkmark" : "checkmark.circle.fill"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(reschedulePending ? .orange
                                         : (isScheduled ? Theme.brandPrimary : .green))
                    Text(reschedulePending
                         ? "Waiting for Reschedule Confirmation"
                         : (isScheduled ? "Appointment Confirmed" : "Service Professional Assigned"))
                        .font(Theme.titleMedium)
                        .foregroundStyle(reschedulePending ? .orange
                                         : (isScheduled ? Theme.brandPrimary : .green))
                }
                Text(reschedulePending
                     ? "Your reschedule request has been sent. Waiting for the technician to confirm."
                     : (isScheduled
                        ? "Your appointment is scheduled. We'll send a reminder before your pro arrives."
                        : "Your request has been claimed and is being reviewed."))
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let dismiss = onDismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: – Scheduled appointment details

    private var scheduledAppointmentSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            // Date & time block
            HStack(spacing: Theme.spacingM) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.brandPrimary.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: "calendar")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.brandPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let t = liveScheduledTime {
                        let df = DateFormatter()
                        let _ = { df.dateStyle = .full; df.timeStyle = .none }()
                        Text(df.string(from: t))
                            .font(Theme.bodyBold)
                            .foregroundStyle(Theme.textPrimary)
                        let tf = DateFormatter()
                        let _ = { tf.dateStyle = .none; tf.timeStyle = .short }()
                        Text(tf.string(from: t))
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.brandPrimary)
                    } else {
                        Text("Date TBD")
                            .font(Theme.bodyBold)
                            .foregroundStyle(Theme.textPrimary)
                        Text("The pro will confirm the exact time")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(Theme.spacingM)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(Theme.brandPrimary.opacity(0.3), lineWidth: 1))

            // Technician row — only shown when assignedTechName is explicitly set in Firestore.
            // proName is the business owner and must NOT be used as a fallback here.
            if !assignedTechName.isEmpty {
                HStack(spacing: Theme.spacingS) {
                    Image(systemName: "person.fill.checkmark")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.brandPrimary)
                    (Text("Your technician will be ")
                        .font(Theme.bodyRegular)
                        .foregroundStyle(Theme.textSecondary)
                    + Text(assignedTechName)
                        .font(Theme.bodyBold)
                        .foregroundStyle(Theme.textPrimary))
                }
                .padding(.horizontal, Theme.spacingS)
            }

        }
    }

    // MARK: – Pro identity

    private var proIdentityCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            // Company row
            HStack(spacing: Theme.spacingM) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: [Color(hex: 0x2979FF).opacity(0.22),
                                     Color(hex: 0x2979FF).opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 56, height: 56)
                    if let url = URL(string: lead.logoUrl), !lead.logoUrl.isEmpty {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable()
                                   .scaledToFill()
                                   .frame(width: 56, height: 56)
                                   .clipShape(RoundedRectangle(cornerRadius: 14))
                            default:
                                Image(systemName: "building.2.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Color(hex: 0x2979FF))
                            }
                        }
                    } else {
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color(hex: 0x2979FF))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Company name + verified badge
                    HStack(spacing: 6) {
                        Text(lead.proBusinessName)
                            .font(Theme.bodyBold)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if lead.proStatus == "active" {
                            Label("Verified", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(hex: 0x2979FF))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: 0x2979FF).opacity(0.12), in: Capsule())
                        }
                    }

                    // Star rating row — always shown once credentials are fetched
                    if let creds = credentials {
                        Button { showReviewsSheet = true } label: {
                            HStack(spacing: 4) {
                                proStarRatingView(creds.reviewCount > 0 ? creds.averageRating : 0)
                                if creds.reviewCount > 0 {
                                    Text(String(format: "%.1f", creds.averageRating))
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("(\(creds.reviewCount) reviews)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(hex: 0x2979FF))
                                } else {
                                    Text("No reviews yet")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x2979FF).opacity(creds.reviewCount > 0 ? 1 : 0.4))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // Expert name
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text(lead.proName)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Device context
                    if !lead.deviceModel.isEmpty || !lead.symptom.isEmpty {
                        let context = [lead.deviceModel, lead.symptom]
                            .filter { !$0.isEmpty }.joined(separator: " — ")
                        Text(context)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color(hex: 0x2979FF).opacity(0.5),
                                 Color(hex: 0x2979FF).opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color(hex: 0x2979FF).opacity(0.12), radius: 12, y: 4)
    }

    // MARK: – Action buttons

    private var actionRow: some View {
        VStack(spacing: Theme.spacingS) {
            // Call + Message
            HStack(spacing: Theme.spacingM) {
                if let phone = lead.proPhone {
                    Button {
                        if let url = URL(string: "tel://\(phone.filter(\.isNumber))") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Call Pro", systemImage: "phone.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingS)
                            .background(Theme.brandSecondary, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let url = URL(string: "sms:\(phone.filter(\.isNumber))") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Message", systemImage: "message.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingS)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Reschedule — only shown for scheduled appointments
            if isScheduled {
                if isRescheduling {
                    VStack(spacing: Theme.spacingS) {
                        Text("Pick a new date & time")
                            .font(Theme.bodyBold)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        DatePicker("", selection: $rescheduleDate,
                                   in: Date()...,
                                   displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .colorScheme(.dark)

                        HStack(spacing: Theme.spacingM) {
                            Button("Cancel") {
                                withAnimation { isRescheduling = false }
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .buttonStyle(.plain)

                            Button("Confirm") {
                                let t = rescheduleDate
                                // Optimistic UI — show pending state immediately.
                                // scheduledTime is NOT updated yet; the API writes
                                // rescheduleRequest to the lead and notifies the contractor.
                                // liveScheduledTime only changes when reschedule_accepted push arrives.
                                reschedulePending = true
                                withAnimation { isRescheduling = false }
                                NotificationCenter.default.post(
                                    name: AppDelegate.rescheduleRequestedByUserNotification,
                                    object: nil,
                                    userInfo: ["leadId": lead.leadId]
                                )
                                postRescheduleRequestedNotification()
                                Task {
                                    let ok = await FirebaseService.shared.rescheduleJob(leadId: lead.leadId, newTime: t)
                                    if !ok {
                                        // API failed — revert optimistic state
                                        reschedulePending = false
                                        NotificationCenter.default.post(
                                            name: AppDelegate.rescheduleRequestedByUserNotification,
                                            object: nil,
                                            userInfo: ["leadId": lead.leadId, "revert": true]
                                        )
                                    }
                                }
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.brandPrimary, in: RoundedRectangle(cornerRadius: 14))
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.spacingM)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.brandPrimary.opacity(0.3), lineWidth: 1))
                } else {
                    Button {
                        withAnimation { isRescheduling = true }
                    } label: {
                        Label("Request Reschedule", systemImage: "calendar.badge.clock")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.brandPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingS)
                            .background(Theme.brandPrimary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.brandPrimary.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: – Credentials (license + insurance)

    @ViewBuilder
    private func credentialsSection(_ c: ContractorCredentials) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            // Section header
            HStack(spacing: Theme.spacingS) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x2979FF))
                Text("License & Insurance")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(spacing: 0) {
                // License
                if !c.licenseNumber.isEmpty {
                    credRow(icon: "checkmark.seal.fill",
                            label: "License #\(c.licenseNumber)",
                            detail: expiryLabel("Expires", c.licenseExpiry))
                    Divider().background(.white.opacity(0.08))
                }

                // Insurance
                if !c.insurancePolicyNumber.isEmpty {
                    credRow(icon: "umbrella.fill",
                            label: "Policy #\(c.insurancePolicyNumber)",
                            detail: expiryLabel("Expires", c.insuranceExpiry))
                    Divider().background(.white.opacity(0.08))
                }

                // View certificate button
                if !c.licenseCertificateUrl.isEmpty {
                    Button {
                        showCertSheet = true
                    } label: {
                        HStack(spacing: Theme.spacingS) {
                            Image(systemName: "doc.viewfinder")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: 0x2979FF))
                                .frame(width: 20)
                            Text("View License Certificate")
                                .font(Theme.bodyRegular)
                                .foregroundStyle(Color(hex: 0x2979FF))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, Theme.spacingM)
                        .padding(.vertical, Theme.spacingS)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(Color(hex: 0x2979FF).opacity(0.18), lineWidth: 1))
        }
    }

    private func credRow(icon: String, label: String, detail: String) -> some View {
        HStack(spacing: Theme.spacingM) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, Theme.spacingS)
    }

    private func expiryLabel(_ prefix: String, _ dateStr: String) -> String {
        guard !dateStr.isEmpty else { return "" }
        // Parse ISO date strings like "2027-04-29"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: dateStr) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .none
            return "\(prefix) \(display.string(from: date))"
        }
        return "\(prefix) \(dateStr)"
    }

    // MARK: – Address sharing note

    private var addressSharedNote: some View {
        HStack(spacing: Theme.spacingS) {
            Image(systemName: "location.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x2979FF).opacity(0.8))
            Text("Your address has been shared with **\(lead.proName)** for the service visit.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
            .strokeBorder(Color(hex: 0x2979FF).opacity(0.18), lineWidth: 1))
    }

    // MARK: – Subtext

    private var subtext: some View {
        HStack(spacing: Theme.spacingS) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            Text("Your AI diagnostic and photos have been shared. **\(lead.proName)** will reach out shortly.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
            .strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }

    // MARK: – Local notification: reschedule request sent

    private func postRescheduleRequestedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Reschedule Request Sent"
        content.body  = "Waiting for confirmation from \(lead.proName.isEmpty ? "your technician" : lead.proName)."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "reschedule_pending_\(lead.leadId)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: – Dispatch listener

    /// Opens a real-time snapshot listener on the lead document.
    /// Handles two live transitions:
    ///  1. status → "enRoute" : shows animated dispatch banner with ETA.
    ///  2. rescheduleRequest   : drives reschedulePending state (fast path alongside push).
    private func startDispatchListener() {
        guard leadListener == nil, !lead.leadId.isEmpty else { return }
        let db = Firestore.firestore()
        leadListener = db.collection("leads").document(lead.leadId)
            .addSnapshotListener { snapshot, _ in
                guard let data = snapshot?.data() else { return }

                // ── En route ─────────────────────────────────────────────
                if let status = data["status"] as? String, status == "enRoute" {
                    let eta = (data["estimatedArrival"] as? Timestamp)?.dateValue()
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.4)) {
                            self.isEnRoute   = true
                            self.dispatchETA = eta
                        }
                    }
                }

                // ── Reschedule request field (Firestore fallback) ────────
                // Fast path is push notifications (reschedule_accepted / reschedule_declined).
                // This listener handles the case where the app is foregrounded but the push
                // hasn't arrived yet, or the app was backgrounded when the contractor responded.
                if let reqDict = data["rescheduleRequest"] as? [String: Any] {
                    let reqStatus = reqDict["status"] as? String ?? ""
                    DispatchQueue.main.async {
                        switch reqStatus {
                        case "pending":
                            // API wrote rescheduleRequest — homeowner is waiting for approval.
                            self.reschedulePending = true

                        case "resolved", "accepted":
                            // Contractor accepted — scheduledTime in the doc has been updated.
                            self.reschedulePending = false
                            if let ts = data["scheduledTime"] as? Timestamp {
                                self.liveScheduledTime = ts.dateValue()
                            }

                        case "declined":
                            self.reschedulePending = false

                        default:
                            break
                        }
                    }
                } else if data["rescheduleRequest"] == nil, self.reschedulePending {
                    // Field was removed (API cleared it after accept/decline).
                    // Push notification is the authoritative source; clear pending optimistically.
                    DispatchQueue.main.async { self.reschedulePending = false }
                }
            }
    }

    // MARK: – Dispatch banner

    @State private var glowPulse = false

    private var dispatchBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: .green.opacity(glowPulse ? 0.9 : 0.3), radius: glowPulse ? 6 : 2)
                .scaleEffect(glowPulse ? 1.3 : 1.0)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: glowPulse)
                .onAppear { glowPulse = true }

            VStack(alignment: .leading, spacing: 2) {
                Text("Pro En Route")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                if let eta = dispatchETA {
                    let mins = max(0, Int(eta.timeIntervalSinceNow / 60))
                    Text(mins > 0
                         ? "\(lead.proName) is ~\(mins) min\(mins == 1 ? "" : "s") away"
                         : "\(lead.proName) is on the way")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Text("\(lead.proName) is on the way")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.green.opacity(0.45), lineWidth: 0.5))
        .shadow(color: .green.opacity(0.2), radius: 10, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

