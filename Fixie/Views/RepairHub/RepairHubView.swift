// Views/RepairHub/RepairHubView.swift
// The persistent Repair Hub — viewport + progress pips + multi-turn chat.
import SwiftUI
import AVFoundation

// MARK: – Keyboard dismiss helper

extension View {
    /// Tapping any non-interactive background area hides the keyboard.
    func dismissKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }
}

struct RepairHubView: View {
    let guide: RepairGuide
    let capturedImage: UIImage?
    let isChatFirst: Bool
    var transitionNamespace: Namespace.ID? = nil
    var onRepairExited: (() -> Void)? = nil   // when set, called instead of dismiss() so the whole sheet closes

    @State private var vm: RepairChatViewModel
    @State private var showShareSheet          = false
    @State private var showRescueSheet         = false
    @State private var showPauseDialog         = false
    @State private var showNoToolToast         = false
    @State private var showResumedCameraSheet  = false
    @State private var resumedCapturedImage: UIImage? = nil
    // Held separately from vm.showMePartName so a new AI message (which triggers
    // vm re-observation) never creates a new Identifiable id and force-dismisses
    // the camera sheet mid-session.
    @State private var showMeItem: ShowMeItem? = nil
    @Namespace private var toolCheckNamespace
    @Environment(\.dismiss) private var dismiss

    // MARK: – Inits

    init(guide: RepairGuide,
         capturedImage: UIImage?,
         isChatFirst: Bool = false,
         transitionNamespace: Namespace.ID? = nil,
         onRepairExited: (() -> Void)? = nil) {
        self.guide               = guide
        self.capturedImage       = capturedImage
        self.isChatFirst         = isChatFirst
        self.transitionNamespace = transitionNamespace
        self.onRepairExited      = onRepairExited
        self._vm = State(initialValue: isChatFirst
            ? RepairChatViewModel(symptomText: guide.session.title,
                                  category: guide.session.category)
            : RepairChatViewModel(guide: guide, capturedImage: capturedImage))
    }

    /// Resume a previously saved session (Save & Resume flow).
    init(resuming session: ActiveSession) {
        let guide = session.snapshot.toRepairGuide()
        self.guide               = guide
        self.capturedImage       = session.imagePath.flatMap {
            UIImage(contentsOfFile: RepairChatViewModel.resolvedImagePath($0))
        }
        self.isChatFirst         = false
        self.transitionNamespace = nil
        self.onRepairExited      = nil
        self._vm = State(initialValue: RepairChatViewModel(resuming: session))
    }

