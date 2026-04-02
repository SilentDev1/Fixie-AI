// DesignSystem/Theme.swift
import SwiftUI

enum Theme {
    // MARK: Typography
    static let titleLarge   = Font.system(size: 34, weight: .bold,   design: .rounded)
    static let titleMedium  = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let bodyBold     = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let bodyRegular  = Font.system(size: 15, weight: .regular, design: .rounded)
    static let caption      = Font.system(size: 12, weight: .medium,  design: .rounded)

    // MARK: Spacing
    static let spacingXS: CGFloat = 4
    static let spacingS:  CGFloat = 8
    static let spacingM:  CGFloat = 16
    static let spacingL:  CGFloat = 24
    static let spacingXL: CGFloat = 32

    // MARK: Corner radii
    static let radiusS:  CGFloat = 12
    static let radiusM:  CGFloat = 20
    static let radiusL:  CGFloat = 28

    // MARK: Liquid Glass – background material
    // iOS 26 exposes .glassEffect(); below we use .ultraThinMaterial as the
    // closest available equivalent for back-compat; swap when targeting 26+.
    static let glassMaterial: Material = .ultraThinMaterial

    // MARK: Brand
    static let brandPrimary   = Color(hex: 0x4FC3F7)
    static let brandSecondary = Color(hex: 0x81C784)
    static let dangerRed      = Color(hex: 0xEF5350)
    static let warningAmber   = Color(hex: 0xFFCA28)

    // High-contrast text for dark environments
    static let textPrimary    = Color.white
    static let textSecondary  = Color.white.opacity(0.72)
    static let textTertiary   = Color.white.opacity(0.45)
}
