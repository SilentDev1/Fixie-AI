// AppIntents/FixieVisualProvider.swift
// iOS 26 Visual Intelligence — registers Fixie as a provider for
// "Mechanical & Home Repair" semantic queries from the system camera.
import AppIntents
import SwiftUI

// MARK: – App Entity

/// A single diagnostic result entity surfaced via Visual Intelligence.
struct FixieRepairEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Repair Diagnosis")
    static var defaultQuery = FixieRepairEntityQuery()

    let id: String              // category raw value
    let displayName: String     // e.g. "Washer/Dryer Repair"
    let categoryIcon: String    // SF Symbol name

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "Diagnose with Fixie",
            image: .init(systemName: categoryIcon)
        )
    }

    init(category: RepairCategory) {
        self.id = category.id
        self.displayName = "\(category.rawValue) Repair"
        self.categoryIcon = category.icon
    }
}

// MARK: – Entity Query

struct FixieRepairEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FixieRepairEntity] {
        RepairCategory.allCases
            .filter { identifiers.contains($0.id) }
            .map { FixieRepairEntity(category: $0) }
    }

    func suggestedEntities() async throws -> [FixieRepairEntity] {
        RepairCategory.allCases.map { FixieRepairEntity(category: $0) }
    }
}

// MARK: – Visual Intelligence Search Intent

/// Triggered when the user points the system camera at mechanical equipment
/// and chooses "Diagnose with Fixie" from the Visual Intelligence overlay.
@available(iOS 26.0, *)
struct OpenFixieDiagnosticIntent: AppIntent {
    static var title: LocalizedStringResource = "Diagnose with Fixie"
    static var description = IntentDescription(
        "Open Fixie's AI camera to diagnose the photographed appliance or equipment.",
        categoryName: "Fixie AI"
    )
    static var openAppWhenRun: Bool = true

    /// The matched repair category (resolved from Visual Intelligence semantic label).
    @Parameter(title: "Repair Category")
    var repairCategory: FixieRepairEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Diagnose \(\.$repairCategory) with Fixie")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let entity = repairCategory ?? FixieRepairEntity(category: .majorAppliances)
        return .result(
            dialog: "Opening Fixie to diagnose your \(entity.displayName).",
            view: VisualIntelligenceSnippetView(entity: entity)
        )
    }
}

// MARK: – Snippet card shown in Visual Intelligence overlay

private struct VisualIntelligenceSnippetView: View {
    let entity: FixieRepairEntity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entity.categoryIcon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(hex: 0x64FFDA))
                .frame(width: 48, height: 48)
                .background(Color(hex: 0x64FFDA).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(entity.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Tap to diagnose with Fixie AI")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: – Semantic content descriptors
// These labels map Visual Intelligence's on-device ML categories to
// Fixie's repair entity so the system knows when to surface our app.

@available(iOS 26.0, *)
extension OpenFixieDiagnosticIntent {
    /// Mechanical and home repair labels the Visual Intelligence engine recognises.
    static var semanticDescriptors: [String] {
        [
            // Major Appliances
            "washing machine", "dryer", "dishwasher", "refrigerator", "oven", "stove",
            // Home Systems
            "air conditioner", "hvac", "water heater", "furnace", "boiler",
            "electric panel", "circuit breaker", "faucet", "pipe",
            // Tech & Electronics
            "laptop", "computer", "smartphone", "tablet", "circuit board",
            // Yard & Tools
            "lawn mower", "snow blower", "chainsaw", "power drill", "leaf blower",
            // Automotive
            "automobile engine", "car engine", "brake", "tire",
            // Small Household
            "vacuum cleaner", "blender", "toaster", "coffee maker",
        ]
    }
}
