// Views/Home/HomeView.swift
import SwiftUI
import PhotosUI

struct HomeView: View {
    @State private var viewModel         = HomeViewModel()
    @State private var showDiagnoseSheet = false
    @State private var showProfileSheet  = false
    @State private var videoPickerItem: PhotosPickerItem? = nil
    @State private var showListenSheet   = false
    @State private var sessionToResume: ActiveSession? = nil
    @State private var showAllHistory      = false
    @State private var selectedServiceLead: ActiveServiceLead? = nil
    @State private var rescheduleJob:       ServiceJob?         = nil
    @State private var sessionToDelete:     ActiveSession?      = nil
    @State private var leadToCancel:        ServiceJob?         = nil
    @State private var jobToResolve:        ServiceJob?         = nil   // "Yes, fixed" → resolution sheet
    @State private var jobToRescheduleFromPast: ServiceJob?     = nil   // "Not yet" → reschedule dialog


    private let columns = [
        GridItem(.flexible(), spacing: Theme.spacingM),
        GridItem(.flexible(), spacing: Theme.spacingM)
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                backgroundGradient.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Theme.spacingXL) {
                        greetingHeader
                        // Service and repair cards are only meaningful when signed in.
                        // On sign-out, AuthService posts authSignedOutNotification which
                        // calls clearAllData() — but also guard here to avoid ghost cards.
                        if AuthService.shared.isSignedIn {
                            // Live status bars — one per en-route pro
                            if !viewModel.enRouteJobs.isEmpty {
                                VStack(spacing: 6) {
                                    ForEach(viewModel.enRouteJobs) { job in
                                        LiveStatusOverlay(job: job)
                                    }
                                }
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            // Scheduled bars — one per confirmed appointment
                            if !viewModel.scheduledJobs.isEmpty {
                                VStack(spacing: 6) {
                                    ForEach(viewModel.scheduledJobs) { job in
                                        ScheduledStatusBar(
                                            job: job,
                                            proRescheduled: viewModel.proRescheduledLeadIds.contains(job.id),
                                            homeAddress: viewModel.homeAddress
                                        )
                                    }
                                }
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            // Horizontal activity carousel (service + continue repair)
                            if !viewModel.jobs.isEmpty || !viewModel.activeSessions.isEmpty {
                                activityCarousel
                            }
                        }
                        chatFirstInput          // ← describe-first entry point
                        categoryGrid
                        if AuthService.shared.isSignedIn {
                            recentRepairsSection
                        }
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.top, Theme.spacingM)
                }

                diagnoseButton
                    .padding(.bottom, Theme.spacingL)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbarContent }
            // Chat-first navigation
            .navigationDestination(item: $viewModel.chatFirstGuide) { guide in
                RepairHubView(guide: guide, capturedImage: nil, isChatFirst: true)
            }
            // Media upload navigation
            .navigationDestination(item: $viewModel.mediaGuide) { guide in
                RepairHubView(guide: guide, capturedImage: nil, isChatFirst: true)
            }
            // Save & Resume navigation
            .navigationDestination(item: $sessionToResume) { session in
                RepairHubView(resuming: session)
            }
            // "See All" history navigation
            .navigationDestination(isPresented: $showAllHistory) {
                HistoryView()
            }
            // Camera sheet — passes any typed description into the diagnosis payload.
            // onChange(false) fires when the sheet closes (e.g. after a pause) so
            // the Activity carousel refreshes even if onAppear doesn't re-fire.
            .sheet(isPresented: $showDiagnoseSheet) {
                CameraView(
                    category:        viewModel.chatFirstCategory,
                    userDescription: viewModel.chatFirstText,
                    onRepairExited:  { showDiagnoseSheet = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: showDiagnoseSheet) { _, isShowing in
                if !isShowing { Task { await viewModel.refreshActiveSession() } }
            }
            // Profile sheet
            .sheet(isPresented: $showProfileSheet) {
                ProfileSheetView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            // Listen-mode camera sheet — also carries the typed description
            .sheet(isPresented: $showListenSheet) {
                CameraView(
                    category:        viewModel.chatFirstCategory,
                    startInListenMode: true,
                    userDescription: viewModel.chatFirstText,
                    onRepairExited:  { showListenSheet = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: showListenSheet) { _, isShowing in
                if !isShowing { Task { await viewModel.refreshActiveSession() } }
            }
            // Active Service sheet — always full height so all content is interactive.
            // .medium detent adds a pan recognizer that consumes taps in the lower half.
            .sheet(item: $selectedServiceLead) { lead in
                ProServiceCardView(lead: lead, onDismiss: { selectedServiceLead = nil })
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            // Reschedule sheet — calendar icon on any activity card
            .sheet(item: $rescheduleJob) { job in
                RescheduleSheet { newTime in
                    rescheduleJob = nil
                    Task { await FirebaseService.shared.rescheduleJob(leadId: job.id, newTime: newTime) }
                }
                .presentationDetents([.height(460)])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
            }
            // Resolution sheet — "Yes, it's fixed" on a past-appointment card
            .sheet(item: $jobToResolve) { job in
                RepairResolutionSheet(job: job) { notes in
                    viewModel.confirmRepairCompleted(leadId: job.id, resolutionNotes: notes)
                    jobToResolve = nil
                }
                .presentationDetents([.height(380)])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
            }
            // "Not yet" reschedule dialog — asks if the user wants to reschedule
            .confirmationDialog(
                "Need to Reschedule?",
                isPresented: Binding(
                    get: { jobToRescheduleFromPast != nil },
                    set: { if !$0 { jobToRescheduleFromPast = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Yes, Reschedule") {
                    if let job = jobToRescheduleFromPast { rescheduleJob = job }
                    jobToRescheduleFromPast = nil
                }
                Button("No, Keep as Is", role: .cancel) { jobToRescheduleFromPast = nil }
            } message: {
                Text("The appointment time has passed. Would you like to request a new time?")
            }
            // Delete paused repair confirmation
            .confirmationDialog(
                "Remove Paused Repair?",
                isPresented: Binding(
                    get: { sessionToDelete != nil },
                    set: { if !$0 { sessionToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let s = sessionToDelete { viewModel.deletePausedSession(s) }
                    sessionToDelete = nil
                }
                Button("Cancel", role: .cancel) { sessionToDelete = nil }
            } message: {
                Text("This will remove the paused repair from your activity. Your chat history will be cleared.")
            }
            // Cancel service lead confirmation
            .confirmationDialog(
                "Cancel Service Request?",
                isPresented: Binding(
                    get: { leadToCancel != nil },
                    set: { if !$0 { leadToCancel = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Cancel Request", role: .destructive) {
                    if let job = leadToCancel { viewModel.cancelServiceLead(leadId: job.id) }
                    leadToCancel = nil
                }
                Button("Keep", role: .cancel) { leadToCancel = nil }
            } message: {
                Text("This will remove the service card from your activity. The pro will not be automatically notified.")
            }
            // Refresh active session every time HomeView appears (e.g. after a repair completes)
            .onAppear {
                Task { await viewModel.refreshActiveSession() }
            }
            // Auto-present ProServiceCardView when a new lead is claimed
            .onChange(of: viewModel.lastClaimedLead) { _, lead in
                if let lead {
                    selectedServiceLead = lead
                    viewModel.lastClaimedLead = nil
                }
            }
            // Calendar deep link (fixie://lead/{leadId}) → open the matching job card
            .onReceive(NotificationCenter.default.publisher(
                for: AppDelegate.deepLinkLeadNotification)
            ) { note in
                guard let leadId = note.userInfo?["leadId"] as? String else { return }
                if let match = viewModel.activeServiceLeads.first(where: { $0.leadId == leadId }) {
                    selectedServiceLead = match
                } else {
                    Task {
                        await viewModel.refreshActiveSession()
                        if let match = viewModel.activeServiceLeads.first(where: { $0.leadId == leadId }) {
                            selectedServiceLead = match
                        }
                    }
                }
            }
            // Dispatch push tap → open the matching job card immediately
            .onReceive(NotificationCenter.default.publisher(
                for: AppDelegate.dispatchTappedNotification)
            ) { note in
                guard let leadId = note.userInfo?["leadId"] as? String else { return }
                if let match = viewModel.activeServiceLeads.first(where: { $0.leadId == leadId }) {
                    selectedServiceLead = match
                } else {
                    // Lead not yet in memory — refresh then present
                    Task {
                        await viewModel.refreshActiveSession()
                        if let match = viewModel.activeServiceLeads.first(where: { $0.leadId == leadId }) {
                            selectedServiceLead = match
                        }
                    }
                }
            }
            // Reschedule push tap (type:"reschedule") — the PRO changed the appointment time.
            // Mark the card amber + "RESCHEDULED" so the user knows, then open the card.
            .onReceive(NotificationCenter.default.publisher(
                for: AppDelegate.rescheduleTappedNotification)
            ) { note in
                guard let leadId = note.userInfo?["leadId"] as? String else { return }
                viewModel.proRescheduledLeadIds.insert(leadId)
                Task {
                    await viewModel.refreshActiveSession()
                    if let match = viewModel.activeServiceLeads.first(where: { $0.leadId == leadId }) {
                        selectedServiceLead = match
                    }
                }
            }
            // Pro accepted reschedule — clear pending, refresh, and re-open card with new time.
            .onReceive(NotificationCenter.default.publisher(
                for: AppDelegate.rescheduleAcceptedNotification)
            ) { note in
                guard let leadId = note.userInfo?["leadId"] as? String else { return }
                viewModel.clearReschedulePending(leadId: leadId)
                Task {
                    await viewModel.refreshActiveSession()
                    if let match = viewModel.activeServiceLeads.first(where: { $0.leadId == leadId }) {
                        selectedServiceLead = match
                    }
                }
            }
            // Homeowner confirmed reschedule → mark card pending.
            // If API later fails (revert:true) → clear the flag.
            .onReceive(NotificationCenter.default.publisher(
                for: AppDelegate.rescheduleRequestedByUserNotification)
            ) { note in
                guard let leadId = note.userInfo?["leadId"] as? String else { return }
                if note.userInfo?["revert"] as? Bool == true {
                    viewModel.clearReschedulePending(leadId: leadId)
                } else {
                    viewModel.markReschedulePending(leadId: leadId)
                }
            }
            // Pro declined reschedule — clear pending state and refresh.
            .onReceive(NotificationCenter.default.publisher(
                for: AppDelegate.rescheduleDeclinedNotification)
            ) { note in
                guard let leadId = note.userInfo?["leadId"] as? String else { return }
                viewModel.clearReschedulePending(leadId: leadId)
                Task { await viewModel.refreshActiveSession() }
            }
            // Video selection handler
            .onChange(of: videoPickerItem) { _, item in
                guard let item else { return }
                videoPickerItem = nil
                Task { await viewModel.analyzeVideo(pickerItem: item) }
            }
            // Media analysis loading overlay
            .overlay {
                if viewModel.isAnalyzingMedia {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: Theme.spacingM) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Theme.brandPrimary))
                                .scaleEffect(1.4)
                            Text("Analyzing your media…")
                                .font(Theme.bodyBold)
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(Theme.spacingXL)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                    }
                }
            }
        }
    }

    // MARK: – Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(hex: 0x0D0D0F), Color(hex: 0x111318), Color(hex: 0x141820)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: – Header

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            Text("Fixie AI")
                .font(Theme.titleLarge)
                .foregroundStyle(Theme.textPrimary)
            Text("What needs fixing today?")
                .font(Theme.bodyRegular)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: – Chat-First Input  ← NEW

    private var chatFirstInput: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            sectionLabel("Describe Your Problem")

            HStack(spacing: Theme.spacingS) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)

                TextField("e.g. dryer runs but no heat…", text: $viewModel.chatFirstText)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit { viewModel.submitChatFirst() }

                if !viewModel.chatFirstText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        viewModel.submitChatFirst()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.brandPrimary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.vertical, Theme.spacingS)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusM)
                .strokeBorder(Theme.brandPrimary.opacity(0.2), lineWidth: 1))

            // Media upload row
            HStack(spacing: Theme.spacingS) {
                PhotosPicker(selection: $videoPickerItem,
                             matching: .videos,
                             photoLibrary: .shared()) {
                    Label("Upload Video", systemImage: "video.badge.plus")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.spacingM)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showListenSheet = true
                } label: {
                    Label("Listen & Diagnose", systemImage: "waveform.badge.mic")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.spacingM)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Category chip row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingS) {
                    ForEach(RepairCategory.allCases) { cat in
                        Button {
                            viewModel.chatFirstCategory = (viewModel.chatFirstCategory == cat) ? nil : cat
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(cat.rawValue)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(viewModel.chatFirstCategory == cat ? .black : cat.accentColor)
                            .padding(.horizontal, Theme.spacingM)
                            .padding(.vertical, 7)
                            .background(
                                viewModel.chatFirstCategory == cat
                                    ? AnyShapeStyle(cat.accentColor)
                                    : AnyShapeStyle(cat.accentColor.opacity(0.12)),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.25), value: viewModel.chatFirstCategory)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    // MARK: – Category Grid

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            sectionLabel("Categories")
            LazyVGrid(columns: columns, spacing: Theme.spacingM) {
                ForEach(RepairCategory.allCases) { category in
                    CategoryCardView(category: category) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        viewModel.startNewRepair(category: category)
                        showDiagnoseSheet = true
                    }
                }
            }
        }
    }

