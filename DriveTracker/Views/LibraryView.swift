import AVKit
import Combine
import SwiftData
import SwiftUI
import UIKit

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
                            .buttonStyle(TrackerPressButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
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
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
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
            .padding(.bottom, 24)
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
        state.isDownloading(video)
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
                            .foregroundStyle(.primary)
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
            .buttonStyle(TrackerPressButtonStyle())
            .disabled(video.isMissingFromDrive)

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
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider().overlay(TrackerPalette.line)

            HStack(spacing: 0) {
                if video.status == .available || video.status == .assigned {
                    Button {
                        if isDownloading {
                            state.cancelDownload(video)
                        } else {
                            state.startParallelDownload(video, context: context)
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
                    .buttonStyle(TrackerPressButtonStyle())
                    .disabled(
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
                .buttonStyle(TrackerPressButtonStyle())
            }
        }
        .background(TrackerPalette.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            .padding(.bottom, 24)
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
            .buttonStyle(TrackerPressButtonStyle())
            .disabled(video.isMissingFromDrive)

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
            if state.isDownloading(video) {
                Button {
                    state.cancelDownload(video)
                } label: {
                    Label("Cancel download", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            } else {
                Button {
                    state.startParallelDownload(video, context: context)
                } label: {
                    Label("Download to Photos", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))
                .disabled(
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
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isEditingSlider = false
    @State private var playbackRate: Float = 1.0
    @State private var timeObserverToken: Any?
    @State private var volume: Double = 1.0
    @State private var isMuted = false
    @State private var audioRouteName = "iPhone"
    @State private var temporaryPreviewURL: URL?
    @State private var isUsingLocalPreview = false
    @State private var isFallingBack = false

    private let speeds: [Float] = [1.0, 1.25, 1.5, 2.0]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isLoading {
                    ZStack {
                        VideoThumbnailView(video: video, width: 220, height: 330)
                            .opacity(0.62)
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Preparing secure Drive stream…")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    .frame(maxHeight: .infinity)
                } else if let player {
                    VStack(spacing: 12) {
                        VideoPlayer(player: player)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity, minHeight: 380, maxHeight: 520)

                        // Fast Range & Review Controls
                        VStack(spacing: 10) {
                            // Instant Range Slider / Scrub Bar
                            VStack(spacing: 4) {
                                Slider(
                                    value: Binding(
                                        get: { currentTime },
                                        set: { newValue in
                                            currentTime = newValue
                                            seek(to: newValue)
                                        }
                                    ),
                                    in: 0...max(duration, 1),
                                    onEditingChanged: { editing in
                                        isEditingSlider = editing
                                    }
                                )
                                .tint(TrackerPalette.accent)

                                HStack {
                                    Text(formatTime(currentTime))
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(TrackerPalette.accent)
                                    Spacer()
                                    Text(formatTime(duration))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(TrackerPalette.muted)
                                }
                            }

                            // Playback controls & Speed selector
                            HStack(spacing: 16) {
                                Button {
                                    jump(by: -5)
                                } label: {
                                    Image(systemName: "gobackward.5")
                                        .font(.title3)
                                }

                                Button {
                                    togglePlayPause()
                                } label: {
                                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(TrackerPalette.accent)
                                }

                                Button {
                                    jump(by: 5)
                                } label: {
                                    Image(systemName: "goforward.5")
                                        .font(.title3)
                                }

                                Spacer()

                                Menu {
                                    ForEach(speeds, id: \.self) { speed in
                                        Button("\(String(format: "%.2fx", speed))") {
                                            setSpeed(speed)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "gauge.with.dots.needle.67percent")
                                        Text("\(String(format: "%.1fx", playbackRate))")
                                            .font(.caption.monospacedDigit().weight(.bold))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(TrackerPalette.raised)
                                    .clipShape(Capsule())
                                }
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)

                            Divider().overlay(TrackerPalette.line)

                            HStack(spacing: 12) {
                                Button {
                                    toggleMute()
                                } label: {
                                    Image(
                                        systemName: isMuted || volume == 0
                                            ? "speaker.slash.fill"
                                            : "speaker.wave.2.fill"
                                    )
                                    .font(.title3)
                                    .frame(width: 34, height: 34)
                                }
                                .buttonStyle(TrackerPressButtonStyle())
                                .accessibilityLabel(isMuted ? "Unmute video" : "Mute video")

                                Slider(value: $volume, in: 0...1)
                                    .tint(TrackerPalette.accent)
                                    .onChange(of: volume) { _, newValue in
                                        player.volume = Float(newValue)
                                        if newValue > 0, isMuted {
                                            isMuted = false
                                            player.isMuted = false
                                        }
                                    }

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Audio")
                                        .font(.caption2)
                                        .foregroundStyle(TrackerPalette.muted)
                                    Text(audioRouteName)
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .frame(width: 72, alignment: .trailing)
                            }
                        }
                        .padding(12)
                        .background(TrackerPalette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
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
            .navigationTitle("Instant Preview & Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadPreview() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .AVPlayerItemFailedToPlayToEndTime
                )
            ) { notification in
                guard notification.object as? AVPlayerItem === player?.currentItem else {
                    return
                }
                beginLocalFallback()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .AVPlayerItemDidPlayToEndTime
                )
            ) { notification in
                guard notification.object as? AVPlayerItem === player?.currentItem else {
                    return
                }
                isPlaying = false
                currentTime = duration
            }
            .onDisappear {
                cleanupPlayer()
            }
        }
    }

    private func loadPreview() async {
        isLoading = true
        loadError = nil
        do {
            try configureAudioSession()
            let item = try await state.previewPlayerItem(video)
            try await validate(item)
            installPlayer(item)
        } catch {
            await loadLocalFallback(streamError: error)
        }
        isLoading = false
    }

    private func validate(_ item: AVPlayerItem) async throws {
        let playable = try await item.asset.load(.isPlayable)
        guard playable else { throw VideoPreviewError.notPlayable }
        if let loadedDuration = try? await item.asset.load(.duration),
           loadedDuration.isNumeric,
           loadedDuration.seconds > 0 {
            duration = loadedDuration.seconds
        }
    }

    private func installPlayer(_ item: AVPlayerItem) {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        item.preferredForwardBufferDuration = isUsingLocalPreview ? 0 : 2
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        let streamPlayer = AVPlayer(playerItem: item)
        streamPlayer.automaticallyWaitsToMinimizeStalling = !isUsingLocalPreview
        streamPlayer.volume = Float(volume)
        streamPlayer.isMuted = isMuted
        player = streamPlayer

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = streamPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            Task { @MainActor in
                guard !isEditingSlider else { return }
                currentTime = time.seconds
                if let itemDuration = streamPlayer.currentItem?.duration.seconds,
                   itemDuration.isFinite,
                   itemDuration > 0 {
                    duration = itemDuration
                }
                isPlaying = streamPlayer.timeControlStatus == .playing
            }
        }

        streamPlayer.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    private func beginLocalFallback() {
        guard !isUsingLocalPreview, !isFallingBack else {
            if isUsingLocalPreview {
                loadError = player?.currentItem?.error?.localizedDescription
                    ?? "The video file could not be played."
            }
            return
        }
        Task { await loadLocalFallback(streamError: player?.currentItem?.error) }
    }

    private func loadLocalFallback(streamError: Error?) async {
        guard !isFallingBack else { return }
        isFallingBack = true
        isLoading = true
        loadError = nil
        player?.pause()
        do {
            let localURL = try await state.previewFile(video)
            temporaryPreviewURL = localURL
            isUsingLocalPreview = true
            let item = AVPlayerItem(url: localURL)
            try await validate(item)
            installPlayer(item)
        } catch {
            loadError = error.localizedDescription.isEmpty
                ? (streamError?.localizedDescription ?? "The preview could not be prepared.")
                : error.localizedDescription
            isPlaying = false
        }
        isLoading = false
        isFallingBack = false
    }

    private func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.2 {
                seek(to: 0)
            }
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    private func toggleMute() {
        guard let player else { return }
        isMuted.toggle()
        player.isMuted = isMuted
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
        try session.setActive(true)
        audioRouteName = session.currentRoute.outputs.first?.portName ?? "iPhone"
    }

    private func jump(by seconds: Double) {
        guard player != nil else { return }
        let target = max(0, min(currentTime + seconds, duration))
        seek(to: target)
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func setSpeed(_ speed: Float) {
        playbackRate = speed
        if isPlaying, let player {
            player.rate = speed
        }
    }

    private func cleanupPlayer() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        player?.pause()
        if let temporaryPreviewURL {
            try? FileManager.default.removeItem(at: temporaryPreviewURL)
            self.temporaryPreviewURL = nil
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds >= 0 else { return "00:00" }
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

private enum VideoPreviewError: LocalizedError {
    case notPlayable

    var errorDescription: String? {
        "Google Drive returned a video format that AVPlayer cannot preview."
    }
}
