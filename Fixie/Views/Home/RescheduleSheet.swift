// Views/Home/RescheduleSheet.swift
// Lets the homeowner pick a new appointment date/time for an active job.
import SwiftUI

struct RescheduleSheet: View {
    var onConfirm: (Date) -> Void

    @State private var selectedDate = Date().addingTimeInterval(3600)
    @Environment(\.dismiss) private var dismiss

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: selectedDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 6) {
                Text("Reschedule Appointment")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Pick a new date and time for your pro.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // Date picker (graphical, dark)
            DatePicker(
                "",
                selection: $selectedDate,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .colorScheme(.dark)
            .padding(.horizontal, 8)

            // Confirm button
            Button {
                onConfirm(selectedDate)
            } label: {
                Text("Confirm — \(formattedDate)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(hex: 0x2979FF), in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Button("Cancel") { dismiss() }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .background(Color(hex: 0x0D0D1A).ignoresSafeArea())
    }
}
