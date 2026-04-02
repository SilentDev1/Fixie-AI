// Services/DiagnosisEngine.swift
import AVFoundation
import Foundation
import UIKit
import FoundationModels

// MARK: – Bounding box (public, used by ARRepairView)

struct PartBoundingBox {
    let partLabel: String
    /// All values normalized 0–1 relative to image dimensions.
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double

    /// Center point (normalized).
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
}

// MARK: – Conversion helpers: Gemini payload → app models
// Free function avoids name collision with GeminiDiagnosisPayload.PartBoundingBox

private func geminiPayloadToRepairGuide(_ payload: GeminiDiagnosisPayload, session: RepairSession) -> RepairGuide {
    let ytQuery = payload.youtubeSearchQuery.isEmpty
        ? DiagnosisResult.buildQuery(brand: payload.brand, model: payload.model, symptom: payload.symptom)
        : payload.youtubeSearchQuery
    let diagnosis = DiagnosisResult(
        brand:                   payload.brand,
        model:                   payload.model,
        symptom:                 payload.symptom,
        possibleFailures:        payload.possibleFailures,
        verificationStep:        payload.verificationStep,
        confidenceScore:         payload.confidenceScore,
        isSafeToProcceed:        payload.isSafeToProcceed,
        youtubeSearchQuery:      ytQuery,
        detectedDevice:          payload.detectedDevice,
        needsModelVerification:  payload.needsModelVerification ?? false,
        suggestedModel:          payload.suggestedModel
    )
    // Filter out false-positive "no repair needed" steps.
    // The AI is instructed never to produce these, but this guard catches edge cases
    // where the model ignores the instruction.  An empty steps array combined with
    // low confidence triggers the clarification flow in seedInitialContext().
    let falsePositiveTitles = ["no repair needed", "no issue", "no fault", "no visible",
                               "working correctly", "good condition", "no damage",
                               "device is fine", "no repair required", "not needed"]
    let filteredSteps = payload.repairSteps.filter { s in
        let lower = s.title.lowercased()
        return !falsePositiveTitles.contains(where: { lower.contains($0) })
    }
    // Non-physical phrases the AI sometimes puts into toolsRequired.
    // These are safety notes, step titles, or instructions — not real tools.
    let nonPhysicalToolPhrases = [
        "safety first", "safety", "caution", "warning", "note:",
        "step ", "first ", "always ", "make sure", "ensure",
        "turn off", "unplug", "disconnect", "remove battery",
        "protective gear", "common sense", "good lighting",
        "none for this", "none needed", "none required",
        "try a different", "try another", "no tools", "n/a",
        "flip it", "flip over", "flip the", "position the", "place the",
        "locate the", "find the", "identify the", "check the", "access the",
        "your hands", "bare hands", "both hands", "your hand", "bare hand",
        "release the", "open the", "press the"
    ]
    let actionVerbPrefixes = [
        "remove", "unplug", "disconnect", "ensure", "check", "turn",
        "locate", "find", "identify", "inspect", "test", "verify",
        "clean", "clear", "prepare", "position", "place", "set",
        "release", "open", "press", "squeeze", "flip", "grab", "hold",
        "pull", "push", "lift", "slide", "insert", "attach", "secure"
    ]
    let steps = filteredSteps.map { s in
        let filteredTools = s.toolsRequired.filter { tool in
            let low = tool.lowercased().trimmingCharacters(in: .whitespaces)
            guard !low.isEmpty, low.count >= 3, low.count < 50 else { return false }
            // Drop anything that matches a non-physical phrase
            if nonPhysicalToolPhrases.contains(where: { low.contains($0) }) { return false }
            // Drop step-instruction lines (start with an action verb)
            let firstWord = low.components(separatedBy: " ").first ?? ""
            if actionVerbPrefixes.contains(firstWord) { return false }
            return true
        }
        return RepairStep(
            order:               s.order,
            title:               s.title,
            detail:              s.detail,
            arAnchorDescription: s.arAnchorDescription,
            toolsRequired:       filteredTools,
            warningNote:         s.warningNote
        )
    }
    let parts = payload.requiredParts.map { p in
        RepairPart(name: p.name, partNumber: p.partNumber, estimatedPrice: p.estimatedPrice)
    }
    let boxes: [PartBoundingBox] = payload.partBoundingBoxes?.map { b in
        PartBoundingBox(partLabel: b.partLabel, x: b.x, y: b.y,
                        width: b.width, height: b.height, confidence: b.confidence)
    } ?? []
    return RepairGuide(session: session, diagnosis: diagnosis,
                       steps: steps, requiredParts: parts, partBoundingBoxes: boxes)
}

