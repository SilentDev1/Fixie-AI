// Views/RepairHub/ModelConfirmationCard.swift
// Liquid Glass card shown before the repair plan when the backend is uncertain about
// the exact device model (needs_model_verification: true).  The user either confirms
// the AI's guess or types a correction.  On confirm, RepairChatViewModel re-diagnoses
// with the confirmed model and slides in the repair plan.
import SwiftUI

struct ModelConfirmationCard: View {
    let suggestedModel: String
    /// Called with the confirmed (or corrected) model string.
    let onConfirm: (String) -> Void

    @State private var isEditing  = false
    @State private var editText   = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            // ── Header ───────────────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.brandPrimary)
                Text("Confirm Device Model")
                    .font(Theme.bodyBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }

            if isEditing {
                editingSection
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal:   .move(edge: .top).combined(with: .opacity)
                    ))
            } else {
                confirmSection
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal:   .move(edge: .top).combined(with: .opacity)
                    ))
            }
        }
        .padding(Theme.spacingM)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: – Confirm section (default state)

    private var confirmSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            // Suggested model chip
            VStack(alignment: .leading, spacing: 6) {
                Text("I identified this as:")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)

                Text(suggestedModel)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.brandPrimary.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.brandPrimary.opacity(0.3), lineWidth: 1))
            }

            // Action buttons
            VStack(spacing: Theme.spacingS) {
                Button {
                    onConfirm(suggestedModel)
                } label: {
                    Text("Yes, that's it")
                        .font(Theme.bodyBold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.brandPrimary, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        editText  = suggestedModel
                        isEditing = true
                    }
                    isFocused = true
                } label: {
                    Text("No, let me fix it")
                        .font(Theme.bodyBold)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: – Edit section (after "No" tap)

    private var editingSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What's the correct model?")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)

                TextField("e.g. Tineco Floor One S5", text: $editText)
                    .font(Theme.bodyRegular)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .onSubmit { submitEdit() }
            }

            Button { submitEdit() } label: {
                Text("Confirm Model")
                    .font(Theme.bodyBold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        editText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? Theme.brandPrimary.opacity(0.35)
                            : Theme.brandPrimary,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
            .buttonStyle(.plain)
            .disabled(editText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isFocused = false
        onConfirm(trimmed)
    }
}
