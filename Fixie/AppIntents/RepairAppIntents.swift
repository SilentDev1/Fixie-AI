// AppIntents/RepairAppIntents.swift
import AppIntents
import SwiftUI

// MARK: – RepairCategory entity (for Siri parameter resolution)

struct RepairCategoryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Repair Category")
    static var defaultQuery = RepairCategoryQuery()

    let id: String
    let displayString: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayString)")
    }

    init(category: RepairCategory) {
        self.id = category.id
        self.displayString = category.rawValue
    }
}

struct RepairCategoryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RepairCategoryEntity] {
        RepairCategory.allCases
            .filter { identifiers.contains($0.id) }
            .map { RepairCategoryEntity(category: $0) }
    }

    func suggestedEntities() async throws -> [RepairCategoryEntity] {
        RepairCategory.allCases.map { RepairCategoryEntity(category: $0) }
    }
}

// MARK: – 1. Start a repair

struct StartRepairIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Repair"
    static var description = IntentDescription(
        "Open Fixie and start diagnosing a repair for a specific category.",
        categoryName: "Fixie AI"
    )
    static var openAppWhenRun = true

    @Parameter(title: "Category", description: "The type of equipment to repair")
    var category: RepairCategoryEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$category) repair")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Opening Fixie for a \(category.displayString) repair.")
    }
}

// MARK: – 2. Order a part

struct OrderPartIntent: AppIntent {
    static var title: LocalizedStringResource = "Order a Repair Part"
    static var description = IntentDescription(
        "Search for and order a specific repair part.",
        categoryName: "Fixie AI"
    )

    @Parameter(title: "Part Name", description: "Name or part number to search for")
    var partName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Order \(\.$partName)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let query = partName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? partName
        let urlString = "https://www.amazon.com/s?k=\(query)"
        return .result(dialog: "Search Amazon for '\(partName)' at: \(urlString)")
    }
}

// MARK: – 3. Find a Pro

struct FindProIntent: AppIntent {
    static var title: LocalizedStringResource = "Find a Repair Professional"
    static var description = IntentDescription(
        "Locate a professional repair service near you.",
        categoryName: "Fixie AI"
    )

    @Parameter(title: "Repair Type", description: "What type of professional to find")
    var repairType: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find a \(\.$repairType) professional")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let query = "\(repairType) repair service near me"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? repairType
        let urlString = "https://www.google.com/search?q=\(query)"
        return .result(dialog: "Find a \(repairType) professional at: \(urlString)")
    }
}

// MARK: – 4. Check tool availability

struct CheckToolsIntent: AppIntent {
    static var title: LocalizedStringResource = "Check My Tools"
    static var description = IntentDescription(
        "Use Fixie's camera to verify you have all required tools.",
        categoryName: "Fixie AI"
    )
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Opening Fixie's Tool Check camera.")
    }
}

// MARK: – App Shortcuts (Siri phrases)

struct FixieAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRepairIntent(),
            phrases: [
                "Start a repair in \(.applicationName)",
                "Diagnose my \(\.$category) with \(.applicationName)",
                "Fix my appliance with \(.applicationName)"
            ],
            shortTitle: "Start Repair",
            systemImageName: "wrench.and.screwdriver"
        )
        AppShortcut(
            intent: OrderPartIntent(),
            phrases: [
                "Order a part in \(.applicationName)",
                "Buy a repair part with \(.applicationName)"
            ],
            shortTitle: "Order Part",
            systemImageName: "cart.fill"
        )
        AppShortcut(
            intent: FindProIntent(),
            phrases: [
                "Find a repair pro with \(.applicationName)",
                "Call a professional using \(.applicationName)"
            ],
            shortTitle: "Find a Pro",
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: CheckToolsIntent(),
            phrases: [
                "Check my tools with \(.applicationName)",
                "Do I have all my tools in \(.applicationName)"
            ],
            shortTitle: "Check Tools",
            systemImageName: "wrench.fill"
        )
    }
}

// MARK: – Error helper

private enum IntentError: Error { case notSupported }