// MARK: – Tool check result (public)

struct ToolCheckResult {
    let missingTools: [String]
    let availableTools: [String]
    let readyToProceed: Bool
    let notes: String
}

// MARK: – Diagnosis engine

final class DiagnosisEngine: Sendable {

    // All image diagnosis routes through FixieBackendService (server-side Gemini).
    // AIManager is kept for audio diagnosis and tool check (no backend endpoint yet).
    private var ai: AIManager { AIManager.shared }
    private let backend = FixieBackendService.shared

    // MARK: – Primary diagnosis (image)

    func diagnose(imageData: Data,
                  category: RepairCategory? = nil,
                  userDescription: String = "") async throws -> RepairGuide {
        // Compress before upload: caps at 1024px longest side, 0.75 JPEG quality.
        // Typical result: ~150–300 KB vs 5–12 MB raw — keeps round-trip < 3 s.
        let compressed = compress(imageData, maxSidePixels: 1024, quality: 0.5)

        // ── Diagnosis: backend first, direct Gemini fallback on notDeployed ─────
        // Routes through the Fixie backend (server-side Gemini) whenever it is
        // reachable.  If the backend times out or returns 404/503 (Replit sleeping
        // or not yet deployed), we fall back silently to the direct Gemini path so
        // the user is never blocked.  HTTP errors (400, 401, 500) and parse errors
        // are NOT silently swallowed — they indicate a bug that needs fixing.
        let payload: GeminiDiagnosisPayload
        do {
            payload = try await backend.diagnose(
                imageData:       compressed,
                category:        category,
                userDescription: userDescription
            )
            print("[Fixie] ✅ Diagnosis via backend")
        } catch FixieBackendService.BackendError.notDeployed {
            // Server unreachable / sleeping — fall back to direct Gemini.
            print("[Fixie] ⚠️ Backend unreachable, falling back to direct Gemini")
            payload = try await ai.diagnose(imageData: compressed, category: category ?? .majorAppliances)
            print("[Fixie] ✅ Diagnosis via direct Gemini (fallback)")
        } catch let err as FixieBackendService.BackendError {
            // HTTP or parse error — surface to the user (server is up, something is wrong).
            print("[Fixie] ❌ Backend error: \(err.localizedDescription ?? "")")
            throw err
        } catch {
            print("[Fixie] ❌ Network error: \(error.localizedDescription)")
            throw error
        }

        let resolvedCategory = resolveCategory(from: payload, hint: category)
        print("[Fixie] 📂 Detected category: \(resolvedCategory.rawValue)")

        // On-device safety pre-screen
        let onDeviceClear = await safetyPreScreen(category: resolvedCategory)

        let session = RepairSession(
            category:    resolvedCategory,
            title:       payload.symptom.isEmpty ? "New Repair" : payload.symptom,
            subtitle:    [payload.brand, payload.model].filter { !$0.isEmpty }.joined(separator: " "),
            isCompleted: false
        )

        var guide = geminiPayloadToRepairGuide(payload, session: session)

        // Safety override
        if !onDeviceClear { guide.diagnosis?.isSafeToProcceed = false }

        // `requires_clarification: true` from the backend means the AI could not see
        // a specific fault.  Force confidence to 0 so seedInitialContext() shows the
        // clarification prompt ("I've identified this as a [device], but I don't see
        // any obvious physical damage — could you describe what's wrong?").
        if payload.requiresClarification == true {
            guide.diagnosis?.confidenceScore = 0.0
        }

        return guide
    }

