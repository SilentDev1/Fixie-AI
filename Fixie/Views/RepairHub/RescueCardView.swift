// Views/RepairHub/RescueCardView.swift
// Two-tier contractor results:
//   Tier 1 — "Fixie Verified Pros"  — from Firestore `contractors` collection
//   Tier 2 — "Local Service Providers" — from MapKit (LocalProService)
import SwiftUI
import MapKit

struct RescueCardView: View {
    let category: RepairCategory
    var searchQuery: String?    = nil          // MapKit override for Tier-2
    var guide: RepairGuide?     = nil          // passed to createLead()
    var capturedImage: UIImage? = nil          // uploaded to imageUrls in the lead
    var currentStepIndex: Int   = 0            // steps already attempted
    var chatSummary: String?    = nil          // last AI message → issueSummary in lead
    var chatMessages: [ChatMessage] = []       // full conversation → chatTranscript in lead

    private var chatTranscript: String {
        chatMessages.map { msg in
            let label = msg.role == .user ? "Customer" : "Fixie AI"
            return "[\(label)]: \(msg.text)"
        }.joined(separator: "\n\n")
    }
    var onProCalled:   ((String, String?) -> Void)? = nil
    /// Called after a lead is successfully created. (leadId, proName)
    var onLeadCreated: ((String, String) -> Void)?  = nil

    @State private var verifiedPros:     [VerifiedPro] = []
    @State private var localPros:        [LocalPro]    = []
    @State private var isLoadingVerified = true
    @State private var isLoadingLocal    = true
    @State private var localLoadError:   String?       = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 36, height: 5)
                    .padding(.top, Theme.spacingM)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Theme.spacingL) {
                        headerSection
                        safetyBanner
                        verifiedSection
                        localSection
                        Spacer(minLength: Theme.spacingXL)
                    }
                    .padding(Theme.spacingM)
                }
            }
        }
        .task {
            // Load both tiers concurrently
            async let vLoad: Void = loadVerifiedPros()
            async let lLoad: Void = loadLocalPros()
            _ = await (vLoad, lLoad)
        }
    }

    // MARK: – Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                HStack(spacing: Theme.spacingS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.warningAmber)
                    Text("Pro Rescue")
                        .font(Theme.titleMedium)
                        .foregroundStyle(Theme.textPrimary)
                }
                Text("Local \(category.rawValue.lowercased()) professionals near \(LocationService.shared.cityState.isEmpty ? "your location" : LocationService.shared.cityState)")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: – Safety banner

    private var safetyBanner: some View {
        HStack(spacing: Theme.spacingS) {
            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                .font(.system(size: 18))
                .foregroundStyle(Theme.warningAmber)
            Text("For gas leaks, electrical fires, or flooding — call **911** immediately. Always verify contractor credentials.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.spacingM)
        .background(Theme.warningAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS).strokeBorder(Theme.warningAmber.opacity(0.25), lineWidth: 1))
    }

    // MARK: – Tier 1: Fixie Verified Pros

    private var verifiedSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            sectionHeader(title: "Fixie Verified Pros",
                          icon: "checkmark.seal.fill",
                          color: Color(hex: 0x2979FF))

            if isLoadingVerified {
                shimmerPlaceholders(count: 2, height: 104)
            } else if verifiedPros.isEmpty {
                verifiedEmptyState
            } else {
                ForEach(verifiedPros) { pro in
                    VerifiedProCard(
                        pro:              pro,
                        guide:            guide,
                        capturedImage:    capturedImage,
                        currentStepIndex: currentStepIndex,
                        chatSummary:      chatSummary,
                        chatTranscript:   chatTranscript,
                        onProCalled:      onProCalled,
                        onLeadCreated:    onLeadCreated
                    )
                }
            }
        }
    }

    private var verifiedEmptyState: some View {
        HStack(spacing: Theme.spacingM) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 26))
                .foregroundStyle(Color(hex: 0x2979FF).opacity(0.45))
            VStack(alignment: .leading, spacing: 3) {
                Text("No Fixie Pros in your area yet.")
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textSecondary)
                Text("Try these local providers instead.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color(hex: 0x2979FF).opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: – Tier 2: Local Service Providers

    private var localSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            sectionHeader(title: "Local Service Providers",
                          icon: "map.fill",
                          color: Theme.textSecondary)

            if isLoadingLocal {
                shimmerPlaceholders(count: 3, height: 80)
            } else if let err = localLoadError {
                localErrorState(message: err)
            } else if localPros.isEmpty {
                Text("No local pros found nearby.")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingL)
            } else {
                ForEach(localPros) { pro in
                    ProRowView(pro: pro, onProCalled: onProCalled)
                }
            }
        }
    }

    private func localErrorState(message: String) -> some View {
        VStack(spacing: Theme.spacingS) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 30))
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task {
                    localLoadError    = nil
                    isLoadingLocal    = true
                    await loadLocalPros()
                }
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.brandPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingL)
    }

    // MARK: – Helpers

    private func sectionHeader(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: Theme.spacingS) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(Theme.titleMedium)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func shimmerPlaceholders(count: Int, height: CGFloat) -> some View {
        VStack(spacing: Theme.spacingS) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.radiusS)
                    .fill(.white.opacity(0.06))
                    .frame(height: height)
                    .shimmer()
            }
        }
    }

    // MARK: – Data fetches

    private func loadVerifiedPros() async {
        isLoadingVerified = true
        verifiedPros = await VerifiedProService.shared.fetchPros(for: category)
        isLoadingVerified = false
    }

    private func loadLocalPros() async {
        isLoadingLocal = true
        localLoadError = nil
        do {
            localPros = try await LocalProService.shared.searchPros(
                for:         category,
                customQuery: searchQuery
            )
        } catch {
            localLoadError = error.localizedDescription
        }
        isLoadingLocal = false
    }
}