    var body: some View {
        GeometryReader { geo in
            contentBody(geo: geo)
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    // Prefer specific device name over generic fallback titles.
                    // Priority: diagnosis brand+model → Vision subtitle → session title
                    let diagName: String = {
                        let b = guide.diagnosis?.brand ?? ""
                        let m = guide.diagnosis?.model ?? ""
                        let joined = "\(b) \(m)".trimmingCharacters(in: .whitespaces)
                        let isGeneric = joined.isEmpty || joined.lowercased().hasPrefix("unknown")
                        return isGeneric ? "" : joined
                    }()
                    let toolbarTitle = !diagName.isEmpty ? diagName
                        : !guide.session.subtitle.isEmpty ? guide.session.subtitle
                        : guide.session.title
                    Text(toolbarTitle)
                        .font(Theme.bodyBold)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if vm.effectiveStepsTotal > 0 {
                        Text("Step \(vm.currentStepIndex + 1) of \(vm.effectiveStepsTotal)")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        // Show Vision-detected item name (session.subtitle) when available,
                        // otherwise fall back to the category name.
                        let headerSubtitle = guide.session.subtitle.isEmpty
                            ? guide.session.category.rawValue
                            : guide.session.subtitle
                        Text(headerSubtitle)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            // Keyboard dismiss chevron (pause moved into the step card)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        // Pause confirmation dialog
        .confirmationDialog("Pause Repair", isPresented: $showPauseDialog, titleVisibility: .visible) {
            Button("Missing Tools/Parts") {
                let tools = vm.guide.steps[safe: vm.currentStepIndex]?.toolsRequired ?? []
                Task { await vm.pauseRepair(reason: "missing_tools", missingTools: tools) }
            }
            Button("Stepping Away") {
                Task { await vm.pauseRepair(reason: "stepped_away") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your progress will be saved. Pick up where you left off from the home screen.")
        }
        // Dismiss when paused — use onRepairExited to close the whole sheet, not just the nav stack
        .onChange(of: vm.hasPaused) { _, paused in
            guard paused else { return }
            if let exit = onRepairExited { exit() } else { dismiss() }
        }
        // Handle pro-called attribution (already saved in ViewModel)
        .onChange(of: vm.didCallPro) { _, called in
            guard called else { return }
            if let exit = onRepairExited { exit() } else { dismiss() }
        }
        .sheet(isPresented: $vm.showToolCheck) {
            // Build the required-tools list from remaining structured steps.
            // When guide.steps is empty (clarification / chat-first mode), fall back to
            // the tool names extracted from the AI's free-form reply so ToolCheckView
            // has a real checklist to match against the scanned image.
            let structuredTools: [String] = vm.guide.steps
                .dropFirst(vm.currentStepIndex)
                .flatMap { $0.toolsRequired }
                .reduce(into: [String]()) { list, tool in
                    let lower = tool.lowercased()
                    if !list.contains(where: { $0.lowercased() == lower }) { list.append(tool) }
                }
            // Always merge structured (from repair plan) + chatFirstTools (from AI message).
            // chatFirstTools catches tools the AI mentioned in free-form reply that the
            // structured repair_steps didn't include, and vice-versa.
            let remainingTools: [String] = (structuredTools + vm.chatFirstTools)
                .reduce(into: [String]()) { list, tool in
                    let lower = tool.lowercased()
                    if !list.contains(where: { $0.lowercased() == lower }) { list.append(tool) }
                }
            ToolCheckView(
                requiredTools: remainingTools,
                transitionNamespace: toolCheckNamespace,
                onComplete: { found, missing in
                    vm.reportToolScanResults(found: found, missing: missing)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: vm.showMePartName) { _, newName in
            if let name = newName, showMeItem == nil {
                showMeItem = ShowMeItem(partName: name)
            } else if newName == nil {
                showMeItem = nil
            }
        }
        .sheet(item: $showMeItem) { item in
            ShowMeCameraSheet(partName: item.partName, vm: vm)
                .presentationDetents([.large])
                .onDisappear { vm.showMePartName = nil; showMeItem = nil }
        }
        .sheet(isPresented: $showResumedCameraSheet) {
            ResumedCameraSheet(vm: vm) { capturedImg in
                resumedCapturedImage = capturedImg
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showShareSheet) {
            ShareRepairCardView(
                guide:          guide,
                capturedImage:  capturedImage,
                stepsCompleted: vm.currentStepIndex
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Pro Rescue sheet — scheduling (ASAP or time) is now handled inside each VerifiedProCard
        .sheet(isPresented: Binding(
            get: { vm.showRescueCard },
            set: { vm.showRescueCard = $0 }
        )) {
            RescueCardView(
                category:         vm.proSearchCategory,
                searchQuery:      vm.proSearchQuery,
                guide:            guide,
                capturedImage:    capturedImage,
                currentStepIndex: vm.currentStepIndex,
                chatSummary:      vm.messages.last(where: { $0.role == .assistant })?.text,
                chatMessages:     vm.messages,
                onProCalled:      { name, phone in vm.onProCalled(name, phone: phone) },
                onLeadCreated:    { leadId, proName in
                    vm.startLeadListener(leadId: leadId, proName: proName)
                    // Lead submitted — navigate back to home so Activity card appears immediately
                    if let exit = onRepairExited { exit() } else { dismiss() }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // Pro service card — shown when a Fixie Verified Pro claims the lead
        .sheet(item: $vm.activeServiceLead) { lead in
            ProServiceCardView(lead: lead, onDismiss: { vm.activeServiceLead = nil })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Resolution success screen — presented when pro marks lead "resolved"
        .fullScreenCover(item: $vm.resolvedLead) { resolution in
            RepairSuccessView(resolution: resolution) {
                vm.resolvedLead = nil
            }
        }
        // After success screen is dismissed, exit the entire repair flow
        .onChange(of: vm.resolvedLead) { old, new in
            guard old != nil, new == nil else { return }
            if let exit = onRepairExited { exit() } else { dismiss() }
        }
    }

    private func contentBody(geo: GeometryProxy) -> some View {
        ZStack(alignment: .bottom) {
            Color(hex: 0x0D0D0F).ignoresSafeArea()
                .dismissKeyboardOnTap()

            // No-Tool-Needed toast
            if showNoToolToast {
                VStack {
                    HStack(spacing: Theme.spacingS) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("No tool needed for this step. You're ready to go!")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .padding(.top, Theme.spacingS)
                .zIndex(99)
            }

            VStack(spacing: 0) {
                if !NetworkMonitor.shared.isConnected {
                    OfflineBanner()
                }

                // Viewport (top ~30%)
                contextViewport
                    .frame(height: vm.isViewportExpanded ? geo.size.height * 0.6
                                                         : geo.size.height * 0.30)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8),
                               value: vm.isViewportExpanded)

                // Step progress bar
                ProgressPipView(
                    totalSteps:       vm.effectiveStepsTotal,
                    currentStep:      vm.currentStepIndex,
                    currentStepTitle: vm.guide.steps[safe: vm.currentStepIndex]?.title ?? ""
                )
                .padding(.horizontal, Theme.spacingM)
                .padding(.top, 4)
                .padding(.bottom, 2)

                // Chat surface expands to fill ALL remaining vertical space.
                // Without maxHeight: .infinity, the ZStack background shows through
                // as black after ToolCheckView sheet dismissal on iOS 26.
                chatSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: – Context Viewport

    private var contextViewport: some View {
        ZStack {
            if isChatFirst {
                // Chat-First placeholder — tap to attach a photo later
                chatFirstPlaceholder
            } else if let img = resumedCapturedImage ?? capturedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if vm.isResumed {
                // Resumed session with no cached image (cross-device or purged cache).
                // Show tappable placeholder — tap opens camera to re-photograph the item.
                resumedScanPlaceholder
            } else {
                CameraPreviewView(session: vm.camera.session)
            }

            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(guide.diagnosis?.symptom ?? guide.session.title)
                            .font(Theme.caption)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let d = guide.diagnosis {
                            Text("\(d.brand) \(d.model)".trimmingCharacters(in: .whitespaces))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                            vm.isViewportExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: vm.isViewportExpanded
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.spacingM)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                           startPoint: .top, endPoint: .bottom))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, Theme.spacingM)
        .padding(.top, Theme.spacingS)
    }

    // MARK: – Chat-First "Tap to Scan" placeholder

    private var chatFirstPlaceholder: some View {
        ZStack {
            Color(hex: 0x111318)
            VStack(spacing: Theme.spacingM) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.brandPrimary.opacity(0.6))
                VStack(spacing: Theme.spacingXS) {
                    Text("Tap to Scan")
                        .font(Theme.bodyBold)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Show me the item to get a visual diagnosis")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(Theme.spacingM)
        }
        .onTapGesture { vm.isViewportExpanded = true }
    }

    // MARK: – Resumed "Add a Photo" placeholder (shown when resumed with no cached image)

    private var resumedScanPlaceholder: some View {
        ZStack {
            Color(hex: 0x111318)
            VStack(spacing: Theme.spacingM) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.brandPrimary.opacity(0.6))
                VStack(spacing: Theme.spacingXS) {
                    Text("Add a Photo")
                        .font(Theme.bodyBold)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Tap to photograph the item so Fixie AI can see it")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(Theme.spacingM)
        }
        .onTapGesture { showResumedCameraSheet = true }
    }

    // MARK: – Tool scan logic
    //
    // Returns true when the wrench button should open ToolCheckView.
    // Checks both the current step's toolsRequired list AND the most recent AI message
    // for "gather these tools" / "Before you start" patterns — so the scanner is always
    // accessible when the AI mentions tools, even if the metadata is empty.

    private var shouldShowToolScanner: Bool {
        let stepHasTools = !(vm.guide.steps[safe: vm.currentStepIndex]?.toolsRequired ?? []).isEmpty
        // chatFirstTools is non-empty when the AI listed tools in clarification/chat-first mode.
        // Check it independently of hasPendingToolsScan so the scanner remains available after
        // hasPendingToolsScan is cleared on the first open.
        if stepHasTools || vm.hasPendingToolsScan || !vm.chatFirstTools.isEmpty { return true }
        guard let lastAI = vm.messages.last(where: { $0.role == .assistant }) else { return false }
        return vm.replyMentionsTools(lastAI.text)
    }

    // MARK: – Chat surface

    private var chatSurface: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .background(.ultraThickMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(height: 0.5)
                }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: Theme.spacingM) {
                        // Build YouTube URL once — passed to the LAST step card only.
                        let ytURL: URL? = {
                            guard let q = vm.guide.diagnosis?.youtubeSearchQuery,
                                  q.components(separatedBy: " ").count >= 6,
                                  !vm.awaitingClarification,
                                  !vm.awaitingModelVerification,
                                  vm.phase != .thinking,
                                  !vm.guide.steps.isEmpty || !vm.chatFirstTools.isEmpty
                            else { return nil }
                            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
                            return URL(string: "https://www.youtube.com/results?search_query=\(encoded)")
                        }()

                        ForEach(vm.messages) { msg in
                            if msg.role == .assistant {
                                // Show Watch button only on the most recent step card
                                let isLastMsg = msg.id == vm.messages.last(where: { $0.role == .assistant })?.id
                                AssistantCard(
                                    message: msg,
                                    onDone:  { vm.markDone(messageId: msg.id) },
                                    onPause: { showPauseDialog = true },
                                    onHelp:  { vm.requestStepHelp() },
                                    ytURL:   isLastMsg ? ytURL : nil
                                )
                                .id(msg.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal:   .opacity
                                ))
                            } else {
                                UserBubble(message: msg)
                                    .id(msg.id)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal:   .opacity
                                    ))
                            }
                        }

                        // Buy buttons for tools missing >5s
                        buyButtonRow

                        // Parts the AI identified as needing to be ordered
                        if !vm.partsRecommended.isEmpty {
                            partsRecommendedCard
                        }

                        // Affiliate buy links for tools missing from the camera scan
                        if !vm.missingToolsFromScan.isEmpty {
                            missingToolsScanCard
                        }

                        if vm.phase == .thinking || vm.isSeeding { ThinkingIndicator() }

                        if case .error(let e) = vm.phase {
                            ErrorBanner(message: e) { vm.retryLastTurn() }
                        }

                        // Model Verification Gate — shown before the plan when the
                        // backend is uncertain about the exact device model.
                        if vm.awaitingModelVerification {
                            ModelConfirmationCard(
                                suggestedModel: vm.suggestedModelName,
                                onConfirm:      { model in vm.confirmModel(confirmedModel: model) }
                            )
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal:   .scale(scale: 0.92).combined(with: .opacity)
                            ))
                            .id("modelVerificationCard")
                        }

                        // YouTube tutorial card — shown only when:
                        Color.clear.frame(height: 110)
                    }
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.top, Theme.spacingS)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    // Scroll to the last seeded message on first appear so Step 1
                    // (with Done/Pause/Help buttons) is visible immediately — messages
                    // seeded in init() don't trigger onChange(of: count).
                    if let last = vm.messages.last {
                        proxy.scrollTo(last.id, anchor: .top)
                    }
                }
                .onChange(of: vm.messages.count) { _, _ in
                    if let last = vm.messages.last {
                        // anchor: .top so long AI replies start at the top rather
                        // than dropping the user into the middle/end of the message.
                        withAnimation { proxy.scrollTo(last.id, anchor: .top) }
                    }
                }
            }

            VStack(spacing: Theme.spacingS) {
                // End-of-flow buttons — visible when all steps are marked done
                if vm.currentStepIndex >= vm.guide.steps.count && !vm.guide.steps.isEmpty {
                    VStack(spacing: Theme.spacingS) {
                        Button { showShareSheet = true } label: {
                            HStack(spacing: Theme.spacingS) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share Summary")
                            }
                            .font(Theme.bodyBold)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingS)
                            .background(Theme.brandSecondary, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button { vm.reportNotFixed() } label: {
                            HStack(spacing: Theme.spacingS) {
                                Image(systemName: "exclamationmark.triangle")
                                Text("Not the Issue — Still Broken")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.spacingS)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.phase == .thinking)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                ChatInputBar(
                    text:              $vm.draftText,
                    isThinking:        vm.phase == .thinking,
                    activeServiceLead: vm.activeServiceLead,
                    pendingProName:    vm.pendingProName,
                    hasToolsRequired:  shouldShowToolScanner,
                    onSend:            { vm.send() },
                    onToolCheck: {
                        // Check BEFORE clearing hasPendingToolsScan — shouldShowToolScanner
                        // reads it, so clearing first causes it to always return false on the
                        // first tap in clarification/chat-first flow.
                        if shouldShowToolScanner {
                            vm.hasPendingToolsScan = false
                            vm.showToolCheck = true
                        } else {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                showNoToolToast = true
                            }
                            Task {
                                try? await Task.sleep(for: .seconds(2.5))
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    showNoToolToast = false
                                }
                            }
                        }
                    },
                    onStuck:           { vm.showRescueCard = true },
                    onViewPro:         { vm.activeServiceLead = vm.activeServiceLead }   // re-set triggers sheet
                )
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.bottom, Theme.spacingM)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.currentStepIndex)
        }
    }

    // MARK: – Parts the AI recommends ordering — affiliate buy links

    @ViewBuilder
    private var partsRecommendedCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack(spacing: Theme.spacingXS) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.brandPrimary)
                Text("Parts you'll need — order now")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.brandPrimary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingS) {
                    ForEach(vm.partsRecommended, id: \.self) { part in
                        AffiliateToolButton(toolName: part)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.brandPrimary.opacity(0.25), lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: – Missing tools from scan — affiliate buy links

    @ViewBuilder
    private var missingToolsScanCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack(spacing: Theme.spacingXS) {
                Image(systemName: "cart.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warningAmber)
                Text("Get missing tools — shipped fast")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warningAmber)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingS) {
                    ForEach(vm.missingToolsFromScan, id: \.self) { tool in
                        AffiliateToolButton(toolName: tool)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.warningAmber.opacity(0.25), lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: – Tool buy row

    @ViewBuilder
    private var buyButtonRow: some View {
        if !vm.toolIntelligence.buyReadyTools.isEmpty {
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                HStack(spacing: Theme.spacingXS) {
                    Image(systemName: "cart.badge.questionmark")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.warningAmber)
                    Text("Missing tools")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warningAmber)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.spacingS) {
                        ForEach(vm.toolIntelligence.buyReadyTools, id: \.self) { tool in
                            AffiliateToolButton(toolName: tool)
                        }
                    }
                }
            }
            .padding(Theme.spacingM)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.warningAmber.opacity(0.2), lineWidth: 1))
        }
    }
}

