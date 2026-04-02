// Views/Shared/InteractiveSnippetView.swift
// Compact SwiftUI card surfaced in Siri / Spotlight for OrderPartIntent.
// Conforms to AppIntents ShowsSnippetView requirement.
import SwiftUI
import AppIntents

// MARK: – Snippet card

/// Shown when the user says "Order a part in Fixie" via Siri or Spotlight.
/// Displays part name, live Amazon price, and a Buy Now deep-link.
struct InteractiveSnippetView: View {
    let partName: String
    let result: AmazonPartResult?

    @State private var isLoadingPrice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 10) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x64FFDA))
                    .frame(width: 36, height: 36)
                    .background(Color(hex: 0x64FFDA).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(result?.title ?? partName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let r = result {
                        Text("Price as of \(r.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let r = result {
                    Text(r.displayPrice)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                }
            }

            // Affiliate disclaimer
            Text(Config.affiliateDisclaimer)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            // Action buttons
            HStack(spacing: 8) {
                if let r = result {
                    // Deep-link: opens Amazon Shopping app (no WebView)
                    Link(destination: r.shoppingAppDeepLink) {
                        Label("Buy on Amazon", systemImage: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(hex: 0x64FFDA), in: Capsule())
                    }
                } else {
                    // Fallback: open Amazon search
                    Link(destination: amazonSearchURL(for: partName)) {
                        Label("Search Amazon", systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func amazonSearchURL(for query: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "https://www.amazon.com/s?k=\(encoded)&tag=\(Config.amazonPartnerTag)") ?? URL(string: "https://www.amazon.com")!
    }
}

// MARK: – Upgrade OrderPartIntent to show snippet

/// Upgraded intent that surfaces an InteractiveSnippetView when run.
@available(iOS 26.0, *)
struct OrderPartWithSnippetIntent: AppIntent {
    static var title: LocalizedStringResource = "Order a Repair Part"
    static var description = IntentDescription(
        "Search Amazon for a repair part and preview live pricing.",
        categoryName: "Fixie AI"
    )

    @Parameter(title: "Part Name", description: "Name or part number to search for")
    var partName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Order \(\.$partName)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        // Try live Amazon PA-API lookup; fall back to nil (snippet shows search button)
        let result = try? await AmazonPAAPIService.shared.searchParts(query: partName, maxResults: 1).first

        return .result(
            dialog: result != nil
                ? "Found \(result!.title) for \(result!.displayPrice) on Amazon."
                : "Search Amazon for '\(partName)'.",
            view: InteractiveSnippetView(partName: partName, result: result)
        )
    }
}