    // MARK: – Re-diagnose after model verification

    /// Called when the user confirms (or corrects) the device model in ModelConfirmationCard.
    /// Sends a fresh request to /api/diagnose with `confirmed_model` so the server can produce
    /// steps tailored to the exact device — fixes shape-based misclassifications like
    /// "Tineco floor cleaner" being mistaken for a washing machine.
    func rediagnose(confirmedModel: String,
                    imageData: Data,
                    category: RepairCategory?,
                    userDescription: String = "") async throws -> RepairGuide {
        let compressed = compress(imageData, maxSidePixels: 1024, quality: 0.5)
        let payload: GeminiDiagnosisPayload
        do {
            payload = try await backend.diagnose(
                imageData:       compressed,
                category:        category,
                userDescription: userDescription,
                confirmedModel:  confirmedModel
            )
            print("[Fixie] ✅ Re-diagnose via backend (confirmedModel: \(confirmedModel))")
        } catch FixieBackendService.BackendError.notDeployed {
            print("[Fixie] ⚠️ Backend unreachable for re-diagnose, falling back to direct Gemini")
            payload = try await ai.diagnose(imageData: compressed,
                                            category: category ?? .techAndElectronics)
        }
        let resolvedCategory = resolveCategory(from: payload, hint: category)
        let onDeviceClear    = await safetyPreScreen(category: resolvedCategory)
        let aiSubtitle       = [payload.brand, payload.model]
            .filter { !$0.isEmpty && $0.lowercased() != "unknown" }
            .joined(separator: " ")
        let session = RepairSession(
            category:    resolvedCategory,
            title:       payload.symptom.isEmpty ? "Repair" : payload.symptom,
            subtitle:    aiSubtitle.isEmpty ? confirmedModel : aiSubtitle,
            isCompleted: false
        )
        var guide = geminiPayloadToRepairGuide(payload, session: session)
        if !onDeviceClear { guide.diagnosis?.isSafeToProcceed = false }
        // A confirmed model should always produce a plan — don't re-trigger verification gate
        guide.diagnosis?.needsModelVerification = false
        return guide
    }

    // MARK: – Streaming diagnosis (progressive UX)

    /// Events from `diagnoseStream()`. The caller iterates the stream and updates UI
    /// for each `.status` event; `.guide` is always the final event.
    enum DiagnoseStreamEvent: Sendable {
        case status(String)
        /// Device name from the backend's first SSE chunk — fires before `.guide`.
        /// CameraView uses this to update the header chip immediately.
        case detectedItem(String)
        case guide(RepairGuide)
    }

    /// Streaming version of `diagnose()` for progressive UX.
    ///
    /// Immediately starts emitting local status messages on a 3-second cycle.
    /// When the backend responds with SSE, those real events take over.
    /// When the backend returns regular JSON (current state), local messages keep cycling
    /// until the payload arrives — giving the "streaming" feel with zero backend changes.
    func diagnoseStream(imageData: Data,
                        category: RepairCategory? = nil,
                        userDescription: String = "",
                        detectedItemName: String = "") -> AsyncThrowingStream<DiagnoseStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let compressed = compress(imageData, maxSidePixels: 1024, quality: 0.5)

                // ── Local status cycling ──────────────────────────────────────
                // Rotates every 3 s while the network call is in-flight.
                // Cancelled the moment the backend starts sending real SSE events.
                let localStatuses = [
                    "Fixie AI Master Technician is on the case…",
                    "Consulting the global repair database…",
                    "Drafting the perfect plan for you…",
                    "Almost ready…"
                ]
                let timerTask = Task {
                    for text in localStatuses {
                        guard !Task.isCancelled else { return }
                        continuation.yield(.status(text))
                        try? await Task.sleep(for: .seconds(3))
                    }
                }

