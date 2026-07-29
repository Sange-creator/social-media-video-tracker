import Charts
import SwiftData
import SwiftUI

struct AnalyticsView: View {
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]
    @Query private var videos: [VideoAsset]
    @Query(sort: \StatusEvent.timestamp, order: .reverse) private var events: [StatusEvent]

    private let calendar = Calendar.autoupdatingCurrent

    private var downloadedVideos: [VideoAsset] {
        videos.filter { $0.downloadedAt != nil }
    }

    private var downloadEvents: [StatusEvent] {
        events.filter { $0.kind == .downloadSucceeded }
    }

    private var todayCount: Int {
        downloadedVideos.filter {
            guard let date = $0.downloadedAt else { return false }
            return calendar.isDateInToday(date)
        }.count
    }

    private var weekCount: Int {
        countDownloads(since: calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday)
    }

    private var monthCount: Int {
        countDownloads(
            since: calendar.dateInterval(of: .month, for: .now)?.start ?? startOfToday
        )
    }

    private var completedCount: Int {
        videos.filter { $0.uploadedAt != nil }.count
    }

    private var completionRate: Double {
        downloadedVideos.isEmpty
            ? 0
            : Double(completedCount) / Double(downloadedVideos.count)
    }

    private var inAppDownloadedKeys: Set<String> {
        Set(downloadEvents.compactMap(\.video?.identityKey))
    }

    private var manualDownloadCount: Int {
        downloadedVideos.filter { !inAppDownloadedKeys.contains($0.identityKey) }.count
    }

    private var redownloadCount: Int {
        max(0, downloadEvents.count - inAppDownloadedKeys.count)
    }

    private var downloadedBytes: Int64 {
        downloadedVideos.reduce(0) { $0 + ($1.size ?? 0) }
    }

    private var missingFromPhotos: Int {
        downloadedVideos.filter(\.isMissingFromPhotos).count
    }

    private var dailyCounts: [AnalyticsDayCount] {
        Self.dayCounts(for: downloadedVideos, days: 14, calendar: calendar)
    }

    private var activeDayCounts: [Date: Int] {
        Dictionary(grouping: downloadedVideos.compactMap(\.downloadedAt)) {
            calendar.startOfDay(for: $0)
        }
        .mapValues(\.count)
    }

    private var bestDay: (date: Date, count: Int)? {
        activeDayCounts.max { lhs, rhs in lhs.value < rhs.value }
            .map { ($0.key, $0.value) }
    }

    private var averagePerActiveDay: Double {
        activeDayCounts.isEmpty
            ? 0
            : Double(downloadedVideos.count) / Double(activeDayCounts.count)
    }

    private var recentDownloads: [VideoAsset] {
        downloadedVideos
            .sorted { ($0.downloadedAt ?? .distantPast) > ($1.downloadedAt ?? .distantPast) }
            .prefix(20)
            .map { $0 }
    }

    private var startOfToday: Date {
        calendar.startOfDay(for: .now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    overviewGrid
                    trendCard
                    accountBreakdown
                    trackingInsights
                    recentActivity
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 104)
            }
            .trackerScreen()
            .navigationTitle("Analytics")
            .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var overviewGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrackerSectionLabel(title: "Download overview", trailing: "Local time")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                AnalyticsMetricCard(
                    value: "\(todayCount)",
                    title: "Today",
                    detail: "Unique videos",
                    symbol: "sun.max",
                    tint: TrackerPalette.accent
                )
                AnalyticsMetricCard(
                    value: "\(weekCount)",
                    title: "Last 7 days",
                    detail: "Unique videos",
                    symbol: "calendar",
                    tint: TrackerPalette.warning
                )
                AnalyticsMetricCard(
                    value: "\(monthCount)",
                    title: "This month",
                    detail: "Unique videos",
                    symbol: "calendar.badge.clock",
                    tint: .cyan
                )
                AnalyticsMetricCard(
                    value: "\(downloadedVideos.count)",
                    title: "All time",
                    detail: "Tracked downloads",
                    symbol: "arrow.down.circle",
                    tint: TrackerPalette.success
                )
            }
        }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(title: "Last 14 days", trailing: "\(weekCount) in last 7 days")

            Chart(dailyCounts) { item in
                BarMark(
                    x: .value("Day", item.date, unit: .day),
                    y: .value("Downloads", item.count)
                )
                .foregroundStyle(
                    item.count > 0 ? TrackerPalette.accent : TrackerPalette.raised
                )
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisGridLine().foregroundStyle(TrackerPalette.line)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(TrackerPalette.muted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(TrackerPalette.line)
                    AxisValueLabel().foregroundStyle(TrackerPalette.muted)
                }
            }
            .frame(height: 180)

            HStack {
                insightValue(
                    value: averagePerActiveDay.formatted(.number.precision(.fractionLength(1))),
                    label: "Average / active day"
                )
                Spacer()
                insightValue(
                    value: bestDay.map { "\($0.count)" } ?? "0",
                    label: bestDay.map {
                        "Best · \($0.date.formatted(.dateTime.month(.abbreviated).day()))"
                    } ?? "Best day"
                )
            }
        }
        .trackerCard()
    }

    private var accountBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrackerSectionLabel(
                title: "By account",
                trailing: "\(accounts.count) accounts"
            )

            if accounts.isEmpty {
                Text("No accounts are configured.")
                    .font(.subheadline)
                    .foregroundStyle(TrackerPalette.muted)
                    .trackerCard()
            } else {
                ForEach(sortedAccountMetrics) { metric in
                    NavigationLink {
                        AccountAnalyticsDetailView(account: metric.account)
                    } label: {
                        AccountAnalyticsRow(metric: metric)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var trackingInsights: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(title: "Tracking details")
            AnalyticsDetailRow(
                title: "Completed / uploaded",
                value: "\(completedCount)",
                detail: completionRate.formatted(.percent.precision(.fractionLength(0))),
                tint: TrackerPalette.success
            )
            Divider().overlay(TrackerPalette.line)
            AnalyticsDetailRow(
                title: "Downloaded inside app",
                value: "\(inAppDownloadedKeys.count)",
                detail: "\(downloadEvents.count) total download actions",
                tint: TrackerPalette.accent
            )
            Divider().overlay(TrackerPalette.line)
            AnalyticsDetailRow(
                title: "Marked downloaded manually",
                value: "\(manualDownloadCount)",
                detail: "Completed outside the app",
                tint: TrackerPalette.warning
            )
            Divider().overlay(TrackerPalette.line)
            AnalyticsDetailRow(
                title: "Re-download actions",
                value: "\(redownloadCount)",
                detail: "Additional saved copies",
                tint: .cyan
            )
            Divider().overlay(TrackerPalette.line)
            AnalyticsDetailRow(
                title: "Downloaded storage",
                value: ByteCountFormatter.string(
                    fromByteCount: downloadedBytes,
                    countStyle: .file
                ),
                detail: "\(missingFromPhotos) missing from Photos",
                tint: missingFromPhotos > 0 ? TrackerPalette.warning : TrackerPalette.muted
            )
        }
        .trackerCard()
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrackerSectionLabel(
                title: "Recent downloads",
                trailing: "\(recentDownloads.count) shown"
            )

            if recentDownloads.isEmpty {
                ContentUnavailableView(
                    "No downloads yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloaded videos will appear here automatically.")
                )
                .foregroundStyle(TrackerPalette.muted)
                .trackerCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentDownloads.enumerated()), id: \.element.identityKey) {
                        index,
                        video in
                        RecentDownloadRow(video: video)
                        if index < recentDownloads.count - 1 {
                            Divider()
                                .overlay(TrackerPalette.line)
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(TrackerPalette.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(TrackerPalette.line, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
        }
    }

    private var sortedAccountMetrics: [AccountDownloadMetric] {
        accounts.map { account in
            let accountDownloads = account.videos.filter { $0.downloadedAt != nil }
            let today = accountDownloads.filter {
                guard let date = $0.downloadedAt else { return false }
                return calendar.isDateInToday(date)
            }.count
            let sevenDaysAgo = calendar.date(
                byAdding: .day,
                value: -6,
                to: startOfToday
            ) ?? startOfToday
            let week = accountDownloads.filter {
                ($0.downloadedAt ?? .distantPast) >= sevenDaysAgo
            }.count
            return AccountDownloadMetric(
                account: account,
                today: today,
                week: week,
                total: accountDownloads.count,
                completed: account.videos.filter { $0.uploadedAt != nil }.count
            )
        }
        .sorted {
            if $0.today != $1.today { return $0.today > $1.today }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.account.sortOrder < $1.account.sortOrder
        }
    }

    private func countDownloads(since date: Date) -> Int {
        downloadedVideos.filter { ($0.downloadedAt ?? .distantPast) >= date }.count
    }

    private func insightValue(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit().weight(.bold))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(TrackerPalette.muted)
        }
    }
}

