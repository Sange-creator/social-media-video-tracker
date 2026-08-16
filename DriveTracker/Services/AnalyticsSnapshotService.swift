import Foundation
import SwiftData

struct AnalyticsDaySnapshot: Codable, Sendable, Equatable, Identifiable {
    let date: Date
    let count: Int

    var id: Date { date }
}

struct AnalyticsRecentDownloadSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let accountName: String
    let downloadedAt: Date
}

struct AnalyticsAccountSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let iconSymbol: String
    let iconColorHex: String
    let sortOrder: Int
    let today: Int
    let week: Int
    let total: Int
    let completed: Int
    let dayCounts: [AnalyticsDaySnapshot]
    let recentDownloads: [AnalyticsRecentDownloadSnapshot]
}

struct AnalyticsSnapshot: Codable, Sendable, Equatable {
    let googleUserID: String
    let generatedAt: Date
    let dailyTarget: Int
    let completedToday: Int
    let activeAccountCount: Int
    let todayCount: Int
    let weekCount: Int
    let monthCount: Int
    let allTimeDownloaded: Int
    let completedCount: Int
    let completionRate: Double
    let inAppDownloadedCount: Int
    let downloadActionCount: Int
    let manuallyCompletedCount: Int
    let redownloadCount: Int
    let downloadedBytes: Int64
    let missingFromPhotos: Int
    let averagePerActiveDay: Double
    let bestDayDate: Date?
    let bestDayCount: Int
    let dayCounts: [AnalyticsDaySnapshot]
    let accounts: [AnalyticsAccountSnapshot]
    let copyActionsToday: Int
    let copyActionCount: Int
    let activeUncopiedEntries: Int
    let activeCopyEntryCount: Int
    let recentDownloads: [AnalyticsRecentDownloadSnapshot]

    static let empty = AnalyticsSnapshot(
        googleUserID: "",
        generatedAt: .distantPast,
        dailyTarget: 0,
        completedToday: 0,
        activeAccountCount: 0,
        todayCount: 0,
        weekCount: 0,
        monthCount: 0,
        allTimeDownloaded: 0,
        completedCount: 0,
        completionRate: 0,
        inAppDownloadedCount: 0,
        downloadActionCount: 0,
        manuallyCompletedCount: 0,
        redownloadCount: 0,
        downloadedBytes: 0,
        missingFromPhotos: 0,
        averagePerActiveDay: 0,
        bestDayDate: nil,
        bestDayCount: 0,
        dayCounts: [],
        accounts: [],
        copyActionsToday: 0,
        copyActionCount: 0,
        activeUncopiedEntries: 0,
        activeCopyEntryCount: 0,
        recentDownloads: []
    )
}