                var finalPayload: GeminiDiagnosisPayload?

                // ── Backend stream ────────────────────────────────────────────
                do {
                    for try await event in backend.diagnoseStream(
                        imageData:        compressed,
                        category:         category,
                        userDescription:  userDescription,
                        detectedItemName: detectedItemName
                    ) {
                        switch event {
                        case .status(let text):
                            timerTask.cancel()       // real SSE — stop local cycling
                            continuation.yield(.status(text))
                        case .detectedItem(let name):
                            // Forward immediately so CameraView can update the header chip
                            // before the full guide arrives.
                            continuation.yield(.detectedItem(name))
                        case .result(let p):
                            finalPayload = p
                            print("[Fixie] ✅ Diagnosis via backend stream")
                        }
                    }
                } catch FixieBackendService.BackendError.notDeployed {
                    print("[Fixie] ⚠️ Backend unreachable, falling back to Gemini")
                    do {
                        finalPayload = try await ai.diagnose(imageData: compressed, category: category ?? .majorAppliances)
                        print("[Fixie] ✅ Diagnosis via Gemini (fallback)")
                    } catch {
                        timerTask.cancel()
                        continuation.finish(throwing: error); return
                    }
                } catch {
                    timerTask.cancel()
                    continuation.finish(throwing: error); return
                }

                timerTask.cancel()

                guard let payload = finalPayload else {
                    continuation.finish(throwing: FixieBackendService.BackendError.parseError("No payload received"))
                    return
                }

                // ── Build RepairGuide ─────────────────────────────────────────
                let resolvedCategory = resolveCategory(from: payload, hint: category)
                print("[Fixie] 📂 Detected category: \(resolvedCategory.rawValue)")

                let onDeviceClear = await safetyPreScreen(category: resolvedCategory)
                // Subtitle: AI brand+model takes priority (e.g. "Yeedi Cube Robot Vacuum").
                // Vision result is a fallback only when Gemini gives nothing useful.
                let aiSubtitle = [payload.brand, payload.model]
                    .filter { !$0.isEmpty && $0.lowercased() != "unknown" }
                    .joined(separator: " ")
                let subtitle = aiSubtitle.isEmpty ? detectedItemName : aiSubtitle
                let session = RepairSession(
                    category:    resolvedCategory,
                    title:       payload.symptom.isEmpty ? "New Repair" : payload.symptom,
                    subtitle:    subtitle,
                    isCompleted: false
                )
                var guide = geminiPayloadToRepairGuide(payload, session: session)
                if !onDeviceClear { guide.diagnosis?.isSafeToProcceed = false }
                if payload.requiresClarification == true { guide.diagnosis?.confidenceScore = 0.0 }

