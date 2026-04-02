// Services/GeminiService.swift
import Foundation
import os

// MARK: – Errors

enum GeminiError: LocalizedError {
    case invalidAPIKey
    case networkError(Error)
    case emptyResponse
    case jsonParseError(String)
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:          return "Gemini API key is not configured."
        case .networkError(let e):    return "Network error: \(e.localizedDescription)"
        case .emptyResponse:          return "Gemini returned an empty response."
        case .jsonParseError(let s):  return "Could not parse AI response: \(s)"
        case .apiError(let c, let m): return "Gemini API error \(c): \(m)"
        }
    }
}

// MARK: – Wire types (Encodable/Decodable mirrors of Gemini REST API)

/// Shared content type used for both single-turn and multi-turn requests.
struct GeminiContent: Encodable {
    struct Part: Encodable {
        var text: String?
        var inlineData: InlineData?
        struct InlineData: Encodable {
            let mimeType: String
            let data: String   // base64
            enum CodingKeys: String, CodingKey { case mimeType, data }
        }
        enum CodingKeys: String, CodingKey { case text, inlineData }
    }
    let role: String
    let parts: [Part]
}

/// Multi-turn chat request — plain-text response.
private struct GeminiChatRequest: Encodable {
    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
        enum CodingKeys: String, CodingKey { case temperature, maxOutputTokens }
    }

    let systemInstruction: GeminiContent
    let contents: [GeminiContent]
    let generationConfig: GenerationConfig
}

private struct GeminiRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            var text: String?
            var inlineData: InlineData?

            struct InlineData: Encodable {
                let mimeType: String
                let data: String   // base64
                enum CodingKeys: String, CodingKey { case mimeType, data }
            }

            enum CodingKeys: String, CodingKey { case text, inlineData }
        }
        let role: String
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let responseMimeType = "application/json"
        let temperature: Double
        let maxOutputTokens: Int
        enum CodingKeys: String, CodingKey {
            case responseMimeType, temperature, maxOutputTokens
        }
    }

    let systemInstruction: Content
    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String }
            let parts: [Part]
        }
        let content: Content
    }
    struct PromptFeedback: Decodable {
        let blockReason: String?
    }
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}

// MARK: – Gemini raw diagnosis payload (what the model returns in JSON)

