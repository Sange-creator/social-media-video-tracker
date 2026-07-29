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
        let assignmentsByAccount = Dictionary(grouping: pending, by: { $0.account!.id })
        let accounts = assignmentsByAccount
            .values
            .compactMap(\.first?.account)
            .sorted { $0.sortOrder < $1.sortOrder }

        // iOS keeps at most 64 pending local notifications. Four six-hour
        // windows × fifteen accounts stays under that cap, while the common
        // ten-account setup produces ten reminders per window.
        let scheduledAccounts = Array(accounts.prefix(15))
        let burstDates = nextBurstDates(after: now, calendar: selectedCalendar)

        for (burstIndex, burstDate) in burstDates.enumerated() {
            for (accountIndex, account) in scheduledAccounts.enumerated() {
                let accountAssignments = (assignmentsByAccount[account.id] ?? [])
                    .sorted { $0.slot < $1.slot }
                guard !accountAssignments.isEmpty else { continue }
                let assignment = accountAssignments[burstIndex % accountAssignments.count]
                guard let video = assignment.video else { continue }
                let minuteOffset = accountIndex * 5
                guard let fireDate = selectedCalendar.date(
                    byAdding: .minute,
                    value: minuteOffset,
                    to: burstDate
                ) else { continue }

                let content = UNMutableNotificationContent()
                content.title = "Download reminder"
                content.body = "\(account.displayName) • \(video.name)"
                content.sound = .default
                content.userInfo = [
                    "accountID": account.id.uuidString,
                    "videoID": video.identityKey
                ]
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: selectedCalendar.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: fireDate
                    ),
                    repeats: false
                )
                let identifier = "\(prefix)\(burstIndex)-\(account.id.uuidString)"
                try? await center.add(
                    UNNotificationRequest(
                        identifier: identifier,
                        content: content,
                        trigger: trigger
                    )
                )
            }
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