                continuation.yield(.guide(guide))
                continuation.finish()
            }
        }
    }

    // MARK: – Video diagnosis (via backend multipart endpoint)

    func diagnoseVideo(videoData: Data,
                       category: RepairCategory? = nil,
                       userDescription: String = "") async throws -> RepairGuide {
        let payload: GeminiDiagnosisPayload
        do {
            payload = try await backend.diagnoseVideo(
                videoData:       videoData,
                category:        category,
                userDescription: userDescription
            )
            print("[Fixie] ✅ Video diagnosis via backend")
        } catch FixieBackendService.BackendError.notDeployed {
            // Backend sleeping — extract first frame and fall back to image diagnosis.
            print("[Fixie] ⚠️ Video backend unreachable, falling back to frame extraction")
            guard let frame = extractFirstFrame(from: videoData),
                  let frameData = frame.jpegData(compressionQuality: 0.75) else {
                throw FixieBackendService.BackendError.notDeployed
            }
            let compressed = compress(frameData, maxSidePixels: 1024, quality: 0.75)
            payload = try await ai.diagnose(imageData: compressed, category: category ?? .majorAppliances)
            print("[Fixie] ✅ Video fallback via direct Gemini (first frame)")
        } catch let err as FixieBackendService.BackendError {
            print("[Fixie] ❌ Video backend error: \(err.localizedDescription ?? "")")
            throw err
        } catch {
            print("[Fixie] ❌ Video network error: \(error.localizedDescription)")
            throw error
        }

        let resolvedCategory = resolveCategory(from: payload, hint: category)
        print("[Fixie] 📂 Detected category: \(resolvedCategory.rawValue)")

        let onDeviceClear = await safetyPreScreen(category: resolvedCategory)

        let session = RepairSession(
            category:    resolvedCategory,
            title:       payload.symptom.isEmpty ? "Video Diagnosis" : payload.symptom,
            subtitle:    [payload.brand, payload.model].filter { !$0.isEmpty }.joined(separator: " "),
            isCompleted: false
        )

        var guide = geminiPayloadToRepairGuide(payload, session: session)
        if !onDeviceClear { guide.diagnosis?.isSafeToProcceed = false }
        if payload.requiresClarification == true { guide.diagnosis?.confidenceScore = 0.0 }
        return guide
    }

    // MARK: – Audio / Listen-mode diagnosis

    /// `audioFormat` is the AVAudioFormat captured from `CameraActor.lastAudioFormat`.
    /// When provided, the raw Float32 PCM chunks are encoded to WAV before upload.
    /// Falls back to direct AI path if the backend is unreachable.
    func diagnoseAudio(audioData: Data,
                       audioFormat: AVAudioFormat? = nil,
                       category: RepairCategory) async throws -> RepairGuide {
        // Build WAV from raw Float32 PCM if we have the audio format.
        let uploadData = audioFormat.map { buildWAV(pcmData: audioData, format: $0) } ?? audioData

        async let onDeviceClearTask = safetyPreScreen(category: category)

        do {
            let payload = try await backend.diagnoseAudio(audioData: uploadData, category: category)
            print("[Fixie] ✅ Audio diagnosis via backend")

            let onDeviceClear = await onDeviceClearTask
            let resolvedCategory = resolveCategory(from: payload, hint: category)
            let session = RepairSession(
                category: resolvedCategory,
                title:    payload.symptom.isEmpty ? "Audio Diagnosis" : payload.symptom,
                subtitle: [payload.brand, payload.model].filter { !$0.isEmpty }.joined(separator: " ")
            )
            var guide = geminiPayloadToRepairGuide(payload, session: session)
            if !onDeviceClear { guide.diagnosis?.isSafeToProcceed = false }
            if payload.requiresClarification == true { guide.diagnosis?.confidenceScore = 0.0 }
            return guide
        } catch {
            // Backend unreachable — fall back to direct AIManager path.
            print("[Fixie] ⚠️ Audio backend unavailable, falling back to AI: \(error.localizedDescription)")
            let (onDeviceClear, payload) = try await (onDeviceClearTask,
                                                      ai.diagnoseAudio(audioData: audioData, category: category))
            let session = RepairSession(
                category: category,
                title:    payload.symptom.isEmpty ? "Audio Diagnosis" : payload.symptom,
                subtitle: [payload.brand, payload.model].filter { !$0.isEmpty }.joined(separator: " ")
            )
            var guide = geminiPayloadToRepairGuide(payload, session: session)
            if !onDeviceClear { guide.diagnosis?.isSafeToProcceed = false }
            return guide
        }
    }

    // MARK: – WAV encoder (Float32 PCM → 16-bit mono WAV)

    /// Converts raw Float32 PCM bytes (as emitted by CameraActor.rawData()) into a
    /// standard 16-bit mono WAV file suitable for multipart upload.
    /// Channels are laid out sequentially by rawData(); only ch0 is used (iPhone mic = mono).
    private func buildWAV(pcmData: Data, format: AVAudioFormat) -> Data {
        let sampleRate    = UInt32(format.sampleRate)
        let channels      = UInt16(1)          // always mono
        let bitsPerSample = UInt16(16)
        let chanCount     = max(1, Int(format.channelCount))
        let totalFloats   = pcmData.count / MemoryLayout<Float32>.size
        let frameCount    = totalFloats / chanCount   // ch0 frames start at index 0

        // Float32 → Int16 clamp-scale
        var int16 = [Int16](repeating: 0, count: frameCount)
        pcmData.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float32.self)
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, floats[i]))
                int16[i] = Int16(clamped * 32_767)
            }
        }
        let audioBytes = int16.withUnsafeBytes { Data($0) }

        let byteRate   = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize   = UInt32(audioBytes.count)

        var header = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        header.append(contentsOf: "RIFF".utf8); le32(36 + dataSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8); le32(16); le16(1) // PCM
        le16(channels); le32(sampleRate); le32(byteRate); le16(blockAlign); le16(bitsPerSample)
        header.append(contentsOf: "data".utf8); le32(dataSize)
        return header + audioBytes
    }

    // MARK: – Tool check

    func checkTools(imageData: Data, requiredTools: [String]) async throws -> ToolCheckResult {
        let compressed = compress(imageData, maxSidePixels: 1024, quality: 0.80)
        let raw = try await ai.checkTools(imageData: compressed, requiredTools: requiredTools)
        return ToolCheckResult(missingTools:   raw.missingTools,
                               availableTools: raw.availableTools,
                               readyToProceed: raw.readyToProceed,
                               notes:          raw.notes)
    }

    // MARK: – Video frame extraction (fallback helper)

    /// Extracts the first readable frame from raw MP4 data. Returns nil if AVFoundation
    /// can't decode the data (e.g. corrupted clip). Used as a fallback when the
    /// video backend endpoint is unreachable.
    private func extractFirstFrame(from videoData: Data) -> UIImage? {
        // Write to a temporary file — AVURLAsset requires a file URL.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        do { try videoData.write(to: tmp) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset     = AVURLAsset(url: tmp)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: – Image compression

    /// Resizes to `maxSidePixels` on the longest side, then JPEG compresses.
    /// Dramatically reduces payload: a 12 MP photo goes from ~8 MB to ~200 KB.
    private func compress(_ data: Data, maxSidePixels: Int, quality: CGFloat) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let size    = image.size
        let maxSide = max(size.width, size.height)

        let target: CGSize
        if maxSide <= CGFloat(maxSidePixels) {
            target = size
        } else {
            let scale = CGFloat(maxSidePixels) / maxSide
            target = CGSize(width: (size.width  * scale).rounded(),
                            height: (size.height * scale).rounded())
        }

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized  = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality) ?? data
    }

    // MARK: – Category resolution (shared across all diagnosis paths)

    /// Resolves the final RepairCategory from a backend payload.
    /// Priority:
    ///   1. `payload.detectedCategory` — AI-provided key (requires updated Replit prompt)
    ///   2. Keyword inference from brand/model/symptom — catches iPads, TVs, routers, etc.
    ///      when the backend omits detectedCategory
    ///   3. `hint` — user's pre-scan chip selection
    ///   4. `.majorAppliances` — last resort
    private func resolveCategory(from payload: GeminiDiagnosisPayload,
                                  hint: RepairCategory?) -> RepairCategory {
        // 1. Backend-provided key
        if let key = payload.detectedCategory, !key.isEmpty {
            if let cat = RepairCategory.fromFirestoreKey(key) { return cat }
            if let cat = RepairCategory.allCases.first(where: { $0.rawValue == key }) { return cat }
        }
        // 2. Keyword inference — runs when backend hasn't sent detectedCategory yet
        if let inferred = inferCategoryFromText(
            brand: payload.brand, model: payload.model, symptom: payload.symptom
        ) { return inferred }
        // 3. User hint, or .techAndElectronics as a neutral fallback
        // (.majorAppliances was the old default — wrong for phones, tablets, TVs, etc.)
        return hint ?? .techAndElectronics
    }

    /// Keyword-based category inference from AI-returned brand/model/symptom text.
    /// Used as a safety net when the backend does not yet emit `detectedCategory`.
    private func inferCategoryFromText(brand: String, model: String, symptom: String) -> RepairCategory? {
        let text = "\(brand) \(model) \(symptom)".lowercased()

        // IT & Networking — check before techAndElectronics (routers are IT, not generic tech)
        let itWords = ["router", "modem", "wi-fi", "wifi", "mesh", "access point",
                       "ethernet", "cable modem", "deco", "orbi", "eero", "netgear",
                       "tp-link", "asus router", "network switch", "printer", "scanner",
                       "nas ", " nas", "network attached"]
        if itWords.contains(where: { text.contains($0) }) { return .itAndNetworking }

        // Tech & Electronics — phones, tablets, computers, TVs, AV gear
        let techWords = ["ipad", "iphone", "ipod", "macbook", "imac", "mac pro", "mac mini",
                         "apple watch", "airpod", "tablet", "laptop", "chromebook", "surface",
                         "android", "pixel", "galaxy", "kindle", "e-reader",
                         "television", " tv ", " tv,", " tv.", "smart tv", "oled", "qled",
                         "monitor", "display", "projector",
                         "camera", "dslr", "mirrorless",
                         "speaker", "soundbar", "headphone", "earphone", "earbuds",
                         "game console", "playstation", "xbox", "nintendo",
                         "smartwatch", "wearable", "drone"]
        if techWords.contains(where: { text.contains($0) }) { return .techAndElectronics }

        // Automotive
        let autoWords = ["car ", "truck", "vehicle", "suv", "van ", "engine", "brake",
                         "transmission", "alternator", "radiator", "tire ", "catalytic",
                         "honda", "toyota", "ford ", "chevy", "chevrolet", "bmw", "mercedes",
                         "audi", "jeep", "dodge", "nissan", "hyundai", "kia ", "subaru",
                         "volkswagen", "tesla", "lexus", "acura"]
        if autoWords.contains(where: { text.contains($0) }) { return .automotive }

        // Yard & Outdoor Tools
        let yardWords = ["lawnmower", "lawn mower", "chainsaw", "leaf blower", "snow blower",
                         "pressure washer", "string trimmer", "weed eater", "tiller",
                         "hedge trimmer", "log splitter", "generator", "riding mower"]
        if yardWords.contains(where: { text.contains($0) }) { return .yardAndTools }

        // Home Systems (HVAC, plumbing, electrical panels)
        let homeSystemWords = ["furnace", "boiler", "water heater", "hvac", "heat pump",
                               "air handler", "breaker panel", "circuit breaker", "fuse box",
                               "thermostat", "sump pump", "water softener"]
        if homeSystemWords.contains(where: { text.contains($0) }) { return .homeSystems }

        return nil   // unknown — caller falls back to hint or .majorAppliances
    }

    // MARK: – On-device Foundation Models safety pre-screen

    private func safetyPreScreen(category: RepairCategory) async -> Bool {
        guard #available(iOS 26.0, *) else { return true }
        do {
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return true }
            let session = LanguageModelSession(model: model)
            let prompt  = """
            A user wants to DIY-repair: \(category.rawValue) — \(category.subtitle).
            Reply with ONLY one word — SAFE or CAUTION — based on general risk level.
            Gas systems, high-voltage panels, refrigerants, and HVAC are CAUTION.
            """
            let response = try await session.respond(to: prompt)
            return !response.content.uppercased().contains("CAUTION")
        } catch {
            return true
        }
    }
}