// MARK: – Affiliate tool buy button

private struct AffiliateToolButton: View {
    let toolName: String
    @State private var result: AmazonPartResult?
    @State private var isLoading = true

    /// Fallback URL when PA-API keys aren't configured — direct Amazon search with affiliate tag.
    private var fallbackURL: URL {
        let q = toolName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? toolName
        return URL(string: "https://www.amazon.com/s?k=\(q)&tag=\(Config.amazonPartnerTag)")
            ?? URL(string: "https://www.amazon.com")!
    }

    var body: some View {
        Group {
            if let item = result {
                // PA-API returned a live listing with price
                Link(destination: item.affiliateWebURL) {
                    buttonLabel(price: item.displayPrice)
                }
            } else if !isLoading {
                // PA-API unavailable / not configured — fall back to Amazon search link
                Link(destination: fallbackURL) {
                    buttonLabel(price: nil)
                }
            } else {
                // Still loading — show amber placeholder skeleton
                Capsule()
                    .fill(Theme.warningAmber.opacity(0.3))
                    .frame(width: 120, height: 36)
            }
        }
        .task {
            if let parts = try? await AmazonPAAPIService.shared.searchParts(
                query: toolName, maxResults: 1
            ) {
                result = parts.first
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private func buttonLabel(price: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cart.fill")
                .font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(toolName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let price {
                    Text(price)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.black.opacity(0.7))
                } else {
                    Text("Buy on Amazon")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.black.opacity(0.7))
                }
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, 8)
        .background(Theme.warningAmber, in: Capsule())
    }
}

// MARK: – Offline banner

private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: Theme.spacingS) {
            Image(systemName: "wifi.slash").font(.system(size: 13, weight: .semibold))
            Text("No internet connection").font(Theme.caption)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingS)
        .background(Theme.dangerRed)
    }
}

