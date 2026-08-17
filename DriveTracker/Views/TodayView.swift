import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]

    private var activeAccounts: [TikTokAccount] {
        accounts.filter { $0.isConfigured && !$0.isPaused && !$0.isMissingFromDrive }
    }

    private var selectedUSZone: USReminderTimeZone {
        USReminderTimeZone(rawValue: state.reminderTimeZoneID) ?? .eastern
    }

    private var totalDailyQuota: Int {
        activeAccounts.reduce(0) { $0 + $1.dailyQuota }
    }

    private var totalCompletedToday: Int {
        activeAccounts.reduce(0) { sum, account in
            sum + account.videos.filter { video in
                guard let uploadedAt = video.uploadedAt else { return false }
                return DayKey.value(for: uploadedAt) == DayKey.value(for: .now)
            }.count
        }
    }

    var body: some View {
        let visibleAccounts = activeAccounts
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    customTopHeader
                    dailyBentoHeader
                    scheduleCard
                    GlobalCopyQueueCard()

                    HStack {
                        TrackerSectionLabel(
                            title: "Tracked Accounts",
                            trailing: "\(visibleAccounts.count) active"
                        )
                    }
                    .padding(.top, 6)

                    ForEach(visibleAccounts) { account in
                        NavigationLink {
                            TodayAccountDetailView(account: account)
                        } label: {
                            TodayAccountRow(account: account)
                        }
                        .buttonStyle(TrackerPressButtonStyle())
                    }

                    if visibleAccounts.isEmpty {
                        ContentUnavailableView(
                            "No active accounts",
                            systemImage: "pause.rectangle",
                            description: Text("Resume an account from the Accounts tab.")
                        )
                        .foregroundStyle(TrackerPalette.muted)
                        .padding(.top, 50)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 120)
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .trackerScreen()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                if state.hasRootFolder {
                    await state.sync(context: context, announce: false)
                } else {
                    try? state.ensureToday(context: context)
                }
            }
        }
        .task {
            await state.refreshFromDriveIfNeeded(context: context)
            try? state.ensureToday(context: context)
            await state.scheduleDownloadNotifications(context: context)
        }
    }

    private var customTopHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TODAY")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(TrackerPalette.textPrimary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(state.isWorking ? TrackerPalette.warning : TrackerPalette.success)
                        .frame(width: 6, height: 6)
                        .shadow(color: (state.isWorking ? TrackerPalette.warning : TrackerPalette.success).opacity(0.8), radius: 3)
                    Text(state.isWorking ? "Syncing Drive..." : "All Folders Synced")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TrackerPalette.muted)
                }
            }

            Spacer()

            Button {
                Task { await state.sync(context: context, announce: false) }
            } label: {
                ZStack {
                    Circle()
                        .fill(TrackerPalette.surface)
                        .frame(width: 40, height: 40)
                        .overlay {
                            Circle().stroke(TrackerPalette.line, lineWidth: 1)
                        }

                    if state.isWorking {
                        ProgressView()
                            .tint(TrackerPalette.accent)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(TrackerPalette.accent)
                    }
                }
            }
            .buttonStyle(TrackerPressButtonStyle())
            .disabled(state.isWorking || !state.hasRootFolder)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var dailyBentoHeader: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(spacing: 14) {
                // Live Status Bar
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(formattedDate(timeline.date))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(TrackerPalette.textPrimary)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(TrackerPalette.success)
                                .frame(width: 5, height: 5)
                            Text(selectedUSZone.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(TrackerPalette.muted)
                        }
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                            .foregroundStyle(TrackerPalette.accent)
                        Text(formattedTime(timeline.date))
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(TrackerPalette.accent)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(TrackerPalette.accent.opacity(0.12), in: Capsule())
                }

                Divider().overlay(TrackerPalette.line)

                // Bento Quota Hub
                HStack(spacing: 16) {
                    RadialQuotaProgress(
                        completed: totalCompletedToday,
                        quota: max(totalDailyQuota, 1),
                        size: 68,
                        lineWidth: 6.5
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(totalCompletedToday) of \(totalDailyQuota) Completed")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(TrackerPalette.textPrimary)

                        let remaining = max(0, totalDailyQuota - totalCompletedToday)
                        Text(remaining == 0 ? "Daily goal achieved!" : "\(remaining) video\(remaining == 1 ? "" : "s") left for today")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(remaining == 0 ? TrackerPalette.success : TrackerPalette.muted)

                        HStack(spacing: 8) {
                            Button {
                                try? state.ensureToday(context: context)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "shuffle")
                                    Text("Shuffle")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TrackerPalette.accent)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(TrackerPalette.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(TrackerPressButtonStyle())
                        }
                        .padding(.top, 2)
                    }

                    Spacer()
                }
            }
            .trackerCard(padding: 16)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = selectedUSZone.timeZone
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = selectedUSZone.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private var activeSlotNumber: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = NewYorkSchedule.timeZone
        let hour = cal.component(.hour, from: .now)
        if hour < 12 { return 1 }
        else if hour < 17 { return 2 }
        else { return 3 }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Suggested US Posting Slots", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(TrackerPalette.muted)
                Spacer()
                Text(selectedUSZone.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TrackerPalette.accent)
            }

            HStack(spacing: 8) {
                ForEach(NewYorkSchedule.slots) { slot in
                    let isActive = slot.number == activeSlotNumber
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            if isActive {
                                Circle()
                                    .fill(TrackerPalette.accent)
                                    .frame(width: 5, height: 5)
                            }
                            Text("Slot \(slot.number)")
                                .font(.caption2.weight(isActive ? .bold : .medium))
                                .foregroundStyle(isActive ? TrackerPalette.accent : TrackerPalette.muted)
                        }
                        Text(slot.label(in: selectedUSZone.timeZone))
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(isActive ? TrackerPalette.accent : TrackerPalette.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(isActive ? TrackerPalette.accent.opacity(0.12) : TrackerPalette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isActive ? TrackerPalette.accent.opacity(0.6) : TrackerPalette.line, lineWidth: isActive ? 1.2 : 0.5)
                    }
                }
            }
        }
        .trackerCard(padding: 14)
    }
}

