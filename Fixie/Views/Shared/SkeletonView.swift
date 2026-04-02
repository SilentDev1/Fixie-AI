// Views/Shared/SkeletonView.swift
import SwiftUI

// MARK: – Shimmer modifier

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            stops: [
                                .init(color: .clear,              location: 0),
                                .init(color: .white.opacity(0.25), location: 0.5),
                                .init(color: .clear,              location: 1),
                            ],
                            startPoint: .init(x: phase,       y: 0.5),
                            endPoint:   .init(x: phase + 0.6, y: 0.5)
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                    }
                )
                .onAppear {
                    withAnimation(
                        .linear(duration: 1.4)
                        .repeatForever(autoreverses: false)
                    ) {
                        phase = 1.6
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(isActive: Bool = true) -> some View {
        modifier(Shimmer(isActive: isActive))
    }
}

// MARK: – Skeleton row (matches RecentRepairCardView dimensions)

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: Theme.spacingM) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
                .frame(width: 44, height: 44)
                .shimmer()

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 14)
                    .frame(maxWidth: 160)
                    .shimmer()
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 11)
                    .frame(maxWidth: 100)
                    .shimmer()
            }

            Spacer()

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
                .frame(width: 36, height: 36)
                .shimmer()
        }
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, Theme.spacingS)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
