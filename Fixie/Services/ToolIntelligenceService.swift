// Services/ToolIntelligenceService.swift
// Fuzzy-matches detected Vision labels against the current step's requiredTools.
// After a required tool has been absent from camera view for >5 seconds, it is
// promoted to buyReadyTools — the UI then surfaces an Amazon affiliate "Buy" button.
import Foundation

@Observable @MainActor
final class ToolIntelligenceService {

    // MARK: – Published state

    /// Tools missing from the frame for more than 5 seconds — show "Buy" for each.
    private(set) var buyReadyTools: [String] = []

    /// Tools currently detected in the most recent frame.
    private(set) var detectedTools: [String] = []

    // MARK: – Private tracking

    /// requiredTool → timestamp when we first noticed it absent.
    private var absenceSince: [String: Date] = [:]
    private var activeScanTask: Task<Void, Never>?

    // MARK: – Public API

    /// Analyse one camera frame against the required tools for the current step.
    /// Call whenever a new frame is ready (throttle to ~every 2 s to control cost).
    func scanFrame(imageData: Data, requiredTools: [String]) {
        activeScanTask?.cancel()
        activeScanTask = Task {
            var seen: Set<String> = []

            let stream = GeminiService.shared.streamToolSightings(
                imageData: imageData,
                requiredTools: requiredTools
            )
            do {
                for try await sighting in stream {
                    guard !Task.isCancelled else { return }
                    if sighting.found { seen.insert(sighting.tool) }
                }
            } catch {
                // Network or API error — skip this frame quietly
                return
            }

            guard !Task.isCancelled else { return }

            detectedTools = Array(seen)
            let now = Date()

            for tool in requiredTools {
                let visible = seen.contains { fuzzyScore($0, tool) > 0.6 }

                if visible {
                    absenceSince.removeValue(forKey: tool)
                } else {
                    let since = absenceSince[tool, default: now]
                    absenceSince[tool] = since
                    if now.timeIntervalSince(since) > 5, !buyReadyTools.contains(tool) {
                        buyReadyTools.append(tool)
                    }
                }
            }
        }
    }

    func reset() {
        activeScanTask?.cancel()
        absenceSince  = [:]
        buyReadyTools = []
        detectedTools = []
    }

    // MARK: – Fuzzy matching

    /// Jaccard-style word-overlap similarity, 0–1.
    private func fuzzyScore(_ a: String, _ b: String) -> Double {
        let lA = a.lowercased()
        let lB = b.lowercased()
        guard !lA.isEmpty && !lB.isEmpty else { return 0 }
        if lA == lB                            { return 1.0 }
        if lA.contains(lB) || lB.contains(lA) { return 0.85 }

        let wordsA = Set(lA.components(separatedBy: .whitespacesAndNewlines))
        let wordsB = Set(lB.components(separatedBy: .whitespacesAndNewlines))
        let union  = wordsA.union(wordsB).count
        guard union > 0 else { return 0 }
        return Double(wordsA.intersection(wordsB).count) / Double(union)
    }
}
