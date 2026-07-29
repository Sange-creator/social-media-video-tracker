import AVKit
import SwiftData
import SwiftUI

struct LibraryView: View {
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]
    @State private var search = ""

    private var filteredAccounts: [TikTokAccount] {
        guard !search.isEmpty else { return accounts }
        return accounts.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) ||
            $0.folderName.localizedCaseInsensitiveContains(search) ||
            ($0.googleEmail?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    TrackerSectionLabel(
                        title: "Tracked accounts",
                        trailing: "\(filteredAccounts.count) accounts"
                    )

                    if filteredAccounts.isEmpty {
                        ContentUnavailableView(
                            accounts.isEmpty ? "No accounts configured" : "No matching accounts",
                            systemImage: "person.2.slash",
                            description: Text(
                                accounts.isEmpty
                                    ? "Add a Drive folder and associate it with an account in Settings."
                                    : "Change the account search."
                            )
                        )
                        .foregroundStyle(TrackerPalette.muted)
                        .padding(.top, 44)
                    } else {
                        ForEach(filteredAccounts) { account in
                            NavigationLink {
                                AccountLibraryView(account: account)
                            } label: {
                                LibraryAccountRow(account: account)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            }
            .trackerScreen()
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Search accounts")
            .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private struct LibraryAccountRow: View {
    let account: TikTokAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                AccountIdentityIcon(
                    symbol: account.iconSymbol,
                    colorHex: account.iconColorHex,
                    size: 50
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                    Label(account.folderName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                        .lineLimit(1)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(TrackerPalette.muted)
            }

            Divider().overlay(TrackerPalette.line)

            HStack {
                TrackerMetric(value: "\(account.videos.count)", label: "Videos")
                Spacer()
                TrackerMetric(value: "\(account.availableCount)", label: "Unused")
                Spacer()
                TrackerMetric(
                    value: "\(account.uploadedCount)",
                    label: "Completed",
                    tint: TrackerPalette.success
                )
            }
        }
        .trackerCard()
    }
}

private struct AccountLibraryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount
    @State private var search = ""
    @State private var selectedStatus: VideoStatus?
    @State private var missingOnly = false
    @State private var previewVideo: VideoAsset?

    private var filteredVideos: [VideoAsset] {
        account.videos
            .filter { video in
                let matchesSearch = search.isEmpty ||
                    video.name.localizedCaseInsensitiveContains(search) ||
                    video.folderPath.localizedCaseInsensitiveContains(search)
                let matchesStatus = selectedStatus == nil || video.status == selectedStatus
                let matchesMissing = !missingOnly || video.isMissingFromDrive
                return matchesSearch && matchesStatus && matchesMissing
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                filterBar
                    .padding(.bottom, 6)

                TrackerSectionLabel(
                    title: "Videos for \(account.displayName)",
                    trailing: "\(filteredVideos.count) files"
                )

                if filteredVideos.isEmpty {
                    ContentUnavailableView(
                        "No matching videos",
                        systemImage: "video.slash",
                        description: Text("Sync the folder or change the filters.")
                    )
                    .foregroundStyle(TrackerPalette.muted)
                    .padding(.top, 44)
                } else {
                    ForEach(filteredVideos) { video in
                        LibraryVideoCard(video: video) {
                            previewVideo = video
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 104)
        }
        .trackerScreen()
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search videos or folders")
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $previewVideo) { video in
            VideoPreviewView(video: video)
        }
        .refreshable {
            await state.sync(context: context, announce: false)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("All statuses") { selectedStatus = nil }
                    ForEach(VideoStatus.allCases) { status in
                        Button(status.title) { selectedStatus = status }
                    }
                } label: {
                    FilterChip(
                        title: selectedStatus?.title ?? "All statuses",
                        selected: selectedStatus != nil
                    )
                }

                Button {
                    missingOnly.toggle()
                } label: {
                    FilterChip(title: "Missing", selected: missingOnly)
                }
            }
        }
    }
}

