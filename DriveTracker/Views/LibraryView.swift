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
                LazyVStack(spacing: 14) {
                    customTopHeader

                    TrackerSectionLabel(
                        title: "Tracked Accounts",
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
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
            .trackerScreen()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var customTopHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LIBRARY")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(TrackerPalette.textPrimary)

                Text("Video Vault & Inventory")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TrackerPalette.muted)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

private struct LibraryAccountRow: View {
    let account: TikTokAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AccountIdentityIcon(
                    symbol: account.iconSymbol,
                    colorHex: account.iconColorHex,
                    size: 52
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Label(account.folderName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                        .lineLimit(1)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TrackerPalette.muted)
            }

            Divider().overlay(TrackerPalette.line)

            HStack {
                TrackerMetric(value: "\(account.videos.count)", label: "Total")
                Spacer()
                TrackerMetric(
                    value: "\(account.availableCount)",
                    label: "Unused",
                    tint: TrackerPalette.accent
                )
                Spacer()
                TrackerMetric(
                    value: "\(account.uploadedCount)",
                    label: "Completed",
                    tint: TrackerPalette.success
                )
            }
        }
        .trackerCard(padding: 16)
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
    @State private var isGridView = true

    private var filteredVideos: [VideoAsset] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !trimmed.isEmpty
        return account.videos.filter { video in
            if isSearching {
                let matches = video.name.localizedCaseInsensitiveContains(trimmed) ||
                    video.folderPath.localizedCaseInsensitiveContains(trimmed)
                guard matches else { return false }
            }
            if let selectedStatus, video.status != selectedStatus { return false }
            if missingOnly, !video.isMissingFromDrive { return false }
            return true
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        let videos = filteredVideos
        ScrollView {
            LazyVStack(spacing: 16) {
                accountHeroCard

                filterBar

                HStack {
                    TrackerSectionLabel(
                        title: "Media Library",
                        trailing: "\(videos.count) videos"
                    )
                    Spacer()
                    Button {
                        isGridView.toggle()
                    } label: {
                        Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TrackerPalette.accent)
                    }
                }

                if videos.isEmpty {
                    ContentUnavailableView(
                        "No matching videos",
                        systemImage: "video.slash",
                        description: Text("Sync the folder or change the filters.")
                    )
                    .foregroundStyle(TrackerPalette.muted)
                    .padding(.top, 44)
                } else if isGridView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(videos) { video in
                            LibraryVideoPosterCard(video: video) {
                                previewVideo = video
                            }
                        }
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(videos) { video in
                            LibraryVideoListCard(video: video) {
                                previewVideo = video
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .trackerScreen()
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search videos or subfolders")
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await state.sync(context: context, announce: false) }
                } label: {
                    if state.isWorking {
                        ProgressView()
                            .tint(TrackerPalette.accent)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TrackerPalette.accent)
                    }
                }
                .disabled(state.isWorking)
            }
        }
        .sheet(item: $previewVideo) { video in
            VideoPreviewView(video: video)
        }
        .refreshable {
            await state.sync(context: context, announce: false)
        }
    }

    private var accountHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AccountIdentityIcon(
                    symbol: account.iconSymbol,
                    colorHex: account.iconColorHex,
                    size: 54
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(TrackerPalette.textPrimary)

                    Label(
                        account.folderName,
                        systemImage: "folder.badge.gearshape"
                    )
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
                    .lineLimit(1)
                }

                Spacer()
            }

            Divider().overlay(TrackerPalette.line)

            HStack {
                TrackerMetric(value: "\(account.videos.count)", label: "Total")
                Spacer()
                TrackerMetric(
                    value: "\(account.availableCount)",
                    label: "Unused",
                    tint: TrackerPalette.accent
                )
                Spacer()
                TrackerMetric(
                    value: "\(account.uploadedCount)",
                    label: "Completed",
                    tint: TrackerPalette.success
                )
                Spacer()
                TrackerMetric(
                    value: "\(account.dailyQuota)",
                    label: "Daily Quota",
                    tint: TrackerPalette.warning
                )
            }
        }
        .trackerCard(padding: 16)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedStatus = nil
                    missingOnly = false
                } label: {
                    FilterChip(
                        title: "All (\(account.videos.count))",
                        selected: selectedStatus == nil && !missingOnly
                    )
                }

                Button {
                    selectedStatus = .available
                    missingOnly = false
                } label: {
                    FilterChip(
                        title: "Unused (\(account.availableCount))",
                        selected: selectedStatus == .available
                    )
                }

                Button {
                    selectedStatus = .uploaded
                    missingOnly = false
                } label: {
                    FilterChip(
                        title: "Completed (\(account.uploadedCount))",
                        selected: selectedStatus == .uploaded
                    )
                }

                Button {
                    missingOnly.toggle()
                    if missingOnly { selectedStatus = nil }
                } label: {
                    FilterChip(title: "Missing", selected: missingOnly)
                }
            }
        }
    }
}