// MARK: – "Show Me" sheet helpers

private struct ShowMeItem: Identifiable {
    // Stable id: same partName → same id, so parent re-renders never cause
    // SwiftUI to see a "new" item and dismiss/re-present the camera sheet.
    var id: String { partName }
    let partName: String
}

private struct ShowMeCameraSheet: View {
    let partName: String
    let vm: RepairChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var captureError: String?
    @State private var isCapturing = false

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()
            VStack(spacing: Theme.spacingL) {
                Text("Show me the **\(partName)**")
                    .font(Theme.titleMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                CameraPreviewView(session: vm.camera.session)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                if let err = captureError {
                    Text(err).font(Theme.caption).foregroundStyle(Theme.dangerRed)
                        .multilineTextAlignment(.center)
                }

                Button {
                    isCapturing = true
                    captureError = nil
                    Task {
                        do {
                            let data = try await vm.camera.capturePhoto()
                            vm.sendWithImage(data)
                            dismiss()
                        } catch {
                            captureError = error.localizedDescription
                        }
                        isCapturing = false
                    }
                } label: {
                    Group {
                        if isCapturing { ProgressView().tint(.black) }
                        else { Text("Capture & Send") }
                    }
                    .font(Theme.bodyBold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingM)
                    .background(Theme.brandPrimary, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                }
                .buttonStyle(.plain)
                .disabled(isCapturing)
            }
            .padding(Theme.spacingL)
        }
        .task {
            await vm.camera.configure()
            await vm.camera.startSession()
        }
        .onDisappear { Task { await vm.camera.stopSession() } }
    }
}

