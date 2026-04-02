// ViewModels/ToolCheckViewModel.swift
import SwiftUI
import UIKit
import Observation
import AVFoundation

// MARK: – Identified tool model

struct IdentifiedTool: Identifiable {
    let id = UUID()
    var name: String
    var isRequired: Bool
    var isFound: Bool
    var boundingBox: PartBoundingBox?
}

// MARK: – Phase

enum ToolCheckPhase: Equatable {
    case idle
    case requestingPermission
    case scanning        // camera live, waiting for capture
    case streaming       // AI streaming results in real-time
    case done
    case error(String)
}

// MARK: – ViewModel

@Observable
@MainActor
final class ToolCheckViewModel {

    // MARK: State
    var phase: ToolCheckPhase = .idle
    var tools: [IdentifiedTool] = []
    var capturedImage: UIImage?
    var hintText = "Lay your tools flat on a surface and tap \"Take Photo\""

    let camera = CameraActor()

    private let gemini  = GeminiService.shared
    private let openai  = OpenAIService.shared
    private var streamTask: Task<Void, Never>?

    // MARK: – Init

    init(requiredTools: [String]) {
        self.tools = requiredTools.map {
            IdentifiedTool(name: $0, isRequired: true, isFound: false)
        }
    }

    var requiredTools: [String] { tools.filter(\.isRequired).map(\.name) }

    var missingTools: [IdentifiedTool] { tools.filter { $0.isRequired && !$0.isFound } }
    var foundRequired: [IdentifiedTool] { tools.filter { $0.isRequired && $0.isFound } }
    var allRequiredFound: Bool { missingTools.isEmpty }

    // MARK: – Session

    func requestAndStart() {
        #if targetEnvironment(simulator)
        // Simulator has no real camera XPC service — err=-17281 loops until session stops.
        // Show a clear placeholder instead of crashing into the XPC retry loop.
        phase = .error("Camera unavailable in Simulator.\nRun on a physical iPhone to scan tools.")
        return
        #endif
        phase = .requestingPermission
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                phase = .error("Camera access denied."); return
            }
            await camera.configure()
            await camera.startSession()
            phase = .scanning
        }
    }

    func stop() {
        streamTask?.cancel()
        Task { await camera.stopSession() }
    }

    // MARK: – Capture + stream analysis

    func scanTools() {
        guard case .scanning = phase else { return }
        hintText = "Capturing…"
        Task {
            do {
                let rawData = try await camera.capturePhoto()
                guard let img = UIImage(data: rawData) else {
                    phase = .error("Could not decode image."); return
                }
                capturedImage = img

                // Stop the camera immediately — user doesn't need to hold still.
                // The frozen photo is shown while AI analyzes in the background.
                await camera.stopSession()

                let compressed = compressImage(rawData)
                phase = .streaming
                hintText = "Identifying your tools…"

                streamTask = Task { await streamAnalysis(imageData: compressed) }

            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    // MARK: – Fuzzy name matching (shared by Gemini + GPT paths)

    private func toolsMatch(_ a: String, _ b: String) -> Bool {
        let aLow = a.lowercased(); let bLow = b.lowercased()
        if aLow.contains(bLow) || bLow.contains(aLow) { return true }
        let aWords = aLow.components(separatedBy: .whitespacesAndNewlines).filter { $0.count >= 4 }
        let bWords = bLow.components(separatedBy: .whitespacesAndNewlines).filter { $0.count >= 4 }
        return aWords.contains(where: { bWords.contains($0) })
    }

    // MARK: – Concurrent GPT-4o (primary) + Gemini streaming (real-time UX)

    private func streamAnalysis(imageData: Data) async {
        // Task.detached: GPT-4o runs on the global cooperative pool, truly parallel with Gemini.
        // async let / Task {} from @MainActor would serialize behind the main actor queue.
        let gptTask = Task.detached { [openai, requiredTools = self.requiredTools] in
            try? await openai.checkToolSightings(imageData: imageData, requiredTools: requiredTools)
        }

        // Gemini streams bounding-box sightings in real-time — chips + outlines appear immediately.
        var geminiSucceeded = false
        do {
            for try await sighting in gemini.streamToolSightings(
                imageData: imageData,
                requiredTools: requiredTools
            ) {
                guard !Task.isCancelled else { break }
                handleSighting(sighting)
            }
            geminiSucceeded = true
        } catch {
            // Gemini failed — GPT result is the sole source (no bounding boxes in that case)
        }

        guard !Task.isCancelled else { gptTask.cancel(); return }

        // Merge GPT-4o result: provides bounding boxes + marks any tool Gemini missed
        if let sightings = await gptTask.value {
            applyGPTSightings(sightings)
        } else if !geminiSucceeded {
            phase = .error("Could not analyze image. Please try again.")
            return
        }

        phase = .done
        hintText = allRequiredFound
            ? "All tools found — ready to go!"
            : "\(missingTools.count) tool(s) missing"
    }

    private func handleSighting(_ sighting: GeminiService.ToolSighting) {
        let box = PartBoundingBox(
            partLabel: sighting.tool,
            x: sighting.x, y: sighting.y,
            width: sighting.width, height: sighting.height,
            confidence: 1.0
        )
        // iOS fuzzy match is authoritative — don't trust Gemini's found field for required tools.
        if let idx = tools.firstIndex(where: { toolsMatch($0.name, sighting.tool) }) {
            let wasFound = tools[idx].isFound
            tools[idx].isFound     = true
            tools[idx].boundingBox = box
            if !wasFound { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        } else if sighting.found {
            tools.append(IdentifiedTool(name: sighting.tool, isRequired: false,
                                        isFound: true, boundingBox: box))
        }
    }

    // Applies GPT-4o's NDJSON sightings: marks tools found + fills bounding boxes Gemini missed.
    private func applyGPTSightings(_ sightings: [GeminiService.ToolSighting]) {
        for sighting in sightings {
            let box = PartBoundingBox(
                partLabel: sighting.tool,
                x: sighting.x, y: sighting.y,
                width: sighting.width, height: sighting.height,
                confidence: 1.0
            )
            if let idx = tools.firstIndex(where: { toolsMatch($0.name, sighting.tool) }) {
                let wasFound = tools[idx].isFound
                tools[idx].isFound = true
                // Use GPT-4o's bounding box only when Gemini didn't provide one
                if tools[idx].boundingBox == nil {
                    tools[idx].boundingBox = box
                }
                if !wasFound { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            } else if sighting.found {
                tools.append(IdentifiedTool(name: sighting.tool, isRequired: false,
                                            isFound: true, boundingBox: box))
            }
        }
    }

    // MARK: – Reset

    func reset() {
        streamTask?.cancel()
        tools = tools.map { var t = $0; t.isFound = false; t.boundingBox = nil; return t }
        capturedImage = nil
        phase = .scanning
        hintText = "Lay your tools flat and tap \"Take Photo\""
        // Restart the camera so the viewfinder is live again for the retake
        Task { await camera.startSession() }
    }

    // MARK: – Image compression

    private func compressImage(_ data: Data, maxSide: Int = 1024, quality: CGFloat = 0.8) -> Data {
        guard let img = UIImage(data: data) else { return data }
        let side = max(img.size.width, img.size.height)
        let scale = side > CGFloat(maxSide) ? CGFloat(maxSide) / side : 1.0
        let newSize = CGSize(width: (img.size.width * scale).rounded(),
                             height: (img.size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized  = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality) ?? data
    }
}
