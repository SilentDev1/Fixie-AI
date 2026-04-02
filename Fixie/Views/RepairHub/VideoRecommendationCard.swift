// Views/RepairHub/VideoRecommendationCard.swift
// Liquid Glass card shown at the bottom of the chat when the AI diagnostic is complete.
// Tapping "Watch Tutorial" opens the YouTube app (or Safari as a fallback) with the
// pre-formed search query the AI generated from: Brand + Model + Component + Issue.
import SwiftUI

struct VideoRecommendationCard: View {

    let searchQuery: String

    // MARK: – YouTube URL helpers

    /// Deep-links into the YouTube app if installed; falls back to the mobile website.
    private var youtubeAppURL: URL? {
        let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "youtube://results?search_query=\(encoded)")
    }

    private var youtubeWebURL: URL? {
        let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.youtube.com/results?search_query=\(encoded)")
    }

    // MARK: – Body

    var body: some View {
        HStack(spacing: 14) {

            // YouTube play thumbnail placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xFF0000).opacity(0.85),
                                     Color(hex: 0xCC0000)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 52)

                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }

            // Query / suggested title
            VStack(alignment: .leading, spacing: 4) {
                Text("Video Tutorial")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text(searchQuery)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            // Watch button
            Button {
                openYouTube()
            } label: {
                Text("Watch")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: 0xFF0000), Color(hex: 0xCC0000)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    // MARK: – Open YouTube

    private func openYouTube() {
        if let appURL = youtubeAppURL,
           UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL = youtubeWebURL {
            UIApplication.shared.open(webURL)
        }
    }
}
