import Foundation
import UserNotifications

@MainActor
final class DownloadNotificationService {
    private let center = UNUserNotificationCenter.current()
    private let prefix = "drive-tracker-download-"
    private let defaults: UserDefaults
    private(set) var timeZoneID: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "reminderTimeZoneID")
        self.timeZoneID = USReminderTimeZone(rawValue: saved ?? "")?.rawValue
            ?? USReminderTimeZone.eastern.rawValue
    }

    func setTimeZone(id: String) {
        guard USReminderTimeZone(rawValue: id) != nil else { return }
        timeZoneID = id
        defaults.set(id, forKey: "reminderTimeZoneID")
    }

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

        let now = Date.now
        var selectedCalendar = Calendar(identifier: .gregorian)
        selectedCalendar.timeZone = TimeZone(identifier: timeZoneID) ?? NewYorkSchedule.timeZone

        let pending = assignments.filter {
            $0.isActive && $0.video?.status == .assigned && $0.account != nil
        }
        let assignmentsByAccount = Dictionary(
            grouping: pending,
            by: { $0.account?.id ?? UUID() }
        )
        let accounts = assignmentsByAccount
            .values
            .compactMap(\.first?.account)
            .sorted { $0.sortOrder < $1.sortOrder }

        var reminders: [(date: Date, calendar: Calendar, account: TikTokAccount, assignment: DailyAssignment)] = []
        for (accountIndex, account) in accounts.enumerated() where account.remindersEnabled {
            let items = (assignmentsByAccount[account.id] ?? []).sorted { $0.slot < $1.slot }
            guard !items.isEmpty else { continue }
            if account.targetTimeZoneID != nil {
                let calendar = account.postingCalendar
                let hours = [account.preferredSlot1Hour, account.preferredSlot2Hour, account.preferredSlot3Hour]
                for (index, assignment) in items.enumerated() {
                    guard let date = calendar.nextDate(after: now,
                        matching: DateComponents(hour: hours[index % hours.count], minute: 0),
                        matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { continue }
                    reminders.append((date, calendar, account, assignment))
                }
            } else {
                // Retain the previous reminder windows until a schedule is explicitly configured.
                for (index, burst) in nextBurstDates(after: now, calendar: selectedCalendar).enumerated() {
                    guard let date = selectedCalendar.date(byAdding: .minute, value: accountIndex * 5, to: burst) else { continue }
                    reminders.append((date, selectedCalendar, account, items[index % items.count]))
                }
            }
        }
        // Keep the earliest reminders across every account within iOS's pending request limit.
        for (index, reminder) in reminders.sorted(by: { $0.date < $1.date }).prefix(60).enumerated() {
            guard let video = reminder.assignment.video else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(reminder.account.uploadPlatform?.rawValue ?? "Upload") reminder"
            content.body = "\(reminder.account.displayName) • \(video.name)"
            content.sound = .default
            content.userInfo = ["accountID": reminder.account.id.uuidString, "videoID": video.identityKey]
            var components = reminder.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
            components.timeZone = reminder.calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "\(prefix)\(index)-\(reminder.account.id)", content: content, trigger: trigger))
        }
    }

    private func nextBurstDates(after now: Date, calendar: Calendar) -> [Date] {
        let burstHours = [3, 9, 15, 21]
        let today = calendar.startOfDay(for: now)
        var candidates: [Date] = []
        for dayOffset in 0 ... 2 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else {
                continue
            }
            for hour in burstHours {
                guard let date = calendar.date(byAdding: .hour, value: hour, to: day),
                      date > now
                else { continue }
                candidates.append(date)
            }
        }
        return Array(candidates.sorted().prefix(4))
    }
}
