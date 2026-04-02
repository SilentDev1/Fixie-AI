// ViewModels/RepairChatViewModel.swift
// The brain of RepairHubView: multi-turn Gemini conversation for the repair session.
import SwiftUI
import AVFoundation

// MARK: – Chat phase

enum ChatPhase: Equatable {
    case idle
    case thinking
    case error(String)
    static func == (l: ChatPhase, r: ChatPhase) -> Bool {
        switch (l, r) {
        case (.idle, .idle), (.thinking, .thinking): return true
        case (.error(let a), .error(let b)):         return a == b
        default: return false
        }
    }
}

// MARK: – ViewModel

@Observable @MainActor
final class RepairChatViewModel {

    // MARK: State
    var messages: [ChatMessage] = []
    var phase: ChatPhase = .idle
    var draftText: String = ""
    var isViewportExpanded: Bool = false
    var showToolCheck: Bool = false
    var currentStepIndex: Int = 0
    /// Tracks the estimated total step count in chat-first / clarification mode where
    /// `guide.steps` is empty. Updated by counting numbered lines in AI replies and
    /// rolling forward in `markDone()`. Persisted in `ActiveSession.stepsTotal`.
    var chatFirstStepsTotal: Int = 0

    /// The effective total steps for progress display.
    /// Uses `guide.steps.count` in structured (camera) flow; `chatFirstStepsTotal`
    /// (rolling estimate) in chat-first / clarification mode where steps are generated
    /// one at a time and `guide.steps` remains empty.
    var effectiveStepsTotal: Int {
        guide.steps.isEmpty
            ? max(chatFirstStepsTotal, currentStepIndex + 1)
            : guide.steps.count
    }

    // MARK: Rescue
    var showRescueCard: Bool = false

    // MARK: Pause & Resume
    var showPauseSheet:   Bool     = false
    var hasPaused:        Bool     = false     // RepairHubView watches to trigger dismiss
    var pauseMissingTools: [String] = []

    // MARK: Pro attribution (set when user calls a pro from RescueCard)
    var calledProName:  String? = nil
    var calledProPhone: String? = nil
    var didCallPro:     Bool    = false        // RepairHubView watches to update history

    // MARK: Lead status tracking (Firestore listener on leads/{leadId})
    var resolvedLead:      ProResolution?     = nil  // non-nil → show RepairSuccessView
    var activeServiceLead: ActiveServiceLead? = nil  // non-nil → show ProServiceCardView
    var activeLeadId:      String?            = nil
    var pendingProName:    String?            = nil  // set when lead submitted, cleared on claim/resolve

    // MARK: Tool Intelligence
    var toolIntelligence = ToolIntelligenceService()

    // MARK: Guide (var — updated after model re-verification)
    var guide: RepairGuide
    let capturedImage: UIImage?
    let isChatFirst: Bool

    /// True when this session was restored from a saved session (local or Firebase).
    /// Used by contextViewport to show a placeholder instead of a blank camera preview.
    var isResumed: Bool = false

    // MARK: Clarification gate
    /// True when the AI couldn't detect an issue (low confidence / empty steps) and is
    /// waiting for the user to describe the problem. YouTube card is hidden in this state.
    var awaitingClarification: Bool = false

    // MARK: Model Verification Gate
    /// True while ModelConfirmationCard is visible (before user confirms the device model).
    var awaitingModelVerification: Bool = false
    /// The model name shown in ModelConfirmationCard.
    var suggestedModelName: String = ""
    /// True while a re-diagnose backend call is in-flight after the user confirms.
    var isRediagnosing: Bool = false

    // MARK: "Show Me" detection
    var showMePartName: String? = nil

    // MARK: Camera re-scan
    let camera = CameraActor()

    // MARK: Learning loop — prior failures injected into every chat turn
    var priorFailures: [String] = []

    // MARK: Repair history context — past logs injected into chatSystemPrompt
    /// Populated async on init from Firestore repair_logs. Ready before the user's first message.
    private var pastRepairContext: String = ""

    // MARK: Scan workspace prompt — true while tools message is visible and scan not yet done
    var hasPendingToolsScan: Bool = false

    /// Tools extracted from the AI's free-form reply when guide.steps is empty
    /// (clarification / chat-first mode).  Passed to ToolCheckView so Gemini can
    /// match the scanned image against the specific tools the AI mentioned.
    var chatFirstTools: [String] = []

    /// Tools the user confirmed were missing after the camera tool scan.
    /// Drives the affiliate buy-link row in RepairHubView.
    var missingToolsFromScan: [String] = []

    /// Replacement parts the AI identified as needed for this repair.
    /// Shown as Amazon affiliate buy links in the chat (separate from scan-verified tools).
    var partsRecommended: [String] = []

    // MARK: – Part vs tool classification

    /// Words that indicate a line item is a replacement part to ORDER, not a reusable tool.
    private static let partStartPrefixes = ["replacement ", "new ", "spare "]
    private static let partKeywords = [
        "brush roll", "main brush", "side brush", "filter", "hepa", "battery",
        "adhesive", "thermal paste", "display assembly", "back cover", "screen",
        "belt", "gasket", "seal", "valve", "pump", "motor", "cartridge",
        "bag", "pad", "roller", "blade", "wheel", "spring", "coil", "sensor",
        "nozzle", "hose", "tube", "tank", "reservoir", "cable", "ribbon",
        "lens", "glass", "panel", "charger", "dock", "module", "chip"
    ]

    /// Returns true when `name` looks like a replacement part (to buy), not a reusable tool.
    static func isReplacementPart(_ name: String) -> Bool {
        let low = name.lowercased().trimmingCharacters(in: .whitespaces)
        if partStartPrefixes.contains(where: { low.hasPrefix($0) }) { return true }
        if partKeywords.contains(where: { low.contains($0) }) { return true }
        return false
    }

    /// Appends `item` to `partsRecommended` if it's a part and not already present.
    private func addPartIfNew(_ item: String) {
        let low = item.lowercased()
        guard !partsRecommended.contains(where: { $0.lowercased() == low }) else { return }
        partsRecommended.append(item)
    }

    // MARK: Not-fixed guard — prevents duplicate logging
    private var hasReportedNotFixed = false

    // AIManager handles Gemini → OpenAI failover and the isRequestInProgress guard
    private var ai: AIManager { AIManager.shared }

    // DiagnosisEngine: used for re-diagnose after model verification
    private let engine = DiagnosisEngine()

    // MARK: Typing / seeding state
    /// True while seedInitialContext() is animating messages in one-by-one.
    /// RepairHubView shows ThinkingIndicator when this or phase == .thinking.
    var isSeeding: Bool = false

    // MARK: – Standard init (from camera diagnosis)

    init(guide: RepairGuide, capturedImage: UIImage?) {
        self.guide          = guide
        self.capturedImage  = capturedImage
        self.isChatFirst    = false
        // Animate messages appearing one-by-one (typing feel) via async task.
        Task { @MainActor in await seedInitialContext() }
        Task { await fetchPriorFailures() }
        Task { await fetchRepairContext() }
    }

    // MARK: – Chat-First init (text entry from HomeView)
    // No image, no pre-generated steps — Gemini generates the repair plan in the first turn.

    init(symptomText: String, category: RepairCategory) {
        let session = RepairSession(category: category, title: symptomText)
        self.guide          = RepairGuide(session: session)
        self.capturedImage  = nil
        self.isChatFirst    = true

        // Seed with user message and immediately ask Gemini for a plan
        messages.append(ChatMessage.user(symptomText))
        Task { await fetchPriorFailures() }
        Task { await fetchRepairContext() }
        Task { await performChatTurn(userText: symptomText) }
    }

    // MARK: – Resume init (from saved ActiveSession)