// MARK: – Resumed repair camera sheet

private struct ResumedCameraSheet: View {
    let vm: RepairChatViewModel
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var captureError: String?
    @State private var isCapturing = false

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()
            VStack(spacing: Theme.spacingL) {
                Text("Photograph the item you're repairing")
                    .font(Theme.titleMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                CameraPreviewView(session: vm.camera.session)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                if let err = captureError {
                    Text(err).font(Theme.caption).foregroundStyle(Theme.dangerRed)
                        .multilineTextAlignment(.center)
                }

                Button {
                    isCapturing = true
                    captureError = nil
                    Task {
                        do {
                            let data = try await vm.camera.capturePhoto()
                            if let img = UIImage(data: data) {
                                onCapture(img)
                            }
                            dismiss()
                        } catch {
                            captureError = error.localizedDescription
                        }
                        isCapturing = false
                    }
                } label: {
                    Group {
                        if isCapturing { ProgressView().tint(.black) }
                        else { Text("Capture Photo") }
                    }
                    .font(Theme.bodyBold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingM)
                    .background(Theme.brandPrimary, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                }
                .buttonStyle(.plain)
                .disabled(isCapturing)
            }
            .padding(Theme.spacingL)
        }
        .task {
            await vm.camera.configure()
            await vm.camera.startSession()
        }
        .onDisappear { Task { await vm.camera.stopSession() } }
    }
}

