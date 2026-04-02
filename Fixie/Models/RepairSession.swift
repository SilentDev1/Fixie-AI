// Models/RepairSession.swift
import Foundation

@Observable
final class RepairSession: Identifiable {
    let id: UUID
    var category: RepairCategory
    var title: String
    var subtitle: String        // e.g. brand + model
    var date: Date
    var isCompleted: Bool
    var thumbnailName: String?  // SF Symbol or asset name

    init(
        id: UUID = UUID(),
        category: RepairCategory,
        title: String,
        subtitle: String = "",
        date: Date = .now,
        isCompleted: Bool = false,
        thumbnailName: String? = nil
    ) {
        self.id            = id
        self.category      = category
        self.title         = title
        self.subtitle      = subtitle
        self.date          = date
        self.isCompleted   = isCompleted
        self.thumbnailName = thumbnailName
    }
}

// MARK: - Sample data
extension RepairSession {
    static let samples: [RepairSession] = [
        RepairSession(category: .majorAppliances, title: "Dryer Not Heating",
                      subtitle: "Samsung DVE45T3400W", isCompleted: true,
                      thumbnailName: "dryer"),
        RepairSession(category: .automotive, title: "Brake Pad Replacement",
                      subtitle: "2019 Honda Accord", isCompleted: false,
                      thumbnailName: "car.fill"),
        RepairSession(category: .homeSystems, title: "Pilot Light Out",
                      subtitle: "Rheem PROG40S-38N", isCompleted: true,
                      thumbnailName: "flame.fill"),
        RepairSession(category: .yardAndTools, title: "Mower Won't Start",
                      subtitle: "Husqvarna YTA22V46", isCompleted: false,
                      thumbnailName: "leaf.fill"),
    ]
}
