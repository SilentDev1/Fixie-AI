// Views/Home/CategoryCardView.swift
import SwiftUI

struct CategoryCardView: View {
    let category: RepairCategory
    var onTap: () -> Void = {}

    @State private var isHovered  = false
    @State private var isPressed  = false

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                // Gradient fill
                LinearGradient(
                    colors: category.gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Decorative large icon (background)
                Image(systemName: category.icon)
                    .font(.system(size: 80, weight: .bold))
                    .foregroundStyle(.white.opacity(0.12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(Theme.spacingS)

                // Frosted label strip
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: category.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(category.rawValue)
                        .font(Theme.bodyBold)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.spacingM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial.opacity(0.6))
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusM)
                    .strokeBorder(.white.opacity(isHovered ? 0.5 : 0.2), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.03 : 1.0))
            .shadow(
                color: category.accentColor.opacity(isHovered ? 0.55 : 0.3),
                radius: isHovered ? 20 : 10,
                y: isHovered ? 8 : 4
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isPressed)
        }
        .buttonStyle(.plain)
        // Gaze-track / hover for Vision Pro & pointer devices
        .onHover { isHovered = $0 }
        ._onButtonGesture(pressing: { isPressed = $0 }, perform: {})
        .aspectRatio(0.9, contentMode: .fit)
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
        ForEach(RepairCategory.allCases) { cat in
            CategoryCardView(category: cat)
        }
    }
    .padding()
    .background(Color(hex: 0x1C1C1E))
}