private struct TodayAccountRow: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount

    private var todaysVideos: [VideoAsset] {
        account.videos.filter { video in
            if video.status == .assigned || video.status == .downloaded { return true }
            guard let uploadedAt = video.uploadedAt else { return false }
            return DayKey.value(for: uploadedAt) == DayKey.value(for: .now)
        }
    }

    private var completedCount: Int {
        todaysVideos.filter { $0.status == .uploaded }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AccountIdentityIcon(
                    symbol: account.iconSymbol,
                    colorHex: account.iconColorHex,
                    size: 46
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(account.folderName)
                            .font(.caption)
                            .foregroundStyle(TrackerPalette.muted)
                            .lineLimit(1)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("\(completedCount)/\(account.dailyQuota)")
                        .font(.system(.subheadline, design: .rounded).monospacedDigit().weight(.bold))
                        .foregroundStyle(completedCount >= account.dailyQuota ? TrackerPalette.success : TrackerPalette.accent)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TrackerPalette.muted)
                }
            }

            if !todaysVideos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(todaysVideos) { video in
                            TodayVideoPosterCard(video: video)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .trackerCard(padding: 14)
        .contentShape(Rectangle())
    }
}

private struct TodayVideoPosterCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let video: VideoAsset

    private var isDownloading: Bool {
        state.isDownloading(video)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VideoThumbnailView(
                video: video,
                width: 112,
                height: 154,
                cornerRadius: 12
            )

            // Top Status Badge
            VStack {
                HStack {
                    StatusPill(status: video.status)
                    Spacer()
                }
                Spacer()
            }
            .padding(6)

            // Bottom Content Scrim with Integrated Action Button
            VStack(alignment: .leading, spacing: 4) {
                Text(video.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if video.status == .assigned || video.status == .available {
                    Button {
                        if isDownloading {
                            state.cancelDownload(video)
                        } else {
                            state.startParallelDownload(video, context: context)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isDownloading {
                                ProgressView()
                                    .tint(Color(hex: "#090A0F"))
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 9, weight: .black))
                            }
                            Text(isDownloading ? "..." : "Get")
                                .font(.system(size: 10, weight: .black))
                        }
                        .foregroundStyle(Color(hex: "#090A0F"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(TrackerPalette.accent, in: Capsule())
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                } else if video.status == .downloaded {
                    Button {
                        state.markCompletedOutsideApp(video, context: context)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("Post")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(TrackerPalette.success, in: Capsule())
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                } else if video.status == .uploaded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                        Text("Done")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(TrackerPalette.success)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(TrackerPalette.success.opacity(0.18), in: Capsule())
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            // A flat scrim keeps the poster row on the fast compositing path
            // while preserving readable white labels over thumbnails.
            .background(Color.black.opacity(0.78))
        }
        .frame(width: 112, height: 154)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: "#222739"), lineWidth: 1)
        }
    }
}

