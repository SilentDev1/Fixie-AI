// Models/RepairCategory.swift
import SwiftUI

enum RepairCategory: String, CaseIterable, Identifiable {
    case majorAppliances    = "Major Appliances"
    case smallHousehold     = "Small Household"
    case homeSystems        = "Home Systems"
    case techAndElectronics = "Tech & Electronics"
    case yardAndTools       = "Yard & Tools"
    case automotive         = "Automotive"
    case homeAndStructure   = "Home & Structure"
    case itAndNetworking    = "IT & Networking"

    var id: String { rawValue }

    /// Camelcase key used in the Firestore `contractors` and `leads` collections.
    /// Must match exactly what the web portal / pro dashboard writes to Firestore.
    var firestoreKey: String {
        switch self {
        case .majorAppliances:    return "majorAppliances"
        case .smallHousehold:     return "smallHousehold"
        case .homeSystems:        return "homeSystems"
        case .techAndElectronics: return "techAndElectronics"
        case .yardAndTools:       return "yardAndTools"
        case .automotive:         return "automotive"
        case .homeAndStructure:   return "homeAndStructure"
        case .itAndNetworking:    return "itAndNetworking"
        }
    }

    /// Reconstructs a `RepairCategory` from a Firestore camelCase key.
    static func fromFirestoreKey(_ key: String) -> RepairCategory? {
        allCases.first { $0.firestoreKey == key }
    }

    /// Short subtitle shown under the category name in cards and pickers.
    var subtitle: String {
        switch self {
        case .majorAppliances:    return "Kitchen & Laundry"
        case .homeSystems:        return "HVAC, Plumbing & Electrical"
        case .techAndElectronics: return "Laptops, Phones & Computers"
        case .yardAndTools:       return "Mowers, Power Tools & Garden"
        case .automotive:         return "Cars & Vehicles"
        case .smallHousehold:     return "Vacuums & Small Appliances"
        case .homeAndStructure:   return "Windows, Doors, Drywall & Flooring"
        case .itAndNetworking:    return "Wi-Fi, Routers, PCs & Printers"
        }
    }

    var icon: String {
        switch self {
        case .majorAppliances:    return "washer"
        case .homeSystems:        return "house.and.flag"
        case .techAndElectronics: return "laptopcomputer"
        case .yardAndTools:       return "leaf"
        case .automotive:         return "car.fill"
        case .smallHousehold:     return "air.purifier.fill"
        case .homeAndStructure:   return "hammer.fill"
        case .itAndNetworking:    return "wifi.router.fill"
        }
    }

    var gradient: [Color] {
        switch self {
        case .majorAppliances:    return [Color(hex: 0x4FC3F7), Color(hex: 0x0288D1)]
        case .homeSystems:        return [Color(hex: 0xFF8A65), Color(hex: 0xE64A19)]
        case .techAndElectronics: return [Color(hex: 0x80DEEA), Color(hex: 0x00838F)]
        case .yardAndTools:       return [Color(hex: 0x81C784), Color(hex: 0x388E3C)]
        case .automotive:         return [Color(hex: 0xCE93D8), Color(hex: 0x7B1FA2)]
        case .smallHousehold:     return [Color(hex: 0xFFCC80), Color(hex: 0xEF6C00)]
        case .homeAndStructure:   return [Color(hex: 0x9575CD), Color(hex: 0xC2185B)]  // Indigo → Magenta
        case .itAndNetworking:    return [Color(hex: 0x4DB6AC), Color(hex: 0x546E7A)]  // Teal → Slate
        }
    }

    var accentColor: Color { gradient[0] }

    /// Expert persona injected into AI system prompts so the model
    /// responds with the right professional voice for each category.
    var expertPersona: String {
        switch self {
        case .majorAppliances:
            return "Master Appliance Technician specializing in large kitchen and laundry equipment " +
                   "(washers, dryers, dishwashers, refrigerators, ovens)"
        case .homeSystems:
            return "Licensed HVAC & Plumbing Specialist certified in heating, cooling, water heaters, " +
                   "plumbing systems, and residential electrical panels"
        case .techAndElectronics:
            return "Senior IT & Electronics Repair Specialist experienced in laptops, desktop computers, " +
                   "smartphones, tablets, and consumer electronics"
        case .yardAndTools:
            return "Outdoor Power Equipment Technician certified in lawn mowers, snow blowers, " +
                   "chainsaws, and gas/electric power tools"
        case .automotive:
            return "Certified Automotive Mechanic (ASE) specializing in engine diagnostics, brakes, " +
                   "suspension, electrical systems, and general vehicle maintenance"
        case .smallHousehold:
            return "Small Appliance Repair Technician experienced in vacuums, blenders, toasters, " +
                   "coffee makers, fans, and countertop kitchen appliances"
        case .homeAndStructure:
            return "Licensed General Contractor and Handyman specializing in windows, doors, drywall " +
                   "repair, interior trim, siding, and flooring installation and repair"
        case .itAndNetworking:
            return "IT Support Specialist and Network Technician experienced in home office setup, " +
                   "Wi-Fi routers, mesh network systems, desktop and laptop repair, and printer troubleshooting"
        }
    }
}

// MARK: - Hex color convenience (unchanged)
extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }
}