// MARK: – AssistantCard

struct AssistantCard: View {
    let message: ChatMessage
    let onDone:  () -> Void
    var onPause: (() -> Void)? = nil   // shows Pause ghost button to the left of Done
    var onHelp:  (() -> Void)? = nil
    var ytURL:   URL? = nil            // Watch button shown next to Help when non-nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack(spacing: Theme.spacingS) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.brandPrimary)
                Text("Fixie AI")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.brandPrimary)
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text(attributedText(from: message.text))
                .font(Theme.bodyRegular)
                .foregroundStyle(.primary)
                .shadow(radius: 1)
                .fixedSize(horizontal: false, vertical: true)

            if message.isStepPrompt && !message.isDone {
                // Button row: [Pause ghost] [Done solid] [Help ghost]
                // Only shown on actual step prompts — not on intro/tools/welcome messages.
                HStack(spacing: Theme.spacingS) {
                    // Pause — ghost/bordered, leftmost
                    if let pause = onPause {
                        Button(action: pause) {
                            Label("Pause", systemImage: "pause.circle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Theme.spacingM)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(
                                    Capsule().strokeBorder(
                                        Theme.textTertiary.opacity(0.35),
                                        lineWidth: 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    // Done — primary solid
                    Button(action: onDone) {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, Theme.spacingM)
                            .padding(.vertical, 6)
                            .background(Theme.brandSecondary, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    // Help — ghost
                    if let help = onHelp {
                        Button(action: help) {
                            Label("Help", systemImage: "questionmark.circle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, Theme.spacingM)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    // Watch — YouTube link, shown only when a real video URL exists
                    if let url = ytURL {
                        Link(destination: url) {
                            Label("Watch", systemImage: "play.rectangle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, Theme.spacingM)
                                .padding(.vertical, 6)
                                .background(Color(red: 1, green: 0, blue: 0), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            } else if message.isStepPrompt {
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.brandSecondary.opacity(0.7))
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributedText(from raw: String) -> AttributedString {
        var result = AttributedString()
        let parts  = raw.components(separatedBy: "**")
        for (i, part) in parts.enumerated() {
            var chunk = AttributedString(part)
            if i % 2 == 1 { chunk.font = .system(.body, design: .default, weight: .bold) }
            result += chunk
        }
        return result
    }
}

// MARK: – UserBubble

struct UserBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.spacingS) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                if let data = message.imageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 160, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(message.text)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.vertical, Theme.spacingS)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

// MARK: – Thinking indicator ("Fixie AI is typing…")

private struct ThinkingIndicator: View {
    @State private var phase: Int = 0  // 0, 1, 2 → which dot is brightest

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Theme.brandPrimary.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.brandPrimary)
            }

            // Bubble
            VStack(alignment: .leading, spacing: 4) {
                Text("Fixie AI")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brandPrimary)

                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(Theme.brandPrimary)
                            .frame(width: 7, height: 7)
                            .scaleEffect(phase == i ? 1.35 : 0.75)
                            .opacity(phase == i ? 1.0 : 0.35)
                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: phase)
                    }
                }
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, Theme.spacingS)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(380))
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: – Error banner

private struct ErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.warningAmber)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(.primary)
                Button("Retry", action: onRetry)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.brandPrimary)
            }
            Spacer()
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.warningAmber.opacity(0.35), lineWidth: 1))
    }
}