private struct TodayAccountDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                AccountTodaySection(account: account)
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .trackerScreen()
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .refreshable {
            await state.sync(context: context, announce: false)
        }
    }
}

private struct AccountTodaySection: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount
    @State private var showManualPicker = false

    private var todaysVideos: [VideoAsset] {
        account.videos.filter { video in
            if video.status == .assigned || video.status == .downloaded { return true }
            guard let uploadedAt = video.uploadedAt else { return false }
            return DayKey.value(for: uploadedAt) == DayKey.value(for: .now)
        }
        .sorted {
            let lhsSlot = $0.activeAssignment?.slot ?? Int.max
            let rhsSlot = $1.activeAssignment?.slot ?? Int.max
            if lhsSlot != rhsSlot { return lhsSlot < rhsSlot }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var shortage: Int {
        max(0, account.dailyQuota - todaysVideos.count)
    }

    private var completed: Int {
        todaysVideos.filter { $0.status == .uploaded }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AccountIdentityIcon(
                    symbol: account.iconSymbol,
                    colorHex: account.iconColorHex,
                    size: 52
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Text("\(account.availableCount) unused  •  \(account.uploadedCount) completed")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(TrackerPalette.muted)
                }
                Spacer()

                RadialQuotaProgress(
                    completed: completed,
                    quota: max(account.dailyQuota, 1),
                    size: 52,
                    lineWidth: 5
                )
            }
            .padding(16)

            HStack(spacing: 10) {
                Button {
                    state.downloadAllAssigned(for: account, context: context)
                } label: {
                    Label("Download All", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))

                Button {
                    showManualPicker = true
                } label: {
                    Label("Choose Video", systemImage: "hand.tap.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            if shortage > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(shortage) unused video\(shortage == 1 ? "" : "s") short of daily quota")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(TrackerPalette.warning)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(TrackerPalette.warning.opacity(0.10))
            }

            Divider().overlay(TrackerPalette.line)

            if todaysVideos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 38))
                        .foregroundStyle(TrackerPalette.muted)
                    Text("No daily suggestions assigned")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TrackerPalette.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(Array(todaysVideos.enumerated()), id: \.element.id) { index, video in
                    TodayVideoRow(video: video, slot: index + 1)
                    if index < todaysVideos.count - 1 {
                        Divider()
                            .overlay(TrackerPalette.line)
                            .padding(.leading, 70)
                    }
                }
            }
        }
        .background(TrackerPalette.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(isPresented: $showManualPicker) {
            ManualVideoPickerView(account: account)
        }
    }
}

private struct ManualVideoPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount

    @State private var search = ""
    @State private var previewVideo: VideoAsset?

    private var availableVideos: [VideoAsset] {
        account.videos
            .filter {
                $0.status == .available &&
                !$0.isMissingFromDrive &&
                $0.canDownload &&
                (search.isEmpty ||
                    $0.name.localizedCaseInsensitiveContains(search) ||
                    $0.folderPath.localizedCaseInsensitiveContains(search))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AccountIdentityIcon(
                            symbol: account.iconSymbol,
                            colorHex: account.iconColorHex,
                            size: 48
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.displayName)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(TrackerPalette.textPrimary)
                            Text("Download any unused video immediately without changing your daily schedule.")
                                .font(.caption)
                                .foregroundStyle(TrackerPalette.muted)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(TrackerPalette.surface)
                }

                Section("Unused Videos (\(availableVideos.count))") {
                    if availableVideos.isEmpty {
                        ContentUnavailableView(
                            "No unused videos",
                            systemImage: "video.slash",
                            description: Text("Sync the folder or change your search.")
                        )
                        .listRowBackground(TrackerPalette.surface)
                    } else {
                        ForEach(availableVideos) { video in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 12) {
                                    VideoThumbnailView(
                                        video: video,
                                        width: 100,
                                        height: 136,
                                        cornerRadius: 10
                                    )

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(video.name)
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(TrackerPalette.textPrimary)
                                            .lineLimit(2)
                                        Label(
                                            video.folderPath.isEmpty ? account.folderName : video.folderPath,
                                            systemImage: "folder"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(TrackerPalette.muted)
                                        .lineLimit(2)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    previewVideo = video
                                }

                                HStack(spacing: 10) {
                                    Button {
                                        if state.isDownloading(video) {
                                            state.cancelDownload(video)
                                        } else {
                                            state.startParallelDownload(video, context: context)
                                        }
                                    } label: {
                                        Label(
                                            state.isDownloading(video) ? "Cancel Download" : "Download Now",
                                            systemImage: state.isDownloading(video) ? "xmark.circle.fill" : "arrow.down.circle.fill"
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(TrackerActionButtonStyle(kind: state.isDownloading(video) ? .secondary : .primary))
                                }

                                Button {
                                    state.markCompletedOutsideApp(video, context: context)
                                } label: {
                                    Label("Already Downloaded", systemImage: "checkmark.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
                                .disabled(state.isDownloading(video))
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(TrackerPalette.surface)
                        }
                    }
                }
            }
            .trackerListStyle()
            .navigationTitle("Choose a Video")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search videos or folders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(TrackerPalette.accent)
                }
            }
            .sheet(item: $previewVideo) { video in
                VideoPreviewView(video: video)
            }
        }
    }
}

