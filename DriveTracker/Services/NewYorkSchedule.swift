import Foundation

enum USReminderTimeZone: String, CaseIterable, Identifiable {
    case eastern = "America/New_York"
    case central = "America/Chicago"
    case mountain = "America/Denver"
    case pacific = "America/Los_Angeles"
    case alaska = "America/Anchorage"
    case hawaii = "Pacific/Honolulu"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eastern: "New York"
        case .central: "Chicago"
        case .mountain: "Denver"
        case .pacific: "Los Angeles"
        case .alaska: "Anchorage"
        case .hawaii: "Honolulu"
        }
    }

    var shortTitle: String {
        switch self {
        case .eastern: "ET"
        case .central: "CT"
        case .mountain: "MT"
        case .pacific: "PT"
        case .alaska: "AKT"
        case .hawaii: "HT"
        }
    }

    var timeZone: TimeZone {
        TimeZone(identifier: rawValue) ?? NewYorkSchedule.timeZone
    }
}

/// Practical starting windows for a broad US audience. Times are shown in
/// New York time and follow daylight-saving changes automatically.
enum NewYorkSchedule {
    struct Slot: Identifiable {
        let number: Int
        let hour: Int
        let minute: Int
        var id: Int { number }

        var label: String {
            label(in: NewYorkSchedule.timeZone)
        }

        func label(in timeZone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = timeZone
            components.hour = hour
            components.minute = minute
            return formatter.string(from: components.date ?? .now)
        }
    }

    static let timeZone = TimeZone(identifier: "America/New_York")!
    static let slots = [
        Slot(number: 1, hour: 9, minute: 0),
        Slot(number: 2, hour: 13, minute: 0),
        Slot(number: 3, hour: 20, minute: 0)
    ]

    static func slot(for number: Int) -> Slot {
        slots[(max(number, 1) - 1) % slots.count]
    }
}
