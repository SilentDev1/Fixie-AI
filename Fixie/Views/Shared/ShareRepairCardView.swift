// Views/Shared/ShareRepairCardView.swift
import SwiftUI

// MARK: – The rendered card (used by ImageRenderer)

@MainActor
struct ShareRepairCard: View {
    let guide:          RepairGuide
    let capturedImage:  UIImage?
    let stepsCompleted: Int

    private var stepsTotal: Int { guide.steps.count }
    private var completionFraction: Double {
        stepsTotal > 0 ? Double(stepsCompleted) / Double(stepsTotal) : 0
    }
    private var isCompleted: Bool { stepsCompleted >= stepsTotal && stepsTotal > 0 }
    private var subtitle: String {
        let d = guide.diagnosis
        return [d?.brand ?? "", d?.model ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(Theme.brandPrimary)
                Text("Fixie AI")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
            }

            // Thumbnail
            if let img = capturedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            // Title + brand/model
            VStack(alignment: .leading, spacing: 4) {
                Text(guide.session.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            // Symptom
            if let symptom = guide.diagnosis?.symptom {
                Text(symptom)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }

            // Step completion bar
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 8)
                        Capsule()
                            .fill(isCompleted ? Theme.brandSecondary : Theme.brandPrimary)
                            .frame(width: geo.size.width * completionFraction, height: 8)
                    }
                }
                .frame(height: 8)
                Text("\(stepsCompleted) of \(stepsTotal) steps complete")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 8)

            // Footer
            Text("Repaired with Fixie")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 360)
        .background(Color(hex: 0x141820))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: – The sheet

struct ShareRepairCardView: View {
    let guide:          RepairGuide
    let capturedImage:  UIImage?
    let stepsCompleted: Int

    @Environment(\.dismiss) private var dismiss
    @State private var renderedImage: UIImage?

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: Theme.spacingXL) {
                // Preview
                if let img = renderedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .padding(.horizontal, Theme.spacingL)
                } else {
                    ShareRepairCard(
                        guide:          guide,
                        capturedImage:  capturedImage,
                        stepsCompleted: stepsCompleted
                    )
                    .padding(.horizontal, Theme.spacingL)
                }

                // Share button
                if let img = renderedImage {
                    ShareLink(
                        item: Image(uiImage: img),
                        preview: SharePreview(guide.session.title, image: Image(uiImage: img))
                    ) {
                        HStack(spacing: Theme.spacingS) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share Repair Summary")
                        }
                        .font(Theme.bodyBold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingM)
                        .background(
                            LinearGradient(
                                colors: [Theme.brandPrimary, Color(hex: 0x29B6F6)],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.spacingL)
                }

                Button("Dismiss") { dismiss() }
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, Theme.spacingXL)
        }
        .task { await renderCard() }
    }

    @MainActor
    private func renderCard() async {
        let renderer = ImageRenderer(content: ShareRepairCard(
            guide:          guide,
            capturedImage:  capturedImage,
            stepsCompleted: stepsCompleted
        ))
        renderer.scale = UIScreen.main.scale
        renderedImage = renderer.uiImage
    }
}