struct GeminiDiagnosisPayload: Decodable {
    struct PartInfo: Decodable {
        let name: String
        let partNumber: String
        let estimatedPrice: Double

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name             = (try? c.decodeIfPresent(String.self, forKey: .name))           ?? ""
            partNumber       = (try? c.decodeIfPresent(String.self, forKey: .partNumber))     ?? ""
            estimatedPrice   = (try? c.decodeIfPresent(Double.self, forKey: .estimatedPrice)) ?? 0
        }
        enum CodingKeys: String, CodingKey {
            case name, partNumber, estimatedPrice
        }
    }
    struct StepInfo: Decodable {
        let order: Int
        let title: String
        let detail: String
        let arAnchorDescription: String?
        let toolsRequired: [String]
        let warningNote: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            order                = (try? c.decodeIfPresent(Int.self,      forKey: .order))               ?? 0
            title                = (try? c.decodeIfPresent(String.self,   forKey: .title))               ?? ""
            detail               = (try? c.decodeIfPresent(String.self,   forKey: .detail))              ?? ""
            arAnchorDescription  =  try? c.decodeIfPresent(String.self,   forKey: .arAnchorDescription)
            toolsRequired        = (try? c.decodeIfPresent([String].self,  forKey: .toolsRequired))      ?? []
            warningNote          =  try? c.decodeIfPresent(String.self,    forKey: .warningNote)
        }
        enum CodingKeys: String, CodingKey {
            case order, title, detail, arAnchorDescription, toolsRequired, warningNote
        }
    }
    /// Normalized image-space bounding boxes for identified parts/components.
    /// x, y = top-left corner (0–1). Used by ARRepairView for raycast placement.
    struct PartBoundingBox: Decodable {
        let partLabel: String
        let x: Double        // normalized, 0–1
        let y: Double
        let width: Double
        let height: Double
        let confidence: Double

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            partLabel  = (try? c.decodeIfPresent(String.self, forKey: .partLabel))  ?? ""
            x          = (try? c.decodeIfPresent(Double.self, forKey: .x))          ?? 0
            y          = (try? c.decodeIfPresent(Double.self, forKey: .y))          ?? 0
            width      = (try? c.decodeIfPresent(Double.self, forKey: .width))      ?? 0
            height     = (try? c.decodeIfPresent(Double.self, forKey: .height))     ?? 0
            confidence = (try? c.decodeIfPresent(Double.self, forKey: .confidence)) ?? 0
        }
        enum CodingKeys: String, CodingKey {
            case partLabel, x, y, width, height, confidence
        }
    }

    let brand: String
    let model: String
    let symptom: String
    let possibleFailures: [String]
    let verificationStep: String
    let confidenceScore: Double
    let isSafeToProcceed: Bool
    let repairSteps: [StepInfo]
    let requiredParts: [PartInfo]
    let partBoundingBoxes: [PartBoundingBox]?
    /// YouTube search query: "How to [verb] [Brand] [Model] [Component] [Issue]".
    /// Example: "How to clean Ryobi P718 stick vacuum filter loss of suction"
    let youtubeSearchQuery: String
    /// Set to true by the Fixie backend when the image is ambiguous and the AI
    /// needs the user to describe the fault in text.  Triggers the clarification
    /// flow in seedInitialContext() (same path as confidenceScore < 0.8).
    let requiresClarification: Bool?
    /// Backend sets true when model identification is uncertain (e.g. shape-alike devices).
    /// Triggers ModelConfirmationCard in RepairHubView before generating the repair plan.
    let needsModelVerification: Bool?
    /// The model name the AI guessed (e.g. "Tineco Floor One S5"). Shown in the card.
    let suggestedModel: String?

    // Custom decoder: all fields have safe defaults so a partial backend response
    // never throws. The decoder's convertFromSnakeCase strategy is already applied
    // before CodingKeys are matched, so camelCase keys here map correctly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brand                  = (try? c.decodeIfPresent(String.self,          forKey: .brand))                ?? ""
        model                  = (try? c.decodeIfPresent(String.self,          forKey: .model))                ?? ""
        symptom                = (try? c.decodeIfPresent(String.self,          forKey: .symptom))              ?? ""
        possibleFailures       = (try? c.decodeIfPresent([String].self,        forKey: .possibleFailures))     ?? []
        verificationStep       = (try? c.decodeIfPresent(String.self,          forKey: .verificationStep))     ?? ""
        confidenceScore        = (try? c.decodeIfPresent(Double.self,          forKey: .confidenceScore))      ?? 0.0
        // Tolerate both spellings: server may spell "proceed" correctly.
        isSafeToProcceed       = (try? c.decodeIfPresent(Bool.self,            forKey: .isSafeToProcceed))
                              ?? (try? c.decodeIfPresent(Bool.self,            forKey: .isSafeToProceed))
                              ?? true
        repairSteps            = (try? c.decodeIfPresent([StepInfo].self,      forKey: .repairSteps))          ?? []
        requiredParts          = (try? c.decodeIfPresent([PartInfo].self,      forKey: .requiredParts))        ?? []
        partBoundingBoxes      =  try? c.decodeIfPresent([PartBoundingBox].self, forKey: .partBoundingBoxes)
        youtubeSearchQuery     = (try? c.decodeIfPresent(String.self,          forKey: .youtubeSearchQuery))   ?? ""
        requiresClarification  =  try? c.decodeIfPresent(Bool.self,            forKey: .requiresClarification)
        needsModelVerification =  try? c.decodeIfPresent(Bool.self,            forKey: .needsModelVerification)
        suggestedModel         =  try? c.decodeIfPresent(String.self,          forKey: .suggestedModel)
        detectedCategory       =  try? c.decodeIfPresent(String.self,          forKey: .detectedCategory)
        detectedDevice         =  try? c.decodeIfPresent(String.self,          forKey: .detectedDevice)
    }

    /// The AI-detected scope key (e.g. "itAndNetworking") returned by the backend.
    /// Takes priority over the user-hint category when building RepairSession.
    /// Mutable so SSE parsing can backfill from outer event fields when the
    /// `result` sub-object doesn't include it.
    var detectedCategory: String?

    /// Human-readable device name returned by the server once the fix lands
    /// (e.g. "iPad Pro 12.9").  When present, used verbatim in the clarification
    /// message instead of joining brand + model, which can produce "unknown unknown".
    var detectedDevice: String?

    enum CodingKeys: String, CodingKey {
        case brand, model, symptom, possibleFailures, verificationStep
        case confidenceScore
        case isSafeToProcceed              // server sends is_safe_to_procceed (typo)
        case isSafeToProceed               // server sends is_safe_to_proceed  (correct)
        case repairSteps, requiredParts, partBoundingBoxes
        case youtubeSearchQuery, requiresClarification
        case needsModelVerification, suggestedModel
        case detectedCategory, detectedDevice
    }
}