    init(resuming session: ActiveSession) {
        let guide = session.snapshot.toRepairGuide()
        self.guide            = guide
        self.capturedImage    = session.imagePath.flatMap {
            UIImage(contentsOfFile: RepairChatViewModel.resolvedImagePath($0))
        }
        self.isChatFirst          = false
        self.isResumed            = true
        self.currentStepIndex     = session.currentStepIndex
        self.chatFirstStepsTotal  = session.stepsTotal   // restores "Step X of Y" on resume

        if session.savedMessages == nil || session.savedMessages!.isEmpty {
            // No saved history (legacy session) — rebuild context; resume shows instantly (no typing anim).
            let step      = guide.steps[safe: session.currentStepIndex]
            let stepTitle = step?.title ?? "next step"
            var resumeCtx = "Welcome back! Resuming at Step \(session.currentStepIndex + 1) of \(max(session.stepsTotal, session.currentStepIndex + 1)) — **\(stepTitle)**."
            if let detail = step?.detail      { resumeCtx += "\n\(detail)" }
            if let warn   = step?.warningNote { resumeCtx += "\n\n⚠️ \(warn)" }
            Task { @MainActor in
                await seedInitialContext()
                messages.append(ChatMessage.contextMessage(resumeCtx))
            }
        } else {
            // Restore the exact conversation that was in progress.
            messages = session.savedMessages!.map {
                $0.role == .user
                    ? ChatMessage.user($0.text)
                    : ChatMessage.assistant($0.text)
            }
            // Append a brief resume marker so the AI knows we just resumed.
            let step      = guide.steps[safe: session.currentStepIndex]
            let stepTitle = step?.title ?? "next step"
            messages.append(ChatMessage.contextMessage(
                "Welcome back! Resuming at Step \(session.currentStepIndex + 1) of \(max(session.stepsTotal, session.currentStepIndex + 1)) — **\(stepTitle)**."
            ))
        }

        Task { await fetchPriorFailures() }
        Task { await fetchRepairContext() }

        // If paused for missing tools, auto-send continuation prompt
        if session.pauseReason == "missing_tools", !session.missingTools.isEmpty {
            let tools = session.missingTools.joined(separator: ", ")
            let userMsg = "I've got the tools now (\(tools)). Ready to continue!"
            messages.append(ChatMessage.user(userMsg))
            Task { await performChatTurn(userText: userMsg) }
        }
    }

    // MARK: – Seed initial context (standard mode)