enum AnalyticsSnapshotService {
    nonisolated static func makeSnapshot(
        container: ModelContainer,
        googleUserID: String
    ) async throws -> AnalyticsSnapshot {
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try buildSnapshot(context: context, googleUserID: googleUserID)
        }.value
    }

    nonisolated private static func buildSnapshot(
        context: ModelContext,
        googleUserID: String
    ) throws -> AnalyticsSnapshot {
        let calendar = Calendar.autoupdatingCurrent
        let todayStart = calendar.startOfDay(for: .now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let monthStart = calendar.dateInterval(of: .month, for: .now)?.start ?? todayStart

        let accounts = try context.fetch(
            FetchDescriptor<TikTokAccount>(
                predicate: #Predicate<TikTokAccount> { $0.googleUserID == googleUserID },
                sortBy: [SortDescriptor(\TikTokAccount.sortOrder)]
            )
        )
        let videos = try context.fetch(
            FetchDescriptor<VideoAsset>(
                predicate: #Predicate<VideoAsset> { $0.googleUserID == googleUserID }
            )
        )
        let statusEvents = try context.fetch(FetchDescriptor<StatusEvent>())
        let copyEntries = try context.fetch(
            FetchDescriptor<CopyEntry>(
                predicate: #Predicate<CopyEntry> { $0.googleUserID == googleUserID }
            )
        )
        let copyEvents = try context.fetch(FetchDescriptor<CopyEvent>())

        let activeAccounts = accounts.filter {
            $0.isConfigured && !$0.isPaused && !$0.isMissingFromDrive
        }
        let activeAccountIDs = Set(activeAccounts.map(\.id))
        let downloaded = videos.filter { $0.downloadedAt != nil }
        // Index once instead of repeatedly filtering the full library for
        // every account and metric during an analytics refresh.
        let videosByAccount = Dictionary(grouping: videos) { $0.account?.id }
        let downloadedByAccount = Dictionary(grouping: downloaded) { $0.account?.id }
        let todayDownloaded = downloaded.lazy.filter {
            $0.downloadedAt.map(calendar.isDateInToday) ?? false
        }
        let weekDownloaded = downloaded.lazy.filter {
            ($0.downloadedAt ?? .distantPast) >= weekStart
        }
        let monthDownloaded = downloaded.lazy.filter {
            ($0.downloadedAt ?? .distantPast) >= monthStart
        }
        let completedToday = videos.filter {
            guard let accountID = $0.account?.id,
                  activeAccountIDs.contains(accountID),
                  let completedAt = $0.uploadedAt
            else { return false }
            return calendar.isDateInToday(completedAt)
        }.count
        let completedCount = videos.filter { $0.uploadedAt != nil }.count

        let userDownloadEvents = statusEvents.filter {
            $0.kindRawValue == StatusEventKind.downloadSucceeded.rawValue &&
            $0.video?.googleUserID == googleUserID
        }
        let inAppDownloadedKeys = Set(userDownloadEvents.compactMap { $0.video?.identityKey })

        let userCopyEvents = copyEvents.filter {
            ($0.kindRawValue == CopyEventKind.copied.rawValue ||
             $0.kindRawValue == CopyEventKind.recopied.rawValue) &&
            $0.entry?.googleUserID == googleUserID
        }
        let activeCopyEntries = copyEntries.filter { !$0.isMissingFromDrive }

        let accountSnapshots = accounts.map { account in
            let accountVideos = videosByAccount[account.id] ?? []
            let accountDownloads = downloadedByAccount[account.id] ?? []
            return AnalyticsAccountSnapshot(
                id: account.id,
                name: account.displayName,
                iconSymbol: account.iconSymbol,
                iconColorHex: account.iconColorHex,
                sortOrder: account.sortOrder,
                today: accountDownloads.filter {
                    $0.downloadedAt.map(calendar.isDateInToday) ?? false
                }.count,
                week: accountDownloads.filter {
                    ($0.downloadedAt ?? .distantPast) >= weekStart
                }.count,
                total: accountDownloads.count,
                completed: accountVideos.lazy.filter { $0.uploadedAt != nil }.count,
                dayCounts: dayCounts(
                    dates: accountDownloads.compactMap(\.downloadedAt),
                    days: 30,
                    calendar: calendar
                ),
                recentDownloads: recentDownloads(from: accountDownloads, limit: 50)
            )
        }
        .sorted {
            if $0.today != $1.today { return $0.today > $1.today }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.sortOrder < $1.sortOrder
        }

        let activeDayCounts = Dictionary(grouping: downloaded.compactMap(\.downloadedAt)) {
            calendar.startOfDay(for: $0)
        }.mapValues(\.count)
        let bestDay = activeDayCounts.max { $0.value < $1.value }

        return AnalyticsSnapshot(
            googleUserID: googleUserID,
            generatedAt: .now,
            dailyTarget: activeAccounts.reduce(0) { $0 + $1.dailyQuota },
            completedToday: completedToday,
            activeAccountCount: activeAccounts.count,
            todayCount: todayDownloaded.count,
            weekCount: weekDownloaded.count,
            monthCount: monthDownloaded.count,
            allTimeDownloaded: downloaded.count,
            completedCount: completedCount,
            completionRate: downloaded.isEmpty
                ? 0
                : Double(completedCount) / Double(downloaded.count),
            inAppDownloadedCount: inAppDownloadedKeys.count,
            downloadActionCount: userDownloadEvents.count,
            manuallyCompletedCount: downloaded.filter {
                !inAppDownloadedKeys.contains($0.identityKey)
            }.count,
            redownloadCount: max(0, userDownloadEvents.count - inAppDownloadedKeys.count),
            downloadedBytes: downloaded.reduce(0) { $0 + ($1.size ?? 0) },
            missingFromPhotos: downloaded.lazy.filter(\.isMissingFromPhotos).count,
            averagePerActiveDay: activeDayCounts.isEmpty
                ? 0
                : Double(downloaded.count) / Double(activeDayCounts.count),
            bestDayDate: bestDay?.key,
            bestDayCount: bestDay?.value ?? 0,
            dayCounts: dayCounts(
                dates: downloaded.compactMap(\.downloadedAt),
                days: 14,
                calendar: calendar
            ),
            accounts: accountSnapshots,
            copyActionsToday: userCopyEvents.filter {
                calendar.isDateInToday($0.timestamp)
            }.count,
            copyActionCount: userCopyEvents.count,
            activeUncopiedEntries: activeCopyEntries.filter { $0.copiedAt == nil }.count,
            activeCopyEntryCount: activeCopyEntries.count,
            recentDownloads: recentDownloads(from: downloaded, limit: 20)
        )
    }

    nonisolated private static func dayCounts(
        dates: [Date],
        days: Int,
        calendar: Calendar
    ) -> [AnalyticsDaySnapshot] {
        let today = calendar.startOfDay(for: .now)
        let grouped = Dictionary(grouping: dates) { calendar.startOfDay(for: $0) }
        return (0 ..< days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return AnalyticsDaySnapshot(date: date, count: grouped[date]?.count ?? 0)
        }
    }

    nonisolated private static func recentDownloads(
        from videos: [VideoAsset],
        limit: Int
    ) -> [AnalyticsRecentDownloadSnapshot] {
        videos
            .compactMap { video -> AnalyticsRecentDownloadSnapshot? in
                guard let downloadedAt = video.downloadedAt else { return nil }
                return AnalyticsRecentDownloadSnapshot(
                    id: video.identityKey,
                    name: video.name,
                    accountName: video.account?.displayName ?? "Unknown account",
                    downloadedAt: downloadedAt
                )
            }
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .prefix(limit)
            .map { $0 }
    }
}