// MARK: – Verified Pro card (Tier 1)

private struct VerifiedProCard: View {
    let pro: VerifiedPro
    var guide: RepairGuide?     = nil
    var capturedImage: UIImage? = nil
    var currentStepIndex: Int   = 0
    var chatSummary:    String? = nil
    var chatTranscript: String  = ""
    var onProCalled:   ((String, String?) -> Void)? = nil
    var onLeadCreated: ((String, String) -> Void)?  = nil

    @State private var leadSent        = false
    @State private var leadFailed      = false
    @State private var isSending       = false
    @State private var sendStatusText  = ""
    @State private var showReviews     = false
    @State private var showSchedule    = false

    private let verifiedBlue = Color(hex: 0x2979FF)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {

            // ── Name row ──────────────────────────────────────────────────
            HStack(spacing: Theme.spacingM) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: [verifiedBlue.opacity(0.22), verifiedBlue.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 48, height: 48)
                    if !pro.logoUrl.isEmpty, let url = URL(string: pro.logoUrl) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFill()
                                   .frame(width: 48, height: 48)
                                   .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                Image(systemName: "wrench.and.screwdriver.fill")
                                    .font(.system(size: 20)).foregroundStyle(verifiedBlue)
                            }
                        }
                    } else {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(verifiedBlue)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pro.name)
                            .font(Theme.bodyBold)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(verifiedBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(verifiedBlue.opacity(0.12), in: Capsule())
                    }

                    // Rating row — tappable to see reviews
                    Button { showReviews = true } label: {
                        HStack(spacing: 4) {
                            proStarRatingView(pro.reviewCount > 0 ? pro.averageRating : 0)
                            if pro.reviewCount > 0 {
                                Text(String(format: "%.1f", pro.averageRating))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("(\(pro.reviewCount))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(verifiedBlue)
                            } else {
                                Text("No reviews yet")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if !pro.address.isEmpty {
                        Text(pro.address)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    if let dist = pro.distanceKm {
                        Text(String(format: "%.1f mi away", dist * 0.621371))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
            }
            .sheet(isPresented: $showReviews) {
                ProReviewsSheet(
                    proId:         pro.id,
                    businessName:  pro.name,
                    averageRating: pro.averageRating,
                    reviewCount:   pro.reviewCount
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(hex: 0x0D0D0F))
            }

            Divider().background(.white.opacity(0.07))

            // ── Actions / Confirmation ────────────────────────────────────
            if leadSent {
                // Success confirmation banner
                VStack(spacing: 6) {
                    HStack(spacing: Theme.spacingS) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("Request sent!")
                            .font(Theme.bodyBold)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    Text("\(pro.name) has received your diagnostic data and will contact you shortly.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Theme.spacingM)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.green.opacity(0.3), lineWidth: 1))
                .transition(.move(edge: .bottom).combined(with: .opacity))

            } else {
                HStack(spacing: Theme.spacingS) {
                    // Schedule — opens ScheduleRepairSheet → creates lead
                    Button { showSchedule = true } label: {
                        HStack(spacing: 6) {
                            if isSending {
                                ProgressView().tint(.black).scaleEffect(0.75)
                                Text(sendStatusText)
                                    .font(.system(size: 12, weight: .semibold))
                            } else {
                                Label("Schedule", systemImage: "calendar.badge.clock")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, Theme.spacingM)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(verifiedBlue, in: Capsule())
                        .animation(.easeInOut(duration: 0.2), value: isSending)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .sheet(isPresented: $showSchedule) {
                        ScheduleRepairSheet { isASAP, requestedTime in
                            showSchedule   = false
                            isSending      = true
                            leadFailed     = false
                            sendStatusText = capturedImage != nil ? "Uploading image…" : "Sending request…"
                            Task {
                                let docId = await FirebaseService.shared.createLead(
                                    proId:            pro.id,
                                    proName:          pro.name,
                                    guide:            guide,
                                    capturedImage:    capturedImage,
                                    currentStepIndex: currentStepIndex,
                                    chatSummary:      chatSummary,
                                    chatTranscript:   chatTranscript,
                                    isASAP:           isASAP,
                                    requestedTime:    requestedTime
                                )
                                sendStatusText = ""
                                if let docId {
                                    withAnimation(.spring(response: 0.4)) { leadSent = true }
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    onLeadCreated?(docId, pro.name)
                                } else {
                                    withAnimation { leadFailed = true }
                                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                                }
                                isSending = false
                            }
                        }
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(.regularMaterial)
                        .preferredColorScheme(.dark)
                    }

                    // Call
                    if let phone = pro.phone {
                        Button {
                            if let url = URL(string: "tel://\(phone.filter(\.isNumber))") {
                                UIApplication.shared.open(url)
                            }
                            onProCalled?(pro.name, phone)
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.black)
                                .frame(width: 38, height: 38)
                                .background(Theme.brandSecondary, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Error state (sign-in required or Firestore failure)
                if leadFailed {
                    Text("Couldn't send request. Please sign in and try again.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dangerRed)
                        .transition(.opacity)
                }
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    LinearGradient(
                        colors: [verifiedBlue.opacity(0.5), verifiedBlue.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: verifiedBlue.opacity(0.14), radius: 14, y: 5)
    }
}

// MARK: – Local provider row (Tier 2, call-only)

private struct ProRowView: View {
    let pro: LocalPro
    var onProCalled: ((String, String?) -> Void)? = nil

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.brandPrimary.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.brandPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(pro.name)
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !pro.address.isEmpty {
                    Text(pro.address)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if let dist = pro.distanceMetres {
                    Text(String(format: "%.1f mi away", dist / 1609.34))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer()

            // Call only — no lead/request for external pros
            if let phone = pro.phoneNumber {
                Button {
                    if let url = URL(string: "tel://\(phone.filter(\.isNumber))") {
                        UIApplication.shared.open(url)
                    }
                    onProCalled?(pro.name, phone)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(Theme.brandSecondary, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: – Shimmer modifier (skeleton loading animation)

private extension View {
    func shimmer() -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.04), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
        )
    }
}
