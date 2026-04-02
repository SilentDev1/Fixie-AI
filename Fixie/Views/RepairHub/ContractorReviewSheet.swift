// Views/RepairHub/ContractorReviewSheet.swift
// Reusable star-rating + comment sheet for reviewing a Fixie Verified Pro.
// Used inline in RepairSuccessView (post-resolution) and as a sheet from HistoryDetailView.
import SwiftUI

struct ContractorReviewSheet: View {
    let proId:           String
    let proName:         String
    let proBusinessName: String
    let leadId:          String
    let deviceModel:     String
    var onComplete:      () -> Void = {}

    @State private var selectedRating  = 0
    @State private var comment         = ""
    @State private var isSubmitting    = false
    @State private var submitted       = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 36, height: 5)
                    .padding(.top, Theme.spacingM)
                    .padding(.bottom, Theme.spacingL)

                if submitted {
                    submittedState
                } else {
                    ratingContent
                }
            }
            .padding(.horizontal, Theme.spacingL)
        }
    }

    // MARK: – Rating form

    private var ratingContent: some View {
        VStack(spacing: Theme.spacingL) {
            // Header
            VStack(spacing: Theme.spacingXS) {
                Image(systemName: "star.bubble.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.brandSecondary)

                Text("Rate Your Experience")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Text(proBusinessName.isEmpty ? proName : proBusinessName)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textSecondary)

                if !deviceModel.isEmpty {
                    Text(deviceModel)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .multilineTextAlignment(.center)

            // Star selector
            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= selectedRating ? "star.fill" : "star")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(star <= selectedRating
                            ? Color.yellow
                            : Theme.textTertiary.opacity(0.5))
                        .scaleEffect(star <= selectedRating ? 1.1 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: selectedRating)
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedRating = star
                        }
                }
            }
            .padding(.vertical, Theme.spacingS)

            // Rating label
            if selectedRating > 0 {
                Text(ratingLabel)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(ratingColor)
                    .transition(.opacity.combined(with: .scale))
            }

            // Comment field (shown once a star is tapped)
            if selectedRating > 0 {
                VStack(alignment: .leading, spacing: Theme.spacingXS) {
                    Text("Tell others about your experience (optional)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)

                    TextField("What went well? How was the service?", text: $comment, axis: .vertical)
                        .font(Theme.bodyRegular)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3...6)
                        .padding(Theme.spacingM)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
                            .strokeBorder(Theme.brandPrimary.opacity(0.25), lineWidth: 1))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer(minLength: 0)

            // Submit button
            Button {
                Task { await submit() }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().tint(.black)
                    } else {
                        Text("Submit Review")
                            .font(Theme.bodyBold)
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.spacingM)
                .background(
                    selectedRating > 0
                        ? AnyShapeStyle(Theme.brandSecondary)
                        : AnyShapeStyle(Theme.textTertiary.opacity(0.25)),
                    in: RoundedRectangle(cornerRadius: Theme.radiusM)
                )
            }
            .buttonStyle(.plain)
            .disabled(selectedRating == 0 || isSubmitting)

            // Skip
            Button {
                onComplete()
                dismiss()
            } label: {
                Text("Skip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, Theme.spacingS)
            }
            .buttonStyle(.plain)

            Spacer(minLength: Theme.spacingL)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedRating)
    }

    // MARK: – Thank-you state

    private var submittedState: some View {
        VStack(spacing: Theme.spacingL) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.brandSecondary)
            Text("Thanks for your review!")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Your feedback helps other homeowners choose the right pro.")
                .font(Theme.bodyRegular)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                onComplete()
                dismiss()
            } label: {
                Text("Done")
                    .font(Theme.bodyBold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingM)
                    .background(Theme.brandSecondary, in: RoundedRectangle(cornerRadius: Theme.radiusM))
            }
            .buttonStyle(.plain)
            Spacer(minLength: Theme.spacingL)
        }
    }

    // MARK: – Helpers

    private var ratingLabel: String {
        switch selectedRating {
        case 1: return "Poor"
        case 2: return "Fair"
        case 3: return "Good"
        case 4: return "Great"
        case 5: return "Excellent!"
        default: return ""
        }
    }

    private var ratingColor: Color {
        switch selectedRating {
        case 1, 2: return Theme.dangerRed
        case 3:    return Theme.warningAmber
        default:   return Theme.brandSecondary
        }
    }

    private func submit() async {
        isSubmitting = true
        await FirebaseService.shared.submitReview(
            proId:       proId,
            leadId:      leadId,
            rating:      selectedRating,
            comment:     comment,
            proName:     proName,
            deviceModel: deviceModel
        )
        // Mark history entry reviewed so the prompt doesn't re-appear
        if let entry = RepairHistoryStore.shared.entries.first(where: { $0.leadId == leadId }) {
            entry.hasReviewed = true
            RepairHistoryStore.shared.loadEntries()
        }
        isSubmitting = false
        withAnimation { submitted = true }
    }
}
