// Views/RepairHub/RepairSuccessView.swift
// Presented as .fullScreenCover when a Fixie Verified Pro marks a lead "resolved".
// High-energy success state with the pro's tech notes, then an inline review prompt.
import SwiftUI

struct RepairSuccessView: View {
    let resolution: ProResolution
    var onDone: () -> Void = {}

    @State private var appeared      = false
    @State private var showReview    = false

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            if showReview {
                ContractorReviewSheet(
                    proId:           resolution.proId,
                    proName:         resolution.proName,
                    proBusinessName: resolution.proBusinessName,
                    leadId:          resolution.leadId,
                    deviceModel:     resolution.deviceModel,
                    onComplete:      onDone
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                successContent
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showReview)
        .onAppear { appeared = true }
    }

    // MARK: – Success content

    private var successContent: some View {
        VStack(spacing: Theme.spacingL) {
            Spacer()

            // ── Animated success emblem ───────────────────────────────
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.green.opacity(0.28), Color.green.opacity(0.07)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 136, height: 136)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
            }
            .scaleEffect(appeared ? 1 : 0.3)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.55, dampingFraction: 0.65), value: appeared)

            // ── Headline ──────────────────────────────────────────────
            VStack(spacing: Theme.spacingS) {
                Text("Repair Successful! 🎉")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Fixed by \(resolution.proName)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
            }
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.45).delay(0.18), value: appeared)

            // ── Tech notes card (shown only when non-empty) ───────────
            if !resolution.resolutionNotes.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacingS) {
                    Label("Tech Notes", systemImage: "note.text")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)

                    Text(resolution.resolutionNotes)
                        .font(Theme.bodyRegular)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(Theme.spacingM)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: Theme.radiusS))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusS)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.30), value: appeared)
            }

            Spacer()

            // ── Rate this pro ─────────────────────────────────────────
            VStack(spacing: Theme.spacingS) {
                Button {
                    withAnimation { showReview = true }
                } label: {
                    Label("Rate \(resolution.proBusinessName.isEmpty ? resolution.proName : resolution.proBusinessName)",
                          systemImage: "star.fill")
                        .font(Theme.bodyBold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingM)
                        .background(Theme.brandSecondary,
                                    in: RoundedRectangle(cornerRadius: Theme.radiusM))
                }
                .buttonStyle(.plain)

                Button(action: onDone) {
                    Text("Skip — Go Home")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, Theme.spacingS)
                }
                .buttonStyle(.plain)
            }
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.4).delay(0.42), value: appeared)
            .padding(.bottom, Theme.spacingL)
        }
        .padding(.horizontal, Theme.spacingL)
    }
}