// MARK: – Gemini raw tool-check payload

struct GeminiToolCheckPayload: Decodable {
    let missingTools: [String]
    let availableTools: [String]
    let readyToProceed: Bool
    let notes: String
}

// MARK: – Service

final class GeminiService: Sendable {
    static let shared = GeminiService()
    private init() {}

    private let session = URLSession.shared
    private let decoder = JSONDecoder()

    // Thread-safe processing flag — prevents duplicate in-flight requests
    // (e.g. rapid taps, view re-renders) from hammering the API quota.
    private let _processingLock = OSAllocatedUnfairLock(initialState: false)
    var isProcessing: Bool { _processingLock.withLock { $0 } }

    /// Returns false if a request is already in-flight; sets the flag and returns true otherwise.
    private func beginRequest() -> Bool {
        _processingLock.withLock { state in
            guard !state else { return false }
            state = true
            return true
        }
    }
    private func endRequest() { _processingLock.withLock { $0 = false } }

    // MARK: – Product identification (quick, plain-text, no JSON mode)

    /// Asks Gemini to name the specific product/device in the image.
    /// Used by `ProductIdentificationService` to cross-check Apple Vision's classification.
    /// Returns "" on any error — callers treat empty as "no result".
    func identifyProduct(imageData: Data, ocrBrand: String) async -> String {
        guard Config.geminiAPIKey != "YOUR_GEMINI_API_KEY_HERE" else { return "" }
        let b64        = imageData.base64EncodedString()
        let brandHint  = ocrBrand.isEmpty ? "" :
            " The image contains this text/brand: \"\(ocrBrand)\"."
        let system     = """
            You are a product identification expert. \
            Respond with ONLY the brand name and model name of the product shown — nothing else. \
            Examples: "Tineco Floor One S5 Combo", "Dyson V15 Detect", "Samsung Galaxy S24". \
            No explanation. No punctuation at the end.
            """
        let userText   = "Identify the specific product or device in this image.\(brandHint)"

        let url = Config.geminiBaseURL
            .appendingPathComponent("\(Config.geminiModel):generateContent")
            .appending(queryItems: [URLQueryItem(name: "key", value: Config.geminiAPIKey)])

        let body = GeminiChatRequest(
            systemInstruction: GeminiContent(role: "system", parts: [.init(text: system)]),
            contents: [GeminiContent(role: "user", parts: [
                .init(inlineData: .init(mimeType: "image/jpeg", data: b64)),
                .init(text: userText)
            ])],
            generationConfig: .init(temperature: 0.1, maxOutputTokens: 50)
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(body)

        return (try? await executeRequest(req))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: – Diagnosis (image)

    func diagnose(
        imageData: Data,
        mimeType: String = "image/jpeg",
        category: RepairCategory? = nil
    ) async throws -> GeminiDiagnosisPayload {
        guard NetworkMonitor.shared.isConnected else {
            throw URLError(.notConnectedToInternet)
        }
        let b64 = imageData.base64EncodedString()
        let userPart = GeminiRequest.Content.Part(inlineData: .init(mimeType: mimeType, data: b64))
        let textPart = GeminiRequest.Content.Part(text: diagnosisPrompt(category: category))
        let content = GeminiRequest.Content(role: "user", parts: [userPart, textPart])
        return try await sendDiagnosis(content: content, category: category)
    }

    // MARK: – Diagnosis (audio – Listen mode)

    func diagnoseAudio(
        audioData: Data,
        mimeType: String = "audio/mp4",
        category: RepairCategory
    ) async throws -> GeminiDiagnosisPayload {
        guard NetworkMonitor.shared.isConnected else {
            throw URLError(.notConnectedToInternet)
        }
        let b64 = audioData.base64EncodedString()
        let audioPart = GeminiRequest.Content.Part(inlineData: .init(mimeType: mimeType, data: b64))
        let textPart  = GeminiRequest.Content.Part(text: audioDiagnosisPrompt(category: category))
        let content   = GeminiRequest.Content(role: "user", parts: [audioPart, textPart])
        return try await sendDiagnosis(content: content, category: category)
    }

    // MARK: – Streaming tool sightings (NDJSON line-by-line via SSE)
    //  Returns an AsyncThrowingStream that yields one ToolSighting per identified tool.
    //  The stream ends when Gemini finishes. Cancelled tasks stop the stream cleanly.

    struct ToolSighting: Decodable, Sendable {
        let tool: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let found: Bool
    }

    func streamToolSightings(
        imageData: Data,
        requiredTools: [String]
    ) -> AsyncThrowingStream<ToolSighting, Error> {
        let (stream, continuation) = AsyncThrowingStream<ToolSighting, Error>.makeStream()
        let capturedSelf = self

        Task {
            guard Config.geminiAPIKey != "YOUR_GEMINI_API_KEY_HERE" else {
                continuation.finish(throwing: GeminiError.invalidAPIKey); return
            }
            do {
                let url = Config.geminiBaseURL
                    .appendingPathComponent("\(Config.geminiModel):streamGenerateContent")
                    .appending(queryItems: [
                        URLQueryItem(name: "key",  value: Config.geminiAPIKey),
                        URLQueryItem(name: "alt",  value: "sse"),
                    ])

                let b64       = imageData.base64EncodedString()
                let imagePart = GeminiRequest.Content.Part(inlineData: .init(mimeType: "image/jpeg", data: b64))
                let toolList  = requiredTools.map { "- \($0)" }.joined(separator: "\n")
                let prompt    = """
                Scan this image and identify EVERY physical hand tool, instrument, or repair \
                equipment you can see (screwdrivers, spudgers, suction cups, heat guns, pry \
                tools, picks, tweezers, pliers, etc.).

                Required tools for this job:
                \(toolList)

                IMPORTANT:
                - Only output tools that are PHYSICAL objects you can see in the image.
                - The required list may contain action steps (e.g. "Power Off the iPad") — \
                  ignore those; they are not physical tools.
                - Use fuzzy matching: "screwdriver" matches "Pentalobe screwdriver P2"; \
                  "suction cup" matches "Suction handle".
                - If you see a tool kit / case, identify the individual tools inside it.

                For EACH physical tool you can see, output exactly ONE JSON object on its own \
                line (NDJSON). Do NOT wrap in arrays or add any other text.
                Schema per line:
                {"tool":"short canonical name","x":0.0,"y":0.0,"width":0.0,"height":0.0,"found":true}
                x,y,width,height are normalized 0–1 from top-left of image.
                For "tool": use the most specific short name possible (e.g. "pentalobe screwdriver", \
                "spudger", "suction cup", "tweezers", "pry pick"). Do NOT say "tool kit" or "set" — \
                name each individual tool inside the kit.
                Set found=true if the tool type matches anything in the required list (fuzzy ok — \
                "screwdriver" matches "Pentalobe screwdriver P2").
                End with: {"tool":"__done__","x":0,"y":0,"width":0,"height":0,"found":false}
                """
                let textPart = GeminiRequest.Content.Part(text: prompt)
                let content  = GeminiRequest.Content(role: "user", parts: [imagePart, textPart])
                let body     = GeminiRequest(
                    systemInstruction: .init(role: "system", parts: [.init(text: capturedSelf.toolCheckSystem)]),
                    contents: [content],
                    generationConfig: .init(temperature: 0.1, maxOutputTokens: 2048)
                )

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody   = try JSONEncoder().encode(body)

                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                var buffer = ""

                for try await line in bytes.lines {
                    // SSE lines look like: "data: {json}"
                    let jsonStr: String
                    if line.hasPrefix("data: ") {
                        jsonStr = String(line.dropFirst(6))
                    } else {
                        continue
                    }
                    // Extract the text delta from the Gemini chunk
                    if let data = jsonStr.data(using: .utf8),
                       let resp = try? capturedSelf.decoder.decode(GeminiResponse.self, from: data),
                       let text = resp.candidates?.first?.content.parts.first?.text {
                        buffer += text
                        // Parse complete NDJSON lines from buffer
                        var lines = buffer.components(separatedBy: "\n")
                        buffer = lines.removeLast() // keep incomplete last line
                        for fragment in lines {
                            let trimmed = fragment.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty,
                                  let d = trimmed.data(using: .utf8),
                                  let sighting = try? capturedSelf.decoder.decode(ToolSighting.self, from: d)
                            else { continue }
                            if sighting.tool == "__done__" { break }
                            continuation.yield(sighting)
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    // MARK: – Tool Check

    func checkTools(
        imageData: Data,
        requiredTools: [String]
    ) async throws -> GeminiToolCheckPayload {
        let b64 = imageData.base64EncodedString()
        let imagePart = GeminiRequest.Content.Part(inlineData: .init(mimeType: "image/jpeg", data: b64))
        let toolList  = requiredTools.map { "- \($0)" }.joined(separator: "\n")
        let prompt    = """
        The user is about to start a repair. Required tools for this job:
        \(toolList)

        Analyze the photo showing their available tools. Identify which tools are present and which are missing.
        Respond ONLY with valid JSON matching this exact schema:
        {
          "missingTools": ["string"],
          "availableTools": ["string"],
          "readyToProceed": true,
          "notes": "string"
        }
        """
        let textPart  = GeminiRequest.Content.Part(text: prompt)
        let content   = GeminiRequest.Content(role: "user", parts: [imagePart, textPart])

        let request   = buildRequest(content: content, system: toolCheckSystem)
        let rawJSON   = try await executeRequest(request)
        return try decodePayload(GeminiToolCheckPayload.self, from: rawJSON)
    }

    // MARK: – Private helpers

    private func sendDiagnosis(content: GeminiRequest.Content, category: RepairCategory?) async throws -> GeminiDiagnosisPayload {
        let request = buildRequest(content: content, system: diagnosisSystemPrompt(category: category))
        let rawJSON = try await executeRequest(request)
        return try decodePayload(GeminiDiagnosisPayload.self, from: rawJSON)
    }

    private func buildRequest(content: GeminiRequest.Content, system: String) -> URLRequest {
        let url = Config.geminiBaseURL
            .appendingPathComponent("\(Config.geminiModel):generateContent")
            .appending(queryItems: [URLQueryItem(name: "key", value: Config.geminiAPIKey)])

        let body = GeminiRequest(
            systemInstruction: .init(role: "system",
                                     parts: [.init(text: system)]),
            contents: [content],
            generationConfig: .init(
                temperature: 0.2,
                maxOutputTokens: Config.maxOutputTokens
            )
        )

        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody    = try? JSONEncoder().encode(body)
        return req
    }

    private func executeRequest(_ request: URLRequest) async throws -> String {
        guard Config.geminiAPIKey != "YOUR_GEMINI_API_KEY_HERE" else {
            throw GeminiError.invalidAPIKey
        }
        guard beginRequest() else {
            throw GeminiError.apiError(429, "Request already in progress")
        }
        defer { endRequest() }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GeminiError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("⛔ Gemini \(http.statusCode): \(body)")
            throw GeminiError.apiError(http.statusCode, body)
        }

        let geminiResp = try decoder.decode(GeminiResponse.self, from: data)

        if let block = geminiResp.promptFeedback?.blockReason {
            throw GeminiError.apiError(400, "Blocked: \(block)")
        }
        guard let text = geminiResp.candidates?.first?.content.parts.first?.text, !text.isEmpty else {
            throw GeminiError.emptyResponse
        }
        return text
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        // Strip any markdown code fences the model may wrap around the JSON
        let cleaned = jsonString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            throw GeminiError.jsonParseError("Could not encode response as UTF-8")
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GeminiError.jsonParseError(error.localizedDescription)
        }
    }

    // MARK: – Prompts

    /// Category-aware system prompt. The category is a user-supplied *hint* — the model
    /// must always identify the actual device visible in the image, regardless of hint,
    /// and proceed with the diagnostic for any item that falls within the 8 supported scopes.
    private func diagnosisSystemPrompt(category: RepairCategory?) -> String {
        let categoryHint = category.map { "The user hinted the category may be \"\($0.rawValue)\" — treat as a suggestion only." }
                        ?? "No category hint was provided — auto-classify to the correct scope below."
        return """
        You are Fixie, an expert repair AI that handles ALL household and personal repair needs.

        SUPPORTED CATEGORIES — ALWAYS proceed if the item fits any of these 8 scopes:
        1. Major Appliances    — fridges, washers, dryers, dishwashers, ovens, ranges
        2. Small Household     — toasters, blenders, coffee makers, vacuums (including stick vacs), fans
        3. Home Systems        — HVAC, furnaces, water heaters, electrical panels, plumbing
        4. Tech & Electronics  — TVs, gaming consoles, speakers, cameras, streaming devices
        5. Yard & Tools        — lawn mowers, snow blowers, power tools, sprinkler systems
        6. Automotive          — car batteries, tires, fluid checks, basic part identification
        7. Home & Structure    — windows, doors, drywall, locks, flooring, siding, trim
        8. IT & Networking     — laptops, desktops, Wi-Fi routers, mesh systems, printers

        \(categoryHint)
        ALWAYS identify the actual device you see and classify it into the correct scope above.
        NEVER say "I only help with [X]" or refuse for any item that fits one of the 8 scopes.

        OUT OF SCOPE — only decline (set isSafeToProcceed:false, symptom:"Out of scope") for items \
        completely unrelated to repair: food, beverages, clothing, living animals, artwork, medications, or people. \
        If the image is unclear, ask for a better photo via the notes field rather than refusing.

        For brand and model: output what you can observe. If the label is unreadable, describe the \
        device type (e.g. "HP Laptop", "TP-Link Mesh Router", "Ryobi Stick Vacuum"). \
        NEVER output "N/A", "Unknown", or any placeholder — always identify something.

        MODEL VERIFICATION — set needs_model_verification:true AND populate suggested_model whenever:
          • You can read a brand name but the model number is uncertain or could match multiple \
            very different product lines (e.g. a RYOBI number that could be a saw OR a vacuum)
          • The exact model number is not visibly legible in the image
          • The device shape matches a category but the specific model changes the repair steps \
            significantly (e.g. "Tineco" could be a mop, a vacuum, or a wet-dry cleaner)
          • OCR text is partially obscured or you are interpolating a model number
        When in doubt, set needs_model_verification:true — it is always better to ask than to \
        generate steps for the wrong device. Only set needs_model_verification:false when you can \
        clearly read both the brand AND the specific model number from the image.

        CRITICAL — FALSE POSITIVE PREVENTION:
        NEVER output a repairStep whose title is "No repair needed", "No issue found", \
        "Device is working correctly", "Good working condition", "No visible damage", or any variation. \
        The user is always reporting a real problem. If you cannot see a specific fault in the photo:
          • Set confidenceScore BELOW 0.80
          • Output an EMPTY repairSteps array []
          • Describe your best guess of the device in brand/model/symptom fields
          • The app will automatically ask the user to describe the issue in text
        NEVER dismiss a user's repair request. ALWAYS seek to find the problem, not dismiss it.

        Be concise, accurate, and safety-conscious.
        Always respond with ONLY valid JSON — no markdown, no explanation outside the JSON.
        """
    }

    private let toolCheckSystem = """
    You are a tool identification expert. \
    Analyze images of tools laid out on a surface and match them against a required list. \
    Respond with ONLY valid JSON — no markdown, no explanation outside the JSON.
    """

    private func diagnosisPrompt(category: RepairCategory?) -> String {
        let hintLine = category.map { "User-hinted category: \($0.rawValue) (suggestion only — auto-classify to the correct scope if needed)." }
                    ?? "No category hint — auto-classify the device to the correct scope."
        return """
        \(hintLine)
        Supported scopes: Major Appliances, Small Household, Home Systems, Tech & Electronics, \
        Yard & Tools, Automotive, Home & Structure, IT & Networking. \
        Proceed for any item in these scopes. Only decline for food, clothing, living animals, artwork, or people.
        Use Chain-of-Thought reasoning across these steps:
        1. IDENTIFY  – Identify the exact device you see: brand, model, and device type. \
           CRITICAL — MODEL VERIFICATION RULE: \
           Set needs_model_verification:TRUE and populate suggested_model unless you can \
           CLEARLY AND UNAMBIGUOUSLY read BOTH the brand name AND the exact model number \
           directly from the image (e.g. a label that says "RYOBI PCL705B2" in full). \
           If you are inferring, estimating, or uncertain about the model number in any way — \
           set needs_model_verification:TRUE. It is always better to ask the user than to generate \
           steps for the wrong device. Examples that MUST trigger verification: any RYOBI alphanumeric \
           code unless fully legible, any vacuum/appliance where model variants have different parts, \
           any device where the label is partially obscured or at an angle.
        2. SYMPTOM   – Describe the specific visible problem
        3. DIAGNOSE  – List the 3 most likely failure points, ranked by probability
        4. VERIFY    – One quick test a DIYer can do to confirm the root cause
        5. SAFETY    – Is this safe for a non-professional? Flag gas/electrical hazards
        6. REPAIR    – Ordered repair steps with tool requirements and AR hints
        7. PARTS     – Replacement parts with typical part numbers and prices

        8. LOCATE – For each key component you can visually identify, output its normalized
           bounding box (x, y = top-left corner; 0–1 range). This is used by the AR overlay
           to place a 3D pointer directly on the part.

        Respond ONLY with valid JSON matching this exact schema:
        {
          "brand": "string",
          "model": "string",
          "symptom": "string",
          "possibleFailures": ["string (most likely first)"],
          "verificationStep": "string",
          "confidenceScore": 0.0,
          "isSafeToProcceed": true,
          "repairSteps": [
            {
              "order": 1,
              "title": "string",
              "detail": "string",
              "arAnchorDescription": "string or null",
              "toolsRequired": ["string"],
              "warningNote": "string or null"
            }
          ],
          "requiredParts": [
            {
              "name": "string",
              "partNumber": "string",
              "estimatedPrice": 0.0
            }
          ],
          "partBoundingBoxes": [
            {
              "partLabel": "string",
              "x": 0.0,
              "y": 0.0,
              "width": 0.0,
              "height": 0.0,
              "confidence": 0.0
            }
          ],
          "youtubeSearchQuery": "How to [verb] [Brand] [Model] [component] [issue]",
          "detectedCategory": "one of: majorAppliances, smallHousehold, homeSystems, techAndElectronics, yardAndTools, automotive, homeAndStructure, itAndNetworking",
          "needs_model_verification": true,
          "suggested_model": "Brand + best-guess model name — ALWAYS populate this when needs_model_verification is true. Set needs_model_verification:false ONLY when brand+model are fully legible in the image."
        }

        For youtubeSearchQuery: craft a natural, specific YouTube search query combining the \
        identified brand, model, the most likely failing component, and the symptom. \
        Example: "How to clean Ryobi P718 stick vacuum filter loss of suction". \
        Use the most searchable phrasing — start with "How to fix", "How to replace", \
        "How to clean", etc. depending on the nature of the repair.

        For detectedCategory: output the camelCase key that best matches the actual device you identified. \
        Use the actual device scope, NOT the user-hinted category.
        """
    }

    // MARK: – Multi-turn chat (Repair Hub)

    /// Sends the full conversation history + a new user turn, returns the assistant reply.
    /// Sends the full conversation history + a new user turn, returns the assistant reply.
    func chatTurn(
        history: [ChatMessage],
        newUserText: String,
        imageData: Data? = nil,
        guide: RepairGuide,
        priorFailures: [String] = [],
        pastRepairContext: String = ""
    ) async throws -> String {
        guard NetworkMonitor.shared.isConnected else {
            throw URLError(.notConnectedToInternet)
        }
        // Build history from ChatMessage array
        var contents: [GeminiContent] = history.map { msg in
            let role = msg.role == .user ? "user" : "model"
            var parts: [GeminiContent.Part] = []
            if let img = msg.imageData {
                parts.append(.init(inlineData: .init(mimeType: "image/jpeg",
                                                      data: img.base64EncodedString())))
            }
            parts.append(.init(text: msg.text))
            return GeminiContent(role: role, parts: parts)
        }

        // New user turn
        var newParts: [GeminiContent.Part] = []
        if let img = imageData {
            newParts.append(.init(inlineData: .init(mimeType: "image/jpeg",
                                                     data: img.base64EncodedString())))
        }
        newParts.append(.init(text: newUserText))
        contents.append(GeminiContent(role: "user", parts: newParts))

        let system = chatSystemPrompt(guide: guide, priorFailures: priorFailures, pastRepairContext: pastRepairContext)
        let body = GeminiChatRequest(
            systemInstruction: GeminiContent(role: "system",
                                              parts: [.init(text: system)]),
            contents: contents,
            generationConfig: .init(temperature: 0.4,
                                    maxOutputTokens: Config.maxOutputTokens)
        )

        let url = Config.geminiBaseURL
            .appendingPathComponent("\(Config.geminiModel):generateContent")
            .appending(queryItems: [URLQueryItem(name: "key", value: Config.geminiAPIKey)])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        return try await executeRequest(req)
    }

    private func chatSystemPrompt(guide: RepairGuide, priorFailures: [String] = [], pastRepairContext: String = "") -> String {
        let symptom   = guide.diagnosis?.symptom ?? "unknown issue"
        let failures  = guide.diagnosis?.possibleFailures.prefix(2).joined(separator: ", ") ?? ""
        let steps     = guide.steps.map { "\($0.order). \($0.title)" }.joined(separator: "\n")

        // Inject live location + weather from LocationService (falls back gracefully)
        let locationCtx = LocationService.shared.contextString

        var failureConstraint = ""
        if !priorFailures.isEmpty {
            let list = priorFailures.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            failureConstraint = """


        PRIOR FAILED STEPS — do NOT repeat these for this device/symptom. \
        Suggest an alternative diagnostic path:
        \(list)
        """
        }

        return """
        You are Fixie, a \(guide.session.category.expertPersona) helping the user fix their \
        \(guide.session.category.rawValue).

        ACTIVE REPAIR CONTEXT:
        - Problem: \(symptom)
        - Likely causes: \(failures)
        - Repair steps planned:
        \(steps.isEmpty ? "(No steps yet — generate a plan based on the conversation)" : steps)

        LOCAL ENVIRONMENT:
        - Location & Weather: \(locationCtx)
        - Use this context to warn about temperature-related risks: frozen pipes below 32°F,
          brittle plastic clips in cold weather, heat stress on seals above 95°F, etc.
        - Suggest finding local contractors via the 'I'm Stuck' button if a High Danger
          flag applies (gas leaks, live electrical panels, refrigerants).\(failureConstraint)

        INSTRUCTIONS:
        - Guide the user step-by-step through the repair in plain conversational English.
        - If they send a new photo, analyze it in context of the repair.
        - When you need to see a specific part, say exactly: "Show me the [part name]"
          so the app can offer an inline camera button.
        - Keep responses concise and actionable. Use numbered lists for multi-step actions.
        - If this is a text-only session (no image), start by generating a clear repair plan.
        - Never repeat the full diagnosis unless asked.
        - CRITICAL — TOOL LIST FORMAT: Whenever your reply includes repair steps, you MUST
          output a "**Tools you'll need:**" section with a bullet list FIRST, before any
          numbered steps. Example:
            **Tools you'll need:**
            - Scissors
            - Utility knife

            1. Cut through the tangled debris...
          Never embed tools only inside step text. Always list them separately up front.
        \(pastRepairContext.isEmpty ? "" : "\n\n\(pastRepairContext)")\(fixieSystemGuardrails)
        """
    }

    private func audioDiagnosisPrompt(category: RepairCategory) -> String {
        """
        Category: \(category.rawValue)
        The user has recorded audio of a mechanical noise from their equipment.
        Analyze the sound characteristics (frequency, rhythm, intermittent vs. continuous, metallic vs. grinding etc.)
        and apply the same Chain-of-Thought diagnosis process.

        Respond ONLY with valid JSON using the same schema as the visual diagnosis.
        Set confidenceScore lower if the audio alone is ambiguous.
        Set partBoundingBoxes to an empty array for audio-only diagnosis.
        """
    }
}