    // Helper: shows typing indicator, waits, then appends a message with a spring animation.
    @MainActor
    private func typeMessage(_ message: ChatMessage, delay: UInt64 = 600) async {
        isSeeding = true
        try? await Task.sleep(nanoseconds: delay * 1_000_000)
        isSeeding = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            messages.append(message)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)  // brief gap between messages
    }

    @MainActor
    private func seedInitialContext() async {
        let imageData = capturedImage?.jpegData(compressionQuality: 0.75)
        let symptom   = guide.diagnosis?.symptom ?? "the issue"
        let brand     = guide.diagnosis?.brand   ?? ""
        let model     = guide.diagnosis?.model   ?? ""
        let appliance = [brand, model]
            .filter { !$0.isEmpty && $0.lowercased() != "unknown" }
            .joined(separator: " ")

        // Item name priority:
        //   1. guide.session.subtitle — AI brand+model (e.g. "Yeedi Cube Robot Vacuum"),
        //      falls back to Vision OCR result only when Gemini returns nothing useful
        //   2. detectedDevice — server-provided (e.g. "iPad Pro 12.9")
        //   3. brand+model AI join (e.g. "Apple iPad")
        //   4. nil — never falls back to category.rawValue ("Small Household" etc.)
        let itemName: String? = {
            if !guide.session.subtitle.isEmpty { return guide.session.subtitle }
            if let d = guide.diagnosis?.detectedDevice, !d.isEmpty { return d }
            if !appliance.isEmpty { return appliance }
            return nil
        }()
        // Symptom clause only when meaningful
        let symptomClause: String = {
            let s = symptom.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty && s != "the issue" && s != "unknown" else { return "" }
            return " The issue is: \(s)."
        }()
        let devicePhrase = itemName.map { "a \($0)" } ?? "this appliance"
        let userCtx = ChatMessage.user(
            "I'm looking at \(devicePhrase).\(symptomClause)",
            imageData: imageData
        )
        // User's own message appears immediately (no typing indicator needed)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            messages.append(userCtx)
        }

        // ── Model Verification Gate ───────────────────────────────────────────
        // Backend flagged uncertainty about the exact device model. Show a confirmation
        // card before generating any repair steps — prevents Tineco→Washing-Machine etc.
        if guide.diagnosis?.needsModelVerification == true {
            let rawSuggested = guide.diagnosis?.suggestedModel
                            ?? (guide.session.subtitle.isEmpty ? nil : guide.session.subtitle)
                            ?? {
                                let b = guide.diagnosis?.brand ?? ""
                                let m = guide.diagnosis?.model ?? ""
                                let j = [b, m].filter { !$0.isEmpty && $0.lowercased() != "unknown" }.joined(separator: " ")
                                return j.isEmpty ? nil : j
                            }()
            suggestedModelName = rawSuggested ?? "this device"
            let label = suggestedModelName == "this device"
                ? "this device"
                : "**\(suggestedModelName)**"
            let verifyMsg = "Before I generate your repair plan, I need to confirm the device. I'm seeing \(label) — is that correct?"
            await typeMessage(ChatMessage.contextMessage(verifyMsg), delay: 800)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                awaitingModelVerification = true
            }
            return
        }

        let confidence = guide.diagnosis?.confidenceScore ?? 0
        let lowConfidence = guide.steps.isEmpty || confidence < 0.8

        if lowConfidence {
            // ── Low-confidence fallback: ask user to describe the problem ──────
            let deviceLabel: String? = {
                if !guide.session.subtitle.isEmpty { return guide.session.subtitle }
                if let d = guide.diagnosis?.detectedDevice, !d.isEmpty { return d }
                let b = guide.diagnosis?.brand ?? ""
                let m = guide.diagnosis?.model ?? ""
                let joined = [b, m].filter { !$0.isEmpty && $0.lowercased() != "unknown" }.joined(separator: " ")
                return joined.isEmpty ? nil : joined
            }()
            let clarification: String
            if let label = deviceLabel {
                clarification = "I can see the **\(label)**, but I don't see any obvious physical damage. Could you please describe exactly what's wrong?"
            } else {
                clarification = "I can see the appliance in your photo, but I don't see any obvious physical damage. Could you please describe exactly what's wrong?"
            }
            await typeMessage(ChatMessage.contextMessage(clarification), delay: 800)
            awaitingClarification = true
        } else {
            await seedRepairPlan()
        }
    }

    // MARK: – Plan seeding (shared by seedInitialContext + confirmModel)

    /// Appends the plan overview, tool checklist, and Step 1 to the chat with typed animation.
    /// Reads from `self.guide` — call AFTER updating `guide` from a re-diagnose response.
    @MainActor
    private func seedRepairPlan() async {
        // Plan overview
        var intro = "I can see the issue. Here's my plan:\n\n"
        for step in guide.steps.prefix(3) {
            intro += "\(step.order). **\(step.title)** — \(step.detail)\n"
        }
        if guide.steps.count > 3 {
            intro += "…and \(guide.steps.count - 3) more steps.\n"
        }
        await typeMessage(ChatMessage.contextMessage(intro), delay: 900)

        // Tool checklist — split items into physical tools (scan) and replacement parts (order)
        let allItems: [String] = guide.steps
            .flatMap { $0.toolsRequired }
            .reduce(into: [String]()) { list, tool in
                let lower = tool.lowercased()
                if !list.contains(where: { $0.lowercased() == lower }) { list.append(tool) }
            }
        let toolItems = allItems.filter { !RepairChatViewModel.isReplacementPart($0) }
        let partItems = allItems.filter { RepairChatViewModel.isReplacementPart($0) }

        // Register parts for the affiliate card
        partItems.forEach { addPartIfNew($0) }

        if !toolItems.isEmpty {
            var toolsMsg = "**Before you start, gather these tools:**\n"
            toolsMsg += toolItems.map { "• \($0)" }.joined(separator: "\n")
            toolsMsg += "\n\nTap **🔧 Scan Workspace** below to verify you have everything ready."
            await typeMessage(ChatMessage.contextMessage(toolsMsg), delay: 600)
            hasPendingToolsScan = true
            chatFirstTools = toolItems
        }

        // Step 1 prompt (shows Done/Pause/Help buttons)
        if let step = guide.steps.first {
            var step1 = "Let's start with **Step 1: \(step.title)**.\n\(step.detail)"
            if let warning = step.warningNote { step1 += "\n\n⚠️ \(warning)" }
            await typeMessage(ChatMessage.assistant(step1), delay: 700)
        }
    }

    // MARK: – Model confirmation

    /// Called by ModelConfirmationCard with either the confirmed suggested model (isCorrect=true)
    /// or the user-typed correction.  Re-diagnoses with the backend, then seeds the repair plan.
    func confirmModel(confirmedModel: String) {
        Task { @MainActor in
            // 1. Dismiss the card
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                awaitingModelVerification = false
            }

            // 2. Show a confirmation user-bubble
            let userMsg = confirmedModel == suggestedModelName
                ? ChatMessage.user("Yes, that's correct.")
                : ChatMessage.user("Actually it's a \(confirmedModel).")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                messages.append(userMsg)
            }

            // 3. Re-diagnose with confirmed model
            isRediagnosing = true
            isSeeding      = true   // show ThinkingIndicator while waiting
            let imageData  = capturedImage?.jpegData(compressionQuality: 0.5) ?? Data()

            do {
                let newGuide = try await engine.rediagnose(
                    confirmedModel:  confirmedModel,
                    imageData:       imageData,
                    category:        guide.session.category,
                    userDescription: guide.diagnosis?.symptom ?? ""
                )
                guide          = newGuide
                isRediagnosing = false
                isSeeding      = false

                // 4. Slide in plan with spring animation
                await seedRepairPlan()

            } catch {
                isRediagnosing = false
                isSeeding      = false
                // Graceful fallback: ask the user to describe the issue
                let fallback = "Got it — **\(confirmedModel)**. Could you describe what's wrong with it so I can build the right repair plan?"
                await typeMessage(ChatMessage.contextMessage(fallback), delay: 400)
            }
        }
    }

    // MARK: – Send user message

    func send() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .idle else { return }
        draftText = ""

        guard NetworkMonitor.shared.isConnected else {
            phase = .error("No internet connection")
            return
        }

        let userMsg = ChatMessage.user(text)
        messages.append(userMsg)
        Task { await performChatTurn(userText: text) }
    }

    func sendWithImage(_ imageData: Data) {
        guard phase == .idle else { return }
        let text    = "Here's the photo you asked for."
        let userMsg = ChatMessage(role: .user, text: text, imageData: imageData)
        messages.append(userMsg)
        showMePartName = nil
        Task { await performChatTurn(userText: text, imageData: imageData) }
    }

    // MARK: – Pro search category + query

    /// Combined diagnosis text used by both proSearchCategory and proSearchQuery.
    private var diagnosisText: String {
        [guide.diagnosis?.brand   ?? "",
         guide.diagnosis?.model   ?? "",
         guide.diagnosis?.symptom ?? "",
         guide.session.title
        ].joined(separator: " ").lowercased()
    }

    /// Word-set from the diagnosis text (lowercased, punctuation stripped).
    /// Used for whole-word matching on short ambiguous keywords to prevent
    /// false positives from substrings (e.g. "phone" in "iPhone app").
    private var diagnosisWords: Set<String> {
        Set(diagnosisText
            .components(separatedBy: .init(charactersIn: " \t\n,.-/()\u{2019}"))
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty })
    }

    /// "Trade License" decision tree — maps AI diagnosis to the correct Firestore
    /// category key. Evaluated once when the user taps "I'm Stuck".
    ///
    /// Tier priority (highest → lowest):
    ///   0. Strict override  — "water" + "heater" anywhere → homeSystems
    ///   1. Home Systems     — licensed plumber / electrician / HVAC required
    ///   2. Major Appliances — standalone chore machines (plug-in, no new main line)
    ///   3. Automotive       — road vehicles or major drivetrain components
    ///   4. Yard & Tools     — outdoor maintenance / construction power tools
    ///   5. Tech & Electronics — personal devices with microchips / screens
    ///   6. Small Household  — portable / countertop convenience items
    ///   7. Fallback         — user's original category selection (logs uncertainty)
    var proSearchCategory: RepairCategory {
        let text  = diagnosisText
        let words = diagnosisWords

        // ── STRICT OVERRIDE: "water" + "heater" anywhere → homeSystems ────
        // Catches "electric water heater", "tankless water heater", "water heater
        // pilot light", etc. regardless of word order or surrounding context.
        if text.contains("water") && text.contains("heater") { return .homeSystems }

        // ── 1. Home Systems ───────────────────────────────────────────────
        // Rule: pressurized water lines, high-voltage hardwiring, or central
        // HVAC infrastructure → licensed trade required (plumber / electrician / HVAC).
        let systemsPhrases: [String] = [
            "hot water", "tankless", "heat pump", "air conditioner", "ac unit",
            "circuit breaker", "electrical panel", "main drain", "sump pump",
            "well pump", "water pump", "gas line", "water line", "pressure tank",
            "ev charger", "electric vehicle charger", "septic tank", "septic system"
        ]
        if systemsPhrases.contains(where: { text.contains($0) }) { return .homeSystems }

        let systemsWords: Set<String> = [
            "hvac", "furnace", "boiler", "plumbing", "plumber",
            "faucet", "drain", "thermostat", "radiator", "ductwork",
            "burner", "ignitor", "flue", "valve", "shutoff", "waterline",
            "condenser", "septic"
        ]
        if !systemsWords.isDisjoint(with: words) { return .homeSystems }

        // ── COUNTERTOP OVERRIDE (before Major Appliances) ────────────────
        // Prevents "Toaster Oven", "Air Fryer Oven", "Countertop Microwave", etc.
        // from matching the Major Appliances "oven" / "microwave" keywords.
        // Rule: if the model name includes a countertop qualifier, it is always
        // Small Household regardless of any appliance-class noun it also contains.
        let countertopPhrases: [String] = [
            "toaster oven", "toaster", "air fryer", "countertop", "mini fridge",
            "portable ac", "personal blender", "personal fan"
        ]
        if countertopPhrases.contains(where: { text.contains($0) }) { return .smallHousehold }

        // ── 2. Major Appliances ───────────────────────────────────────────
        // Rule: standalone chore machine that plugs into an existing outlet.
        // Does NOT require a licensed plumber to install a new main water line.
        let appliancePhrases: [String] = [
            "washing machine", "clothes dryer", "trash compactor",
            "wine cooler", "garbage disposal", "ice maker", "built-in oven",
            "french door", "side by side"
        ]
        if appliancePhrases.contains(where: { text.contains($0) }) { return .majorAppliances }

        let applianceWords: Set<String> = [
            "refrigerator", "fridge", "dishwasher", "oven", "range", "stove",
            "washer", "dryer", "freezer", "compactor", "cooktop"
        ]
        if !applianceWords.isDisjoint(with: words) { return .majorAppliances }

        // ── 3. Automotive ─────────────────────────────────────────────────
        let autoPhrases: [String] = [
            "check engine", "oil change", "brake pad", "tire rotation",
            "transmission fluid", "spark plug", "timing belt", "catalytic converter",
            "head gasket", "wheel bearing"
        ]
        if autoPhrases.contains(where: { text.contains($0) }) { return .automotive }

        let autoWords: Set<String> = [
            "car", "truck", "suv", "vehicle", "motorcycle", "motorbike",
            "transmission", "brake", "brakes", "tire", "tires", "alternator",
            "carburetor", "engine",
            "honda", "toyota", "ford", "bmw", "mercedes", "chevrolet",
            "hyundai", "kia", "audi", "volvo", "subaru", "nissan",
            "jeep", "dodge", "lexus", "tesla", "gm", "harley"
        ]
        if !autoWords.isDisjoint(with: words) { return .automotive }

        // ── 4. Yard & Tools ───────────────────────────────────────────────
        let yardPhrases: [String] = [
            "lawn mower", "leaf blower", "snow blower", "power tool",
            "weed eater", "weed trimmer", "string trimmer", "hedge trimmer",
            "pressure washer", "circular saw", "table saw", "air compressor"
        ]
        if yardPhrases.contains(where: { text.contains($0) }) { return .yardAndTools }

        let yardWords: Set<String> = [
            "mower", "chainsaw", "tractor", "trimmer", "blower",
            "drill", "saw", "pruner", "sprinkler", "edger", "aerator",
            "generator", "compressor"
        ]
        if !yardWords.isDisjoint(with: words) { return .yardAndTools }

        // ── 5. Tech & Electronics ─────────────────────────────────────────
        // Checked AFTER homeSystems and majorAppliances — "smart fridge" or
        // "wi-fi thermostat" must not land here.
        let techPhrases: [String] = [
            "macbook pro", "macbook air", "apple watch", "apple tv",
            "samsung galaxy", "google pixel", "surface pro", "ipad pro",
            "ipad air", "ipad mini", "gaming console", "graphics card",
            "smart watch", "smart tv", "flat screen", "oled tv"
        ]
        if techPhrases.contains(where: { text.contains($0) }) { return .techAndElectronics }

        // Whole-word match only — prevents "phone" in "earphone" or
        // "lg" in "lg washing machine" (appliance already caught above).
        let techWords: Set<String> = [
            "ipad", "iphone", "macbook", "laptop", "tablet", "computer",
            "android", "chromebook", "kindle", "imac", "airpods",
            "samsung", "google", "microsoft", "sony",
            "dell", "lenovo", "asus", "acer", "pixel",
            "drone", "monitor", "console", "playstation", "xbox", "nintendo",
            "smartwatch", "tv"
        ]
        if !techWords.isDisjoint(with: words) { return .techAndElectronics }

        // ── 6. Small Household ────────────────────────────────────────────
        // "space heater" is explicitly portable — does NOT trigger homeSystems.
        let smallHHPhrases: [String] = [
            "space heater", "air fryer", "coffee maker", "stand mixer",
            "vacuum cleaner", "robot vacuum", "hand vacuum"
        ]
        if smallHHPhrases.contains(where: { text.contains($0) }) { return .smallHousehold }

        let smallHHWords: Set<String> = [
            "vacuum", "toaster", "blender", "microwave", "coffeemaker",
            "kettle", "juicer", "mixer", "dehumidifier", "humidifier",
            "airfryer", "fan", "disposal"
        ]
        if !smallHHWords.isDisjoint(with: words) { return .smallHousehold }

        // ── 7. Fallback ───────────────────────────────────────────────────
        // No high-confidence match — default to the user's manually selected
        // category and log uncertainty for the Superadmin Dashboard.
        logCategoryUncertainty()
        return guide.session.category
    }

    /// Fires a structured log entry when the decision tree falls through to the
    /// fallback. The Superadmin Dashboard can query these to identify new keyword
    /// gaps and expand coverage over time.
    private func logCategoryUncertainty() {
        let entry = [
            "event":       "category_uncertainty",
            "deviceModel": guide.diagnosis?.model   ?? "",
            "symptom":     guide.diagnosis?.symptom ?? guide.session.title,
            "fallback":    guide.session.category.rawValue
        ]
        // Console trace — replace with Analytics.logEvent() when wired to dashboard
        print("[Fixie] ⚠️ proSearchCategory fallback:", entry)
    }

    /// Device-specific MapKit query string for Tier-2 pro search.
    /// Ordered by specificity: exact device phrases → category-level defaults.
    var proSearchQuery: String {
        let text = diagnosisText

        // ── Home Systems ──────────────────────────────────────────────────
        if text.contains("water heater") || text.contains("hot water") ||
           text.contains("tankless") {
            return "Licensed Plumber Water Heater Repair"
        }
        if text.contains("sump pump") || text.contains("well pump") {
            return "Licensed Plumber Pump Repair"
        }
        if text.contains("drain") || text.contains("faucet") ||
           text.contains("pipe") || text.contains("plumb") ||
           text.contains("septic") {
            return "Licensed Plumber"
        }
        if text.contains("furnace") || text.contains("boiler") ||
           text.contains("heat pump") || text.contains("hvac") {
            return "Licensed HVAC Heating Repair"
        }
        if text.contains("air conditioner") || text.contains("ac unit") ||
           text.contains("condenser") || text.contains("cooling") {
            return "Licensed HVAC AC Cooling Repair"
        }
        if text.contains("circuit breaker") || text.contains("electrical panel") ||
           text.contains("ev charger") || text.contains("wiring") ||
           text.contains("outlet") {
            return "Licensed Electrician"
        }
        // ── Major Appliances ──────────────────────────────────────────────
        if text.contains("refrigerator") || text.contains("fridge") ||
           text.contains("freezer") {
            return "Refrigerator Appliance Repair Service"
        }
        if text.contains("washer") || text.contains("washing machine") ||
           text.contains("dryer") || text.contains("clothes dryer") {
            return "Washer Dryer Laundry Appliance Repair"
        }
        if text.contains("dishwasher") { return "Dishwasher Appliance Repair Service" }
        if text.contains("oven") || text.contains("range") || text.contains("stove") {
            return "Oven Range Stove Appliance Repair"
        }
        // ── Automotive ────────────────────────────────────────────────────
        if text.contains("motorcycle") || text.contains("motorbike") {
            return "Motorcycle Repair Service"
        }
        // ── Delegate to category-level default ────────────────────────────
        switch proSearchCategory {
        case .homeSystems:        return "Licensed Plumber HVAC Repair"
        case .majorAppliances:    return "Appliance Repair Service"
        case .techAndElectronics: return "Certified Electronics Repair"
        case .automotive:         return "Auto Mechanic Car Repair"
        case .yardAndTools:       return "Lawn Equipment Power Tool Repair"
        case .smallHousehold:     return "Small Appliance Repair"
        case .homeAndStructure:   return "General Contractor Handyman"
        case .itAndNetworking:    return "IT Support Computer Repair"
        }
    }

    // MARK: – Retry last turn

    func retryLastTurn() {
        guard let lastUserMsg = messages.last(where: { $0.role == .user }),
              phase != .thinking else { return }
        guard NetworkMonitor.shared.isConnected else {
            phase = .error("No internet connection")
            return
        }
        Task { await performChatTurn(userText: lastUserMsg.text, imageData: lastUserMsg.imageData) }
    }

    // MARK: – Active session builder

    private func buildActiveSession(status: String,
                                    pauseReason: String? = nil,
                                    missingTools: [String] = []) -> ActiveSession {
        let saved: [SavedChatMessage]? = messages.isEmpty ? nil : messages.map {
            SavedChatMessage(role: $0.role == .user ? .user : .assistant, text: $0.text)
        }
        return ActiveSession(
            userId:           AuthService.shared.currentUser?.id ?? "local",
            currentStepIndex: currentStepIndex,
            status:           status,
            pauseReason:      pauseReason,
            missingTools:     missingTools,
            deviceModel:      guide.diagnosis?.model   ?? "",
            symptom:          guide.diagnosis?.symptom ?? guide.session.title,
            categoryRaw:      guide.session.category.rawValue,
            stepsTotal:       effectiveStepsTotal,
            snapshot:         RepairGuideSnapshot(from: guide),
            updatedAt:        Date(),
            imagePath:        cachedImagePath(),
            savedMessages:    saved
        )
    }

    /// Persists `capturedImage` to Application Support (never OS-purged).
    /// Returns only the **filename** (e.g. `repair_UUID.jpg`), not the full path,
    /// so the stored value stays valid across sandbox container UUID changes.
    private func cachedImagePath() -> String? {
        guard let img = capturedImage,
              let data = img.jpegData(compressionQuality: 0.78) else { return nil }
        let filename = "repair_\(guide.id.uuidString).jpg"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try? data.write(to: url)
        return filename
    }

    /// Resolves a stored `imagePath` (filename or legacy absolute path) to the
    /// current full path inside Application Support.
    static func resolvedImagePath(_ stored: String) -> String {
        // New format: just the filename — reconstruct against current container
        if !stored.hasPrefix("/") {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return dir.appendingPathComponent(stored).path
        }
        // Legacy format: absolute path baked in at save time — use as-is.
        // If the file has moved (container UUID rotated), fall through to the
        // filename-only reconstruction as a best-effort fallback.
        if FileManager.default.fileExists(atPath: stored) { return stored }
        let filename = (stored as NSString).lastPathComponent
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(filename).path
    }

    // MARK: – Mark step done

    func markDone(messageId: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let completedText = messages[idx].text   // capture before mutation
        messages[idx].isDone = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Reset tool intelligence for the new step
        toolIntelligence.reset()

        // Log this step as completed in Firestore (fire-and-forget)
        let guideId = guide.id.uuidString
        Task {
            await FirebaseService.shared.appendCompletedStep(stepText: completedText)
        }

        currentStepIndex += 1

        // Chat-first / clarification mode: guide.steps is empty so there's no pre-built
        // step list.  Ask the AI for the next step; it continues the repair conversation.
        if guide.steps.isEmpty {
            let stepNum = currentStepIndex   // already incremented (0-based → 1-based label)
            // Roll chatFirstStepsTotal forward — we know there's at least one more step ahead.
            chatFirstStepsTotal = max(chatFirstStepsTotal, stepNum + 1)
            // Auto-save progress so pause/resume always shows the correct step.
            // (Structured flow saves here too; chat-first had no save, causing "Step 1 of 0".)
            let savedSession = buildActiveSession(status: "in_progress")
            savedSession.saveLocal()
            let guideSnap  = guide; let stepSnap = currentStepIndex
            let msgsSnap   = messages
            let totalSnap  = effectiveStepsTotal
            let savedSnap  = msgsSnap.map { SavedChatMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
            Task {
                await FirebaseService.shared.saveActiveSession(
                    guide:         guideSnap,
                    stepIndex:     stepSnap,
                    status:        "in_progress",
                    stepsTotal:    totalSnap,
                    savedMessages: savedSnap
                )
                await FirebaseService.shared.syncChatHistory(
                    guideId: guideSnap.id.uuidString, messages: msgsSnap
                )
            }
            let nextPrompt = "Step \(stepNum) complete. Please give me the next step."
            messages.append(ChatMessage.user(nextPrompt))
            Task { await performChatTurn(userText: nextPrompt) }
            return
        }

        if currentStepIndex < guide.steps.count {
            let next   = guide.steps[currentStepIndex]
            let prompt = "Great! Step \(next.order): **\(next.title)**.\n\(next.detail)"
                + (next.warningNote.map { "\n\n⚠️ \($0)" } ?? "")
            messages.append(ChatMessage.assistant(prompt))
            // Auto-save progress: Firebase is authoritative; local cache for offline/fast-path.
            let session = buildActiveSession(status: "in_progress")
            session.saveLocal()
            let snapshotMessages = messages
            let totalSnap        = effectiveStepsTotal
            let savedSnap        = snapshotMessages.map { SavedChatMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
            Task {
                await FirebaseService.shared.saveActiveSession(
                    guide:         guide,
                    stepIndex:     currentStepIndex,
                    status:        "in_progress",
                    stepsTotal:    totalSnap,
                    savedMessages: savedSnap
                )
                await FirebaseService.shared.syncChatHistory(guideId: guideId, messages: snapshotMessages)
            }
        } else {
            RepairHistoryStore.shared.save(
                guide:          guide,
                capturedImage:  capturedImage,
                stepsCompleted: currentStepIndex
            )
            // All steps done — remove only this repair's session (others remain)
            ActiveSession.removeLocal(guideId: guide.id.uuidString)
            let completionMsg = ChatMessage.contextMessage(
                "🎉 You've completed all the repair steps! "
                + "If the problem persists, tap the camera icon to show me the result "
                + "and I'll help diagnose further.")
            messages.append(completionMsg)
            let finalMessages = messages
            let archivedGuide = guide
            Task {
                await FirebaseService.shared.clearActiveSession()
                await FirebaseService.shared.syncChatHistory(guideId: guideId, messages: finalMessages)
                // Archive permanently so user can look back + AI learns from it next time
                await FirebaseService.shared.archiveRepairLog(guide: archivedGuide, messages: finalMessages)
            }
        }
    }

    // MARK: – Core chat turn

    func performChatTurn(userText: String, imageData: Data? = nil) async {
        // User has now described the issue — clear the clarification gate so the
        // YouTube card can appear once the AI produces a real repair plan.
        if awaitingClarification { awaitingClarification = false }
        phase = .thinking
        do {
            let reply = try await ai.chatTurn(
                history: messages.dropLast().filter { $0.role == .user || $0.role == .assistant },
                newUserText: userText,
                imageData: imageData,
                guide: guide,
                priorFailures: priorFailures,
                pastRepairContext: pastRepairContext
            )

            // Detect "Show me the [part]" camera prompt on a background thread.
            // showRescueCard is intentionally NOT triggered here — the Pro sheet is
            // only shown via the explicit "I'm Stuck — Find a Pro" button tap.
            let showMePart: String? = await Task.detached(priority: .utility) {
                let lower = reply.lowercased()
                guard lower.contains("show me the ") else { return nil }
                // Don't auto-pop camera when "Show me the..." is embedded inside a numbered
                // step guide. A multi-step reply (contains step 2+) means the "Show me" is
                // contextual instruction inside a step — not a standalone photo request.
                let hasMultipleSteps = lower.range(of: #"\n[2-9][0-9]*[\.\)]"#,
                                                   options: .regularExpression) != nil
                guard !hasMultipleSteps,
                      let range = lower.range(of: "show me the ") else { return nil }
                return reply[range.upperBound...]
                    .components(separatedBy: CharacterSet(charactersIn: ".,!?\n"))
                    .first?
                    .trimmingCharacters(in: .whitespaces)
            }.value

            // Back on @MainActor — single batch of state writes, no redundant re-renders
            if let name = showMePart { showMePartName = name }
            // Activate tool scanner as soon as the AI mentions any tools in its reply.
            // When guide.steps is empty, also extract tool names so ToolCheckView has a
            // real checklist to match against instead of an empty required-tools list.
            if !hasPendingToolsScan && replyMentionsTools(reply) {
                hasPendingToolsScan = true
                // Always extract tools from AI reply regardless of whether structured steps exist.
                // In camera flow, guide.steps may be non-empty but toolsRequired is empty — the AI
                // reply is the only source of tool names in that case.
                let extracted = extractToolsFromReply(reply)
                if !extracted.isEmpty {
                    let existing = Set(chatFirstTools.map { $0.lowercased() })
                    for t in extracted where !existing.contains(t.lowercased()) {
                        // Route to parts vs tools
                        if RepairChatViewModel.isReplacementPart(t) {
                            addPartIfNew(t)
                        } else {
                            chatFirstTools.append(t)
                        }
                    }
                }
            }
            // Infer total step count from numbered items in the AI reply.
            // The plan overview (e.g. "1. Gather tools\n2. Open device\n…\n9. Test") gives us
            // a concrete total we can use for the progress bar in chat-first mode.
            if guide.steps.isEmpty {
                let numberedLineCount = reply.components(separatedBy: "\n")
                    .filter { line in
                        let s = line.trimmingCharacters(in: .whitespaces)
                        return s.range(of: #"^\d+[\.\)]"#, options: .regularExpression) != nil
                    }
                    .count
                if numberedLineCount > 0 {
                    chatFirstStepsTotal = max(chatFirstStepsTotal, numberedLineCount)
                }
            }
            // Scan narrative text for replacement parts (e.g. "replace the brush roll")
            // regardless of whether a tools bullet list is present.
            extractPartsFromNarrative(reply)
            // Split reply into a tools bubble + a steps bubble so the user sees
            // "gather these tools" BEFORE the repair instructions, as separate cards.
            let (toolsPart, stepsPart) = splitToolsFromSteps(reply)
            if let tools = toolsPart, !tools.isEmpty {
                messages.append(ChatMessage.contextMessage(tools))
            }
            let bodyText = stepsPart ?? reply
            // When guide.steps is empty (clarification flow or chat-first mode), the AI IS
            // generating the repair plan — show Done/Pause/Help buttons so the user can
            // tap "Done" to advance.  For normal camera flow with structured steps, keep
            // conversational replies as contextMessage (no buttons).
            if guide.steps.isEmpty {
                messages.append(ChatMessage.assistant(bodyText))
            } else {
                messages.append(ChatMessage.contextMessage(bodyText))
            }
            phase = .idle
            // Sync full conversation to Firestore after every AI turn (includes user message)
            let guideIdForSync = guide.id.uuidString
            let messagesForSync = messages
            Task {
                await FirebaseService.shared.syncChatHistory(
                    guideId:  guideIdForSync,
                    messages: messagesForSync
                )
            }
        } catch {
            phase = .error(Self.friendlyError(error))
        }
    }

    // MARK: – Learning loop helpers

    /// Fetches prior failed steps from Firestore and stores them for injection into chat prompts.
    private func fetchPriorFailures() async {
        let category    = guide.session.category
        let deviceModel = sanitizedDeviceModel()
        let symptom     = guide.diagnosis?.symptom ?? guide.session.title
        priorFailures = await FirebaseService.shared.fetchPriorFailures(
            category: category, deviceModel: deviceModel, symptom: symptom
        )
    }

    /// Fetches past repair chat logs for the same category/device and stores them for AI injection.
    /// Runs concurrently with seedInitialContext — ready long before the user's first typed message.
    private func fetchRepairContext() async {
        let context = await FirebaseService.shared.fetchRepairContext(
            category: guide.session.category.firestoreKey,
            deviceName: guide.diagnosis?.brand ?? ""
        )
        await MainActor.run { pastRepairContext = context }
        if !context.isEmpty {
            print("[Fixie] 📖 Loaded past repair context (\(context.count) chars)")
        }
    }

    /// Returns true when an AI reply mentions tools — used to activate the wrench scanner button
    /// immediately, even in chat-first sessions where seedInitialContext() is not called.
    /// Called by both performChatTurn (to set hasPendingToolsScan) and RepairHubView's
    /// shouldShowToolScanner (to keep the scanner accessible on every message re-render).
    func replyMentionsTools(_ text: String) -> Bool {
        let t = text.lowercased()
        let keywords = [
            "you'll need", "you will need", "gather these", "gather the following",
            "required tools", "tools needed", "tools required", "tools for this",
            "following tools", "before you start", "tools you'll need",
            // Common tool names — catches inline mentions like "grab a Phillips screwdriver"
            "screwdriver", "multimeter", "pliers", "wrench", "drill",
            "utility knife", "putty knife", "hammer", "level", "tape measure",
            "wire stripper", "voltage tester", "socket", "allen key", "hex key",
            "soldering", "heat gun", "pry bar", "caulk gun", "staple gun"
        ]
        return keywords.contains(where: { t.contains($0) })
    }

    /// Extracts a list of tool names from an AI reply that mentions tools.
    /// Looks for bullet/numbered list items that appear after a tool-listing phrase.
    /// Used in clarification/chat-first mode where guide.steps is empty.
    func extractToolsFromReply(_ text: String) -> [String] {
        let lower = text.lowercased()

        // Find where the tools section starts
        let sectionKeywords = [
            "you'll need:", "you will need:", "required tools:", "tools needed:",
            "tools required:", "gather these tools:", "following tools:",
            "tools you'll need:", "tools:", "materials needed:", "what you'll need:",
            // Curly/smart apostrophe variants (AI output often uses \u2019 instead of ASCII ')
            "you\u{2019}ll need:", "tools you\u{2019}ll need:", "what you\u{2019}ll need:"
        ]
        var sectionStart: String.Index? = nil
        for kw in sectionKeywords {
            if let r = lower.range(of: kw) {
                if sectionStart == nil || r.lowerBound < sectionStart! {
                    sectionStart = r.upperBound
                }
            }
        }

        // Parse whichever section we found (or the whole text as fallback)
        let parseRange = sectionStart.map { $0..<text.endIndex } ?? text.startIndex..<text.endIndex
        let section = String(text[parseRange])
        var tools: [String] = []

        // Action verbs that indicate a step instruction, not a tool name.
        // e.g. "Use the screwdriver to..." / "Create a Gap" / "Power Off the iPad" / "Lift the Screen"
        let actionVerbs: Set<String> = [
            "apply", "assemble", "attach", "avoid", "back", "begin", "carefully", "check",
            "clean", "close", "complete", "connect", "create", "disconnect",
            "discharge", "ensure", "gently", "hold", "insert", "install",
            "lift", "locate", "lower", "open", "peel", "place", "position", "power",
            "prepare", "press", "pry", "pull", "push", "put", "reassemble", "reassembly",
            "reconnect", "remove", "replace", "reseat", "route", "secure", "separate",
            "slide", "soften", "start", "test", "trim", "turn", "unplug", "unscrew",
            "verify", "use", "using", "wedge", "work", "clear", "cut", "wipe", "flush",
            "reset", "wrap", "tighten", "loosen", "charge", "dry", "rinse", "soak",
            "try", "none", "no",
            "flip", "position", "orient", "place", "set", "grab", "hold", "locate",
            "find", "identify", "check", "access", "expose", "prepare",
            "release", "open", "close", "press", "squeeze", "undo", "redo"
            // NOTE: "heat" and "warm" removed — they appear as noun adjuncts in tool names
            // like "Heat gun" and "Warm compress". Step instructions use them as verbs only
            // after longer phrases that are already caught by the word-count filter.
        ]

        // Section headers that signal the end of the tools list.
        // e.g. "**Repair Steps:**", "**Step-by-Step:**", "**Instructions:**"
        // NOTE: "here's how" intentionally removed — it's a conversational phrase
        // ("here's how to untangle it:") that appears BEFORE tool-embedded steps, not
        // a section header. Including it caused a premature break before any items were parsed.
        let stepSectionHeaders: [String] = [
            "repair step", "step-by-step", "instructions:", "repair plan:",
            "repair process:", "follow these step"
        ]

        for line in section.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let low = trimmed.lowercased()

            // Stop at "Step N" lines or any section header that marks the repair plan
            if low.hasPrefix("step ") || low.hasPrefix("**step") { break }
            if stepSectionHeaders.contains(where: { low.contains($0) }) { break }
            // Stop at any bold section header (e.g. "**Repair Plan:**") that isn't a tool group.
            // A bare "**" line (trimmed.count == 2) is the CLOSING markdown marker from the
            // already-matched "**Tools you'll need:**" header — skip it, don't break.
            if trimmed.hasPrefix("**") && (trimmed.hasSuffix(":**") || trimmed.hasSuffix("**")) {
                guard trimmed.count > 2 else { continue } // bare "**" = closing marker, not a header
                let headerLow = trimmed.lowercased()
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let isToolHeader = ["tool", "material", "supply", "part", "need", "require", "gather"]
                    .contains(where: { headerLow.contains($0) })
                if !isToolHeader { break }
            }

            // Extract bullet or numbered list items
            var candidate: String? = nil
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("* ") {
                candidate = String(trimmed.dropFirst(2))
            } else if let r = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                candidate = String(trimmed[r.upperBound...])
            }

            if var tool = candidate {
                // BREAK on numbered bold step titles like "**Safety First:** Remove the battery..."
                // We've moved past the tools section into the repair steps — stop parsing entirely.
                // Using break (not continue) ensures we don't pick up later step titles as tools.
                let trimmedCandidate = tool.trimmingCharacters(in: .whitespaces)
                if trimmedCandidate.hasPrefix("**") && trimmedCandidate.contains("**:") {
                    break
                }

                // Strip markdown bold, take only the part before a colon
                // (e.g. "Heat gun: for warming adhesive" → "Heat gun")
                tool = tool.replacingOccurrences(of: "**", with: "")
                tool = tool.components(separatedBy: ":").first ?? tool
                tool = tool.trimmingCharacters(in: .whitespaces)

                // Strip parenthetical text BEFORE word count check so
                // "Scissors or utility knife (if more cutting is needed)" → "Scissors or utility knife"
                // doesn't get rejected by the 7-word cap.
                if let parenIdx = tool.firstIndex(of: "(") {
                    tool = String(tool[..<parenIdx]).trimmingCharacters(in: .whitespaces)
                }

                // Skip if empty, too long, or a question
                guard !tool.isEmpty && tool.count < 60 && !tool.hasSuffix("?") else { continue }

                let firstWord = tool.components(separatedBy: " ").first?.lowercased() ?? ""

                // Skip questions (even without trailing ?)
                let questionStarters: Set<String> = ["have", "do", "did", "can", "will", "is",
                                                      "are", "does", "would", "should"]
                guard !questionStarters.contains(firstWord) else { continue }

                // Skip step instructions (action verb at the start).
                // For "tool-intro" verbs only (use/using/grab/get/take/need), salvage the tool
                // noun embedded in patterns like "Using scissors or a utility knife, carefully...".
                // Other repair verbs (pull, clean, press, etc.) don't embed tool names — skip entirely.
                if actionVerbs.contains(firstWord) {
                    let toolIntroVerbs: Set<String> = ["use", "using", "grab", "get", "take", "need", "with"]
                    guard toolIntroVerbs.contains(firstWord) else { continue }
                    // Drop the leading verb word and extract everything before the first comma/period
                    let afterVerb = tool.components(separatedBy: " ").dropFirst().joined(separator: " ")
                    let beforeDelimiter = afterVerb.components(separatedBy: CharacterSet(charactersIn: ",.")).first ?? afterVerb
                    // Split on "or" to handle "scissors or a utility knife"
                    for part in beforeDelimiter.components(separatedBy: " or ") {
                        var extracted = part.trimmingCharacters(in: .whitespaces)
                        // Strip leading articles (a, an, the)
                        for art in ["a ", "an ", "the "] where extracted.lowercased().hasPrefix(art) {
                            extracted = String(extracted.dropFirst(art.count))
                        }
                        // Strip trailing prepositions that signal a description, not a name
                        for suffix in [" to", " and", " carefully", " gently", " along"] where extracted.lowercased().hasSuffix(suffix) {
                            extracted = String(extracted.dropLast(suffix.count))
                        }
                        extracted = extracted.trimmingCharacters(in: .whitespaces)
                        let wc = extracted.components(separatedBy: " ").count
                        guard !extracted.isEmpty && extracted.count >= 3 && extracted.count < 50 && wc <= 4 else { continue }
                        // Skip plain prepositions/particles that slipped through (off, up, down, in, out)
                        let skipWords: Set<String> = ["off", "out", "up", "down", "on", "over",
                                                       "away", "apart", "back", "around"]
                        guard !skipWords.contains(extracted.lowercased()) else { continue }
                        let lower = extracted.lowercased()
                        if !tools.contains(where: { $0.lowercased() == lower }) {
                            tools.append(extracted)
                        }
                    }
                    continue
                }

                // Skip non-physical recommendations that slip past the actionVerbs filter.
                // NOTE: Device names (ipad, battery, screen, cable) intentionally removed —
                // they appear in valid replacement-part names like "New iPad Pro battery",
                // "Replacement screen", "USB-C cable". Step instructions using those words
                // are already caught by actionVerbs (e.g. "Disconnect the Battery" →
                // "disconnect" is in actionVerbs; "Lift the Screen" → "lift" is filtered).
                let toolLow = tool.lowercased()
                let nonToolWords = ["the board", "professional", "assistance", " help",
                                    "guidance", "consultation", "service", "warranty",
                                    "replacement kit", "none for this", "none needed",
                                    "none required", "no tools", "try a different",
                                    "try another", "n/a",
                                    "your hands", "bare hands", "both hands",
                                    "your hand", "bare hand"]
                guard !nonToolWords.contains(where: { toolLow.contains($0) }) else { continue }

                // Skip items that look like full sentences (7+ words = almost certainly a step)
                // Tool/part names like "New iPad Pro 12.9 battery" = 5 words are kept.
                let wordCount = tool.components(separatedBy: " ").count
                guard wordCount <= 7 else { continue }

                // Split on " or " to handle compound alternatives: "Scissors or a utility knife"
                let parts = tool.components(separatedBy: " or ")
                for var part in parts {
                    // Strip leading articles (a, an, the) from each part
                    for art in ["a ", "an ", "the "] where part.lowercased().hasPrefix(art) {
                        part = String(part.dropFirst(art.count))
                    }
                    part = part.trimmingCharacters(in: .whitespaces)
                    guard !part.isEmpty && part.count >= 3 && part.count < 60 else { continue }
                    let partLow = part.lowercased()
                    if !tools.contains(where: { $0.lowercased() == partLow }) {
                        tools.append(part)
                    }
                }
            }
        }
        return tools
    }

    /// Splits an AI reply that contains "**Tools you'll need:**" + numbered steps
    /// into two parts: (toolsSection, stepsSection).
    /// Returns (nil, nil) when no tools header is found — caller uses the full reply.
    private func splitToolsFromSteps(_ text: String) -> (String?, String?) {
        let toolsKeywords = [
            "**tools you'll need:**", "**tools you\u{2019}ll need:**",
            "**you'll need:**", "**you\u{2019}ll need:**",
            "**tools needed:**", "**tools required:**",
            "**what you'll need:**", "**what you\u{2019}ll need:**"
        ]
        let lower = text.lowercased()
        guard let kwRange = toolsKeywords.lazy.compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return (nil, nil)
        }

        // Find where the numbered steps begin after the tools header
        // (a line that starts with "1." or "1)") — that's the split point.
        let afterHeader = text[kwRange.upperBound...]
        var splitIdx: String.Index? = nil
        for line in afterHeader.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) != nil {
                if let idx = text.range(of: line, range: kwRange.upperBound..<text.endIndex)?.lowerBound {
                    splitIdx = idx
                    break
                }
            }
        }

        guard let split = splitIdx else {
            // No numbered steps found — entire reply is the tools section
            return (text, nil)
        }

        let toolsPart = String(text[text.startIndex..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
        let stepsPart = String(text[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (toolsPart.isEmpty ? nil : toolsPart,
                stepsPart.isEmpty ? nil : stepsPart)
    }

    /// Scans AI narrative text for part-indicator phrases and appends extracted part
    /// names to `partsRecommended`. Catches parts mentioned in prose (e.g. "you'll need
    /// to replace the brush roll") that never appear in the bullet-list format that
    /// `extractToolsFromReply` parses.
    private func extractPartsFromNarrative(_ text: String) {
        let lower = text.lowercased()
        let triggers = [
            "replace the ", "replacing the ", "replacement ",
            "a new ", "need a new ", "need the new ",
            "install a new ", "install the new ", "install a replacement ",
            "buy a new ", "order a new ", "purchase a new ",
            "buy a replacement ", "order a replacement ", "purchase a replacement "
        ]
        // Words that end a noun phrase (prepositions, conjunctions, pronouns)
        let stopWords: Set<String> = [
            "on", "of", "for", "to", "in", "with", "by", "and", "or", "but",
            "if", "is", "are", "was", "from", "at", "your", "their", "its",
            "this", "that", "which", "when", "where", "so", "as", "than",
            "using", "via", "into", "onto", "upon", "across", "before", "after"
        ]
        // Nouns too generic to be useful part names
        let skipNouns: Set<String> = [
            "it", "device", "appliance", "unit", "machine", "repair", "fix", "service",
            "part", "component", "item", "thing", "one", "them", "these", "those",
            "model", "brand", "system", "piece", "assembly"
        ]

        for trigger in triggers {
            var searchFrom = lower.startIndex
            while let r = lower.range(of: trigger, range: searchFrom..<lower.endIndex) {
                let after = String(lower[r.upperBound...])
                // Take words until we hit a stop word or punctuation (max 4 words)
                var nounWords: [String] = []
                for rawWord in after.components(separatedBy: .whitespacesAndNewlines)
                        .filter({ !$0.isEmpty }).prefix(4) {
                    let clean = rawWord.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()"))
                    guard !clean.isEmpty else { break }
                    guard !stopWords.contains(clean) else { break }
                    nounWords.append(clean)
                    // Stop if the word itself contained clause-ending punctuation
                    if rawWord.contains(",") || rawWord.contains(".") || rawWord.contains(";") { break }
                }
                let noun = nounWords.joined(separator: " ")
                if noun.count >= 3 && noun.count < 50 && nounWords.count >= 1 {
                    let isSkip = skipNouns.contains(where: { noun == $0 || noun.hasPrefix($0 + " ") })
                    if !isSkip { addPartIfNew(noun) }
                }
                searchFrom = r.upperBound
            }
        }
    }

    /// Returns a clean brand+model string, stripping AI placeholder values like
    /// "N/A", "Not a Major Appliance", "Unknown", etc.
    private func sanitizedDeviceModel() -> String {
        let raw = [guide.diagnosis?.brand ?? "", guide.diagnosis?.model ?? ""]
        return raw.filter { part in
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !t.isEmpty, t != "-", t != "n/a", t != "na" else { return false }
            guard !t.hasPrefix("unknown"), !t.hasPrefix("not a"), !t.hasPrefix("not an") else { return false }
            return true
        }.joined(separator: " ")
    }

    /// Called when the user closes ToolCheckView after a scan.
    /// Posts a scan summary in chat then asks the AI what to do about missing tools.
    func reportToolScanResults(found: [String], missing: [String]) {
        // Ignore if the scan found nothing at all (user closed before scanning)
        guard !found.isEmpty || !missing.isEmpty else { return }

        // Build a compact summary message
        var lines: [String] = ["**🔧 Tool Scan Complete**"]
        if !found.isEmpty {
            lines.append("✅ Found: \(found.joined(separator: ", "))")
        }
        if !missing.isEmpty {
            lines.append("❌ Missing: \(missing.joined(separator: ", "))")
        }
        messages.append(ChatMessage.contextMessage(lines.joined(separator: "\n")))

        // All tools confirmed — tell the AI so it proceeds with the first repair step
        if missing.isEmpty {
            let readyPrompt = found.isEmpty
                ? "Tool scan complete. No special tools needed for this repair. Please give me the first repair step."
                : "Tool scan complete. I have confirmed all required tools: \(found.joined(separator: ", ")). Please give me the first repair step now."
            Task { await performChatTurn(userText: readyPrompt) }
            return
        }

        // Expose missing tools so RepairHubView can show affiliate buy links
        missingToolsFromScan = missing

        // Ask the AI what to do — run as a background turn (no visible user bubble)
        let aiPrompt = missing.count == 1
            ? "Tool scan result: I have \(found.isEmpty ? "none of the tools" : found.joined(separator: ", ")) but I'm missing the \(missing[0]). Should I proceed without it, pause to order it, or call a pro?"
            : "Tool scan result: I have \(found.isEmpty ? "none of the required tools" : found.joined(separator: ", ")) but I'm missing \(missing.joined(separator: ", ")). Can I proceed without them, should I pause to order them, or is this a job for a pro?"
        Task { await performChatTurn(userText: aiPrompt) }
    }

    /// Sends a "Help / I'm Stuck" prompt for the current step without user typing.
    func requestStepHelp() {
        guard phase == .idle else { return }
        let stepTitle = guide.steps[safe: currentStepIndex]?.title ?? "this step"
        let helpText  = "I'm having trouble with \"\(stepTitle)\". Can you explain in more detail or suggest an alternative approach?"
        messages.append(ChatMessage.user(helpText))
        Task { await performChatTurn(userText: helpText) }
    }

    /// Logs the completed-but-failed steps to Firestore and prompts Gemini for an alternative path.
    func reportNotFixed() {
        guard !hasReportedNotFixed, phase == .idle else { return }
        hasReportedNotFixed = true

        let category    = guide.session.category
        let deviceModel = sanitizedDeviceModel()
        let symptom     = guide.diagnosis?.symptom ?? guide.session.title
        let failedSteps = guide.steps.map { $0.title }

        // Log to Firestore (fire-and-forget)
        Task {
            await FirebaseService.shared.logFailedDiagnostic(
                category:    category,
                deviceModel: deviceModel,
                symptom:     symptom,
                failedSteps: failedSteps
            )
            // Refresh local prior-failures so the very next turn picks them up
            await fetchPriorFailures()
        }

        // Ask Gemini for an alternative path
        let reportText = "I completed all the steps but the problem is still not fixed. Can you suggest an alternative diagnostic path?"
        messages.append(ChatMessage.user(reportText))
        Task { await performChatTurn(userText: reportText) }
    }

    // MARK: – Pause repair

    /// Saves current progress locally + Firestore and signals RepairHubView to dismiss.
    func pauseRepair(reason: String, missingTools: [String] = []) {
        pauseMissingTools = missingTools
        // Local cache: instant — "Continue Your Repair" card shows immediately on same device.
        buildActiveSession(status: "paused", pauseReason: reason, missingTools: missingTools).saveLocal()
        // Dismiss right away — don't wait for Firestore.
        hasPaused = true
        // Firebase save — authoritative store for cross-device resume.
        let g          = guide
        let idx        = currentStepIndex
        let total      = effectiveStepsTotal
        let savedMsgs  = messages.map { SavedChatMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
        Task {
            await FirebaseService.shared.saveActiveSession(
                guide:         g,
                stepIndex:     idx,
                status:        "paused",
                pauseReason:   reason,
                missingTools:  missingTools,
                stepsTotal:    total,
                savedMessages: savedMsgs
            )
        }
    }

    // MARK: – Pro called (contractor attribution)

    /// Records that the user handed the repair to a contractor.
    /// Saves to history with pro attribution and clears the active session.
    func onProCalled(_ name: String, phone: String?) {
        guard !didCallPro else { return }
        didCallPro    = true
        calledProName  = name
        calledProPhone = phone
        showRescueCard = false

        RepairHistoryStore.shared.save(
            guide:          guide,
            capturedImage:  capturedImage,
            stepsCompleted: currentStepIndex,
            proName:        name,
            proPhone:       phone
        )
        ActiveSession.removeLocal(guideId: guide.id.uuidString)
        Task { await FirebaseService.shared.clearActiveSession() }
    }

    // MARK: – Resolution tracking

    /// Starts a Firestore snapshot listener for the given lead.
    /// Handles both "claimed" (pro assigned) and "resolved" (repair complete) transitions.
    /// Also persists the pending lead to UserDefaults so HomeViewModel can restart
    /// the listener if the user navigates away before the pro claims the job.
    func startLeadListener(leadId: String, proName: String) {
        activeLeadId   = leadId
        pendingProName = proName
        ActiveServiceLead.savePendingLead(leadId: leadId, proName: proName)

        // Stamp the pendingLeadId on the saved session so HomeView can show
        // "Waiting for Pro" instead of "Continue Repair" for this session.
        var sessions = ActiveSession.loadAllLocal()
        if let idx = sessions.firstIndex(where: { $0.id == guide.id.uuidString }) {
            sessions[idx].pendingLeadId = leadId
            sessions[idx].saveLocal()
        }

        FirebaseService.shared.startLeadStatusListener(
            leadId:  leadId,
            proName: proName,
            onClaimed: { [weak self] lead in
                Task { @MainActor [weak self] in
                    self?.handleClaimed(lead)
                }
            },
            onResolved: { [weak self] resolution in
                Task { @MainActor [weak self] in
                    await self?.handleResolution(resolution)
                }
            }
        )
    }

    /// Pro has claimed the lead — persist to UserDefaults and update UI.
    private func handleClaimed(_ lead: ActiveServiceLead) {
        var existing = ActiveServiceLead.loadAllLocal()
        if let idx = existing.firstIndex(where: { $0.leadId == lead.leadId }) {
            existing[idx] = lead
        } else {
            existing.append(lead)
        }
        ActiveServiceLead.saveAllLocal(existing)
        ActiveServiceLead.clearPendingLead()
        pendingProName    = nil
        activeServiceLead = lead
        showRescueCard    = false   // dismiss the find-a-pro sheet; pro service card takes over
    }

    /// Handles a "resolved" status from the Firestore listener:
    /// migrates the repair to history, clears the active session, shows success screen.
    private func handleResolution(_ resolution: ProResolution) async {
        activeLeadId      = nil
        pendingProName    = nil
        activeServiceLead = nil
        ActiveServiceLead.clearLocal()
        ActiveServiceLead.clearPendingLead()

        // Migrate to cloud history; fall back to local store if Firestore fails
        let migrated = await FirebaseService.shared.migrateLeadToHistory(
            guide:      guide,
            proName:    resolution.proName,
            proPhone:   nil,
            resolution: resolution
        )
        if !migrated {
            RepairHistoryStore.shared.save(
                guide:          guide,
                capturedImage:  capturedImage,
                stepsCompleted: currentStepIndex,
                proName:        resolution.proName,
                proPhone:       nil
            )
        }

        // Clear active session — repair is complete
        ActiveSession.removeLocal(guideId: guide.id.uuidString)
        await FirebaseService.shared.clearActiveSession()

        // Present success screen (RepairHubView observes vm.resolvedLead)
        resolvedLead = resolution
    }

    // MARK: – Error mapping

    private static func friendlyError(_ error: Error) -> String {
        if let geminiErr = error as? GeminiError,
           case .apiError(_, _) = geminiErr {
            return "Something went wrong. Please try again."
        }
        if let urlErr = error as? URLError, urlErr.code == .notConnectedToInternet {
            return "No internet connection. Check your connection and try again."
        }
        return "Something went wrong. Please try again."
    }
}