/// 9:16 Vertical Poster Grid Card matching the Stitch UI design
private struct LibraryVideoPosterCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    let preview: () -> Void

    private var isDownloading: Bool {
        state.isDownloading(video)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VideoThumbnailView(
                    video: video,
                    width: nil,
                    height: 220,
                    cornerRadius: 14
                )
                .frame(maxWidth: .infinity)

                // Top duration badge & indicators
                HStack(spacing: 4) {
                    if video.isMissingFromDrive {
                        Image(systemName: "icloud.slash")
                            .font(.caption2.bold())
                            .foregroundStyle(TrackerPalette.danger)
                            .padding(5)
                            .background(Color.black.opacity(0.7), in: Circle())
                    }

                    StatusPill(status: video.status)
                }
                .padding(8)

                // Bottom Content Scrim Overlay
                VStack(alignment: .leading, spacing: 4) {
                    Spacer()
                    Text(video.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if !video.folderPath.isEmpty {
                        Text(video.folderPath)
                            .font(.system(size: 10))
                            .foregroundStyle(TrackerPalette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: preview)

            // Bottom Quick Action Bar
            HStack(spacing: 8) {
                if video.status == .available || video.status == .assigned {
                    Button {
                        if isDownloading {
                            state.cancelDownload(video)
                        } else {
                            state.startParallelDownload(video, context: context)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isDownloading ? "xmark" : "arrow.down")
                            Text(isDownloading ? "Cancel" : "Download")
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isDownloading ? TrackerPalette.warning : Color(hex: "#090A0F"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(isDownloading ? TrackerPalette.surface : TrackerPalette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                    .disabled(!isDownloading && (video.isMissingFromDrive || !video.canDownload))
                } else if video.status == .uploaded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Saved")
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TrackerPalette.success)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(TrackerPalette.success.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                NavigationLink {
                    VideoDetailView(video: video)
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TrackerPalette.muted)
                        .frame(width: 32, height: 32)
                        .background(TrackerPalette.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(TrackerPressButtonStyle())
            }
            .padding(8)
            .background(TrackerPalette.surface)
        }
        .background(TrackerPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 0.5)
        }
    }
}

private struct LibraryVideoListCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    let preview: () -> Void
    @State private var confirmRedownload = false

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
                        height: 110,
                        cornerRadius: 10
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Text(video.name)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(TrackerPalette.textPrimary)
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
                        }
                        if video.isMissingFromPhotos {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(TrackerPalette.warning)
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
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(TrackerPalette.accent)
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
                if video.status == .available || video.status == .assigned || video.status == .uploaded {
                    Button {
                        if isDownloading {
                            state.cancelDownload(video)
                        } else if video.status == .uploaded {
                            confirmRedownload = true
                        } else {
                            state.startParallelDownload(video, context: context)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isDownloading {
                                ProgressView()
                                    .tint(TrackerPalette.warning)
                            } else {
                                Image(
                                    systemName: video.status == .uploaded
                                        ? "arrow.clockwise"
                                        : "arrow.down.to.line"
                                )
                            }
                            Text(
                                isDownloading
                                    ? "Cancel"
                                    : (video.status == .uploaded ? "Download Again" : "Download")
                            )
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
                        !isDownloading &&
                        (video.isMissingFromDrive || !video.canDownload)
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
        .confirmationDialog(
            "Do you want to download again?",
            isPresented: $confirmRedownload
        ) {
            Button("Download Again") {
                state.startParallelRedownload(video, context: context)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Another copy of \(video.name) will be saved to Photos.")
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
    @State private var confirmRedownload = false
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
            TrackerSectionLabel(title: "Video Details")

            Button {
                showPreview = true
            } label: {
                VideoThumbnailView(
                    video: video,
                    width: 200,
                    height: 268,
                    cornerRadius: 14
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerPressButtonStyle())
            .disabled(video.isMissingFromDrive)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .foregroundStyle(TrackerPalette.muted)
                Text("Tap the poster frame to stream a real-time preview directly from Drive.")
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
                LabeledContent("Drive File ID") {
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
                    Label("Cancel Download", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            } else {
                Button {
                    state.startParallelDownload(video, context: context)
                } label: {
                    Label("Download Original to Photos", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))
                .disabled(video.isMissingFromDrive || !video.canDownload)
            }
        }

        if video.status == .available {
            Button {
                state.selectManually(video, context: context)
            } label: {
                Label("Add to Today's Queue", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            .disabled(video.isMissingFromDrive || !video.canDownload)
        }

        if video.status == .available || video.status == .assigned {
            Button {
                state.markCompletedOutsideApp(video, context: context)
            } label: {
                Label("Mark Already Downloaded", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            .disabled(state.isDownloading(video))
        }

        if video.status == .uploaded {
            if state.isDownloading(video) {
                Button {
                    state.cancelDownload(video)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            } else {
                Button {
                    confirmRedownload = true
                } label: {
                    Label("Download Another Copy", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))
                .disabled(video.isMissingFromDrive || !video.canDownload)
            }

            Button {
                state.undoUpload(video, context: context)
            } label: {
                Label("Undo Completed Status", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            .disabled(state.isDownloading(video))
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Audit History",
                trailing: "\(sortedEvents.count) events"
            )

            if sortedEvents.isEmpty {
                Text("No status changes yet.")
                    .font(.subheadline)
                    .foregroundStyle(TrackerPalette.muted)
            } else {
                ForEach(Array(sortedEvents.enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(TrackerPalette.accent)
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.kind.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(TrackerPalette.textPrimary)
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

/// Video Preview Studio & Metadata Inspector matching Stitch Screen 3
struct VideoPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
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
            ScrollView {
                VStack(spacing: 16) {
                    // Video Player Frame
                    ZStack {
                        if isLoading {
                            ZStack {
                                VideoThumbnailView(video: video, width: 220, height: 330, cornerRadius: 16)
                                    .opacity(0.60)
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .controlSize(.large)
                                        .tint(TrackerPalette.accent)
                                    Text("Streaming from Drive…")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(TrackerPalette.textPrimary)
                                }
                            }
                            .frame(height: 380)
                        } else if let loadError {
                            ContentUnavailableView(
                                "Preview unavailable",
                                systemImage: "exclamationmark.triangle",
                                description: Text(loadError)
                            )
                            .frame(height: 320)
                        } else if let player {
                            VStack(spacing: 12) {
                                VideoPlayer(player: player)
                                    .background(Color.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(TrackerPalette.line, lineWidth: 0.5)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 460)

                                // Scrubber & Playback Controls
                                VStack(spacing: 10) {
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
                                                .font(.caption2.monospacedDigit().weight(.bold))
                                                .foregroundStyle(TrackerPalette.accent)
                                            Spacer()
                                            Text(formatTime(duration))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(TrackerPalette.muted)
                                        }
                                    }

                                    HStack(spacing: 18) {
                                        Button {
                                            jump(by: -5)
                                        } label: {
                                            Image(systemName: "gobackward.5")
                                                .font(.title3)
                                                .foregroundStyle(TrackerPalette.textPrimary)
                                        }

                                        Button {
                                            togglePlayPause()
                                        } label: {
                                            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                                .font(.system(size: 44))
                                                .foregroundStyle(TrackerPalette.accent)
                                        }

                                        Button {
                                            jump(by: 5)
                                        } label: {
                                            Image(systemName: "goforward.5")
                                                .font(.title3)
                                                .foregroundStyle(TrackerPalette.textPrimary)
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
                                                    .font(.caption2.monospacedDigit().weight(.bold))
                                            }
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 5)
                                            .background(TrackerPalette.raised)
                                            .clipShape(Capsule())
                                            .overlay {
                                                Capsule().stroke(TrackerPalette.line, lineWidth: 0.5)
                                            }
                                        }
                                        .foregroundStyle(TrackerPalette.textPrimary)
                                    }
                                    .padding(.horizontal, 4)

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
                                            .font(.body)
                                            .foregroundStyle(TrackerPalette.muted)
                                            .frame(width: 32, height: 32)
                                        }
                                        .buttonStyle(TrackerPressButtonStyle())

                                        Slider(value: $volume, in: 0...1)
                                            .tint(TrackerPalette.accent)
                                            .onChange(of: volume) { _, newValue in
                                                player.volume = Float(newValue)
                                                if newValue > 0, isMuted {
                                                    isMuted = false
                                                    player.isMuted = false
                                                }
                                            }

                                        Text(audioRouteName)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(TrackerPalette.muted)
                                            .lineLimit(1)
                                            .frame(width: 60, alignment: .trailing)
                                    }
                                }
                                .padding(14)
                                .background(TrackerPalette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(TrackerPalette.line, lineWidth: 0.5)
                                }
                            }
                        }
                    }

                    // Metadata & Technical Specs Inspector
                    VStack(alignment: .leading, spacing: 10) {
                        Text(video.name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(TrackerPalette.textPrimary)

                        HStack(spacing: 8) {
                            StatusPill(status: video.status)

                            Label(
                                video.folderPath.isEmpty ? (video.account?.folderName ?? "Drive folder") : video.folderPath,
                                systemImage: "folder"
                            )
                            .font(.caption)
                            .foregroundStyle(TrackerPalette.muted)
                            .lineLimit(1)
                        }

                        HStack(spacing: 12) {
                            Label("Original Quality", systemImage: "sparkles.tv")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(TrackerPalette.muted)
                            Text("•")
                                .foregroundStyle(TrackerPalette.muted)
                            Label(video.account?.displayName ?? "Account", systemImage: "person.circle")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(TrackerPalette.muted)
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .trackerCard(padding: 14)

                    // Action Dock
                    VStack(spacing: 10) {
                        if video.status != .uploaded {
                            Button {
                                state.startParallelDownload(video, context: context)
                                dismiss()
                            } label: {
                                Label("Download Original to Photos", systemImage: "arrow.down.to.line.compact")
                                    .font(.subheadline.weight(.bold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TrackerActionButtonStyle(kind: .primary))
                            .disabled(video.isMissingFromDrive || !video.canDownload)

                            Button {
                                state.markCompletedOutsideApp(video, context: context)
                                dismiss()
                            } label: {
                                Label("Mark Already Downloaded", systemImage: "checkmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
                        } else {
                            HStack {
                                Label("Completed & Saved to Photos", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(TrackerPalette.success)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .trackerScreen()
            .navigationTitle("Video Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TrackerPalette.accent)
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