private struct TodayVideoRow: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var auth: GoogleAuthService
    let video: VideoAsset
    let slot: Int
    @State private var showPreview = false

    private var isDownloading: Bool {
        state.isDownloading(video)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    VideoThumbnailView(
                        video: video,
                        width: 78,
                        height: 104,
                        cornerRadius: 10
                    )

                    Text("\(slot)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color(hex: "#090A0F"))
                        .frame(width: 18, height: 18)
                        .background(TrackerPalette.accent)
                        .clipShape(Circle())
                        .padding(5)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(video.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                        .lineLimit(2)

                    Label(
                        video.folderPath.isEmpty ? (video.account?.folderName ?? "Drive folder") : video.folderPath,
                        systemImage: "folder"
                    )
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
                    .lineLimit(1)

                    HStack(spacing: 8) {
                        StatusPill(status: video.status)

                        Button {
                            showPreview = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8))
                                Text("Preview")
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TrackerPalette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(TrackerPalette.accent.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(TrackerPressButtonStyle())
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                showPreview = true
            }

            if isDownloading {
                VStack(spacing: 6) {
                    if let progress = state.downloads.progressByIdentity[video.identityKey] {
                        let writtenMB = ByteCountFormatter.string(fromByteCount: progress.bytesWritten, countStyle: .file)
                        let totalMB = progress.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file) : "..."
                        Text("Downloading \(writtenMB) / \(totalMB) (\(Int(progress.fraction * 100))%)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(TrackerPalette.accent)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Text("Connecting background download…")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(TrackerPalette.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    if let progress = state.downloads.progressByIdentity[video.identityKey] {
                        ProgressView(value: progress.fraction)
                            .tint(TrackerPalette.accent)
                    } else {
                        ProgressView()
                            .tint(TrackerPalette.accent)
                    }
                }
                .padding(.vertical, 4)
            }

            actionRow
        }
        .padding(14)
        .sheet(isPresented: $showPreview) {
            VideoPreviewView(video: video)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch video.status {
        case .assigned:
            if auth.userID != video.googleUserID {
                Button {
                    Task {
                        await state.switchGoogleAccount(
                            hint: video.account?.googleEmail,
                            context: context
                        )
                    }
                } label: {
                    Label("Connect \(video.account?.googleEmail ?? "source account")", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            } else {
                ViewThatFits(in: .horizontal) {
                    assignedActions(axis: .horizontal)
                    assignedActions(axis: .vertical)
                }
            }

        case .downloaded:
            Label("Finalizing completion…", systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrackerPalette.accent)

        case .uploaded:
            HStack {
                Label(
                    video.uploadedAt?.formatted(date: .omitted, time: .shortened) ?? "Completed",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(TrackerPalette.success)
                Spacer()
            }

        case .available:
            EmptyView()
        }
    }

    private func assignedActions(axis: Axis) -> some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 8) { assignedActionButtons }
            } else {
                VStack(spacing: 8) { assignedActionButtons }
            }
        }
    }

    @ViewBuilder
    private var assignedActionButtons: some View {
        if isDownloading {
            Button {
                state.cancelDownload(video)
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
        } else {
            Button {
                state.startParallelDownload(video, context: context)
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .primary))
            .disabled(video.isMissingFromDrive || !video.canDownload)
        }

        Button {
            state.markCompletedOutsideApp(video, context: context)
        } label: {
            Label("Completed", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
        .disabled(isDownloading)

        if let assignment = video.activeAssignment {
            Button("Replace") {
                state.replace(assignment, context: context)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            .disabled(isDownloading)
        }
    }
}
