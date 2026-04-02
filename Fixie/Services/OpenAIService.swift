// Services/OpenAIService.swift
// GPT-4o-mini fallback — same return types as GeminiService so AIManager
// can swap providers transparently. Uses the OpenAI Chat Completions API
// with vision support for image-based calls.
import Foundation

// MARK: – Errors

enum OpenAIError: LocalizedError {
    case invalidAPIKey
    case networkError(Error)
    case emptyResponse
    case jsonParseError(String)
    case apiError(Int, String)
    case audioNotSupported

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:       return "OpenAI API key is not configured."
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .emptyResponse:       return "OpenAI returned an empty response."
        case .jsonParseError(let s): return "Could not parse AI response: \(s)"
        case .apiError(let c, _):  return "AI service error \(c). Please try again."
        case .audioNotSupported:   return "Audio diagnosis requires Gemini. Please try again when quota resets."
        }
    }
}

// MARK: – Service

final class OpenAIService: Sendable {
    static let shared = OpenAIService()
    private init() {}

    private let session = URLSession.shared
    private let decoder = JSONDecoder()
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    // MARK: – Diagnosis (image) — returns the same payload type as GeminiService

    func diagnose(imageData: Data, category: RepairCategory) async throws -> GeminiDiagnosisPayload {
        let messages = buildMessages(
            system: diagnosisSystem(category: category),
            imageBase64: imageData.base64EncodedString(),
            userText: diagnosisPrompt(category: category)
        )
        let raw = try await execute(messages: messages, jsonMode: true)
        return try decodePayload(GeminiDiagnosisPayload.self, from: raw)
    }

    // MARK: – Product identification (quick, plain-text)

