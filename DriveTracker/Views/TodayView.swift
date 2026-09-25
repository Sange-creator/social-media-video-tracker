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

    var body: some View {
        let visibleAccounts = activeAccounts
        let totalQuota = visibleAccounts.reduce(0) { $0 + $1.dailyQuota }
        let totalCompleted = visibleAccounts.reduce(0) { sum, account in
            sum + account.videos.filter { video in
                guard let uploadedAt = video.uploadedAt else { return false }
                return DayKey.isToday(uploadedAt)
            }.count
        }

        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    customTopHeader
                    todayDashboardHeader(completed: totalCompleted, quota: totalQuota)
                    GlobalCopyQueueCard()

                    HStack {
                        TrackerSectionLabel(
                            title: "Tracked Accounts",
                            trailing: "\(visibleAccounts.count) active"
                        )
                    }
                    .padding(.top, 6)

                    ForEach(visibleAccounts) { account in
                        TodayAccountRow(account: account)
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
            }
            .trackerScreen()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await state.sync(context: context, announce: false)
            }
        }
        .task {
            let todayCandidates = Array(activeAccounts.flatMap { $0.videos.filter { $0.status == .assigned || $0.status == .available } }.prefix(8))
            ThumbnailService.shared.prefetchThumbnails(
                for: todayCandidates,
                api: state.api,
                currentUserID: state.auth.userID
            )
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
                    Text(syncStatusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TrackerPalette.muted)
                }
            }

            Spacer()

            Button {
                Task {
                    await state.sync(context: context, announce: false)
                }
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
            .disabled(state.isWorking || activeAccounts.isEmpty)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var syncStatusText: String {
        if state.isWorking { return "Checking Drive…" }
        if let lastSyncAt = state.lastSyncAt {
            return "Updated \(lastSyncAt.formatted(.relative(presentation: .named)))"
        }
        return "Ready to sync"
    }

    private func todayDashboardHeader(completed: Int, quota: Int) -> some View {
        VStack(spacing: 14) {
            // Live Status Bar
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(formattedDate(.now))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(TrackerPalette.textPrimary)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(TrackerPalette.success)
                            .frame(width: 6, height: 6)
                        Text(selectedUSZone.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(TrackerPalette.muted)
                    }
                }

                Spacer()

                TodayLiveClockView(timeZone: selectedUSZone.timeZone)
            }

            Divider().overlay(TrackerPalette.line)

            // Bento Quota Hub & Progress
            HStack(spacing: 14) {
                RadialQuotaProgress(
                    completed: completed,
                    quota: max(quota, 1),
                    size: 62,
                    lineWidth: 6
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(completed) of \(quota) Completed")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TrackerPalette.textPrimary)

                    let remaining = max(0, quota - completed)
                    Text(remaining == 0 ? "Daily goal achieved!" : "\(remaining) video\(remaining == 1 ? "" : "s") left for today")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(remaining == 0 ? TrackerPalette.success : TrackerPalette.muted)

                    Button {
                        try? state.ensureToday(context: context)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shuffle")
                            Text("Shuffle Suggestions")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TrackerPalette.accent)
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                    .padding(.top, 2)
                }

                Spacer()
            }

            Divider().overlay(TrackerPalette.line)

            // Suggested US Posting Slots
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Suggested US Posting Windows", systemImage: "sparkles")
                        .font(.caption2.weight(.bold))
                        .tracking(0.4)
                        .foregroundStyle(TrackerPalette.muted)
                    Spacer()
                }

                HStack(spacing: 8) {
                    ForEach(NewYorkSchedule.slots) { slot in
                        let isActive = slot.number == activeSlotNumber
                        VStack(spacing: 3) {
                            HStack(spacing: 3) {
                                if isActive {
                                    Circle()
                                        .fill(TrackerPalette.accent)
                                        .frame(width: 4, height: 4)
                                }
                                Text("Slot \(slot.number)")
                                    .font(.system(size: 10, weight: isActive ? .bold : .medium))
                                    .foregroundStyle(isActive ? TrackerPalette.accent : TrackerPalette.muted)
                            }
                            Text(slot.label(in: selectedUSZone.timeZone))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(isActive ? TrackerPalette.accent : TrackerPalette.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(isActive ? TrackerPalette.accent.opacity(0.14) : TrackerPalette.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isActive ? TrackerPalette.accent.opacity(0.7) : TrackerPalette.line, lineWidth: isActive ? 1.2 : 0.5)
                        }
                    }
                }
            }
        }
        .trackerCard(padding: 14)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.timeZone = selectedUSZone.timeZone
        return Self.dateFormatter.string(from: date)
    }

    private var activeSlotNumber: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = NewYorkSchedule.timeZone
        let hour = cal.component(.hour, from: .now)
        if hour < 12 { return 1 }
        else if hour < 17 { return 2 }
        else { return 3 }
    }
}

