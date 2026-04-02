// Views/Home/LiveStatusOverlay.swift
// Sticky top banner shown when a pro is en route.
import SwiftUI

struct LiveStatusOverlay: View {
    let job: ServiceJob

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing green dot
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: .green.opacity(pulse ? 0.9 : 0.3), radius: pulse ? 6 : 2)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            VStack(alignment: .leading, spacing: 1) {
                Text("Pro En Route")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
                Text(job.proName.isEmpty ? "Your pro is on the way" : "\(job.proName) is on the way")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
            }

            Spacer()

            // ETA badge — replaces the Track button
            if let mins = job.minsAway {
                VStack(spacing: 1) {
                    Text("\(mins)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Text("min\(mins == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.green.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.green.opacity(0.35), lineWidth: 0.5))
            } else {
                Text("On the way")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.green.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .green.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }
}