// MARK: – ProgressPipView (overhauled to show step label)

struct ProgressPipView: View {
    let totalSteps:       Int
    let currentStep:      Int
    let currentStepTitle: String

    private var progress: Double {
        // Use (currentStep + 1) / totalSteps so the current step registers as progress.
        // Step 10 of 10 = 100%, Step 1 of 10 = 10% (more intuitive than 0% on step 1).
        totalSteps > 0 ? Double(currentStep + 1) / Double(totalSteps) : 0
    }

    var body: some View {
        VStack(spacing: 8) {
            // Label row: "Step X of Y · Title"
            HStack(spacing: 6) {
                if totalSteps > 0 {
                    Text("Step \(min(currentStep + 1, totalSteps)) of \(totalSteps)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brandPrimary)
                    if !currentStepTitle.isEmpty {
                        Text("·")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Theme.textTertiary)
                        Text(currentStepTitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(progress > 0 ? Theme.brandPrimary : Theme.textTertiary)
            }

            // Progress track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule().fill(.white.opacity(0.18))
                    // Filled portion
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Theme.brandPrimary, Theme.brandSecondary],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(10, geo.size.width * progress))
                        .shadow(color: Theme.brandPrimary.opacity(0.5), radius: 4, x: 0, y: 0)
                        .animation(.spring(response: 0.4), value: progress)
                }
            }
            .frame(height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.brandPrimary.opacity(0.20), lineWidth: 1)
        )
    }
}

