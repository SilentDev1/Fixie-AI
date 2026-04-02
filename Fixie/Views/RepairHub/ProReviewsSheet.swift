// Views/RepairHub/ProReviewsSheet.swift
// Reusable sheet that shows all reviews for a Fixie Verified Pro.
// Used from both VerifiedProCard (RescueCardView) and ProServiceCardView.
import SwiftUI

struct ProReviewsSheet: View {
    let proId:         String
    let businessName:  String
    let averageRating: Double
    let reviewCount:   Int

    @State private var reviews: [ContractorReview] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: Theme.spacingS) {
                    Text(businessName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: 6) {
                        proStarRatingView(averageRating)
                        Text(String(format: "%.1f", averageRating))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text("· \(reviewCount) \(reviewCount == 1 ? "review" : "reviews")")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, Theme.spacingL)
                .padding(.bottom, Theme.spacingM)

                Divider().background(.white.opacity(0.1))

                if isLoading {
                    Spacer()
                    ProgressView().tint(Color(hex: 0x2979FF))
                    Spacer()
                } else if reviews.isEmpty {
                    Spacer()
                    VStack(spacing: Theme.spacingS) {
                        Image(systemName: "star.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.textTertiary)
                        Text("No reviews yet")
                            .font(Theme.bodyRegular)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(reviews) { review in
                                ProReviewRow(review: review)
                                Divider().background(.white.opacity(0.07))
                            }
                        }
                        .padding(.bottom, Theme.spacingXL)
                    }
                }
            }
        }
        .task {
            reviews = await FirebaseService.shared.fetchContractorReviews(proId: proId)
            isLoading = false
        }
    }
}

struct ProReviewRow: View {
    let review: ContractorReview

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack {
                proStarRatingView(Double(review.rating))
                Spacer()
                Text(review.date, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 4) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                Text(review.customerName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                if !review.deviceModel.isEmpty {
                    Text("· \(review.deviceModel)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if !review.comment.isEmpty {
                Text(review.comment)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, Theme.spacingM)
    }
}

// Shared star helper for review sheets
func proStarRatingView(_ rating: Double) -> some View {
    HStack(spacing: 2) {
        ForEach(1...5, id: \.self) { i in
            let filled = rating >= Double(i)
            let half   = !filled && rating >= Double(i) - 0.5
            Image(systemName: filled ? "star.fill" : (half ? "star.leadinghalf.filled" : "star"))
                .font(.system(size: 11))
                .foregroundStyle(Color.yellow)
        }
    }
}
