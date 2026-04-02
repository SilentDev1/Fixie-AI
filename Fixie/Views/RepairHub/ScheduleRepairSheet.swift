// Views/RepairHub/ScheduleRepairSheet.swift
// Presented before RescueCardView so the user can pick ASAP or schedule a time.
import SwiftUI

struct ScheduleRepairSheet: View {
    var onConfirm: (Bool, Date?) -> Void   // (isASAP, requestedTime)

    @State private var selectedDate = Date().addingTimeInterval(3600)
    @State private var showDatePicker = false
    @State private var pulse = false

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

            VStack(alignment: .leading, spacing: 8) {
                Text("Schedule Your Repair")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("How soon do you need a pro?")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)

            VStack(spacing: 14) {
                // ASAP button — prominent, pulsing
                Button { onConfirm(true, nil) } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.18))
                                .frame(width: 44, height: 44)
                                .scaleEffect(pulse ? 1.08 : 1.0)
                                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                           value: pulse)
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ASAP — Urgent")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("Get a pro as soon as possible")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.7))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                // Schedule for Later — with inline DatePicker
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showDatePicker.toggle()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: 0x2979FF).opacity(0.18))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x2979FF))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Schedule for Later")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text(showDatePicker ? formattedDate : "Pick a date & time")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Image(systemName: showDatePicker ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x2979FF).opacity(0.7))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.plain)

                    if showDatePicker {
                        Divider()
                            .background(.white.opacity(0.1))
                            .padding(.horizontal, 18)

                        DatePicker(
                            "",
                            selection: $selectedDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.graphical)
                        .colorScheme(.dark)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)

                        Button {
                            onConfirm(false, selectedDate)
                        } label: {
                            Text("Confirm — \(formattedDate)")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(hex: 0x2979FF), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 16)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .strokeBorder(Color(hex: 0x2979FF).opacity(0.35), lineWidth: 1)
                        )
                )
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 32)
        }
        .onAppear { pulse = true }
    }
}
