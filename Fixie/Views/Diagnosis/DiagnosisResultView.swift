// Views/Diagnosis/DiagnosisResultView.swift
import SwiftUI

struct DiagnosisResultView: View {
    let guide: RepairGuide

    @State private var navigateToSafety    = false
    @State private var navigateToParts     = false
    @State private var selectedFailureIdx  = 0

    private var diagnosis: DiagnosisResult? { guide.diagnosis }

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: Theme.spacingL) {
                    heroCard
                    if let d = diagnosis {
                        cotSection(d)
                        failuresSection(d)
                        safetyBanner(d)
                    }
                    ctaButtons
                    AIDisclosureBadge()
                    Spacer(minLength: Theme.spacingXL)
                }
                .padding(.horizontal, Theme.spacingM)
                .padding(.top, Theme.spacingM)
            }
        }
        .navigationTitle("Diagnosis")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToSafety) {
            SafetyView(session: guide.session, guide: guide)
        }
        .navigationDestination(isPresented: $navigateToParts) {
            PartsView(guide: guide)
        }
    }

    // MARK: – Hero card (thumbnail + headline)

    private var heroCard: some View {
        ZStack(alignment: .bottomLeading) {
            // Gradient background
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .fill(
                    LinearGradient(
                        colors: guide.session.category.gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 200)

            // Category icon watermark
            Image(systemName: guide.session.category.icon)
                .font(.system(size: 100, weight: .bold))
                .foregroundStyle(.white.opacity(0.08))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(Theme.spacingM)

            // Text content
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                if let d = diagnosis {
                    Text("\(d.brand) \(d.model)".trimmingCharacters(in: .whitespaces))
                        .font(Theme.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(d.symptom)
                        .font(Theme.titleMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                } else {
                    Text(guide.session.title)
                        .font(Theme.titleMedium)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(Theme.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial.opacity(0.7))
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: – Chain-of-Thought summary

    private func cotSection(_ d: DiagnosisResult) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            sectionLabel("Chain-of-Thought")

            VStack(spacing: 0) {
                cotRow(step: "Identify",  value: "\(d.brand) \(d.model)".trimmingCharacters(in: .whitespaces),
                       icon: "tag.fill",  color: Theme.brandPrimary, isLast: false)
                cotRow(step: "Symptom",   value: d.symptom,
                       icon: "exclamationmark.bubble.fill", color: Theme.warningAmber, isLast: false)
                cotRow(step: "Diagnosis", value: d.possibleFailures.first ?? "Unknown",
                       icon: "stethoscope", color: Color(hex: 0xFF8A65), isLast: false)
                cotRow(step: "Verify",    value: d.verificationStep,
                       icon: "checkmark.magnifyingglass", color: Theme.brandSecondary, isLast: true)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))

            // Confidence meter
            confidenceMeter(score: d.confidenceScore)
        }
    }

    private func cotRow(step: String, value: String, icon: String, color: Color, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.spacingM) {
            // Vertical connector line + icon
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.15), in: Circle())

                if !isLast {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.uppercased())
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .kerning(0.8)
                Text(value.isEmpty ? "—" : value)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.spacingM)
            Spacer()
        }
        .padding(.leading, Theme.spacingM)
    }

    // MARK: – Confidence ring

    private func confidenceMeter(score: Double) -> some View {
        HStack(spacing: Theme.spacingM) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 6)
                    .frame(width: 52, height: 52)
                Circle()
                    .trim(from: 0, to: score)
                    .stroke(
                        score > 0.75 ? Theme.brandSecondary :
                        score > 0.5  ? Theme.warningAmber : Theme.dangerRed,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 52, height: 52)
                Text("\(Int(score * 100))%")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Confidence Score")
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                Text(score < Config.lowConfidenceThreshold
                     ? "Low confidence — consider sharing more photos"
                     : "Diagnosis is reliable")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
    }

    // MARK: – Ranked failure points

    private func failuresSection(_ d: DiagnosisResult) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            sectionLabel("Likely Failure Points")
            VStack(spacing: Theme.spacingS) {
                ForEach(Array(d.possibleFailures.prefix(3).enumerated()), id: \.offset) { idx, failure in
                    HStack(spacing: Theme.spacingM) {
                        Text("#\(idx + 1)")
                            .font(Theme.caption)
                            .foregroundStyle(idx == 0 ? Theme.dangerRed : Theme.textTertiary)
                            .frame(width: 28)
                        Text(failure)
                            .font(Theme.bodyRegular)
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Probability bar
                        Capsule()
                            .fill(idx == 0 ? Theme.dangerRed : Color.white.opacity(0.2))
                            .frame(width: CGFloat(3 - idx) * 18 + 18, height: 4)
                    }
                    .padding(Theme.spacingM)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                }
            }
        }
    }

    // MARK: – Safety banner

    private func safetyBanner(_ d: DiagnosisResult) -> some View {
        HStack(spacing: Theme.spacingM) {
            Image(systemName: d.isSafeToProcceed ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(d.isSafeToProcceed ? Theme.brandSecondary : Theme.dangerRed)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.isSafeToProcceed ? "DIY-Safe" : "Professional Recommended")
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                Text(d.isSafeToProcceed
                     ? "This repair is within reach of a careful DIYer."
                     : "Gas, high-voltage, or refrigerant involved. Proceed with caution.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(Theme.spacingM)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .fill((d.isSafeToProcceed ? Theme.brandSecondary : Theme.dangerRed).opacity(0.1))
                .strokeBorder(
                    (d.isSafeToProcceed ? Theme.brandSecondary : Theme.dangerRed).opacity(0.35),
                    lineWidth: 1
                )
        )
    }

    // MARK: – CTA buttons

    private var ctaButtons: some View {
        VStack(spacing: Theme.spacingM) {
            // Primary: Start Repair
            Button { navigateToSafety = true } label: {
                HStack(spacing: Theme.spacingS) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                    Text("Start Repair")
                        .font(Theme.bodyBold)
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.spacingM)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusM)
                        .fill(
                            LinearGradient(
                                colors: [Theme.brandSecondary, Color(hex: 0x66BB6A)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .shadow(color: Theme.brandSecondary.opacity(0.4), radius: 12, y: 4)
            }
            .buttonStyle(.plain)

            // Secondary: Get Parts
            Button { navigateToParts = true } label: {
                HStack(spacing: Theme.spacingS) {
                    Image(systemName: "cart.fill")
                    Text("Get Parts (\(guide.requiredParts.count))")
                        .font(Theme.bodyBold)
                }
                .foregroundStyle(Theme.brandPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.spacingM)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusM)
                        .strokeBorder(Theme.brandPrimary.opacity(0.5), lineWidth: 1.5)
                        .background(Theme.brandPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radiusM))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: – Helper

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.titleMedium)
            .foregroundStyle(Theme.textPrimary)
    }
}
