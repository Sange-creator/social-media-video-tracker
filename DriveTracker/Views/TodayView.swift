import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            TodayFeed()
                .navigationTitle("Today")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { TodaySyncButton() }
                }
                .refreshable { await state.sync(context: context) }
        }
    }
}

// The feed only depends on persisted records. Progress, toasts, and network
// activity are observed by their individual controls rather than this list.
private struct TodayFeed: View {
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]
    @Query private var media: [VideoAsset]

    var body: some View {
        let groups = TodayFeedIndex.build(accounts: accounts, media: media)
        List {
            if groups.isEmpty {
                ContentUnavailableView("No active accounts", systemImage: "folder",
                    description: Text("Add or resume an account to see today's videos."))
            } else {
                Section {
                    TodaySummary(completed: groups.reduce(0) { $0 + $1.completed },
                                 quota: groups.reduce(0) { $0 + $1.account.dailyQuota })
                }
                ForEach(groups) { group in
                    Section {
                        NavigationLink {
                            TodayAccountDetailView(account: group.account)
                        } label: {
                            HStack(spacing: 12) {
                                AccountIdentityIcon(symbol: group.account.iconSymbol, colorHex: group.account.iconColorHex, size: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.account.displayName).font(.headline)
                                    Text("\(group.completed) of \(group.account.dailyQuota) completed" +
                                         (group.photoCount > 0 ? " · \(group.photoCount) photos" : ""))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        ForEach(group.videos) { video in
                            TodayMediaRow(video: video)
                        }
                        if group.videos.isEmpty {
                            Text("No videos queued. Open the account to choose media.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        TodayAccountActions(account: group.account, hasPending: group.videos.contains { $0.status == .assigned || $0.status == .available })
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(TrackerPalette.canvas)
        .contentMargins(.vertical, 8)
    }
}

struct TodayFeedGroup: Identifiable {
    let account: TikTokAccount
    var videos: [VideoAsset] = []
    var completed = 0
    var photoCount = 0
    var id: UUID { account.id }
}

enum TodayFeedIndex {
    static func build(accounts: [TikTokAccount], media: [VideoAsset]) -> [TodayFeedGroup] {
        let active = accounts.filter { $0.modelContext != nil && !$0.isDeleted && $0.isConfigured && !$0.isPaused && !$0.isMissingFromDrive }
        var groups = active.map { TodayFeedGroup(account: $0) }
        let positions = Dictionary(grouping: active.indices, by: { "\(active[$0].googleUserID)|\(active[$0].driveFolderID)" })
        for video in media where video.modelContext != nil && !video.isDeleted {
            let key = "\(video.googleUserID)|\(video.accountFolderID)"
            guard let indices = positions[key] else { continue }
            if video.isPhoto {
                guard !video.isMissingFromDrive else { continue }
                for index in indices { groups[index].photoCount += 1 }
                continue
            }
            let completedToday = video.uploadedAt.map { DayKey.isToday($0) } ?? false
            guard completedToday || (!video.isMissingFromDrive && (video.status == .assigned || video.status == .downloaded)) else { continue }
            for index in indices {
                groups[index].videos.append(video)
                if completedToday { groups[index].completed += 1 }
            }
        }
        for index in groups.indices {
            groups[index].videos.sort {
                let lhs = $0.activeAssignment?.slot ?? Int.max
                let rhs = $1.activeAssignment?.slot ?? Int.max
                return lhs == rhs ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : lhs < rhs
            }
        }
        return groups
    }
}

private struct TodaySummary: View {
    let completed: Int
    let quota: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Date.now, format: .dateTime.weekday().month().day()).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(completed) / \(quota)").font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Text(completed >= quota ? "You're caught up" : "\(max(0, quota - completed)) videos remaining")
                .font(.title2.weight(.semibold))
            ProgressView(value: Double(min(completed, quota)), total: Double(max(1, quota)))
                .tint(TrackerPalette.accent)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct TodaySyncButton: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    var body: some View {
        Button {
            Task { await state.sync(context: context, announce: true) }
        } label: {
            if state.isSyncing { ProgressView() }
            else { Image(systemName: "arrow.clockwise") }
        }
        .disabled(state.isSyncing)
        .accessibilityLabel("Sync Drive")
    }
}

private struct TodayAccountActions: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount
    let hasPending: Bool
    var body: some View {
        HStack {
            if hasPending {
                Button("Download all", systemImage: "arrow.down.to.line") {
                    state.downloadAllAssigned(for: account, context: context)
                }
            }
            Spacer()
            Button("Shuffle", systemImage: "shuffle") {
                state.shuffleSuggestions(for: account, context: context)
            }
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
    }
}

private struct TodayMediaRow: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    let video: VideoAsset
    @State private var showPreview = false
    @State private var showReplacementPicker = false
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Button { showPreview = true } label: {
                VideoThumbnailView(video: video, width: 56, height: 72, cornerRadius: 8)
                    .overlay { Image(systemName: video.isPhoto ? "photo" : "play.fill").font(.caption).foregroundStyle(.white) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(video.name)")
            .disabled(video.isMissingFromDrive)
            VStack(alignment: .leading, spacing: 5) {
                Text((video.name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " "))
                    .font(.body).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                Text(video.status.title.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            TodayDownloadControl(video: video, downloads: state.downloads)
            Menu { TodayMediaActions(video: video, chooseOther: { showReplacementPicker = true }) } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Actions for \(video.name)")
        }
        .padding(.vertical, 4)
        .contextMenu { TodayMediaActions(video: video, chooseOther: { showReplacementPicker = true }) }
        .sheet(isPresented: $showPreview) { VideoPreviewView(video: video) }
        .sheet(isPresented: $showReplacementPicker) {
            if let account = video.account, let assignment = video.activeAssignment {
                ManualVideoPickerView(account: account, replacing: assignment)
            }
        }
    }
}

private struct TodayMediaActions: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    let chooseOther: () -> Void
    var body: some View {
        if !video.uploadText.isEmpty {
            Button("Copy upload text", systemImage: "doc.on.clipboard") { state.copyUploadText(for: video) }
        }
        if video.status != .uploaded {
            Button("Mark completed", systemImage: "checkmark.circle") { state.markCompletedOutsideApp(video, context: context) }
            if video.activeAssignment != nil && video.status == .assigned {
                Button("Choose other video", systemImage: "arrow.triangle.2.circlepath", action: chooseOther)
                    .disabled(state.isDownloading(video) || state.isSavingToPhotos(video))
            }
        } else {
            Button("Undo completion", systemImage: "arrow.uturn.backward") { state.undoUpload(video, context: context) }
            Button("Download another copy", systemImage: "arrow.down") { state.startParallelDownload(video, context: context) }
                .disabled(video.isMissingFromDrive || !video.canDownload)
        }
    }
}

private struct TodayDownloadControl: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @ObservedObject var downloads: DownloadCoordinator
    let video: VideoAsset
    init(video: VideoAsset, downloads: DownloadCoordinator) { self.video = video; self.downloads = downloads }
    var body: some View {
        Group {
            if state.isSavingToPhotos(video) {
                VStack(spacing: 4) {
                    Text("100%").font(.caption.monospacedDigit())
                    ProgressView()
                    Text("Saving…").font(.caption2)
                }.accessibilityLabel("Downloaded 100 percent, verifying and saving to Photos")
            } else if let progress = downloads.progressByIdentity[video.identityKey] {
                Button { state.cancelDownload(video) } label: {
                    VStack(spacing: 4) {
                        let fraction = TodayDownloadProgress.clamped(progress.fraction)
                        if progress.totalBytes > 0 {
                            Text("\(Int(fraction * 100))%")
                                .font(.caption.monospacedDigit())
                            ProgressView(value: fraction).frame(width: 44)
                        } else {
                            ProgressView()
                            Text("Downloading…").font(.caption2)
                        }
                    }
                }.accessibilityLabel("Cancel download")
            } else if state.isDownloading(video) {
                Button { state.cancelDownload(video) } label: {
                    VStack(spacing: 4) {
                        if video.size ?? 0 > 0 { Text("0%").font(.caption.monospacedDigit()) }
                        ProgressView()
                        Text("Connecting…").font(.caption2)
                    }
                }.accessibilityLabel("Connecting to Drive, cancel download")
            } else if video.status == .uploaded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(TrackerPalette.success)
            } else if video.status == .downloaded && !video.isPhoto {
                Button("Complete") { state.markCompletedOutsideApp(video, context: context) }
            } else if video.isPhoto && video.status == .downloaded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(TrackerPalette.success)
            } else {
                Button { state.startParallelDownload(video, context: context) } label: {
                    Image(systemName: "arrow.down.circle").font(.title3)
                }.accessibilityLabel("Download \(video.name)")
                .disabled(state.isSavingToPhotos(video) || !video.canDownload)
            }
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
    }
}

private struct TodayAccountDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount
    @State private var showManualPicker = false
    @Query private var media: [VideoAsset]

    init(account: TikTokAccount) {
        self.account = account
        let userID = account.googleUserID, folderID = account.driveFolderID
        _media = Query(filter: #Predicate<VideoAsset> {
            $0.googleUserID == userID && $0.accountFolderID == folderID
        })
    }

    var body: some View {
        let group = TodayFeedIndex.build(accounts: [account], media: media).first
        let photos = media.filter { $0.modelContext != nil && !$0.isDeleted && !$0.isMissingFromDrive && $0.isPhoto }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        List {
            if let group {
                Section {
                    TodaySummary(completed: group.completed, quota: account.dailyQuota)
                    TodayAccountDownloadProgress(videos: group.videos, quota: account.dailyQuota, downloads: state.downloads)
                    TodayAccountActions(account: account, hasPending: group.videos.contains { $0.status == .assigned })
                    Button("Help me choose another video", systemImage: "plus") { showManualPicker = true }
                    if group.videos.count < account.dailyQuota {
                        Label("\(account.dailyQuota - group.videos.count) more videos needed for today's target", systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section("Today's videos") {
                    ForEach(group.videos) { TodayMediaRow(video: $0) }
                    if group.videos.isEmpty { Text("No videos queued").foregroundStyle(.secondary) }
                }
                if !photos.isEmpty {
                    Section("Photos") {
                        Button("Download available photos", systemImage: "arrow.down.to.line") {
                            state.downloadAllPhotos(for: account, context: context)
                        }
                        ForEach(photos) { TodayMediaRow(video: $0) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(TrackerPalette.canvas)
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await state.sync(context: context, folderIDs: [account.driveFolderID]) }
        .sheet(isPresented: $showManualPicker) { ManualVideoPickerView(account: account) }
    }
}

private struct ManualVideoPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let account: TikTokAccount
    var replacing: DailyAssignment? = nil
    @Query private var media: [VideoAsset]

    init(account: TikTokAccount, replacing: DailyAssignment? = nil) {
        self.account = account
        self.replacing = replacing
        let userID = account.googleUserID, folderID = account.driveFolderID
        _media = Query(filter: #Predicate<VideoAsset> {
            $0.googleUserID == userID && $0.accountFolderID == folderID
        })
    }

    @State private var search = ""
    @State private var previewVideo: VideoAsset?
    @State private var mediaFilter: MediaTypeFilter = .videos

    private var availableItems: [VideoAsset] {
        let showPhotos = replacing == nil && account.hasPhotos && mediaFilter == .photos
        return media
            .filter {
                $0.modelContext != nil && !$0.isDeleted &&
                (showPhotos ? $0.isPhoto : $0.isVideo) &&
                ($0.status == .available || (replacing == nil && $0.status == .assigned)) &&
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
                            Text(replacing != nil ? "Choose any available video to replace this suggestion. Search by video name or folder." : account.hasPhotos
                                ? "Download any unused video or photo immediately without changing your daily schedule."
                                : "Download any unused video immediately without changing your daily schedule.")
                                .font(.caption)
                                .foregroundStyle(TrackerPalette.muted)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(TrackerPalette.surface)
                }

                if replacing == nil && account.hasPhotos {
                    Section {
                        Picker("Media Format", selection: $mediaFilter) {
                            Text("Videos (\(account.availableVideosList.count))").tag(MediaTypeFilter.videos)
                            Text("Photos (\(account.availablePhotos.count))").tag(MediaTypeFilter.photos)
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(Color.clear)
                }

                let isPhotoSection = replacing == nil && account.hasPhotos && mediaFilter == .photos
                let sectionTitle = isPhotoSection
                    ? "Available Photos (\(availableItems.count))"
                    : "Available Videos (\(availableItems.count))"

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
                                            Text("100% downloaded • Saving to Photos…")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(TrackerPalette.accent)
                                            Spacer()
                                        }
                                        ProgressView()
                                            .tint(TrackerPalette.accent)
                                    }
                                    .padding(.vertical, 2)
                                } else if state.isDownloading(video) {
                                    TodayPickerDownloadProgress(video: video, downloads: state.downloads)
                                }

                                if let replacing {
                                    Button("Choose this video", systemImage: "checkmark.circle") {
                                        if state.replace(replacing, with: video, context: context) { dismiss() }
                                    }
                                    .buttonStyle(TrackerActionButtonStyle(kind: .primary))
                                } else {
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
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(TrackerPalette.surface)
                        }
                    }
                }
            }
            .trackerListStyle()
            .navigationTitle(replacing != nil ? "Choose other video" : "Help me choose a video")
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


enum TodayDownloadProgress {
    static func clamped(_ fraction: Double) -> Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }

    static func fraction(completed: Int, partials: [Double], total: Int) -> Double {
        guard total > 0 else { return 0 }
        return clamped((Double(completed) + partials.reduce(0) { $0 + clamped($1) }) / Double(total))
    }
}

private struct TodayAccountDownloadProgress: View {
    @EnvironmentObject private var state: AppState
    let videos: [VideoAsset]
    let quota: Int
    @ObservedObject var downloads: DownloadCoordinator

    var body: some View {
        let completed = videos.filter { $0.downloadedAt != nil }.count
        let partials = videos.filter { $0.downloadedAt == nil }.compactMap {
            state.isSavingToPhotos($0) ? 1 : downloads.progressByIdentity[$0.identityKey]?.fraction
        }
        let total = max(quota, videos.count)
        let fraction = TodayDownloadProgress.fraction(completed: completed, partials: partials, total: total)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today's downloads")
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
            }
            ProgressView(value: fraction).tint(TrackerPalette.accent)
            Text("\(completed) of \(total) videos downloaded")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}


private struct TodayPickerDownloadProgress: View {
    let video: VideoAsset
    @ObservedObject var downloads: DownloadCoordinator

    var body: some View {
        let progress = downloads.progressByIdentity[video.identityKey]
        let fraction = TodayDownloadProgress.clamped(progress?.fraction ?? 0)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progress?.totalBytes ?? 0 > 0 ? "Downloading \(Int(fraction * 100))%" : "Downloading from Drive…")
                    .font(.caption2.weight(.bold)).foregroundStyle(TrackerPalette.accent)
                Spacer()
                if let progress, progress.totalBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: progress.bytesWritten, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(TrackerPalette.muted)
                }
            }
            if let progress, progress.totalBytes > 0 { ProgressView(value: fraction) }
            else { ProgressView() }
        }
        .padding(.vertical, 2)
    }
}
