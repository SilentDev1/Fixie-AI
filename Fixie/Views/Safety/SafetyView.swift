// Views/Safety/SafetyView.swift
import SwiftUI

struct SafetyCheckItem: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    var isConfirmed: Bool = false
}

struct SafetyView: View {
    let session: RepairSession
    var guide: RepairGuide? = nil
    var onSafetyCleared: () -> Void = {}

    @State private var navigateToRepair = false
    @State private var env = EnvironmentContextService.shared

    @State private var checklist: [SafetyCheckItem] = [
        SafetyCheckItem(label: "Power is OFF / unplugged", icon: "powerplug.fill"),
        SafetyCheckItem(label: "Gas supply is closed",     icon: "flame.fill"),
        SafetyCheckItem(label: "Water supply is off",      icon: "drop.fill"),
        SafetyCheckItem(label: "Area is ventilated",       icon: "wind"),
        SafetyCheckItem(label: "Safety gear is on",        icon: "eyeglasses"),
    ]
    @State private var photoConfirmed = false

    private var allConfirmed: Bool {
        checklist.allSatisfy(\.isConfirmed) && photoConfirmed
    }

    var body: some View {
        ZStack {
            Color(hex: 0x0D0D0F).ignoresSafeArea()

            VStack(spacing: Theme.spacingL) {
                // Warning header
                header

                // Environment warnings (WeatherKit)
                if !env.warnings.isEmpty {
                    environmentWarnings
                }

                // Checklist
                VStack(spacing: Theme.spacingS) {
                    ForEach($checklist) { $item in
                        checkRow(item: $item)
                    }
                }
                .padding(Theme.spacingM)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))

                // Photo confirmation
                photoConfirmRow

                Spacer()

                // Proceed button
                Button {
                    onSafetyCleared()
                    if guide != nil { navigateToRepair = true }
                } label: {
                    Text("All Clear — Show Repair Steps")
                        .font(Theme.bodyBold)
                        .foregroundStyle(allConfirmed ? .black : Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.spacingM)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusM)
                                .fill(allConfirmed ? Theme.brandSecondary : Color.white.opacity(0.08))
                        )
                }
                .disabled(!allConfirmed)
                .animation(.easeInOut(duration: 0.2), value: allConfirmed)
            }
            .padding(Theme.spacingM)
        }
        .task { await env.refresh(for: session.category) }
        .navigationTitle("Safety Check")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToRepair) {
            if let g = guide { RepairGuideView(guide: g) }
        }
    }

    // MARK: – Environment warnings

    private var environmentWarnings: some View {
        VStack(spacing: Theme.spacingS) {
            ForEach(env.warnings) { warning in
                HStack(alignment: .top, spacing: Theme.spacingM) {
                    Image(systemName: warning.systemImage)
                        .font(.system(size: 20))
                        .foregroundStyle(warningColor(warning.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.headline)
                            .font(Theme.bodyBold)
                            .foregroundStyle(warningColor(warning.severity))
                        Text(warning.body)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.spacingM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusM)
                        .fill(warningColor(warning.severity).opacity(0.1))
                        .strokeBorder(warningColor(warning.severity).opacity(0.4), lineWidth: 1)
                )
            }
        }
    }

    private func warningColor(_ severity: EnvironmentWarning.Severity) -> Color {
        switch severity {
        case .emergency: return Theme.dangerRed
        case .caution:   return Theme.warningAmber
        case .info:      return Theme.brandPrimary
        }
    }

    private var header: some View {
        HStack(spacing: Theme.spacingM) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.warningAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Safety First")
                    .font(Theme.titleMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text("Confirm all safety conditions before proceeding.")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .fill(Theme.warningAmber.opacity(0.12))
                .strokeBorder(Theme.warningAmber.opacity(0.35), lineWidth: 1)
        )
    }

    private func checkRow(item: Binding<SafetyCheckItem>) -> some View {
        Button {
            item.wrappedValue.isConfirmed.toggle()
        } label: {
            HStack(spacing: Theme.spacingM) {
                Image(systemName: item.wrappedValue.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(item.wrappedValue.isConfirmed ? Theme.brandSecondary : Theme.textSecondary)
                    .frame(width: 28)

                Text(item.wrappedValue.label)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: item.wrappedValue.isConfirmed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(item.wrappedValue.isConfirmed ? Theme.brandSecondary : Theme.textTertiary)
            }
            .padding(.vertical, Theme.spacingXS)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: item.wrappedValue.isConfirmed)
    }

    private var photoConfirmRow: some View {
        Button {
            // TODO: trigger camera capture for AI power-off verification
            photoConfirmed = true
        } label: {
            HStack(spacing: Theme.spacingM) {
                Image(systemName: photoConfirmed ? "camera.fill" : "camera")
                    .font(.system(size: 18))
                    .foregroundStyle(photoConfirmed ? Theme.brandPrimary : Theme.textSecondary)
                Text(photoConfirmed ? "Power-off photo confirmed by AI" : "Take photo to confirm power is off")
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: photoConfirmed ? "checkmark.circle.fill" : "arrow.right.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(photoConfirmed ? Theme.brandPrimary : Theme.textTertiary)
            }
            .padding(Theme.spacingM)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusM))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusM)
                    .strokeBorder(
                        photoConfirmed ? Theme.brandPrimary.opacity(0.5) : Color.white.opacity(0.12),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: photoConfirmed)
    }
}

#Preview {
    SafetyView(session: RepairSession.samples[0])
}