    // MARK: – Recent Repairs

    private var recentRepairsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            HStack {
                sectionLabel("Recent Repairs")
                Spacer()
                if !viewModel.recentSessions.isEmpty {
                    Button("See All") { showAllHistory = true }
                        .font(Theme.caption)
                        .foregroundStyle(Theme.brandPrimary)
                }
            }

            if viewModel.isLoading {
                VStack(spacing: Theme.spacingS) {
                    ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
                }
            } else if viewModel.filteredSessions.isEmpty {
                emptyRecentState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.spacingM) {
                        ForEach(viewModel.filteredSessions) { session in
                            RecentRepairCardView(session: session)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private var emptyRecentState: some View {
        HStack {
            Spacer()
            VStack(spacing: Theme.spacingS) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.textTertiary)
                Text("No repairs yet.\nTap diagnose to get started.")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, Theme.spacingXL)
            Spacer()
        }
    }

    // MARK: – FAB

    private var diagnoseButton: some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            viewModel.selectedCategory = nil
            showDiagnoseSheet = true
        } label: {
            HStack(spacing: Theme.spacingS) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                Text("Point & Diagnose")
                    .font(Theme.bodyBold)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, Theme.spacingXL)
            .padding(.vertical, Theme.spacingM)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [Theme.brandPrimary, Color(hex: 0x29B6F6)],
                    startPoint: .leading, endPoint: .trailing
                ))
            )
            .shadow(color: Theme.brandPrimary.opacity(0.55), radius: 20, y: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: – Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Image("FixieLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showProfileSheet = true } label: {
                let auth = AuthService.shared
                if auth.isSignedIn, let user = auth.currentUser {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Theme.brandPrimary, Color(hex: 0x29B6F6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(width: 30, height: 30)
                        if !user.photoURL.isEmpty, let url = URL(string: user.photoURL) {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable()
                                       .scaledToFill()
                                       .frame(width: 30, height: 30)
                                       .clipShape(Circle())
                                } else {
                                    Text(user.avatarInitials)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.black)
                                }
                            }
                        } else {
                            Text(user.avatarInitials)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                        }
                    }
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: – Activity Carousel

    /// Thumbnail loaded from the active session's saved image path.
    private var sessionThumbnail: UIImage? {
        guard let stored = viewModel.activeSession?.imagePath else { return nil }
        return UIImage(contentsOfFile: RepairChatViewModel.resolvedImagePath(stored))
    }

    private var activityCarousel: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            sectionLabel("Activity")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingM) {
                    // Job cards (service leads)
                    ForEach(viewModel.jobs) { job in
                        JobActivityCard(
                            job: job,
                            thumbnail: job.status == .pending ? sessionThumbnail : nil,
                            proRescheduled: viewModel.proRescheduledLeadIds.contains(job.id),
                            onReschedule: { rescheduleJob = job },
                            onDelete: { leadToCancel = job },
                            onRepairConfirmed: { jobToResolve = job },
                            onNotYet: { jobToRescheduleFromPast = job }
                        ) {
                            // Clear "rescheduled" badge when user opens the card
                            viewModel.proRescheduledLeadIds.remove(job.id)
                            if let lead = job.lead {
                                // Claimed lead → open ProServiceCardView
                                selectedServiceLead = lead
                            } else if job.status == .pending,
                                      let session = viewModel.activeSession {
                                // Pending lead → return to the repair where the request was made
                                sessionToResume = session
                            }
                        }
                    }
                    // Continue Repair cards — one per paused session.
                    // Hidden when a claimed/active service lead already covers the session
                    // (the JobActivityCard shows the lead status instead).
                    ForEach(viewModel.activeSessions.filter { session in
                        guard let leadId = session.pendingLeadId else { return true }
                        return !viewModel.activeServiceLeads.contains { $0.leadId == leadId }
                    }) { session in
                        ContinueRepairCard(
                            session: session,
                            onDelete: { sessionToDelete = session }
                        ) {
                            guard session.pendingLeadId == nil else { return }
                            sessionToResume = session
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: – Helper

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.titleMedium)
            .foregroundStyle(Theme.textPrimary)
    }
}

