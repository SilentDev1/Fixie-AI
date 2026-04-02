// Views/History/InvoiceCardView.swift
// Displays a single contractor invoice inside the history detail sheet.
import SwiftUI

struct InvoiceCardView: View {
    let invoice: Invoice

    private let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = .current
        return f
    }()

    private func format(_ value: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: value)) ?? "$\(String(format: "%.2f", value))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: business name + invoice number + total
            HStack(alignment: .top, spacing: Theme.spacingS) {
                VStack(alignment: .leading, spacing: 3) {
                    if !invoice.businessName.isEmpty {
                        Text(invoice.businessName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    if !invoice.invoiceNumber.isEmpty {
                        Text(invoice.invoiceNumber)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(invoice.issuedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(format(invoice.finalTotal))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: 0x2979FF).opacity(0.15), in: Capsule())
                    if !invoice.status.isEmpty {
                        Text(invoice.status.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            .padding(.bottom, Theme.spacingS)

            // Line items
            if !invoice.lineItems.isEmpty {
                Divider().background(.white.opacity(0.08))
                    .padding(.bottom, Theme.spacingS)

                ForEach(invoice.lineItems) { item in
                    HStack(alignment: .top, spacing: Theme.spacingS) {
                        Text(item.description)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(format(item.amount))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.bottom, 4)
                }

                // Total row
                Divider().background(.white.opacity(0.08))
                    .padding(.vertical, Theme.spacingXS)

                HStack {
                    Text("Total")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(format(invoice.finalTotal))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            // Resolution notes
            if !invoice.notes.isEmpty {
                Divider().background(.white.opacity(0.08))
                    .padding(.top, Theme.spacingS)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resolution Notes")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                    Text(invoice.notes)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(Theme.spacingM)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS)
            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    private var statusColor: Color {
        switch invoice.status.lowercased() {
        case "paid":    return .green
        case "draft":   return Color(hex: 0xFFAB00)
        case "sent":    return Color(hex: 0x2979FF)
        default:        return Theme.textTertiary
        }
    }
}
