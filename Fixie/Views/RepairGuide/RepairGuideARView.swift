// Views/RepairGuide/RepairGuideARView.swift
// Based on user's starter code — fully implemented.
import SwiftUI
import RealityKit
import ARKit

struct RepairGuideARView: View {
    let guide: RepairGuide
    @Binding var currentStepIndex: Int

    // Coordinator bridge
    @State private var coordinator: ARRepairCoordinator?
    @State private var isLocked = false

    // Liquid Glass UI State
    @Environment(\.colorScheme) var colorScheme
    @Namespace private var arNamespace

    private var currentStep: RepairStep? {
        guide.steps[safe: currentStepIndex]
    }

    // Gemini bounding box for the current step's referenced part
    private var currentBoundingBox: PartBoundingBox? {
        guard let step = currentStep,
              let desc = step.arAnchorDescription?.lowercased() else { return nil }
        return guide.partBoundingBoxes.first { $0.partLabel.lowercased().contains(desc) }
            ?? guide.partBoundingBoxes.first
    }

    var body: some View {
        ZStack {
            // ── 3D Engine ─────────────────────────────────────────────
            ARRepairARViewContainer(
                boundingBox: .constant(currentBoundingBox),
                isLocked: $isLocked,
                stepLabel: currentStep?.arAnchorDescription,
                onCoordinatorReady: { coord in
                    coordinator = coord
                }
            )
            .ignoresSafeArea()

            // ── Liquid Glass Overlays ─────────────────────────────────
            VStack(spacing: 0) {
                // Top instruction strip
                HStack(alignment: .top) {
                    instructionHeader
                    Spacer()
                    lockIndicator
                }
                .padding(Theme.spacingM)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusM)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
                .padding(Theme.spacingM)

                Spacer()

                // Bottom step navigator
                stepNavigatorBar
                    .padding(.bottom, Theme.spacingM)
            }
        }
        .onChange(of: currentStepIndex) { _, _ in
            // Unlock marker when user advances to next step
            coordinator?.unlockMarker()
        }
    }

    // MARK: – Instruction header

    private var instructionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step \(currentStepIndex + 1) of \(guide.steps.count)")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .kerning(0.6)
            Text(currentStep?.title ?? "")
                .font(Theme.bodyBold)
                .foregroundStyle(Theme.textPrimary)
            if let anchor = currentStep?.arAnchorDescription {
                Label(anchor, systemImage: "arrow.down.circle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.brandPrimary)
            }
        }
    }

    // MARK: – Lock indicator

    private var lockIndicator: some View {
        Button {
            if isLocked {
                coordinator?.unlockMarker()
            } else {
                coordinator?.lockMarker()
            }
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isLocked ? Theme.brandPrimary : Theme.textSecondary)
                .padding(10)
                .background(
                    isLocked ? Theme.brandPrimary.opacity(0.2) : Color.white.opacity(0.08),
                    in: Circle()
                )
                .overlay(
                    Circle().strokeBorder(
                        isLocked ? Theme.brandPrimary.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isLocked)
    }

    // MARK: – Step navigator

    private var stepNavigatorBar: some View {
        HStack(spacing: Theme.spacingM) {
            // Previous
            Button {
                guard currentStepIndex > 0 else { return }
                currentStepIndex -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(currentStepIndex > 0 ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(currentStepIndex == 0)

            // Progress pips
            HStack(spacing: 6) {
                ForEach(guide.steps.indices, id: \.self) { idx in
                    Capsule()
                        .fill(idx == currentStepIndex ? Theme.brandPrimary
                              : idx < currentStepIndex ? Theme.brandSecondary
                              : Color.white.opacity(0.2))
                        .frame(width: idx == currentStepIndex ? 22 : 8, height: 6)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8),
                                   value: currentStepIndex)
                }
            }

            // Next / Done
            Button {
                if currentStepIndex < guide.steps.count - 1 {
                    coordinator?.triggerStepCompleteHaptic()
                    currentStepIndex += 1
                }
            } label: {
                Image(systemName: currentStepIndex < guide.steps.count - 1
                      ? "chevron.right" : "checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(Theme.brandPrimary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.spacingL)
        .padding(.vertical, Theme.spacingM)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: – Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