private struct TodayLiveClockView: View {
    let timeZone: TimeZone

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            HStack(spacing: 5) {
                Image(systemName: "clock.fill")
                    .font(.caption2)
                    .foregroundStyle(TrackerPalette.accent)
                Text(timeline.date.formatted(Date.FormatStyle(timeZone: timeZone).hour().minute()))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(TrackerPalette.accent)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(TrackerPalette.accent.opacity(0.12), in: Capsule())
        }
    }
}

private struct TodayAccountRow: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount
    @State private var selectedMedia: MediaTypeFilter = .videos

    var body: some View {
        // High-performance single-pass traversal of account videos in local memory
        let allVideos = account.videos
        let currentVideos: [VideoAsset] = allVideos.filter { video in
            guard video.isVideo else { return false }
            if video.status == .assigned || video.status == .downloaded { return true }
            guard let uploadedAt = video.uploadedAt else { return false }
            return DayKey.isToday(uploadedAt)
        }
        .sorted {
            let lhsSlot = $0.activeAssignment?.slot ?? Int.max
            let rhsSlot = $1.activeAssignment?.slot ?? Int.max
            if lhsSlot != rhsSlot { return lhsSlot < rhsSlot }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        let completed = currentVideos.filter { $0.status == .uploaded }.count
        let hasPendingDownloads = currentVideos.contains { $0.status == .assigned || $0.status == .available }
        let hasPhotos = allVideos.contains { $0.isPhoto && !$0.isMissingFromDrive }
        let availablePhotos: [VideoAsset] = hasPhotos ? allVideos.filter { $0.isPhoto && $0.status == .available && !$0.isMissingFromDrive && $0.canDownload }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : []
        let downloadedPhotos: [VideoAsset] = hasPhotos ? allVideos.filter { $0.isPhoto && ($0.status == .downloaded || $0.status == .uploaded) && !$0.isMissingFromDrive }.sorted { ($0.uploadedAt ?? $0.downloadedAt ?? .distantPast) > ($1.uploadedAt ?? $1.downloadedAt ?? .distantPast) } : []

        VStack(alignment: .leading, spacing: 14) {
            // Account Header: Full account name (zero ellipsis/dot-dot-dot), Quota progress, and Chevron
            HStack(alignment: .center, spacing: 12) {
                NavigationLink {
                    TodayAccountDetailView(account: account)
                } label: {
                    HStack(spacing: 12) {
                        AccountIdentityIcon(
                            symbol: account.iconSymbol,
                            colorHex: account.iconColorHex,
                            size: 44
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(TrackerPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)

                            HStack(spacing: 6) {
                                Text(account.folderName)
                                    .font(.caption)
                                    .foregroundStyle(TrackerPalette.muted)
                                    .lineLimit(1)

                                if hasPhotos {
                                    Text("•").font(.caption2).foregroundStyle(TrackerPalette.muted)
                                    Text("\(availablePhotos.count) photos")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(TrackerPalette.accent)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(TrackerPressButtonStyle())

                Spacer(minLength: 8)

                // Quota Progress Badge
                HStack(spacing: 4) {
                    Text("\(completed)/\(account.dailyQuota)")
                        .font(.system(.subheadline, design: .rounded).monospacedDigit().weight(.bold))
                        .foregroundStyle(completed >= account.dailyQuota ? TrackerPalette.success : TrackerPalette.accent)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    (completed >= account.dailyQuota ? TrackerPalette.success : TrackerPalette.accent).opacity(0.12),
                    in: Capsule()
                )

                NavigationLink {
                    TodayAccountDetailView(account: account)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TrackerPalette.muted)
                }
                .buttonStyle(TrackerPressButtonStyle())
            }

            // Media filter if account supports photos
            if hasPhotos {
                Picker("Media Format", selection: $selectedMedia) {
                    Text("Videos (\(currentVideos.count))").tag(MediaTypeFilter.videos)
                    Text("Photos (\(availablePhotos.count))").tag(MediaTypeFilter.photos)
                }
                .pickerStyle(.segmented)
            }

            if hasPhotos && selectedMedia == .photos {
                // Photos View: Clean adaptive grid, no cutoffs!
                if availablePhotos.isEmpty && downloadedPhotos.isEmpty {
                    Text("No photos available in this folder.")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if !availablePhotos.isEmpty {
                            HStack {
                                Text("PHOTOS TO DOWNLOAD (\(availablePhotos.count))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(TrackerPalette.accent)
                                Spacer()
                                Button {
                                    state.downloadAllPhotos(for: account, context: context)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text("Download All Photos")
                                    }
                                    .font(.caption2.weight(.bold))
                                }
                                .buttonStyle(TrackerActionButtonStyle(kind: .primary, compact: true))
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                ForEach(availablePhotos) { photo in
                                    TodayPhotoGridItem(video: photo, downloads: state.downloads)
                                }
                            }
                        }

                        if !downloadedPhotos.isEmpty {
                            Text("DOWNLOADED PHOTOS (\(downloadedPhotos.count))")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(TrackerPalette.success)
                                .padding(.top, 4)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                ForEach(downloadedPhotos) { photo in
                                    TodayPhotoGridItem(video: photo, downloads: state.downloads)
                                }
                            }
                        }
                    }
                }
            } else {
                // The Daily Videos: consistent 3-column card dimensions regardless of video count
                let firstThree = Array(currentVideos.prefix(3))
                if !firstThree.isEmpty {
                    GeometryReader { proxy in
                        let spacing: CGFloat = 8
                        let itemWidth = max(0, (proxy.size.width - (spacing * 2)) / 3)

                        HStack(spacing: spacing) {
                            ForEach(Array(firstThree.enumerated()), id: \.element.id) { index, video in
                                TodayVideoPosterCard(video: video, slot: index + 1)
                                    .frame(width: itemWidth > 0 ? itemWidth : nil)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 148)
                }
            }

            // Dedicated, Centered "Download All Videos" button when downloads are pending
            if hasPendingDownloads && (selectedMedia == .videos || !hasPhotos) {
                Button {
                    state.downloadAllAssigned(for: account, context: context)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download All Videos")
                    }
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))
                .padding(.top, 2)
            }
        }
        .trackerCard(padding: 14)
    }
}

private struct TodayVideoPosterCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    var slot: Int? = nil
    @State private var showPreview = false

    private var isDownloading: Bool {
        state.isDownloading(video)
    }

    private var isSaving: Bool {
        state.isSavingToPhotos(video)
    }

    private var progressPercent: Int? {
        guard let progress = state.downloads.progressByIdentity[video.identityKey], progress.totalBytes > 0 else {
            return nil
        }
        return Int((progress.fraction * 100).rounded())
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background Thumbnail with tap-to-preview
            Button {
                showPreview = true
            } label: {
                ZStack {
                    VideoThumbnailView(
                        video: video,
                        width: nil,
                        height: 148,
                        cornerRadius: 12
                    )
                    .frame(maxWidth: .infinity)

                    // Subtle play pill in center
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 26, height: 26)
                    Image(systemName: video.isPhoto ? "photo" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            // Top Status Badge & Optional Slot Number
            VStack {
                HStack(spacing: 4) {
                    if let slot {
                        Text("\(slot)")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(Color(hex: "#090A0F"))
                            .frame(width: 15, height: 15)
                            .background(TrackerPalette.accent, in: Circle())
                    }
                    StatusPill(status: video.status)

                    Spacer()
                }
                Spacer()
            }
            .padding(6)

            // Bottom Content Scrim with 1-Tap Action Button
            VStack(alignment: .leading, spacing: 4) {
                Text(video.name)
                    .font(.system(size: 10.5, weight: .bold))
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
                        HStack(spacing: 3) {
                            if isSaving {
                                ProgressView()
                                    .tint(Color(hex: "#090A0F"))
                                    .scaleEffect(0.6)
                                Text("Saving")
                                    .font(.system(size: 9.5, weight: .black))
                            } else if isDownloading {
                                ProgressView()
                                    .tint(Color(hex: "#090A0F"))
                                    .scaleEffect(0.6)
                                Text(progressPercent.map { "\($0)%" } ?? "...")
                                    .font(.system(size: 9.5, weight: .black))
                            } else {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 9, weight: .black))
                                Text("Get")
                                    .font(.system(size: 10, weight: .black))
                            }
                        }
                        .foregroundStyle(Color(hex: "#090A0F"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(TrackerPalette.accent, in: Capsule())
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                    .disabled(isSaving)
                } else if video.status == .downloaded {
                    HStack(spacing: 4) {
                        if !video.uploadText.isEmpty {
                            Button {
                                state.copyUploadText(for: video)
                            } label: {
                                Image(systemName: "doc.on.clipboard.fill")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Color(hex: "#090A0F"))
                                    .frame(width: 24, height: 24)
                                    .background(TrackerPalette.accent, in: Circle())
                            }
                            .buttonStyle(TrackerPressButtonStyle())
                        }

                        Button {
                            state.markCompletedOutsideApp(video, context: context)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Post")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(TrackerPalette.success, in: Capsule())
                        }
                        .buttonStyle(TrackerPressButtonStyle())
                    }
                } else if video.status == .uploaded {
                    HStack(spacing: 4) {
                        if !video.uploadText.isEmpty {
                            Button {
                                state.copyUploadText(for: video)
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(TrackerPalette.muted)
                                    .frame(width: 24, height: 24)
                                    .background(TrackerPalette.raised, in: Circle())
                            }
                            .buttonStyle(TrackerPressButtonStyle())
                        }

                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                            Text("Done")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(TrackerPalette.success)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(TrackerPalette.success.opacity(0.18), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .padding(.top, 18)
            .background(
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.65), Color.black.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 0.5)
        }
        .sheet(isPresented: $showPreview) {
            VideoPreviewView(video: video)
        }
    }
}


private struct TodayPhotoGridItem: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    @ObservedObject var downloads: DownloadCoordinator
    @State private var showPreview = false

    private var isDownloading: Bool {
        state.isDownloading(video)
    }

    private var isSaving: Bool {
        state.isSavingToPhotos(video)
    }

    private var progressPercent: Int? {
        guard let progress = downloads.progressByIdentity[video.identityKey], progress.totalBytes > 0 else {
            return nil
        }
        return Int((progress.fraction * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showPreview = true } label: {
                ZStack(alignment: .topTrailing) {
                    VideoThumbnailView(video: video, width: nil, height: 100, cornerRadius: 10)
                        .frame(maxWidth: .infinity)

                    Image(systemName: "photo.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.5), in: Circle())
                        .padding(5)
                }
            }
            .buttonStyle(.plain)

            Text(video.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TrackerPalette.textPrimary)
                .lineLimit(1)

            if video.status == .assigned || video.status == .available {
                Button {
                    isDownloading ? state.cancelDownload(video) : state.startParallelDownload(video, context: context)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isDownloading ? "xmark.circle.fill" : "arrow.down.circle.fill")
                        Text(isSaving ? "Saving…" : (isDownloading ? (progressPercent.map { "\($0)%" } ?? "...") : "Download"))
                    }
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: isDownloading ? .secondary : .primary, compact: true))
                .disabled(isSaving)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Downloaded")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TrackerPalette.success)
                .frame(maxWidth: .infinity, minHeight: 30)
            }
        }
        .padding(8)
        .background(TrackerPalette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 0.5)
        }
        .sheet(isPresented: $showPreview) {
            VideoPreviewView(video: video)
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
            guard video.isVideo else { return false }
            if video.status == .assigned || video.status == .downloaded { return true }
            guard let uploadedAt = video.uploadedAt else { return false }
            return DayKey.isToday(uploadedAt)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text("\(account.availableVideosList.count) unused videos  •  \(account.uploadedCount) completed" + (account.hasPhotos ? "  •  \(account.availablePhotos.count) photos" : ""))
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
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download All Videos")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))

                Button {
                    showManualPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.tap.fill")
                        Text(account.hasPhotos ? "Choose Media" : "Choose Video")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
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

            if account.hasPhotos {
                VStack(alignment: .leading, spacing: 14) {
                    Divider().overlay(TrackerPalette.line)

                    HStack(alignment: .center) {
                        Label("Photos", systemImage: "photo.stack.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(TrackerPalette.textPrimary)

                        Spacer()

                        Text("\(account.availablePhotos.count) unused • \(account.downloadedPhotos.count) downloaded")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(TrackerPalette.muted)
                    }

                    if !account.availablePhotos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("PHOTOS TO DOWNLOAD (\(account.availablePhotos.count))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(TrackerPalette.accent)

                                Spacer()

                                Button {
                                    state.downloadAllPhotos(for: account, context: context)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text("Download All")
                                    }
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(TrackerPalette.accent)
                                }
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                ForEach(account.availablePhotos) { photo in
                                    TodayPhotoGridItem(video: photo, downloads: state.downloads)
                                }
                            }
                        }
                    }

                    if !account.downloadedPhotos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DOWNLOADED PHOTOS (\(account.downloadedPhotos.count))")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(TrackerPalette.success)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                                ForEach(account.downloadedPhotos) { photo in
                                    TodayPhotoGridItem(video: photo, downloads: state.downloads)
                                }
                            }
                        }
                    }
                }
                .padding(16)
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
    @State private var mediaFilter: MediaTypeFilter = .videos

    private var availableItems: [VideoAsset] {
        let baseList: [VideoAsset]
        if account.hasPhotos && mediaFilter == .photos {
            baseList = account.availablePhotos
        } else {
            baseList = account.availableVideosList
        }
        return baseList
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
                            Text(account.hasPhotos
                                ? "Download any unused video or photo immediately without changing your daily schedule."
                                : "Download any unused video immediately without changing your daily schedule.")
                                .font(.caption)
                                .foregroundStyle(TrackerPalette.muted)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(TrackerPalette.surface)
                }

                if account.hasPhotos {
                    Section {
                        Picker("Media Format", selection: $mediaFilter) {
                            Text("Videos (\(account.availableVideosList.count))").tag(MediaTypeFilter.videos)
                            Text("Photos (\(account.availablePhotos.count))").tag(MediaTypeFilter.photos)
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.clear)
                }

                let isPhotoSection = account.hasPhotos && mediaFilter == .photos
                let sectionTitle = isPhotoSection
                    ? "Unused Photos (\(availableItems.count))"
                    : "Unused Videos (\(availableItems.count))"

                Section(sectionTitle) {
                    if availableItems.isEmpty {
                        ContentUnavailableView(
                            isPhotoSection ? "No unused photos" : "No unused videos",
                            systemImage: isPhotoSection ? "photo.on.rectangle.angled" : "video.slash",
                            description: Text("Sync the folder or change your search.")
                        )
                        .listRowBackground(TrackerPalette.surface)
                    } else {
                        ForEach(availableItems) { video in
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

                                if state.isSavingToPhotos(video) {
                                    VStack(spacing: 6) {
                                        HStack {
                                            Text("Saving to Photos…")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(TrackerPalette.accent)
                                            Spacer()
                                        }
                                        ProgressView()
                                            .tint(TrackerPalette.accent)
                                    }
                                    .padding(.vertical, 2)
                                } else if state.isDownloading(video) {
                                    let progress = state.downloads.progressByIdentity[video.identityKey]
                                    let fraction = progress?.fraction ?? 0
                                    let percent = Int(fraction * 100)

                                    VStack(spacing: 6) {
                                        HStack {
                                            Text(fraction > 0 ? "Downloading \(percent)%" : "Downloading from Drive…")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(TrackerPalette.accent)
                                            Spacer()
                                            if let bytes = progress?.bytesWritten, let total = progress?.totalBytes, total > 0 {
                                                Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(TrackerPalette.muted)
                                            }
                                        }

                                        ProgressView(value: fraction > 0 ? fraction : nil)
                                            .tint(TrackerPalette.accent)
                                    }
                                    .padding(.vertical, 2)
                                }

                                HStack(spacing: 10) {
                                    Button {
                                        if state.isSavingToPhotos(video) {
                                            // saving in progress
                                        } else if state.isDownloading(video) {
                                            state.cancelDownload(video)
                                        } else {
                                            state.startParallelDownload(video, context: context)
                                        }
                                    } label: {
                                        Label(
                                            state.isSavingToPhotos(video) ? "Saving to Photos…" : (state.isDownloading(video) ? "Cancel Download" : "Download Now"),
                                            systemImage: state.isSavingToPhotos(video) ? "arrow.down.circle" : (state.isDownloading(video) ? "xmark.circle.fill" : "arrow.down.circle.fill")
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(TrackerActionButtonStyle(kind: state.isDownloading(video) ? .secondary : .primary))
                                    .disabled(state.isSavingToPhotos(video))
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
            .navigationTitle(account.hasPhotos ? (mediaFilter == .photos ? "Choose a Photo" : "Choose a Video") : "Choose a Video")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: account.hasPhotos && mediaFilter == .photos ? "Search photos or folders" : "Search videos or folders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(TrackerPalette.accent)
                }
            }
            .overlay(alignment: .bottom) {
                Group {
                    if let error = state.errorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(TrackerPalette.warning)
                            Text(error)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(TrackerPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(TrackerPalette.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(TrackerPalette.warning.opacity(0.40), lineWidth: 0.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: Color.black.opacity(0.40), radius: 16, y: 6)
                    } else if let message = state.toastMessage {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(TrackerPalette.success)
                            Text(message)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(TrackerPalette.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(TrackerPalette.surface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(TrackerPalette.success.opacity(0.35), lineWidth: 0.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: Color.black.opacity(0.40), radius: 16, y: 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.errorMessage)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.toastMessage)
                .allowsHitTesting(false)
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

    private var selectedUSZone: USReminderTimeZone {
        USReminderTimeZone(rawValue: state.reminderTimeZoneID) ?? .eastern
    }

    private var activeSlotNumber: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = NewYorkSchedule.timeZone
        let hour = cal.component(.hour, from: .now)
        if hour < 12 { return 1 }
        else if hour < 17 { return 2 }
        else { return 3 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Slot Badge & Status Header
            HStack(alignment: .center, spacing: 6) {
                HStack(spacing: 5) {
                    Text("\(slot)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(Color(hex: "#090A0F"))
                        .frame(width: 18, height: 18)
                        .background(TrackerPalette.accent, in: Circle())

                    Text("SLOT \(slot)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                }

                if slot <= NewYorkSchedule.slots.count {
                    let slotDef = NewYorkSchedule.slots[slot - 1]
                    let isCurrent = slotDef.number == activeSlotNumber
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(TrackerPalette.muted)
                    Text(slotDef.label(in: selectedUSZone.timeZone))
                        .font(.system(size: 10.5, weight: isCurrent ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(isCurrent ? TrackerPalette.accent : TrackerPalette.muted)
                }

                Spacer()

                StatusPill(status: video.status)
            }

            // Thumbnail & Title Row
            HStack(alignment: .center, spacing: 12) {
                Button {
                    showPreview = true
                } label: {
                    ZStack {
                        VideoThumbnailView(
                            video: video,
                            width: 72,
                            height: 72,
                            cornerRadius: 10
                        )

                        Circle()
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 26, height: 26)
                        Image(systemName: video.isPhoto ? "photo" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(video.name)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(video.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                        .lineLimit(2)

                    Label(
                        video.folderPath.isEmpty ? (video.account?.folderName ?? "Drive folder") : video.folderPath,
                        systemImage: "folder"
                    )
                    .font(.caption2)
                    .foregroundStyle(TrackerPalette.muted)
                    .lineLimit(1)
                }

                Spacer()
            }

            // Progress Indicators
            if state.isSavingToPhotos(video) {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(TrackerPalette.accent)
                        .scaleEffect(0.8)
                    Text("Saving to Photos…")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TrackerPalette.accent)
                    Spacer()
                }
                .padding(.vertical, 2)
            } else if isDownloading {
                VStack(spacing: 4) {
                    let progress = state.downloads.progressByIdentity[video.identityKey]
                    HStack {
                        if let progress, progress.totalBytes > 0 {
                            let writtenMB = ByteCountFormatter.string(fromByteCount: progress.bytesWritten, countStyle: .file)
                            let totalMB = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                            Text("Downloading \(writtenMB) / \(totalMB) (\(Int(progress.fraction * 100))%)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(TrackerPalette.accent)
                        } else {
                            Text("Downloading from Drive…")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(TrackerPalette.accent)
                        }
                        Spacer()
                        Button("Cancel") {
                            state.cancelDownload(video)
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TrackerPalette.danger)
                    }

                    if let progress {
                        ProgressView(value: progress.fraction)
                            .tint(TrackerPalette.accent)
                    } else {
                        ProgressView()
                            .tint(TrackerPalette.accent)
                    }
                }
                .padding(.vertical, 2)
            }

            // Action Buttons Row
            actionRow
        }
        .padding(12)
        .background(TrackerPalette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 0.5)
        }
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
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary, compact: true))
            } else {
                HStack(spacing: 8) {
                    if !isDownloading && !state.isSavingToPhotos(video) {
                        Button {
                            state.startParallelDownload(video, context: context)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TrackerActionButtonStyle(kind: .primary, compact: true))
                        .disabled(video.isMissingFromDrive || !video.canDownload)

                        Button {
                            state.markCompletedOutsideApp(video, context: context)
                        } label: {
                            Label("Completed", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TrackerActionButtonStyle(kind: .secondary, compact: true))

                        if let assignment = video.activeAssignment {
                            Button {
                                state.replace(assignment, context: context)
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption.weight(.bold))
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(TrackerActionButtonStyle(kind: .secondary, compact: true))
                        }
                    }
                }
            }

        case .downloaded:
            HStack(spacing: 8) {
                Button {
                    state.markCompletedOutsideApp(video, context: context)
                } label: {
                    Label("Mark Completed", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary, compact: true))

                if let assignment = video.activeAssignment {
                    Button {
                        state.replace(assignment, context: context)
                    } label: {
                        Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(TrackerActionButtonStyle(kind: .secondary, compact: true))
                }
            }

        case .uploaded:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.success)
                Text(video.uploadedAt != nil ? "Completed at \(video.uploadedAt!.formatted(date: .omitted, time: .shortened))" : "Completed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrackerPalette.success)
                Spacer()

                Button {
                    state.startParallelDownload(video, context: context)
                } label: {
                    Label("Re-download", systemImage: "arrow.down.circle")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .quiet, compact: true))
            }
            .padding(.vertical, 2)

        case .available:
            HStack(spacing: 8) {
                Button {
                    state.startParallelDownload(video, context: context)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary, compact: true))
            }
        }
    }
}
