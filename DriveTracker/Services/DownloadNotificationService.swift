import Foundation
import UserNotifications

@MainActor
final class DownloadNotificationService {
    private let center = UNUserNotificationCenter.current()
    private let prefix = "drive-tracker-download-"

    func requestAccessAndSchedule(assignments: [DailyAssignment]) async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return false }
            await schedule(assignments: assignments)
            return true
        } catch {
            return false
        }
    }

    func schedule(assignments: [DailyAssignment]) async {
        let existing = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { $0.hasPrefix(prefix) })

        let calendar = Calendar(identifier: .gregorian)
        let now = Date.now
        var nyCalendar = calendar
        nyCalendar.timeZone = NewYorkSchedule.timeZone
        let today = nyCalendar.dateComponents([.year, .month, .day], from: now)

        for assignment in assignments where assignment.isActive && assignment.video?.status == .assigned {
            guard let video = assignment.video, let account = assignment.account else { continue }
            let slot = NewYorkSchedule.slot(for: assignment.slot)
            let offsetChoices = [10, 15, 20, 30]
            let stableSeed = assignment.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
            let offset = offsetChoices[abs(stableSeed) % offsetChoices.count]
            var components = today
            components.hour = slot.hour
            components.minute = slot.minute + offset
            components.second = 0
            guard let fireDate = nyCalendar.date(from: components), fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Download reminder"
            content.body = "\(account.displayName) • \(video.name) • \(slot.label) New York (+\(offset) min)"
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: nyCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            try? await center.add(UNNotificationRequest(identifier: prefix + assignment.id.uuidString, content: content, trigger: trigger))
        }
    }
}
