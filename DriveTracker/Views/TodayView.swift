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
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    commandHeader
                    scheduleCard
                    GlobalCopyQueueCard()

                    HStack {
                        TrackerSectionLabel(
                            title: "Choose an account",
                            trailing: "\(activeAccounts.count) active"
                        )
                    }
                    .padding(.top, 4)

                    ForEach(activeAccounts) { account in
                        NavigationLink {
                            TodayAccountDetailView(account: account)
                        } label: {
                            TodayAccountRow(account: account)
                        }
                        .buttonStyle(TrackerPressButtonStyle())
                    }

                    if activeAccounts.isEmpty {
                        ContentUnavailableView(
                            "No active accounts",
                            systemImage: "pause.rectangle",
                            description: Text("Resume an account from the Accounts tab.")
                        )
                        .foregroundStyle(TrackerPalette.muted)
                        .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .trackerScreen()
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.sync(context: context, announce: false) }
                    } label: {
                        if state.isWorking {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(state.isWorking || !state.hasRootFolder)
                    .accessibilityLabel("Sync Google Drive")
                }
            }
            .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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

    private var commandHeader: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        formattedDate(timeline.date)
                    )
                    .font(.subheadline.weight(.semibold))

                    Text(selectedUSZone.title)
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                }
                Spacer()
                Text(
                    formattedTime(timeline.date)
                )
                .font(.title3.monospacedDigit().weight(.semibold))
            }
            .trackerCard(padding: 14)
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

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Suggested US schedule", systemImage: "clock.badge.checkmark")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(selectedUSZone.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrackerPalette.accent)
            }
            HStack(spacing: 8) {
                ForEach(NewYorkSchedule.slots) { slot in
                    VStack(spacing: 3) {
                        Text("Video \(slot.number)")
                            .font(.caption)
                            .foregroundStyle(TrackerPalette.muted)
                        Text(slot.label(in: selectedUSZone.timeZone))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(TrackerPalette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .trackerCard()
    }
}

private struct TodayAccountRow: View {
    let account: TikTokAccount

    var body: some View {
        HStack(spacing: 13) {
            AccountIdentityIcon(
                symbol: account.iconSymbol,
                colorHex: account.iconColorHex,
                size: 44
            )
            Text(account.displayName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard(padding: 13)
        .contentShape(Rectangle())
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
            HStack(spacing: 12) {
                AccountIdentityIcon(
                    symbol: account.iconSymbol,
                    colorHex: account.iconColorHex,
                    size: 46
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.headline.weight(.semibold))
                    Text("\(account.availableCount) unused  /  \(account.uploadedCount) completed")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(TrackerPalette.muted)
                }
                Spacer()
                Text("\(completed)/\(account.dailyQuota)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(completed == account.dailyQuota ? TrackerPalette.success : .primary)
            }
            .padding(15)

            HStack(spacing: 10) {
                Button {
                    Task { await state.downloadAllAssigned(for: account, context: context) }
                } label: {
                    Label("Download all", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))

                Button {
                    showManualPicker = true
                } label: {
                    Label("Choose video", systemImage: "hand.tap.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 13)

            if shortage > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(shortage) unused video\(shortage == 1 ? "" : "s") short")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(TrackerPalette.warning)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(TrackerPalette.warning.opacity(0.07))
            }

            Divider().overlay(TrackerPalette.line)

            ForEach(Array(todaysVideos.enumerated()), id: \.element.id) { index, video in
                TodayVideoRow(video: video, slot: index + 1)
                if index < todaysVideos.count - 1 {
                    Divider()
                        .overlay(TrackerPalette.line)
                        .padding(.leading, 54)
                }
            }
        }
        .background(TrackerPalette.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    HStack(spacing: 13) {
                        AccountIdentityIcon(
                            symbol: account.iconSymbol,
                            colorHex: account.iconColorHex,
                            size: 48
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.displayName)
                                .font(.headline.weight(.bold))
                            Text("Choose any unused video and download it immediately. Your daily suggestions stay unchanged.")
                                .font(.caption)
                                .foregroundStyle(TrackerPalette.muted)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Unused videos · \(availableVideos.count)") {
                    if availableVideos.isEmpty {
                        ContentUnavailableView(
                            "No unused videos",
                            systemImage: "video.slash",
                            description: Text("Sync the folder or change your search.")
                        )
                    } else {
                        ForEach(availableVideos) { video in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 12) {
                                    VideoThumbnailView(
                                        video: video,
                                        width: 106,
                                        height: 142
                                    )

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(video.name)
                                            .font(.subheadline.weight(.semibold))
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
                                    Label("Already Downloaded — Mark Completed", systemImage: "checkmark.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
                            }
                            .padding(.vertical, 6)
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
                    Button("Cancel") { dismiss() }
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
                VideoThumbnailView(video: video)
                    .overlay(alignment: .topLeading) {
                        Text(String(format: "%02d", slot))
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.68))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .padding(5)
                    }

                VStack(alignment: .leading, spacing: 7) {
                    Text(video.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if !video.folderPath.isEmpty {
                        Label(video.folderPath, systemImage: "folder")
                            .font(.caption2)
                            .foregroundStyle(TrackerPalette.muted)
                            .lineLimit(2)
                    }
                    if (video.status == .assigned || video.status == .downloaded),
                       let assignment = video.activeAssignment {
                        let zone = USReminderTimeZone(rawValue: state.reminderTimeZoneID) ?? .eastern
                        Text(
                            "Suggested window • \(NewYorkSchedule.slot(for: assignment.slot).label(in: zone.timeZone)) \(zone.shortTitle)"
                        )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TrackerPalette.accent)
                    }
                    HStack(spacing: 6) {
                        StatusPill(status: video.status)
                        if video.isMissingFromDrive {
                            Text("Missing")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(TrackerPalette.danger)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !video.isMissingFromDrive else { return }
                showPreview = true
            }

            if isDownloading {
                VStack(spacing: 6) {
                    if let progress = state.downloads.progressByIdentity[video.identityKey] {
                        let writtenMB = ByteCountFormatter.string(fromByteCount: progress.bytesWritten, countStyle: .file)
                        let totalMB = progress.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file) : "..."
                        Text("Downloading \(writtenMB) / \(totalMB) (\(Int(progress.fraction * 100))%)")
                            .font(.caption.monospacedDigit().weight(.semibold))
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
        .padding(15)
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
                    systemImage: "checkmark"
                )
                .font(.caption.monospacedDigit().weight(.semibold))
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
                HStack(spacing: 9) { assignedActionButtons }
            } else {
                VStack(spacing: 9) { assignedActionButtons }
            }
        }
    }

    @ViewBuilder
    private var assignedActionButtons: some View {
        if isDownloading {
            Button {
                state.cancelDownload(video)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
        } else {
            Button {
                state.startParallelDownload(video, context: context)
            } label: {
                Label("Download", systemImage: "arrow.down")
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
