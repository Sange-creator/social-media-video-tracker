import Foundation

/// Practical starting windows for a broad US audience. Times are shown in
/// New York time and follow daylight-saving changes automatically.
enum NewYorkSchedule {
    struct Slot: Identifiable {
        let number: Int
        let hour: Int
        let minute: Int
        var id: Int { number }

        var label: String {
            let formatter = DateFormatter()
            formatter.timeZone = NewYorkSchedule.timeZone
            formatter.dateFormat = "h:mm a"
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = NewYorkSchedule.timeZone
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
