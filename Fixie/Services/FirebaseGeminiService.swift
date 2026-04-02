// Services/FirebaseGeminiService.swift
// Firebase AI Logic SDK alternative backend.
// Drop-in replacement for GeminiService once you add GoogleService-Info.plist
// and `firebase-ios-sdk` via Swift Package Manager.
//
// Setup steps:
//  1. Create a Firebase project at console.firebase.google.com
//  2. Enable "Vertex AI in Firebase" (Firebase AI Logic)
//  3. Download GoogleService-Info.plist → drag into Xcode project root
//  4. Add firebase-ios-sdk package:  https://github.com/firebase/firebase-ios-sdk
//  5. Add `FirebaseAI` to linked frameworks
//  6. In DiagnosisEngine, replace `GeminiService.shared` with `FirebaseGeminiService.shared`
//
// IMPORTANT: Comment out the `import FirebaseAI` below until the SDK is added,
// otherwise the project will fail to compile.

import Foundation
// import FirebaseAI          ← uncomment after SDK setup
// import FirebaseCore        ← uncomment after SDK setup

// MARK: – Protocol (enables clean swap between direct REST and Firebase)

protocol AIBackend: Sendable {
    func diagnose(imageData: Data, category: RepairCategory) async throws -> GeminiDiagnosisPayload
    func diagnoseAudio(audioData: Data, category: RepairCategory) async throws -> GeminiDiagnosisPayload
    func checkTools(imageData: Data, requiredTools: [String]) async throws -> GeminiToolCheckPayload
    func streamToolSightings(imageData: Data, requiredTools: [String]) -> AsyncThrowingStream<GeminiService.ToolSighting, Error>
}

// MARK: – Make GeminiService conform to the protocol

extension GeminiService: AIBackend {
    func diagnose(imageData: Data, category: RepairCategory) async throws -> GeminiDiagnosisPayload {
        try await diagnose(imageData: imageData, mimeType: "image/jpeg", category: category)
    }
    func diagnoseAudio(audioData: Data, category: RepairCategory) async throws -> GeminiDiagnosisPayload {
        try await diagnoseAudio(audioData: audioData, mimeType: "audio/mp4", category: category)
    }
}

// MARK: – Firebase AI Logic implementation (stub — activate after SDK setup)

final class FirebaseGeminiService: AIBackend, Sendable {

    static let shared = FirebaseGeminiService()
    private init() {}

    // MARK: – Diagnosis (image)

    func diagnose(imageData: Data, category: RepairCategory) async throws -> GeminiDiagnosisPayload {
        // ── Activate after SDK setup ──────────────────────────────────
        // let ai    = FirebaseAI.firebaseAI(backend: .googleAI())
        // let model = ai.generativeModel(modelName: Config.geminiModel)
        // let image = try InlineDataPart(data: imageData, mimeType: "image/jpeg")
        // let resp  = try await model.generateContent(image, diagnosisPrompt(category: category))
        // return try parsePayload(GeminiDiagnosisPayload.self, from: resp.text ?? "")
        // ─────────────────────────────────────────────────────────────
        throw FirebaseAIError.sdkNotConfigured
    }

    // MARK: – Audio

    func diagnoseAudio(audioData: Data, category: RepairCategory) async throws -> GeminiDiagnosisPayload {
        throw FirebaseAIError.sdkNotConfigured
    }

    // MARK: – Tool check

    func checkTools(imageData: Data, requiredTools: [String]) async throws -> GeminiToolCheckPayload {
        throw FirebaseAIError.sdkNotConfigured
    }

    // MARK: – Streaming

    func streamToolSightings(imageData: Data, requiredTools: [String]) -> AsyncThrowingStream<GeminiService.ToolSighting, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: FirebaseAIError.sdkNotConfigured)
        }
    }

    // MARK: – Errors

    enum FirebaseAIError: LocalizedError {
        case sdkNotConfigured
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .sdkNotConfigured:
                return "Firebase AI SDK not configured. Follow the setup instructions in FirebaseGeminiService.swift."
            case .parseError(let msg):
                return "Firebase AI parse error: \(msg)"
            }
        }
    }
}