private struct AnalyticsMetricCard: View {
    let value: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(tint)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(TrackerPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .trackerCard(padding: 14)
    }
}

private struct AccountDownloadMetric: Identifiable {
    let account: TikTokAccount
    let today: Int
    let week: Int
    let total: Int
    let completed: Int

    var id: UUID { account.id }
}

private struct AccountAnalyticsRow: View {
    let metric: AccountDownloadMetric

    var body: some View {
        HStack(spacing: 12) {
            AccountIdentityIcon(
                symbol: metric.account.iconSymbol,
                colorHex: metric.account.iconColorHex,
                size: 44
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(metric.account.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Today \(metric.today)  ·  7 days \(metric.week)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TrackerPalette.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(metric.total)")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(TrackerPalette.accent)
                Text("ALL TIME")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(TrackerPalette.muted)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard(padding: 13)
    }
}

private struct AnalyticsDetailRow: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
            }
            Spacer()
            Text(value)
                .font(.headline.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
        }
    }
}

private struct RecentDownloadRow: View {
    let video: VideoAsset

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(TrackerPalette.accent)
                .frame(width: 32, height: 32)
                .background(TrackerPalette.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(video.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(video.account?.displayName ?? "Unknown account")
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
            }
            Spacer()
            if let date = video.downloadedAt {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(date, style: .time)
                        .font(.caption.monospacedDigit().weight(.semibold))
                    Text(date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(TrackerPalette.muted)
                }
            }
        }
        .padding(12)
    }
}

