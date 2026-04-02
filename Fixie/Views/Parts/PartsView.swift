// Views/Parts/PartsView.swift
import SwiftUI

struct PartsView: View {
    let guide: RepairGuide

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            if guide.requiredParts.isEmpty {
                emptyState
            } else {
                partsList
            }
        }
        .navigationTitle("Parts & Shop")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var partsList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Theme.spacingM) {
                ForEach(guide.requiredParts) { part in
                    partRow(part)
                }
                callAProButton
                AffiliateDisclaimerBadge()
            }
            .padding(Theme.spacingM)
        }
    }

    private func partRow(_ part: RepairPart) -> some View {
        HStack(spacing: Theme.spacingM) {
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Text(part.name)
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                Text("Part #\(part.partNumber)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                Label(
                    part.isAvailableLocally ? "Available locally" : "Ships 1-2 days",
                    systemImage: part.isAvailableLocally ? "mappin.circle.fill" : "shippingbox.fill"
                )
                .font(Theme.caption)
                .foregroundStyle(part.isAvailableLocally ? Theme.brandSecondary : Theme.brandPrimary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: Theme.spacingS) {
                Text(part.estimatedPrice, format: .currency(code: "USD"))
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)

                Button("Buy") {
                    let url = part.buyURL
                        ?? URL(string: "https://www.amazon.com/s?k=\(part.partNumber.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? part.partNumber)")
                    if let url { UIApplication.shared.open(url) }
                }
                .font(Theme.caption)
                .foregroundStyle(.black)
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, 6)
                .background(Theme.brandPrimary, in: Capsule())
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var callAProButton: some View {
        Button {
            // Open Yelp / Thumbtack search for local repair pros
            let query = "\(guide.session.category.rawValue) repair professional"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "repair professional"
            let url = URL(string: "https://www.thumbtack.com/search?q=\(query)")
                ?? URL(string: "https://www.yelp.com/search?find_desc=\(query)")
            if let url { UIApplication.shared.open(url) }
        } label: {
            HStack(spacing: Theme.spacingM) {
                Image(systemName: "phone.fill")
                Text("Call a Pro")
                    .font(Theme.bodyBold)
            }
            .foregroundStyle(Theme.dangerRed)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.spacingM)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusM)
                    .strokeBorder(Theme.dangerRed.opacity(0.5), lineWidth: 1.5)
                    .background(Theme.dangerRed.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radiusM))
            )
        }
        .buttonStyle(.plain)
        .padding(.top, Theme.spacingS)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacingM) {
            Image(systemName: "cart")
                .font(.system(size: 52))
                .foregroundStyle(Theme.textTertiary)
            Text("No parts identified yet.\nComplete diagnosis first.")
                .font(Theme.bodyRegular)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }
}