// MARK: – Scheduled Status Bar

private struct ScheduledStatusBar: View {
    let job:            ServiceJob
    var proRescheduled: Bool = false
    /// Supplies the user's home address for the calendar event location field.
    var homeAddress:    String = ""

    @State private var isSyncingCalendar = false

    private var calendarManager: CalendarManager { CalendarManager.shared }

    private var barColor: Color {
        if job.reschedulePending { return .orange }
        if proRescheduled        { return Color(hex: 0xFFC107) }
        return job.categoryAccentColor
    }

    private var barIcon: String {
        if job.reschedulePending { return "clock.badge.questionmark" }
        if proRescheduled        { return "calendar.badge.exclamationmark" }
        return "calendar.badge.checkmark"
    }

    private var barTitle: String {
        if job.reschedulePending { return "Reschedule Pending" }
        if proRescheduled {
            let biz = job.proBusinessName.isEmpty ? job.proName : job.proBusinessName
            return "Rescheduled by \(biz)"
        }
        return "Appointment Scheduled"
    }

    private var formattedTime: String {
        guard let t = job.scheduledTime else { return "Appointment confirmed" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: t)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(barColor)
                .frame(width: 8, height: 8)
                .shadow(color: barColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(barTitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(barColor)
                let name = job.proBusinessName.isEmpty ? job.proName : job.proBusinessName
                let subtitle = (proRescheduled || job.reschedulePending)
                    ? formattedTime
                    : (name.isEmpty ? formattedTime : "\(name) · \(formattedTime)")
                Text(subtitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer()

            // "Add to Calendar" — shown only when permission has not been granted yet.
            // Once granted, sync happens automatically and this button disappears.
            if !calendarManager.isAuthorized, let lead = job.lead {
                Button {
                    isSyncingCalendar = true
                    Task {
                        await calendarManager.requestAndSync(lead: lead, userAddress: homeAddress)
                        isSyncingCalendar = false
                    }
                } label: {
                    if isSyncingCalendar {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: barColor))
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(barColor)
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
            }

            Image(systemName: barIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(barColor)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(barColor.opacity(0.4), lineWidth: 0.5))
        .shadow(color: barColor.opacity(0.15), radius: 10, y: 4)
        .padding(.horizontal, 16)
    }
}

// MARK: – Job Activity Card

private struct JobActivityCard: View {
    let job:                ServiceJob
    let thumbnail:          UIImage?       // optional captured photo (used for pending jobs)
    let proRescheduled:     Bool           // pro changed the appointment time (cloud push received)
    let onReschedule:       () -> Void
    var onDelete:           (() -> Void)? = nil
    var onRepairConfirmed:  (() -> Void)? = nil  // "Yes, it's fixed!" → HomeView shows resolution sheet
    var onNotYet:           (() -> Void)? = nil  // "Not yet" → HomeView asks about reschedule
    let onTap:              () -> Void

    @State private var glowPulse = false

    private let cardW: CGFloat = 240
    private let cardH: CGFloat = 130

    private var scheduledLabel: String? {
        guard let t = job.scheduledTime else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: t)
    }

    /// Orange for homeowner-pending reschedule; amber for pro-changed; category color for normal.
    var statusColor: Color {
        switch job.status {
        case .pending:   return Color(hex: 0x2979FF)
        case .claimed:   return job.categoryAccentColor
        case .scheduled:
            if job.reschedulePending { return .orange }
            if proRescheduled        { return Color(hex: 0xFFC107) }  // amber
            return job.categoryAccentColor
        case .enRoute:   return .green
        case .arrived:   return .green
        case .completed: return .gray
        }
    }

    var statusLabel: String {
        switch job.status {
        case .pending:   return "WAITING FOR PRO"
        case .claimed:   return "PRO ASSIGNED"
        case .scheduled:
            if job.reschedulePending { return "RESCHEDULE PENDING" }
            if proRescheduled        { return "RESCHEDULED" }
            return "SCHEDULED"
        case .enRoute:   return "PRO EN ROUTE"
        case .arrived:   return "PRO ARRIVED"
        case .completed: return "COMPLETED"
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                // Background: photo thumbnail (pending) or Liquid Glass
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: cardW, height: cardH)
                            .clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(.ultraThinMaterial)
                            .frame(width: cardW, height: cardH)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))

                // Scrim over photo so text stays readable
                if thumbnail != nil {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .frame(width: cardW, height: cardH)
                }

                // Border / glow
                let isLive = job.status == .enRoute || job.status == .arrived
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(
                        isLive
                            ? AnyShapeStyle(LinearGradient(
                                colors: [.green.opacity(glowPulse ? 1.0 : 0.4), .green.opacity(0.1)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(statusColor.opacity(
                                (job.status == .claimed || job.status == .scheduled)
                                    ? (glowPulse ? 0.7 : 0.25) : (thumbnail != nil ? 0.5 : 0.12)
                              )),
                        lineWidth: isLive ? 1.5 : 0.5
                    )
                    .frame(width: cardW, height: cardH)
                    .shadow(color: isLive
                                ? .green.opacity(glowPulse ? 0.5 : 0.15)
                                : (job.status == .claimed || job.status == .scheduled
                                    ? statusColor.opacity(glowPulse ? 0.35 : 0.08) : .clear),
                            radius: glowPulse ? 10 : 3)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: glowPulse)

                // Content — all anchored to bottom-leading
                VStack(alignment: .leading, spacing: 4) {
                    Spacer()

                    Text(statusLabel)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(statusColor)
                        .tracking(0.5)

                    // Logo + business name on one row
                    HStack(spacing: 8) {
                        if thumbnail == nil {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(statusColor.opacity(0.15))
                                if !job.logoUrl.isEmpty, let url = URL(string: job.logoUrl) {
                                    AsyncImage(url: url) { phase in
                                        if case .success(let img) = phase {
                                            img.resizable().scaledToFit()
                                        } else {
                                            Image(systemName: "wrench.and.screwdriver.fill")
                                                .font(.system(size: 12)).foregroundStyle(statusColor)
                                        }
                                    }
                                    .padding(4)
                                } else {
                                    Image(systemName: job.status == .pending
                                          ? "clock.fill" : "wrench.and.screwdriver.fill")
                                        .font(.system(size: 12)).foregroundStyle(statusColor)
                                }
                            }
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }

                        Text(job.proBusinessName.isEmpty ? job.proName : job.proBusinessName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }

                    let itemLabel = job.deviceModel.isEmpty ? job.symptom : job.deviceModel
                    if !itemLabel.isEmpty {
                        Text(itemLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    // Pro-rescheduled attribution row
                    if proRescheduled && job.status == .scheduled {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.exclamationmark")
                                .font(.system(size: 9))
                                .foregroundStyle(statusColor)
                            let biz = job.proBusinessName.isEmpty ? job.proName : job.proBusinessName
                            Text("By \(biz)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                        }
                    }

                    // Pending reschedule subtitle
                    if job.reschedulePending && job.status == .scheduled {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            Text("Awaiting confirmation")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }

                    // Scheduled time row — shown when a time has been confirmed
                    if let label = scheduledLabel {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(statusColor)
                            Text(label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(14)

                // Reschedule icon — top trailing
                let showReschedule = job.status != .completed && !job.reschedulePending && !proRescheduled
                if showReschedule {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: onReschedule) {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .padding(10)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }

                // Trash icon — bottom trailing (hidden when pro is already en route/arrived)
                let canDelete = onDelete != nil
                    && job.status != .enRoute && job.status != .arrived
                if canDelete {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button { onDelete?() } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .padding(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Past-appointment overlay — shown when scheduled time has elapsed.
                if job.isAppointmentPast {
                    ZStack {
                        Color.black.opacity(0.75)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                        VStack(spacing: 6) {
                            Text("Appointment passed")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                                .tracking(0.3)
                            Text("Was it repaired?")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            HStack(spacing: 10) {
                                Button { onRepairConfirmed?() } label: {
                                    Text("Yes, fixed ✓")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Theme.brandPrimary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                Button { onNotYet?() } label: {
                                    Text("Not yet")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(.white.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: cardW, height: cardH)
                    .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            if job.status == .enRoute || job.status == .arrived
                || job.status == .claimed || job.status == .scheduled
                || job.reschedulePending || proRescheduled {
                glowPulse = true
            }
        }
    }
}

// MARK: – Continue Repair Card

private struct ContinueRepairCard: View {
    let session:  ActiveSession
    let onDelete: () -> Void
    let onTap:    () -> Void

    private let cardW: CGFloat = 200
    private let cardH: CGFloat = 120

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                // Background: repair photo or solid
                if let stored = session.imagePath,
                   let img = UIImage(contentsOfFile: RepairChatViewModel.resolvedImagePath(stored)) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardW, height: cardH)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(width: cardW, height: cardH)
                }

                // Scrim
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center, endPoint: .bottom
                )
                .frame(width: cardW, height: cardH)

                // Text
                let isPending = session.pendingLeadId != nil
                VStack(alignment: .leading, spacing: 3) {
                    Text(isPending ? "WAITING FOR PRO" : "CONTINUE REPAIR")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(isPending ? .orange : Theme.brandPrimary)
                        .tracking(0.5)
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: cardW - 24, alignment: .leading)
                    Text(isPending ? "Awaiting confirmation" : session.progressLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(12)

                // Border
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder((isPending ? Color.orange : Theme.brandPrimary).opacity(0.5), lineWidth: 0.5)
                    .frame(width: cardW, height: cardH)

                // Trash button — bottom trailing
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                                .padding(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: cardW, height: cardH)
            }
            .frame(width: cardW, height: cardH)
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}


// MARK: – Repair Resolution Sheet

private struct RepairResolutionSheet: View {
    let job: ServiceJob
    let onSubmit: (String) -> Void   // passes resolution notes

    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @FocusState private var focused: Bool

    private var deviceLabel: String {
        job.deviceModel.isEmpty ? job.symptom : job.deviceModel
    }

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.spacingL) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Repair Complete")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Tell us what was fixed on your \(deviceLabel) so we can update your history and notify \(job.proBusinessName.isEmpty ? "the pro" : job.proBusinessName).")
                        .font(Theme.bodyRegular)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Notes input
                VStack(alignment: .leading, spacing: 8) {
                    Text("What was repaired?")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Color.white.opacity(focused ? 0.25 : 0.08), lineWidth: 1)
                            )
                        if notes.isEmpty {
                            Text("e.g. Replaced the heating element, cleaned filters…")
                                .font(Theme.bodyRegular)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $notes)
                            .font(Theme.bodyRegular)
                            .foregroundStyle(Theme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .focused($focused)
                    }
                    .frame(height: 110)
                }

                // Info pill
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.brandPrimary)
                    Text("An invoice request will be sent to the pro.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(10)
                .background(Theme.brandPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                Spacer()

                // Submit
                Button {
                    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(trimmed.isEmpty ? "Repair confirmed by homeowner." : trimmed)
                } label: {
                    Text("Submit & Move to History")
                        .font(Theme.bodyBold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingM)
                        .background(Theme.brandPrimary, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.spacingL)
        }
        .onAppear { focused = true }
    }
}

#Preview {
    HomeView().preferredColorScheme(.dark)
}