private struct AccountAnalyticsDetailView: View {
    let account: TikTokAccount
    private let calendar = Calendar.autoupdatingCurrent

    private var downloaded: [VideoAsset] {
        account.videos
            .filter { $0.downloadedAt != nil }
            .sorted { ($0.downloadedAt ?? .distantPast) > ($1.downloadedAt ?? .distantPast) }
    }

    private var today: Int {
        downloaded.filter {
            guard let date = $0.downloadedAt else { return false }
            return calendar.isDateInToday(date)
        }.count
    }

    private var week: Int {
        let start = calendar.date(
            byAdding: .day,
            value: -6,
            to: calendar.startOfDay(for: .now)
        ) ?? .now
        return downloaded.filter { ($0.downloadedAt ?? .distantPast) >= start }.count
    }

    private var dayCounts: [AnalyticsDayCount] {
        AnalyticsView.dayCounts(for: downloaded, days: 30, calendar: calendar)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                HStack {
                    TrackerMetric(value: "\(today)", label: "Today", tint: TrackerPalette.accent)
                    Spacer()
                    TrackerMetric(value: "\(week)", label: "Last 7 days", tint: TrackerPalette.warning)
                    Spacer()
                    TrackerMetric(value: "\(downloaded.count)", label: "All time", tint: TrackerPalette.success)
                }
                .trackerCard()

                VStack(alignment: .leading, spacing: 12) {
                    TrackerSectionLabel(title: "30-day trend")
                    Chart(dayCounts) { item in
                        LineMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Downloads", item.count)
                        )
                        .foregroundStyle(TrackerPalette.accent)
                        AreaMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Downloads", item.count)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    TrackerPalette.accent.opacity(0.30),
                                    TrackerPalette.accent.opacity(0.02)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .foregroundStyle(TrackerPalette.muted)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 180)
                }
                .trackerCard()

                VStack(alignment: .leading, spacing: 0) {
                    TrackerSectionLabel(
                        title: "Download history",
                        trailing: "\(downloaded.count) videos"
                    )
                    .padding(14)
                    Divider().overlay(TrackerPalette.line)
                    ForEach(Array(downloaded.prefix(50).enumerated()), id: \.element.identityKey) {
                        index,
                        video in
                        RecentDownloadRow(video: video)
                        if index < min(downloaded.count, 50) - 1 {
                            Divider()
                                .overlay(TrackerPalette.line)
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(TrackerPalette.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(TrackerPalette.line, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .padding(16)
            .padding(.bottom, 104)
        }
        .trackerScreen()
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct AnalyticsDayCount: Identifiable {
    let date: Date
    let count: Int

    var id: Date { date }
}

private extension AnalyticsView {
    static func dayCounts(
        for videos: [VideoAsset],
        days: Int,
        calendar: Calendar
    ) -> [AnalyticsDayCount] {
        let today = calendar.startOfDay(for: .now)
        let grouped = Dictionary(grouping: videos.compactMap(\.downloadedAt)) {
            calendar.startOfDay(for: $0)
        }
        return (0 ..< days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return AnalyticsDayCount(date: date, count: grouped[date]?.count ?? 0)
        }
    }
}
