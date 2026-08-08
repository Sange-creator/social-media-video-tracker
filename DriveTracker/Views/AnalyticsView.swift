import Charts
import SwiftData
import SwiftUI

struct AnalyticsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState

    private var dailyProgress: Double {
        snapshot.dailyTarget > 0
            ? Double(snapshot.completedToday) / Double(snapshot.dailyTarget)
            : 0
    }

    private var dailyCounts: [AnalyticsDayCount] {
        snapshot.dayCounts.map { AnalyticsDayCount(date: $0.date, count: $0.count) }
    }

    private var snapshot: AnalyticsSnapshot {
        guard state.analyticsSnapshot.googleUserID == state.auth.userID else { return .empty }
        return state.analyticsSnapshot
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    dailyTrackerCard
                    overviewGrid
                    trendCard
                    accountBreakdown
                    trackingInsights
                    copyQueueInsights
                    recentActivity
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .trackerScreen()
            .navigationTitle("Analytics")
            .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task { state.scheduleAnalyticsRefresh(context: context) }
    }

    private var dailyTrackerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            TrackerSectionLabel(
                title: "Daily tracker",
                trailing: Date.now.formatted(.dateTime.month(.abbreviated).day())
            )

            HStack(alignment: .top) {
                TrackerMetric(
                    value: "\(snapshot.completedToday)/\(snapshot.dailyTarget)",
                    label: "Completed today",
                    tint: dailyProgress >= 1 ? TrackerPalette.success : .primary
                )
                Spacer()
                TrackerMetric(
                    value: "\(snapshot.activeAccountCount)",
                    label: "Active accounts",
                    tint: TrackerPalette.warning
                )
                Spacer()
                TrackerMetric(
                    value: dailyProgress.formatted(
                        .percent.precision(.fractionLength(0))
                    ),
                    label: "Completion",
                    tint: TrackerPalette.accent
                )
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(TrackerPalette.raised)
                    Rectangle()
                        .fill(
                            dailyProgress >= 1
                                ? TrackerPalette.success
                                : TrackerPalette.accent
                        )
                        .frame(
                            width: geometry.size.width * min(max(dailyProgress, 0), 1)
                        )
                }
            }
            .frame(height: 4)

            HStack {
                Text("\(snapshot.todayCount) downloaded today")
                Spacer()
                Text("\(max(0, snapshot.dailyTarget - snapshot.completedToday)) remaining")
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard()
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    dailyProgress >= 1
                        ? TrackerPalette.success
                        : TrackerPalette.accent
                )
                .frame(height: 2)
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
                    value: "\(snapshot.todayCount)",
                    title: "Today",
                    detail: "Unique videos",
                    symbol: "sun.max",
                    tint: TrackerPalette.accent
                )
                AnalyticsMetricCard(
                    value: "\(snapshot.weekCount)",
                    title: "Last 7 days",
                    detail: "Unique videos",
                    symbol: "calendar",
                    tint: TrackerPalette.warning
                )
                AnalyticsMetricCard(
                    value: "\(snapshot.monthCount)",
                    title: "This month",
                    detail: "Unique videos",
                    symbol: "calendar.badge.clock",
                    tint: .cyan
                )
                AnalyticsMetricCard(
                    value: "\(snapshot.allTimeDownloaded)",
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
            TrackerSectionLabel(
                title: "Last 14 days",
                trailing: "\(snapshot.weekCount) in last 7 days"
            )

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
                    value: snapshot.averagePerActiveDay.formatted(
                        .number.precision(.fractionLength(1))
                    ),
                    label: "Average / active day"
                )
                Spacer()
                insightValue(
                    value: "\(snapshot.bestDayCount)",
                    label: snapshot.bestDayDate.map {
                        "Best · \($0.formatted(.dateTime.month(.abbreviated).day()))"
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
                trailing: "\(snapshot.accounts.count) accounts"
            )

            if snapshot.accounts.isEmpty {
                Text("No accounts are configured.")
                    .font(.subheadline)
                    .foregroundStyle(TrackerPalette.muted)
                    .trackerCard()
            } else {
                ForEach(snapshot.accounts) { metric in
                    NavigationLink {
                        AccountAnalyticsDetailView(account: metric)
                    } label: {
                        AccountAnalyticsRow(metric: metric)
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                }
            }
        }
    }

    private var trackingInsights: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(title: "Tracking details")
            AnalyticsDetailRow(
                title: "Completed / uploaded",
                value: "\(snapshot.completedCount)",
                detail: snapshot.completionRate.formatted(
                    .percent.precision(.fractionLength(0))
                ),
                tint: TrackerPalette.success
            )
            Divider().overlay(TrackerPalette.line)
            AnalyticsDetailRow(
                title: "Downloaded inside app",
                value: "\(snapshot.inAppDownloadedCount)",
                detail: "\(snapshot.downloadActionCount) total download actions",
                tint: TrackerPalette.accent
            )
            Divider().overlay(TrackerPalette.line)
            AnalyticsDetailRow(
                title: "Marked downloaded manually",
                value: "\(snapshot.manuallyCompletedCount)",
                detail: "Completed outside the app",
                tint: TrackerPalette.warning
            )
            Divider().overlay(TrackerPalette.line)
            AnalyticsDetailRow(
                title: "Re-download actions",
                value: "\(snapshot.redownloadCount)",
                detail: "Additional saved copies",
                tint: .cyan
            )
            Divider().overlay(TrackerPalette.line)
            AnalyticsDetailRow(
                title: "Downloaded storage",
                value: ByteCountFormatter.string(
                    fromByteCount: snapshot.downloadedBytes,
                    countStyle: .file
                ),
                detail: "\(snapshot.missingFromPhotos) missing from Photos",
                tint: snapshot.missingFromPhotos > 0
                    ? TrackerPalette.warning
                    : TrackerPalette.muted
            )
        }
        .trackerCard()
    }

    private var copyQueueInsights: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Copy queue",
                trailing: "\(snapshot.activeUncopiedEntries) uncopied"
            )
            HStack {
                TrackerMetric(
                    value: "\(snapshot.copyActionsToday)",
                    label: "Copied today",
                    tint: TrackerPalette.accent
                )
                Spacer()
                TrackerMetric(
                    value: "\(snapshot.copyActionCount)",
                    label: "All copy actions",
                    tint: TrackerPalette.success
                )
                Spacer()
                TrackerMetric(
                    value: "\(snapshot.activeCopyEntryCount)",
                    label: "Active text",
                    tint: TrackerPalette.warning
                )
            }

            Text("One shared queue is used across all managed accounts.")
                .font(.caption)
                .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard()
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrackerSectionLabel(
                title: "Recent downloads",
                trailing: "\(snapshot.recentDownloads.count) shown"
            )

            if snapshot.recentDownloads.isEmpty {
                ContentUnavailableView(
                    "No downloads yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloaded videos will appear here automatically.")
                )
                .foregroundStyle(TrackerPalette.muted)
                .trackerCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.recentDownloads.enumerated()), id: \.element.id) {
                        index,
                        video in
                        RecentDownloadRow(video: video)
                        if index < snapshot.recentDownloads.count - 1 {
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

    private func insightValue(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption)
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
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(TrackerPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .trackerCard(padding: 14)
    }
}

private struct AccountAnalyticsRow: View {
    let metric: AnalyticsAccountSnapshot

    var body: some View {
        HStack(spacing: 12) {
            AccountIdentityIcon(
                symbol: metric.iconSymbol,
                colorHex: metric.iconColorHex,
                size: 44
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(metric.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Today \(metric.today)  ·  7 days \(metric.week)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TrackerPalette.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(metric.total)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(TrackerPalette.accent)
                Text("All time")
                    .font(.caption2)
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
    let video: AnalyticsRecentDownloadSnapshot

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
                Text(video.accountName)
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(video.downloadedAt, style: .time)
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(video.downloadedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(TrackerPalette.muted)
            }
        }
        .padding(12)
    }
}

private struct AccountAnalyticsDetailView: View {
    let account: AnalyticsAccountSnapshot

    private var dayCounts: [AnalyticsDayCount] {
        account.dayCounts.map { AnalyticsDayCount(date: $0.date, count: $0.count) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                HStack {
                    TrackerMetric(
                        value: "\(account.today)",
                        label: "Today",
                        tint: TrackerPalette.accent
                    )
                    Spacer()
                    TrackerMetric(
                        value: "\(account.week)",
                        label: "Last 7 days",
                        tint: TrackerPalette.warning
                    )
                    Spacer()
                    TrackerMetric(
                        value: "\(account.total)",
                        label: "All time",
                        tint: TrackerPalette.success
                    )
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
                        trailing: "\(account.recentDownloads.count) shown"
                    )
                    .padding(14)
                    Divider().overlay(TrackerPalette.line)
                    ForEach(Array(account.recentDownloads.enumerated()), id: \.element.id) {
                        index,
                        video in
                        RecentDownloadRow(video: video)
                        if index < account.recentDownloads.count - 1 {
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
            .padding(.bottom, 24)
        }
        .trackerScreen()
        .navigationTitle(account.name)
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