private struct LibraryVideoCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    let preview: () -> Void

    private var isDownloading: Bool {
        state.downloadIdentity == video.identityKey
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: preview) {
                HStack(spacing: 12) {
                    VideoThumbnailView(
                        video: video,
                        width: 82,
                        height: 110
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Text(video.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        StatusPill(status: video.status)

                        if !video.folderPath.isEmpty {
                            Label(video.folderPath, systemImage: "folder")
                                .font(.caption2)
                                .foregroundStyle(TrackerPalette.muted)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 6)

                    VStack(spacing: 9) {
                        if video.isMissingFromDrive {
                            Image(systemName: "icloud.slash")
                                .foregroundStyle(TrackerPalette.danger)
                                .accessibilityLabel("Missing from Drive")
                        }
                        if video.isMissingFromPhotos {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(TrackerPalette.warning)
                                .accessibilityLabel("Deleted from Photos")
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(video.isMissingFromDrive || !video.canDownload)

            Divider().overlay(TrackerPalette.line)

            HStack(spacing: 0) {
                if video.status == .available || video.status == .assigned {
                    Button {
                        if isDownloading {
                            state.cancelDownload(video)
                        } else {
                            Task { await state.download(video, context: context) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isDownloading {
                                ProgressView()
                                    .tint(TrackerPalette.warning)
                            } else {
                                Image(systemName: "arrow.down.to.line")
                            }
                            Text(isDownloading ? "Cancel" : "Download")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            isDownloading
                                ? TrackerPalette.warning
                                : TrackerPalette.accent
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        (!isDownloading && state.downloadIdentity != nil) ||
                        video.isMissingFromDrive ||
                        !video.canDownload
                    )

                    Divider()
                        .overlay(TrackerPalette.line)
                        .frame(height: 24)
                }

                NavigationLink {
                    VideoDetailView(video: video)
                } label: {
                    Label("Details", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TrackerPalette.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(TrackerPalette.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(TrackerPalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct VideoDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    @State private var confirmReset = false
    @State private var showPreview = false

    private var sortedEvents: [StatusEvent] {
        video.events.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                videoCard
                historyCard
            }
            .padding(16)
            .padding(.bottom, 104)
        }
        .trackerScreen()
        .navigationTitle(video.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .confirmationDialog(
            "Reset downloaded status?",
            isPresented: $confirmReset
        ) {
            Button("Reset", role: .destructive) {
                state.resetDownload(video, context: context)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The video remains in Photos. This only changes tracker history.")
        }
        .sheet(isPresented: $showPreview) {
            VideoPreviewView(video: video)
        }
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            TrackerSectionLabel(title: "Video details")

            Button {
                showPreview = true
            } label: {
                VideoThumbnailView(
                    video: video,
                    width: 190,
                    height: 254
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(video.isMissingFromDrive || !video.canDownload)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .foregroundStyle(TrackerPalette.muted)
                Text("Preview streams the video from Drive and does not mark it completed.")
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(TrackerPalette.line)

            VStack(spacing: 12) {
                LabeledContent("Account", value: video.account?.displayName ?? "Unknown")
                LabeledContent(
                    "Folder",
                    value: video.folderPath.isEmpty
                        ? (video.account?.folderName ?? "Unknown")
                        : video.folderPath
                )
                LabeledContent("State") {
                    StatusPill(status: video.status)
                }
                LabeledContent("Drive file ID") {
                    Text(video.driveFileID)
                        .font(.caption.monospaced())
                        .foregroundStyle(TrackerPalette.muted)
                        .lineLimit(1)
                }
                if let downloadedAt = video.downloadedAt {
                    LabeledContent("Downloaded", value: downloadedAt.formatted())
                }
                if let uploadedAt = video.uploadedAt {
                    LabeledContent("Completed", value: uploadedAt.formatted())
                }
            }
            .font(.subheadline)

            if video.isMissingFromDrive {
                Label(
                    "Deleted or moved out of the tracked Drive folder",
                    systemImage: "icloud.slash"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrackerPalette.danger)
            }
            if video.isMissingFromPhotos {
                Label(
                    "Saved copy is no longer in Photos",
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrackerPalette.warning)
            }

            Divider().overlay(TrackerPalette.line)

            TrackerSectionLabel(title: "Actions")
            actionButtons

            if video.status == .available {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(TrackerPalette.warning)
                    Text("Adding this video to Today may replace an untouched suggestion when the account list is full. Completed videos are never suggested again.")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .trackerCard(padding: 16)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if video.status == .available || video.status == .assigned {
            if state.downloadIdentity == video.identityKey {
                Button {
                    state.cancelDownload(video)
                } label: {
                    Label("Cancel download", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            } else {
                Button {
                    Task { await state.download(video, context: context) }
                } label: {
                    Label("Download to Photos", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))
                .disabled(
                    state.downloadIdentity != nil ||
                    video.isMissingFromDrive ||
                    !video.canDownload
                )
            }
        }

        if video.status == .available {
            Button {
                state.selectManually(video, context: context)
            } label: {
                Label("Add to today’s queue", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            .disabled(video.isMissingFromDrive || !video.canDownload)
        }

        if video.status == .available || video.status == .assigned {
            Button {
                state.markCompletedOutsideApp(video, context: context)
            } label: {
                Label(
                    "Already downloaded — Mark completed",
                    systemImage: "checkmark.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
        }

        if video.status == .downloaded {
            Label("Completing automatically…", systemImage: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TrackerPalette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if video.status == .uploaded {
            Button {
                Task { await state.redownload(video, context: context) }
            } label: {
                Label("Download another copy", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .primary))

            Button {
                state.undoUpload(video, context: context)
            } label: {
                Label("Undo completed status", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
        }

        if video.downloadedAt != nil {
            Button {
                state.verifyPhotoCopy(video, context: context)
            } label: {
                Label("Verify saved Photos copy", systemImage: "photo.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Audit history",
                trailing: "\(sortedEvents.count) events"
            )

            if sortedEvents.isEmpty {
                Text("No status changes yet.")
                    .font(.subheadline)
                    .foregroundStyle(TrackerPalette.muted)
            } else {
                ForEach(Array(sortedEvents.enumerated()), id: \.element.id) {
                    index,
                    event in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(TrackerPalette.accent)
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.kind.title)
                                .font(.subheadline.weight(.semibold))
                            Text(event.timestamp.formatted())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(TrackerPalette.muted)
                            if let detail = event.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(TrackerPalette.muted)
                            }
                        }
                    }
                    if index < sortedEvents.count - 1 {
                        Divider()
                            .overlay(TrackerPalette.line)
                            .padding(.leading, 19)
                    }
                }
            }
        }
        .trackerCard(padding: 16)
    }
}

struct VideoPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    let video: VideoAsset

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if isLoading {
                    ProgressView("Loading preview from Google Drive…")
                        .tint(TrackerPalette.accent)
                        .frame(maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    .frame(maxHeight: .infinity)
                } else if let player {
                    VideoPlayer(player: player)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(video.name)
                        .font(.headline)
                        .lineLimit(2)
                    Label(
                        video.folderPath.isEmpty ? (video.account?.folderName ?? "Drive folder") : video.folderPath,
                        systemImage: "folder"
                    )
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .trackerScreen()
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadPreview() }
            .onDisappear {
                player?.pause()
            }
        }
    }

    private func loadPreview() async {
        isLoading = true
        do {
            let item = try await state.previewPlayerItem(video)
            let streamPlayer = AVPlayer(playerItem: item)
            player = streamPlayer
            streamPlayer.play()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