// MARK: – Chat input bar

struct ChatInputBar: View {
    @Binding var text: String
    let isThinking:        Bool
    var activeServiceLead: ActiveServiceLead? = nil
    var pendingProName:    String?            = nil   // lead submitted, awaiting pro claim
    var hasToolsRequired:  Bool = true   // false → show "no tool" toast instead of scanner
    var scanPulseActive:   Bool = false  // unused — kept for API compatibility
    let onSend:      () -> Void
    let onToolCheck: () -> Void
    let onStuck:     () -> Void
    var onViewPro:   () -> Void = {}

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: Theme.spacingS) {
            HStack(spacing: Theme.spacingS) {
                Button(action: onToolCheck) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 16, weight: .semibold))
                        // Bright tint when scanner is ready; dim when no tools detected yet.
                        // Static — no bounce, scale, or pulse animations.
                        .foregroundStyle(hasToolsRequired ? Theme.brandPrimary : Theme.textTertiary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                TextField("Ask Fixie…", text: $text, axis: .vertical)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...4)
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.vertical, Theme.spacingS)
                    .background(.ultraThinMaterial, in: Capsule())
                    .disabled(isThinking)
                    .focused($isInputFocused)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSend()          // clears draftText first
                    isInputFocused = false
                } label: {
                    Image(systemName: isThinking ? "ellipsis" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty || isThinking
                                         ? Theme.textTertiary : Theme.brandPrimary)
                        .symbolEffect(.bounce, value: isThinking)
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
            }

            // Bottom row — three exclusive states (highest priority first)
            if let pro = activeServiceLead {
                // ── STATE 3: Pro claimed the job ──────────────────────────
                Button(action: onViewPro) {
                    HStack(spacing: Theme.spacingS) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Pro Assigned — \(pro.proBusinessName)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.green)
                            Text("Tap to view contact & details")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))

            } else if let proName = pendingProName {
                // ── STATE 2: Lead submitted, waiting for pro to accept ────
                HStack(spacing: Theme.spacingS) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Theme.brandPrimary))
                        .scaleEffect(0.75)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Request Sent to \(proName)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.brandPrimary)
                        Text("Waiting for pro to accept…")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, 9)
                .background(Theme.brandPrimary.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.brandPrimary.opacity(0.3), lineWidth: 1))
                .transition(.move(edge: .bottom).combined(with: .opacity))

            } else {
                // ── STATE 1: No active lead — show rescue trigger ─────────
                Button(action: onStuck) {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("I'm Stuck — Find a Pro")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: activeServiceLead != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: pendingProName != nil)
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, Theme.spacingS)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        // Dismiss keyboard as soon as the AI starts thinking — user needs to read the reply.
        .onChange(of: isThinking) { _, thinking in
            if thinking { isInputFocused = false }
        }
    }
}