    /// Asks GPT-4o to name the specific product/device in the image.
    /// Used by `ProductIdentificationService` to cross-check Apple Vision's classification.
    /// Returns "" on any error — callers treat empty as "no result".
    func identifyProduct(imageData: Data, ocrBrand: String) async -> String {
        guard Config.openAIAPIKey != "YOUR_OPENAI_API_KEY_HERE" else { return "" }
        let brandHint = ocrBrand.isEmpty ? "" :
            " The image contains this text/brand: \"\(ocrBrand)\"."
        let system = """
            You are a product identification expert. \
            Respond with ONLY the brand name and model name of the product shown — nothing else. \
            Examples: "Tineco Floor One S5 Combo", "Dyson V15 Detect", "Samsung Galaxy S24". \
            No explanation. No punctuation at the end.
            """
        let messages = buildMessages(
            system: system,
            imageBase64: imageData.base64EncodedString(),
            userText: "Identify the specific product or device in this image.\(brandHint)"
        )
        return (try? await execute(messages: messages, jsonMode: false))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: – Audio diagnosis — gpt-4o-audio-preview fallback

    func diagnoseAudio(audioData: Data, category: RepairCategory) async throws -> GeminiDiagnosisPayload {
        guard Config.openAIAPIKey != "YOUR_OPENAI_API_KEY_HERE" else {
            throw OpenAIError.invalidAPIKey
        }
        let body = OAIAudioRequest(
            model: "gpt-4o-audio-preview",
            messages: [
                OAIAudioMessage(role: "system", content: .text(diagnosisSystem(category: category)
                    + "\nAlways respond with ONLY valid JSON — no markdown, no explanation outside the JSON.")),
                OAIAudioMessage(role: "user", content: .audioParts(
                    audio: OAIAudioRequest.InputAudio(
                        data: audioData.base64EncodedString(),
                        format: "mp4"
                    ),
                    text: diagnosisPrompt(category: category)
                ))
            ],
            max_completion_tokens: Config.maxOutputTokens,
            modalities: ["text"]
        )
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Config.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) }
        catch { throw OpenAIError.networkError(error) }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("⛔ OpenAI audio \(http.statusCode): \(body)")
            throw OpenAIError.apiError(http.statusCode, body)
        }
        let resp = try decoder.decode(OAIResponse.self, from: data)
        guard let text = resp.choices.first?.message.content, !text.isEmpty else {
            throw OpenAIError.emptyResponse
        }
        return try decodePayload(GeminiDiagnosisPayload.self, from: text)
    }

    // MARK: – Tool check

    func checkTools(imageData: Data, requiredTools: [String]) async throws -> GeminiToolCheckPayload {
        let toolList = requiredTools.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        Analyze this image of tools. Required tools for the job:
        \(toolList)

        Respond ONLY with valid JSON:
        {"missingTools":["string"],"availableTools":["string"],"readyToProceed":true,"notes":"string"}
        """
        let messages = buildMessages(
            system: toolCheckSystem,
            imageBase64: imageData.base64EncodedString(),
            userText: prompt
        )
        let raw = try await execute(messages: messages, jsonMode: true)
        return try decodePayload(GeminiToolCheckPayload.self, from: raw)
    }

    // MARK: – Tool sightings (NDJSON with bounding boxes — used by ToolCheckViewModel)

    func checkToolSightings(imageData: Data, requiredTools: [String]) async throws -> [GeminiService.ToolSighting] {
        let toolList = requiredTools.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        Scan this image and identify EVERY physical hand tool, instrument, or repair equipment \
        you can see (screwdrivers, spudgers, suction cups, heat guns, pry tools, tweezers, \
        pliers, etc.).

        Required tools for this job:
        \(toolList)

        IMPORTANT:
        - Only identify physical objects visible in the image.
        - The required list may contain action steps (e.g. "Power Off the device") — ignore those.
        - Use fuzzy matching: "screwdriver" matches "Pentalobe screwdriver P2".
        - If you see a tool kit or case, identify the individual tools inside it.

        For EACH physical tool you can see, output exactly ONE JSON object on its own line \
        (NDJSON). No markdown, no extra text, no arrays.
        Schema:
        {"tool":"short name","x":0.0,"y":0.0,"width":0.0,"height":0.0,"found":true}
        x,y,width,height are normalized 0–1 from the top-left of the image.
        Set found=true if the tool matches anything in the required list.
        End with: {"tool":"__done__","x":0,"y":0,"width":0,"height":0,"found":false}
        """
        let messages = buildMessages(
            system: "You are a tool identification expert. Analyze images of tools laid out on a surface. Respond ONLY with NDJSON — one JSON object per line, no markdown, no extra text.",
            imageBase64: imageData.base64EncodedString(),
            userText: prompt
        )
        let raw = try await execute(messages: messages, jsonMode: false)
        var sightings: [GeminiService.ToolSighting] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.hasPrefix("{"),
                  let d = trimmed.data(using: .utf8),
                  let s = try? JSONDecoder().decode(GeminiService.ToolSighting.self, from: d)
            else { continue }
            if s.tool == "__done__" { break }
            sightings.append(s)
        }
        return sightings
    }

    // MARK: – Multi-turn chat

    func chatTurn(
        history: [ChatMessage],
        newUserText: String,
        imageData: Data? = nil,
        guide: RepairGuide,
        priorFailures: [String] = [],
        pastRepairContext: String = ""
    ) async throws -> String {
        var msgs: [OAIMessage] = [
            OAIMessage(role: "system", content: .text(chatSystemPrompt(guide: guide, priorFailures: priorFailures, pastRepairContext: pastRepairContext)))
        ]
        for msg in history {
            let role = msg.role == .user ? "user" : "assistant"
            msgs.append(OAIMessage(role: role, content: .text(msg.text)))
        }
        if let img = imageData {
            msgs.append(OAIMessage(role: "user", content: .parts([
                .image(base64: img.base64EncodedString(), mimeType: "image/jpeg"),
                .text(newUserText)
            ])))
        } else {
            msgs.append(OAIMessage(role: "user", content: .text(newUserText)))
        }
        return try await execute(messages: msgs, jsonMode: false)
    }

    // MARK: – Wire types

    private struct OAIMessage: Encodable {
        let role: String
        let content: OAIContent
    }

    private enum OAIContent: Encodable {
        case text(String)
        case parts([OAIPart])

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .parts(let p): try c.encode(p)
            }
        }
    }

    private struct OAIPart: Encodable {
        let type: String
        let text: String?
        let image_url: ImageURL?

        struct ImageURL: Encodable {
            let url: String
            let detail: String = "auto"
        }

        static func text(_ s: String) -> OAIPart {
            OAIPart(type: "text", text: s, image_url: nil)
        }
        static func image(base64: String, mimeType: String) -> OAIPart {
            OAIPart(type: "image_url", text: nil,
                    image_url: ImageURL(url: "data:\(mimeType);base64,\(base64)"))
        }
    }

    private struct OAIChatRequest: Encodable {
        let model: String
        let messages: [OAIMessage]
        let max_completion_tokens: Int
        let response_format: ResponseFormat?

        struct ResponseFormat: Encodable { let type: String }
    }

    // MARK: – Audio request wire types (gpt-4o-audio-preview)

    private struct OAIAudioRequest: Encodable {
        struct InputAudio: Encodable {
            let data: String   // base64
            let format: String // "mp4", "wav", "mp3"
        }
        let model: String
        let messages: [OAIAudioMessage]
        let max_completion_tokens: Int
        let modalities: [String]

        enum CodingKeys: String, CodingKey {
            case model, messages, modalities
            case max_completion_tokens
        }
    }

    private struct OAIAudioMessage: Encodable {
        let role: String
        let content: AudioContent

        enum AudioContent: Encodable {
            case text(String)
            case audioParts(audio: OAIAudioRequest.InputAudio, text: String)

            func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let s):
                    var c = encoder.singleValueContainer()
                    try c.encode(s)
                case .audioParts(let audio, let text):
                    var c = encoder.unkeyedContainer()
                    try c.encode(AudioPart(type: "input_audio", input_audio: audio, text: nil))
                    try c.encode(AudioPart(type: "text", input_audio: nil, text: text))
                }
            }

            private struct AudioPart: Encodable {
                let type: String
                let input_audio: OAIAudioRequest.InputAudio?
                let text: String?
            }
        }
    }

    private struct OAIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    // MARK: – Network

    private func buildMessages(system: String, imageBase64: String, userText: String) -> [OAIMessage] {
        [
            OAIMessage(role: "system", content: .text(system)),
            OAIMessage(role: "user", content: .parts([
                .image(base64: imageBase64, mimeType: "image/jpeg"),
                .text(userText)
            ]))
        ]
    }

    private func execute(messages: [OAIMessage], jsonMode: Bool) async throws -> String {
        guard Config.openAIAPIKey != "YOUR_OPENAI_API_KEY_HERE" else {
            throw OpenAIError.invalidAPIKey
        }
        let body = OAIChatRequest(
            model: Config.openAIModel,
            messages: messages,
            max_completion_tokens: Config.maxOutputTokens,
            response_format: jsonMode ? .init(type: "json_object") : nil
        )
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Config.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OpenAIError.networkError(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("⛔ OpenAI \(http.statusCode): \(body)")
            throw OpenAIError.apiError(http.statusCode, body)
        }
        let resp = try decoder.decode(OAIResponse.self, from: data)
        guard let text = resp.choices.first?.message.content, !text.isEmpty else {
            throw OpenAIError.emptyResponse
        }
        return text
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        let cleaned = jsonString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else {
            throw OpenAIError.jsonParseError("UTF-8 encoding failed")
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw OpenAIError.jsonParseError(error.localizedDescription) }
    }

    // MARK: – Prompts

    private func diagnosisSystem(category: RepairCategory) -> String {
        """
        You are Fixie, an expert repair AI. \
        The user has hinted this may be a \(category.rawValue) item, but that is only a hint. \
        ALWAYS identify the actual device you see — tablet, phone, laptop, appliance, vehicle, tool, etc. \
        For brand and model: output what you can actually observe. \
        If you cannot read a label, describe the device type (e.g. "Tablet", "Laptop"). \
        NEVER output "N/A", "Not a \(category.rawValue)", or "Unknown" — always identify something. \
        Be concise, accurate, and safety-conscious. \
        Always respond with ONLY valid JSON — no markdown, no explanation outside the JSON.
        """
    }

    private let toolCheckSystem = """
    You are a tool identification expert. \
    Analyze images of tools laid out on a surface and match them against a required list. \
    Respond with ONLY valid JSON — no markdown, no explanation outside the JSON.
    """

    private func diagnosisPrompt(category: RepairCategory) -> String {
        """
        Category: \(category.rawValue)
        Apply Chain-of-Thought diagnosis. Respond ONLY with valid JSON matching this schema:
        {"brand":"string","model":"string","symptom":"string",
         "possibleFailures":["string"],"verificationStep":"string",
         "confidenceScore":0.0,"isSafeToProcceed":true,
         "repairSteps":[{"order":1,"title":"string","detail":"string",
           "arAnchorDescription":null,"toolsRequired":["string"],"warningNote":null}],
         "requiredParts":[{"name":"string","partNumber":"string","estimatedPrice":0.0}],
         "partBoundingBoxes":[]}
        """
    }

    private func chatSystemPrompt(guide: RepairGuide, priorFailures: [String] = [], pastRepairContext: String = "") -> String {
        let locationCtx = LocationService.shared.contextString
        var failureConstraint = ""
        if !priorFailures.isEmpty {
            let list = priorFailures.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            failureConstraint = "\nPRIOR FAILED STEPS — do NOT repeat these. Suggest an alternative path:\n\(list)"
        }
        return """
        You are Fixie, a \(guide.session.category.expertPersona) helping the user fix their \
        \(guide.session.category.rawValue).
        Guide them step-by-step through the repair. When you need to see a specific part, \
        say exactly: "Show me the [part name]".
        When your reply includes repair steps, output "**Tools you'll need:**" as a bullet list before the numbered steps.
        Location context: \(locationCtx.isEmpty ? "unknown" : locationCtx).\(failureConstraint)
        Keep responses concise and actionable.
        \(pastRepairContext.isEmpty ? "" : "\n\(pastRepairContext)")\(fixieSystemGuardrails)
        """
    }
}
