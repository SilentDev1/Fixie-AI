// Views/Home/RecentRepairCardView.swift
import SwiftUI

struct RecentRepairCardView: View {
    let session: RepairSession

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Background tinted glass
            RoundedRectangle(cornerRadius: Theme.radiusS)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusS)
                        .fill(
                            LinearGradient(
                                colors: [
                                    session.category.accentColor.opacity(0.25),
                                    session.category.accentColor.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            // Border
            RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(session.category.accentColor.opacity(0.35), lineWidth: 1)

            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                // Icon + status badge
                HStack {
                    Image(systemName: session.category.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(session.category.accentColor)
                    Spacer()
                    Image(systemName: session.isCompleted ? "checkmark.seal.fill" : "clock.fill")
                        .font(.caption)
                        .foregroundStyle(session.isCompleted ? Theme.brandSecondary : Theme.warningAmber)
                }

                Text(session.title)
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                Text(session.subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)

                Text(session.date, style: .date)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.spacingM)
        }
        .frame(width: 160, height: 140)
    }
}

#Preview {
    ScrollView(.horizontal) {
        HStack(spacing: 12) {
            ForEach(RepairSession.samples) { session in
                RecentRepairCardView(session: session)
            }
        }
        .padding()
    }
    .background(Color(hex: 0x1C1C1E))
}
