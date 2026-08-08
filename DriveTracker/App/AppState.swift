import CryptoKit
import AVFoundation
import Foundation
import SwiftData
import UIKit

struct DriveFolderChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let resourceKey: String?
}

@MainActor
final class AppState: ObservableObject {
    @Published var isWorking = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    @Published var lastSyncAt: Date?
    @Published private(set) var analyticsSnapshot: AnalyticsSnapshot
    @Published private(set) var activeDownloadIdentities: Set<String> = []
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    @Published private(set) var reminderTimeZoneID: String
    @Published private(set) var globalCopyQueueLastSyncedAt: Date? {
        didSet { defaults.set(globalCopyQueueLastSyncedAt, forKey: Keys.globalCopyQueueLastSyncedAt) }
    }
    @Published private(set) var globalCopyQueueIssue: String?
    @Published private(set) var globalCopyQueueLink: String {
        didSet { defaults.set(globalCopyQueueLink, forKey: Keys.globalCopyQueueLink) }
    }
    @Published private(set) var globalCopyQueueSheetID: String {
        didSet { defaults.set(globalCopyQueueSheetID, forKey: Keys.globalCopyQueueSheetID) }
    }
    @Published private(set) var globalCopyQueueResourceKey: String? {
        didSet { defaults.set(globalCopyQueueResourceKey, forKey: Keys.globalCopyQueueResourceKey) }
    }

    @Published var rootLink: String {
        didSet { defaults.set(rootLink, forKey: Keys.rootLink) }
    }
    @Published private(set) var rootFolderID: String {
        didSet { defaults.set(rootFolderID, forKey: Keys.rootFolderID) }
    }
    @Published private(set) var rootResourceKey: String? {
        didSet { defaults.set(rootResourceKey, forKey: Keys.rootResourceKey) }
    }

    let auth: GoogleAuthService
    let downloads: DownloadCoordinator
    let notifications: DownloadNotificationService

    private let defaults: UserDefaults
    private let api: DriveAPIClient
    private let syncService: DriveSyncService
    private let copyQueueService: CopyQueueService
    private let photoLibrary = PhotoLibraryService()
    private let assignmentEngine = AssignmentEngine()
    private let backupService: BackupService
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private var thumbnailTasks: [String: Task<UIImage?, Never>] = [:]
    private var backupTask: Task<Void, Never>?
    private var analyticsTask: Task<Void, Never>?
    private var isBackingUp = false
    private var backupRequestedWhileRunning = false
    private var startupMaintenanceTask: Task<Void, Never>?
    private var copyQueueSyncTask: Task<CopyQueueSyncResult, Error>?
    private var copyQueueSyncTaskKey: String?
    private var copyQueueSyncTaskToken: UUID?
    private var activeCopyQueueGoogleUserID: String?
    private var hasStarted = false
    private var lastAutomaticSyncAttempt: Date?
    private let automaticDriveRefreshInterval: TimeInterval = 45

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let auth = GoogleAuthService()
        let api = DriveAPIClient(auth: auth)
        self.auth = auth
        self.api = api
        self.syncService = DriveSyncService(api: api)
        self.copyQueueService = CopyQueueService(api: api)
        self.downloads = DownloadCoordinator()
        let notifications = DownloadNotificationService(defaults: defaults)
        self.notifications = notifications
        self.reminderTimeZoneID = notifications.timeZoneID
        self.backupService = BackupService(api: api, defaults: defaults)
        self.rootLink = defaults.string(forKey: Keys.rootLink) ?? ""
        self.rootFolderID = defaults.string(forKey: Keys.rootFolderID) ?? ""
        self.rootResourceKey = defaults.string(forKey: Keys.rootResourceKey)
        self.lastSyncAt = defaults.object(forKey: Keys.lastSyncAt) as? Date
        self.analyticsSnapshot = defaults.data(forKey: Keys.analyticsSnapshot)
            .flatMap { try? JSONDecoder().decode(AnalyticsSnapshot.self, from: $0) }
            ?? .empty
        self.globalCopyQueueLink = (defaults.string(forKey: Keys.globalCopyQueueLink) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.globalCopyQueueSheetID = defaults.string(forKey: Keys.globalCopyQueueSheetID) ?? ""
        self.globalCopyQueueResourceKey = defaults.string(forKey: Keys.globalCopyQueueResourceKey)
        self.globalCopyQueueLastSyncedAt =
            defaults.object(forKey: Keys.globalCopyQueueLastSyncedAt) as? Date
        self.thumbnailCache.countLimit = 60
        self.thumbnailCache.totalCostLimit = 48 * 1_024 * 1_024
        defaults.set(self.globalCopyQueueLink, forKey: Keys.globalCopyQueueLink)
    }

    var hasRootFolder: Bool { !rootFolderID.isEmpty }
    var lastBackupAt: Date? { backupService.lastBackupAt }
    var hasGlobalCopyQueueSheet: Bool { !globalCopyQueueSheetID.isEmpty }

    func start(context: ModelContext) async {
        guard !hasStarted else { return }
        hasStarted = true
        purgeLegacyDemoData(context: context)
        refreshAutomaticAccountIcons(context: context)
        downloads.setRecoveryHandler { [weak self] identity, url in
            Task { @MainActor in
                await self?.finishRecoveredDownload(
                    identity: identity,
                    localURL: url,
                    context: context
                )
            }
        }
        await auth.restore()
        if let userID = auth.userID {
            activateCopyQueueConfiguration(for: userID)
        }
        if !defaults.bool(forKey: Keys.requestedResetVerified) {
            guard deleteLocalData(context: context) else { return }
            if auth.isSignedIn {
                do {
                    try await backupService.deleteRemoteBackup()
                } catch {
                    // Local reset remains authoritative. Automatic restore is
                    // suppressed until a new folder is explicitly connected.
                }
            }
            defaults.set(true, forKey: Keys.requestedResetVerified)
            defaults.set(true, forKey: Keys.suppressAutomaticRestore)
            statusMessage = "Tracker setup cleared. Google remains connected; configure your accounts and folders again."
            return
        }
        guard auth.isSignedIn, let userID = auth.userID else { return }
        do {
            if !defaults.bool(forKey: Keys.suppressAutomaticRestore),
               let backup = try await backupService.restoreIfLocalStoreIsEmpty(
                context: context,
                expectedGoogleUserID: userID
            ) {
                rootLink = backup.rootLink
                rootFolderID = backup.rootFolderID
                rootResourceKey = backup.rootResourceKey
                applyCopyQueueConfiguration(from: backup)
                statusMessage = "Tracking history restored from Drive."
            }
            let hasSources = try activateDriveSourceConfiguration(
                for: userID,
                context: context
            )
            try ensureToday(context: context)
            scheduleAnalyticsRefresh(context: context)
            if hasSources { scheduleStartupMaintenance(context: context) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn(context: ModelContext) async {
        await perform {
            try await auth.signIn()
            guard let userID = auth.userID else { throw GoogleAuthError.missingUserID }
            activateCopyQueueConfiguration(for: userID)
            if !defaults.bool(forKey: Keys.suppressAutomaticRestore),
               let backup = try await backupService.restoreIfLocalStoreIsEmpty(
                context: context,
                expectedGoogleUserID: userID
            ) {
                rootLink = backup.rootLink
                rootFolderID = backup.rootFolderID
                rootResourceKey = backup.rootResourceKey
                applyCopyQueueConfiguration(from: backup)
                statusMessage = "Tracking history restored from Drive."
            }
            let hasSources = try activateDriveSourceConfiguration(
                for: userID,
                context: context
            )
            try ensureToday(context: context)
            scheduleAnalyticsRefresh(context: context)
            if hasSources {
                scheduleStartupMaintenance(context: context)
            }
        }
    }

    func switchGoogleAccount(hint: String? = nil, context: ModelContext) async {
        await perform {
            try await auth.switchAccount(hint: hint)
            guard let userID = auth.userID else { throw GoogleAuthError.missingUserID }
            activateCopyQueueConfiguration(for: userID)
            if !defaults.bool(forKey: Keys.suppressAutomaticRestore),
               let backup = try await backupService.restoreIfLocalStoreIsEmpty(
                context: context,
                expectedGoogleUserID: userID
            ) {
                rootLink = backup.rootLink
                rootFolderID = backup.rootFolderID
                rootResourceKey = backup.rootResourceKey
                applyCopyQueueConfiguration(from: backup)
            }
            let hasSources = try activateDriveSourceConfiguration(
                for: userID,
                context: context
            )
            try ensureToday(context: context)
            scheduleAnalyticsRefresh(context: context)
            if hasSources {
                scheduleStartupMaintenance(context: context)
            }
        }
    }

    func driveFolders(in parentID: String = "root", resourceKey: String? = nil) async throws
        -> [DriveFolderChoice]
    {
        try await api.listChildren(of: parentID, folderResourceKey: resourceKey)
            .filter(\.isFolder)
            .map {
                DriveFolderChoice(
                    id: $0.effectiveID,
                    name: $0.name,
                    resourceKey: $0.effectiveResourceKey
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func sharedDriveFolders() async throws -> [DriveFolderChoice] {
        try await api.listSharedFolders()
            .map {
                DriveFolderChoice(
                    id: $0.effectiveID,
                    name: $0.name,
                    resourceKey: $0.effectiveResourceKey
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func folderChoice(from link: String) async throws -> DriveFolderChoice {
        let reference = try DriveLinkParser().parse(link)
        let item = try await api.item(id: reference.folderID, resourceKey: reference.resourceKey)
        guard item.isFolder else { throw DriveLinkError.invalidFolderLink }
        return DriveFolderChoice(
            id: reference.folderID,
            name: item.name,
            resourceKey: reference.resourceKey ?? item.effectiveResourceKey
        )
    }

    func associateFolder(
        _ folder: DriveFolderChoice,
        link: String? = nil,
        accountID: UUID?,
        accountName: String,
        folderName: String,
        dailyQuota: Int,
        iconSymbol: String,
        iconColorHex: String,
        context: ModelContext
    ) async {
        await perform {
            let cleanAccountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanFolderName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanAccountName.isEmpty, !cleanFolderName.isEmpty else {
                throw DriveAssociationError.missingNames
            }
            var resolvedLink = link?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if resolvedLink.isEmpty {
                resolvedLink = "https://drive.google.com/drive/folders/\(folder.id)"
                if let key = folder.resourceKey {
                    resolvedLink += "?resourcekey=\(key)"
                }
            }
            try await addDriveSource(
                reference: DriveFolderReference(
                    folderID: folder.id,
                    resourceKey: folder.resourceKey
                ),
                folderName: cleanFolderName,
                accountID: accountID,
                accountName: cleanAccountName,
                dailyQuota: dailyQuota,
                iconSymbol: iconSymbol,
                iconColorHex: iconColorHex,
                link: resolvedLink,
                context: context
            )
        }
    }

    func sync(context: ModelContext, announce: Bool = false) async {
        guard !isWorking else { return }
        isWorking = true
        if announce { errorMessage = nil }
        defer { isWorking = false }
        do {
            guard let userID = auth.userID else { throw GoogleAuthError.notSignedIn }
            let sources = try context.fetch(FetchDescriptor<DriveSource>())
                .filter { $0.googleUserID == userID && $0.isEnabled }
            guard !sources.isEmpty else { throw DriveLinkError.empty }
            var videoCount = 0
            var newVideoCount = 0
            for source in sources {
                let linkedAccounts = try context.fetch(FetchDescriptor<TikTokAccount>())
                    .filter { $0.sourceID == source.id }
                for account in linkedAccounts {
                    // Older builds linked several child accounts to one parent source.
                    // Preserve those accounts by scanning their own folder. New builds
                    // always have one explicitly chosen folder per account.
                    let reference = linkedAccounts.count == 1
                        ? DriveFolderReference(
                            folderID: source.rootFolderID,
                            resourceKey: source.rootResourceKey
                        )
                        : DriveFolderReference(
                            folderID: account.driveFolderID,
                            resourceKey: account.folderResourceKey
                        )
                    let result = try await syncSource(
                        source,
                        account: account,
                        reference: reference,
                        context: context
                    )
                    videoCount += result.videosFound
                    newVideoCount += result.newVideos
                }
            }
            if hasGlobalCopyQueueSheet {
                do {
                    let result = try await syncCopyQueueNow(
                        googleUserID: userID,
                        context: context
                    )
                    globalCopyQueueLastSyncedAt = result.syncedAt
                    globalCopyQueueIssue = nil
                    persistActiveCopyQueueConfiguration()
                } catch {
                    globalCopyQueueIssue = error.localizedDescription
                }
            }
            setSyncDate()
            lastAutomaticSyncAttempt = .now
            try ensureToday(context: context)
            if announce {
                statusMessage = "Folder check complete: \(videoCount) videos tracked; \(newVideoCount) new."
            }
            scheduleBackup(context: context)
        } catch {
            // Pull-to-refresh tasks are allowed to be cancelled by SwiftUI
            // (for example, when the gesture ends or the view changes). That
            // is not a Drive error and should never surface as an alert.
            guard !isCancellation(error) else { return }
            if announce {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshFromDriveIfNeeded(context: ModelContext) async {
        guard hasStarted, auth.isSignedIn, !isWorking else { return }
        if let lastAutomaticSyncAttempt,
           Date.now.timeIntervalSince(lastAutomaticSyncAttempt) < automaticDriveRefreshInterval {
            return
        }
        guard
            let sourceCount = try? context.fetchCount(FetchDescriptor<DriveSource>()),
            sourceCount > 0
        else { return }
        lastAutomaticSyncAttempt = .now
        await sync(context: context, announce: false)
    }

    /// Poll while the app is usable so newly uploaded Drive videos normally
    /// appear within one minute. iOS suspends this loop when the app is closed;
    /// the scene-activation refresh catches up immediately on return.
    func runForegroundDriveRefreshLoop(context: ModelContext) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(automaticDriveRefreshInterval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refreshFromDriveIfNeeded(context: context)
        }
    }

    func ensureToday(context: ModelContext) throws {
        let accounts = try context.fetch(FetchDescriptor<TikTokAccount>())
        for account in accounts.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            _ = try assignmentEngine.ensureAssignments(for: account, context: context)
        }
    }

    func enableDownloadNotifications(context: ModelContext) async -> Bool {
        let assignments = (try? context.fetch(FetchDescriptor<DailyAssignment>())) ?? []
        return await notifications.requestAccessAndSchedule(assignments: assignments)
    }

    func scheduleDownloadNotifications(context: ModelContext) async {
        let assignments = (try? context.fetch(FetchDescriptor<DailyAssignment>())) ?? []
        await notifications.schedule(assignments: assignments)
    }

    func setReminderTimeZone(_ id: String, context: ModelContext) {
        guard USReminderTimeZone(rawValue: id) != nil else { return }
        reminderTimeZoneID = id
        notifications.setTimeZone(id: id)
        Task { await scheduleDownloadNotifications(context: context) }
    }

    func replace(_ assignment: DailyAssignment, context: ModelContext) {
        do {
            if try assignmentEngine.replace(assignment, context: context) {
                statusMessage = "A new video was selected."
                scheduleBackup(context: context)
            } else {
                errorMessage = "No unused replacement video is available."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shuffleSuggestions(for account: TikTokAccount, context: ModelContext) {
        do {
            let changed = try assignmentEngine.shuffleSuggestions(for: account, context: context)
            guard changed > 0 else {
                errorMessage = "There are no unused videos available to shuffle into the suggestions."
                return
            }
            statusMessage = "\(changed) suggestion\(changed == 1 ? "" : "s") shuffled for \(account.displayName)."
            scheduleBackup(context: context)
            Task { await scheduleDownloadNotifications(context: context) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectManually(_ video: VideoAsset, context: ModelContext) {
        do {
            guard try assignmentEngine.selectManually(video, context: context) != nil else {
                errorMessage = "This file cannot be selected. Check its account, Drive status, and download permission."
                return
            }
            statusMessage = "\(video.name) was added to today’s queue."
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseAndDownload(_ video: VideoAsset, context: ModelContext) async {
        errorMessage = nil
        do {
            guard try assignmentEngine.selectManually(
                video,
                replaceExistingSuggestion: false,
                context: context
            ) != nil else {
                errorMessage = "This video cannot be downloaded. Check its folder status and download permission."
                return
            }
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await download(video, context: context)
    }

    func isDownloading(_ identityKey: String) -> Bool {
        activeDownloadIdentities.contains(identityKey)
    }

    func isDownloading(_ video: VideoAsset) -> Bool {
        activeDownloadIdentities.contains(video.identityKey)
    }

    func download(_ video: VideoAsset, context: ModelContext) async {
        guard !activeDownloadIdentities.contains(video.identityKey) else { return }
        activeDownloadIdentities.insert(video.identityKey)
        toastMessage = "Download started for \(video.name)"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        await performReservedDownload(video, context: context)
    }

    private func performReservedDownload(_ video: VideoAsset, context: ModelContext) async {
        defer {
            activeDownloadIdentities.remove(video.identityKey)
            activeDownloadTasks.removeValue(forKey: video.identityKey)
        }
        do {
            guard auth.userID == video.googleUserID else {
                throw DriveAssociationError.wrongGoogleAccount(video.account?.googleEmail)
            }
            guard !video.isMissingFromDrive, video.canDownload else {
                throw DriveAssociationError.videoMissing
            }
            try assignmentEngine.markDownloadStarted(video, context: context)
            let request = try await api.downloadRequest(for: video)
            let localURL = try await downloads.download(request: request, identity: video.identityKey)
            defer { try? FileManager.default.removeItem(at: localURL) }
            try await verifyOriginalFile(video: video, localURL: localURL)
            let photoID = try await photoLibrary.saveVideo(
                at: localURL,
                accountName: video.account?.displayName ?? "Account"
            )
            try assignmentEngine.completeVerifiedDownload(
                video,
                photoIdentifier: photoID,
                context: context
            )
            toastMessage = "Downloaded and completed • \(video.name)"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            scheduleBackup(context: context)
            await scheduleDownloadNotifications(context: context)
        } catch {
            if !isCancellation(error) {
                try? assignmentEngine.markDownloadFailed(video, error: error, context: context)
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    func startParallelDownload(_ video: VideoAsset, context: ModelContext) {
        guard !activeDownloadIdentities.contains(video.identityKey) else { return }
        // Reserve the identity synchronously so a fast double tap cannot create
        // two background URLSession tasks before the first Task begins running.
        activeDownloadIdentities.insert(video.identityKey)
        toastMessage = "Download started for \(video.name)"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let task = Task {
            await performReservedDownload(video, context: context)
        }
        activeDownloadTasks[video.identityKey] = task
    }

    func downloadAllAssigned(for account: TikTokAccount, context: ModelContext) async {
        let assignedVideos = account.videos.filter {
            ($0.status == .assigned || $0.status == .available) &&
            !$0.isMissingFromDrive &&
            $0.canDownload &&
            !activeDownloadIdentities.contains($0.identityKey)
        }
        for video in assignedVideos {
            startParallelDownload(video, context: context)
        }
    }

    func cancelDownload(_ video: VideoAsset) {
        downloads.cancel(identity: video.identityKey)
        activeDownloadTasks[video.identityKey]?.cancel()
        activeDownloadTasks.removeValue(forKey: video.identityKey)
        activeDownloadIdentities.remove(video.identityKey)
        toastMessage = "Download canceled"
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    func syncGlobalCopyQueue(
        context: ModelContext,
        announceErrors: Bool = true
    ) async {
        guard let userID = auth.userID, hasGlobalCopyQueueSheet else { return }
        do {
            let result = try await syncCopyQueueNow(
                googleUserID: userID,
                context: context
            )
            globalCopyQueueLastSyncedAt = result.syncedAt
            globalCopyQueueIssue = nil
            persistActiveCopyQueueConfiguration()
            if result.changed {
                scheduleBackup(context: context)
            }
        } catch {
            globalCopyQueueIssue = error.localizedDescription
            if announceErrors, !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func connectGlobalCopyQueue(
        link: String? = nil,
        context: ModelContext
    ) async -> Bool {
        guard let userID = auth.userID else {
            errorMessage = GoogleAuthError.notSignedIn.localizedDescription
            return false
        }
        do {
            let cleanLink = (link ?? globalCopyQueueLink)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reference = try GoogleSheetLinkParser().parse(cleanLink)
            let syncKey = copyQueueSyncKey(
                sheetID: reference.fileID,
                resourceKey: reference.resourceKey,
                googleUserID: userID
            )
            let result = try await serializedCopyQueueSync(key: syncKey) {
                try await self.copyQueueService.syncGlobal(
                    sheetID: reference.fileID,
                    resourceKey: reference.resourceKey,
                    googleUserID: userID,
                    context: context
                )
            }
            let configurationChanged =
                globalCopyQueueLink != cleanLink ||
                globalCopyQueueSheetID != reference.fileID ||
                globalCopyQueueResourceKey != reference.resourceKey
            globalCopyQueueLink = cleanLink
            globalCopyQueueSheetID = reference.fileID
            globalCopyQueueResourceKey = reference.resourceKey
            globalCopyQueueLastSyncedAt = result.syncedAt
            globalCopyQueueIssue = nil
            persistActiveCopyQueueConfiguration()
            toastMessage = result.entriesFound == 0
                ? "Queue connected — add content in column A"
                : "Queue connected — \(result.entriesFound) entries ready"
            if configurationChanged || result.changed {
                scheduleBackup(context: context)
            }
            return true
        } catch {
            globalCopyQueueIssue = error.localizedDescription
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func changeGlobalCopyQueue() {
        globalCopyQueueSheetID = ""
        globalCopyQueueResourceKey = nil
        globalCopyQueueIssue = nil
        globalCopyQueueLastSyncedAt = nil
        persistActiveCopyQueueConfiguration()
    }

    func copyToClipboard(_ entry: CopyEntry, context: ModelContext) {
        let wasCopied = entry.copiedAt != nil
        let timestamp = Date.now
        UIPasteboard.general.string = entry.content
        guard UIPasteboard.general.string == entry.content else {
            errorMessage = "The text could not be placed on the clipboard. Please try again."
            return
        }
        entry.copiedAt = timestamp
        entry.copyCount += 1
        entry.updatedAt = timestamp
        context.insert(
            CopyEvent(
                kind: wasCopied ? .recopied : .copied,
                timestamp: timestamp,
                detail: "Copied from Queue row \(entry.sourceRow)",
                accountName: "Global Copy Queue",
                entryIdentityKey: entry.identityKey,
                contentPreview: entry.content,
                entry: entry
            )
        )
        do {
            try context.save()
            toastMessage = wasCopied ? "Copied again" : "Copied to clipboard"
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markCopyEntryUncopied(_ entry: CopyEntry, context: ModelContext) {
        entry.copiedAt = nil
        entry.updatedAt = .now
        context.insert(
            CopyEvent(
                kind: .markedUncopied,
                detail: "Returned to the uncopied queue",
                accountName: "Global Copy Queue",
                entryIdentityKey: entry.identityKey,
                contentPreview: entry.content,
                entry: entry
            )
        )
        do {
            try context.save()
            toastMessage = "Returned to uncopied"
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func redownload(_ video: VideoAsset, context: ModelContext) async {
        guard !activeDownloadIdentities.contains(video.identityKey) else { return }
        activeDownloadIdentities.insert(video.identityKey)
        defer {
            activeDownloadIdentities.remove(video.identityKey)
            activeDownloadTasks.removeValue(forKey: video.identityKey)
        }
        do {
            guard auth.userID == video.googleUserID else {
                throw DriveAssociationError.wrongGoogleAccount(video.account?.googleEmail)
            }
            guard !video.isMissingFromDrive, video.canDownload else {
                throw DriveAssociationError.videoMissing
            }
            let request = try await api.downloadRequest(for: video)
            let localURL = try await downloads.download(request: request, identity: video.identityKey)
            defer { try? FileManager.default.removeItem(at: localURL) }
            try await verifyOriginalFile(video: video, localURL: localURL)
            let photoID = try await photoLibrary.saveVideo(
                at: localURL,
                accountName: video.account?.displayName ?? "Account"
            )
            video.photoLocalIdentifier = photoID
            video.downloadedAt = video.downloadedAt ?? .now
            video.isMissingFromPhotos = false
            video.updatedAt = .now
            context.insert(
                StatusEvent(
                    kind: .downloadSucceeded,
                    detail: "Explicitly re-downloaded to Photos",
                    accountName: video.account?.displayName ?? "Unknown account",
                    driveFileID: video.driveFileID,
                    videoName: video.name,
                    video: video
                )
            )
            try context.save()
            toastMessage = "Downloaded again • \(video.name)"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            scheduleBackup(context: context)
        } catch {
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    func verifyPhotoCopy(_ video: VideoAsset, context: ModelContext) {
        guard let identifier = video.photoLocalIdentifier else {
            video.isMissingFromPhotos = video.downloadedAt != nil
            try? context.save()
            return
        }
        guard let exists = photoLibrary.savedAssetExists(localIdentifier: identifier) else {
            errorMessage = "Allow Photos access to verify the saved copy."
            return
        }
        video.isMissingFromPhotos = !exists
        video.updatedAt = .now
        do {
            try context.save()
            statusMessage = exists
                ? "The saved Photos copy is still available."
                : "The video was deleted from Photos. Download history remains recorded."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markUploaded(_ video: VideoAsset, context: ModelContext) {
        do {
            try assignmentEngine.markUploaded(video, context: context)
            statusMessage = "Completion recorded for \(video.account?.displayName ?? "account")."
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markCompletedOutsideApp(_ video: VideoAsset, context: ModelContext) {
        do {
            try assignmentEngine.markCompletedOutsideApp(video, context: context)
            statusMessage = "\(video.name) was marked completed."
            scheduleBackup(context: context)
            Task { await scheduleDownloadNotifications(context: context) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoUpload(_ video: VideoAsset, context: ModelContext) {
        do {
            try assignmentEngine.undoUpload(video, context: context)
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetDownload(_ video: VideoAsset, context: ModelContext) {
        do {
            try assignmentEngine.resetDownload(video, context: context)
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func accountChanged(_ account: TikTokAccount, context: ModelContext) {
        account.dailyQuota = min(30, max(1, account.dailyQuota))
        account.displayName = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = AccountIconCatalog.style(forName: account.displayName, fallbackID: account.id)
        account.iconSymbol = style.symbol
        account.iconColorHex = style.colorHex
        account.isConfigured = !account.displayName.isEmpty
        account.updatedAt = .now
        do {
            try context.save()
            try ensureToday(context: context)
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAccount(_ account: TikTokAccount, context: ModelContext) {
        do {
            let sourceID = account.sourceID
            context.delete(account)
            if let sourceID {
                let remainingAccounts = try context.fetch(FetchDescriptor<TikTokAccount>())
                    .filter { $0.sourceID == sourceID && $0.id != account.id }
                if remainingAccounts.isEmpty,
                   let source = try context.fetch(FetchDescriptor<DriveSource>())
                    .first(where: { $0.id == sourceID }) {
                    context.delete(source)
                }
            }
            try context.save()
            if let userID = auth.userID {
                _ = try activateDriveSourceConfiguration(for: userID, context: context)
            } else if try context.fetchCount(FetchDescriptor<DriveSource>()) == 0 {
                rootLink = ""
                rootFolderID = ""
                rootResourceKey = nil
            }
            try ensureToday(context: context)
            statusMessage = "Account removed from the tracker. Google Drive files were not deleted."
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previewFile(_ video: VideoAsset) async throws -> URL {
        guard auth.userID == video.googleUserID else {
            throw DriveAssociationError.wrongGoogleAccount(video.account?.googleEmail)
        }
        guard !video.isMissingFromDrive else {
            throw DriveAssociationError.videoMissing
        }
        return try await api.previewFile(for: video)
    }

    func previewPlayerItem(_ video: VideoAsset) async throws -> AVPlayerItem {
        guard auth.userID == video.googleUserID else {
            throw DriveAssociationError.wrongGoogleAccount(video.account?.googleEmail)
        }
        guard !video.isMissingFromDrive else {
            throw DriveAssociationError.videoMissing
        }
        return try await api.streamingPlayerItem(for: video)
    }

    func thumbnailImage(for video: VideoAsset) async -> UIImage? {
        let identity = video.identityKey
        let cacheKey = identity as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        // SwiftUI can create the same row more than once while scrolling. Share
        // one request instead of starting duplicate Drive downloads and image
        // decodes for the same file.
        if let existingTask = thumbnailTasks[identity] {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self,
                  self.auth.userID == video.googleUserID,
                  !video.isMissingFromDrive,
                  video.thumbnailLink != nil,
                  let data = try? await self.api.thumbnailData(for: video)
            else { return nil }

            // UIImage decoding is CPU work. Keep it off the main actor so a
            // scrolling Library never freezes while a thumbnail arrives.
            let image = await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value
            guard let image else { return nil }
            let imageCost = image.cgImage.map {
                $0.bytesPerRow * $0.height
            } ?? data.count
            self.thumbnailCache.setObject(image, forKey: cacheKey, cost: imageCost)
            return image
        }
        thumbnailTasks[identity] = task
        let image = await task.value
        thumbnailTasks[identity] = nil
        return image
    }

    func backupNow(context: ModelContext) async {
        guard auth.isSignedIn, let userID = auth.userID else { return }
        guard !isBackingUp else {
            backupRequestedWhileRunning = true
            backupService.markDirty()
            return
        }
        isBackingUp = true
        defer {
            isBackingUp = false
            if backupRequestedWhileRunning {
                backupRequestedWhileRunning = false
                backupService.markDirty()
                scheduleBackup(context: context)
            }
        }
        do {
            let currentSource = try context.fetch(FetchDescriptor<DriveSource>())
                .filter { $0.googleUserID == userID && $0.isEnabled }
                .sorted { $0.createdAt > $1.createdAt }
                .first
            try await backupService.save(
                context: context,
                rootLink: currentSource?.rootLink ?? "",
                rootFolderID: currentSource?.rootFolderID ?? "",
                rootResourceKey: currentSource?.rootResourceKey,
                googleUserID: userID,
                globalCopyQueueLink: globalCopyQueueLink,
                globalCopyQueueSheetID: globalCopyQueueSheetID,
                globalCopyQueueResourceKey: globalCopyQueueResourceKey
            )
            objectWillChange.send()
        } catch {
            backupService.markDirty()
        }
    }

    func scheduleBackup(context: ModelContext) {
        backupService.markDirty()
        scheduleAnalyticsRefresh(context: context)
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.backupNow(context: context)
        }
    }

    /// Rebuild analytics in a private SwiftData context. The previous snapshot
    /// remains visible until the new one is ready, so opening Analytics never
    /// blocks a tab-selection animation.
    func scheduleAnalyticsRefresh(context: ModelContext) {
        guard let googleUserID = auth.userID else { return }
        let container = context.container
        analyticsTask?.cancel()
        analyticsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            do {
                let snapshot = try await AnalyticsSnapshotService.makeSnapshot(
                    container: container,
                    googleUserID: googleUserID
                )
                guard !Task.isCancelled, self.auth.userID == googleUserID else { return }
                self.analyticsSnapshot = snapshot
                if let data = try? JSONEncoder().encode(snapshot) {
                    self.defaults.set(data, forKey: Keys.analyticsSnapshot)
                }
            } catch {
                // Keep the last valid snapshot. Analytics is informative and
                // should never surface a blocking error during normal use.
            }
        }
    }

    func deleteRemoteBackup() async {
        await perform {
            try await backupService.deleteRemoteBackup()
            statusMessage = "Drive backup deleted."
        }
    }

    @discardableResult
    func deleteLocalData(context: ModelContext) -> Bool {
        do {
            // Delete concrete objects in dependency order. SwiftData batch
            // deletion can fail when an older store contains relationship
            // rows from a previous schema.
            for event in try context.fetch(FetchDescriptor<StatusEvent>()) {
                context.delete(event)
            }
            try context.save()
            for event in try context.fetch(FetchDescriptor<CopyEvent>()) {
                context.delete(event)
            }
            try context.save()
            for assignment in try context.fetch(FetchDescriptor<DailyAssignment>()) {
                context.delete(assignment)
            }
            try context.save()
            for entry in try context.fetch(FetchDescriptor<CopyEntry>()) {
                context.delete(entry)
            }
            try context.save()
            for video in try context.fetch(FetchDescriptor<VideoAsset>()) {
                context.delete(video)
            }
            try context.save()
            for account in try context.fetch(FetchDescriptor<TikTokAccount>()) {
                context.delete(account)
            }
            try context.save()
            for source in try context.fetch(FetchDescriptor<DriveSource>()) {
                context.delete(source)
            }
            try context.save()
            rootLink = ""
            rootFolderID = ""
            rootResourceKey = nil
            globalCopyQueueLink = ""
            globalCopyQueueSheetID = ""
            globalCopyQueueResourceKey = nil
            globalCopyQueueIssue = nil
            globalCopyQueueLastSyncedAt = nil
            analyticsSnapshot = .empty
            defaults.removeObject(forKey: Keys.analyticsSnapshot)
            clearStoredCopyQueueConfigurations()
            defaults.set(true, forKey: Keys.suppressAutomaticRestore)
            statusMessage = "Local tracking data deleted."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func purgeLegacyDemoData(context: ModelContext) {
        do {
            let demoAccounts = try context.fetch(FetchDescriptor<TikTokAccount>())
                .filter { $0.googleUserID == "demo-user" }
            let demoVideos = try context.fetch(FetchDescriptor<VideoAsset>())
                .filter { $0.googleUserID == "demo-user" }
            guard !demoAccounts.isEmpty || !demoVideos.isEmpty else { return }

            for account in demoAccounts {
                context.delete(account)
            }
            for video in demoVideos where video.account == nil {
                context.delete(video)
            }
            try context.save()
            rootLink = ""
            rootFolderID = ""
            rootResourceKey = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAutomaticAccountIcons(context: ModelContext) {
        guard let accounts = try? context.fetch(FetchDescriptor<TikTokAccount>()) else { return }
        var changed = false
        for account in accounts {
            let style = AccountIconCatalog.style(forName: account.displayName, fallbackID: account.id)
            if account.iconSymbol != style.symbol || account.iconColorHex != style.colorHex {
                account.iconSymbol = style.symbol
                account.iconColorHex = style.colorHex
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    func dismissMessages() {
        statusMessage = nil
        errorMessage = nil
        toastMessage = nil
    }

    private func setSyncDate() {
        lastSyncAt = .now
        defaults.set(lastSyncAt, forKey: Keys.lastSyncAt)
    }

    private func addDriveSource(
        reference: DriveFolderReference,
        folderName: String,
        accountID: UUID?,
        accountName: String,
        dailyQuota: Int,
        iconSymbol: String,
        iconColorHex: String,
        link: String,
        context: ModelContext
    ) async throws {
        guard let userID = auth.userID else { throw GoogleAuthError.notSignedIn }
        let email = auth.email ?? "Google account"
        let sources = try context.fetch(FetchDescriptor<DriveSource>())
        let source: DriveSource
        if let existing = sources.first(where: {
            $0.googleUserID == userID && $0.rootFolderID == reference.folderID
        }) {
            source = existing
            source.displayName = folderName
            source.rootLink = link
            source.rootResourceKey = reference.resourceKey
            source.isEnabled = true
        } else {
            source = DriveSource(
                googleUserID: userID,
                googleEmail: email,
                rootFolderID: reference.folderID,
                rootResourceKey: reference.resourceKey,
                rootLink: link,
                displayName: folderName
            )
            context.insert(source)
        }

        let allAccounts = try context.fetch(FetchDescriptor<TikTokAccount>())
        let account: TikTokAccount
        let automaticStyle = AccountIconCatalog.style(forName: accountName)
        if let accountID, let existing = allAccounts.first(where: { $0.id == accountID }) {
            if let previousSourceID = existing.sourceID, previousSourceID != source.id,
               !allAccounts.contains(where: {
                   $0.id != existing.id && $0.sourceID == previousSourceID
               }),
               let previousSource = sources.first(where: { $0.id == previousSourceID }) {
                previousSource.isEnabled = false
            }
            account = existing
            account.driveFolderID = reference.folderID
            account.folderResourceKey = reference.resourceKey
            account.folderName = folderName
            account.displayName = accountName
            account.dailyQuota = min(30, max(1, dailyQuota))
            account.iconSymbol = automaticStyle.symbol
            account.iconColorHex = automaticStyle.colorHex
            account.sourceID = source.id
            account.googleEmail = email
            account.googleUserID = userID
            account.isConfigured = true
            account.isMissingFromDrive = false
            account.updatedAt = .now
        } else {
            account = TikTokAccount(
                googleUserID: userID,
                driveFolderID: reference.folderID,
                folderResourceKey: reference.resourceKey,
                folderName: folderName,
                displayName: accountName,
                dailyQuota: dailyQuota,
                sortOrder: allAccounts.count,
                sourceID: source.id,
                googleEmail: email,
                isConfigured: true,
                iconSymbol: automaticStyle.symbol,
                iconColorHex: automaticStyle.colorHex
            )
            context.insert(account)
        }
        try context.save()

        let result = try await syncSource(
            source,
            account: account,
            reference: reference,
            context: context
        )
        rootLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        rootFolderID = reference.folderID
        rootResourceKey = reference.resourceKey
        defaults.set(false, forKey: Keys.suppressAutomaticRestore)
        setSyncDate()
        try ensureToday(context: context)
        statusMessage = "Connected \(folderName) to \(accountName): \(result.videosFound) videos found."
        scheduleBackup(context: context)
    }

    private func syncSource(
        _ source: DriveSource,
        account: TikTokAccount,
        reference: DriveFolderReference,
        context: ModelContext
    ) async throws -> DriveSyncResult {
        guard auth.userID == source.googleUserID else {
            throw GoogleAuthError.notSignedIn
        }
        let result = try await syncService.sync(
            root: reference,
            account: account,
            context: context
        )
        source.lastSyncedAt = .now
        try context.save()
        return result
    }

    private func finishRecoveredDownload(
        identity: String,
        localURL: URL,
        context: ModelContext
    ) async {
        defer { try? FileManager.default.removeItem(at: localURL) }
        do {
            let videos = try context.fetch(FetchDescriptor<VideoAsset>())
            guard let video = videos.first(where: { $0.identityKey == identity }) else {
                return
            }
            try await verifyOriginalFile(video: video, localURL: localURL)
            let photoID = try await photoLibrary.saveVideo(
                at: localURL,
                accountName: video.account?.displayName ?? "Account"
            )
            try assignmentEngine.completeVerifiedDownload(
                video,
                photoIdentifier: photoID,
                context: context
            )
            toastMessage = "Downloaded and completed • \(video.name)"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            scheduleBackup(context: context)
        } catch {
            errorMessage = "Background download recovery failed: \(error.localizedDescription)"
        }
    }

    private func verifyKnownPhotoCopies(context: ModelContext) {
        guard let videos = try? context.fetch(FetchDescriptor<VideoAsset>()) else { return }
        let identifiers = videos.compactMap(\.photoLocalIdentifier)
        guard let existingIdentifiers = photoLibrary.existingAssetIdentifiers(identifiers) else {
            return
        }
        var changed = false
        for video in videos where video.downloadedAt != nil {
            guard let identifier = video.photoLocalIdentifier else { continue }
            let missing = !existingIdentifiers.contains(identifier)
            if video.isMissingFromPhotos != missing {
                video.isMissingFromPhotos = missing
                video.updatedAt = .now
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    private func scheduleStartupMaintenance(context: ModelContext) {
        startupMaintenanceTask?.cancel()
        // Let the first frame and navigation become interactive before the
        // initial Drive/Photos maintenance work begins.
        lastAutomaticSyncAttempt = nil
        startupMaintenanceTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            await self.refreshFromDriveIfNeeded(context: context)
        }
    }

    private func verifyOriginalFile(video: VideoAsset, localURL: URL) async throws {
        let expectedSize = video.size
        let expectedChecksum = video.checksum
        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            if let expectedSize,
               let actualSize = attributes[.size] as? NSNumber,
               actualSize.int64Value != expectedSize {
                throw DownloadIntegrityError.sizeMismatch
            }

            guard let expectedChecksum, !expectedChecksum.isEmpty else { return }
            let handle = try FileHandle(forReadingFrom: localURL)
            defer { try? handle.close() }
            var hasher = Insecure.MD5()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let actualChecksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
                throw DownloadIntegrityError.checksumMismatch
            }
        }.value
    }

    private func syncCopyQueueNow(
        googleUserID: String,
        context: ModelContext
    ) async throws -> CopyQueueSyncResult {
        let sheetID = globalCopyQueueSheetID
        let resourceKey = globalCopyQueueResourceKey
        guard !sheetID.isEmpty else { throw CopyQueueError.sheetMissing }
        let key = copyQueueSyncKey(
            sheetID: sheetID,
            resourceKey: resourceKey,
            googleUserID: googleUserID
        )
        return try await serializedCopyQueueSync(key: key) {
            try await self.copyQueueService.syncGlobal(
                sheetID: sheetID,
                resourceKey: resourceKey,
                googleUserID: googleUserID,
                context: context
            )
        }
    }

    private func serializedCopyQueueSync(
        key: String,
        operation: @escaping @MainActor () async throws -> CopyQueueSyncResult
    ) async throws -> CopyQueueSyncResult {
        if let activeTask = copyQueueSyncTask {
            if copyQueueSyncTaskKey == key {
                return try await activeTask.value
            }
            _ = try? await activeTask.value
        }

        let token = UUID()
        let task = Task { @MainActor in
            try await operation()
        }
        copyQueueSyncTask = task
        copyQueueSyncTaskKey = key
        copyQueueSyncTaskToken = token
        defer {
            if copyQueueSyncTaskToken == token {
                copyQueueSyncTask = nil
                copyQueueSyncTaskKey = nil
                copyQueueSyncTaskToken = nil
            }
        }
        return try await task.value
    }

    private func copyQueueSyncKey(
        sheetID: String,
        resourceKey: String?,
        googleUserID: String
    ) -> String {
        "\(googleUserID)|\(sheetID)|\(resourceKey ?? "")"
    }

    private func applyCopyQueueConfiguration(from backup: TrackerBackup) {
        guard let sheetID = backup.globalCopyQueueSheetID, !sheetID.isEmpty else { return }
        globalCopyQueueLink = backup.globalCopyQueueLink?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        globalCopyQueueSheetID = sheetID
        globalCopyQueueResourceKey = backup.globalCopyQueueResourceKey
        persistActiveCopyQueueConfiguration()
    }

    @discardableResult
    private func activateDriveSourceConfiguration(
        for googleUserID: String,
        context: ModelContext
    ) throws -> Bool {
        let currentSource = try context.fetch(FetchDescriptor<DriveSource>())
            .filter { $0.googleUserID == googleUserID && $0.isEnabled }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        rootLink = currentSource?.rootLink ?? ""
        rootFolderID = currentSource?.rootFolderID ?? ""
        rootResourceKey = currentSource?.rootResourceKey
        return currentSource != nil
    }

    private func activateCopyQueueConfiguration(for googleUserID: String) {
        activeCopyQueueGoogleUserID = googleUserID
        if
            let data = defaults.data(forKey: copyQueueConnectionKey(for: googleUserID)),
            let connection = try? JSONDecoder().decode(CopyQueueConnection.self, from: data)
        {
            globalCopyQueueLink = connection.link
            globalCopyQueueSheetID = connection.sheetID
            globalCopyQueueResourceKey = connection.resourceKey
            globalCopyQueueLastSyncedAt = connection.lastSyncedAt
            globalCopyQueueIssue = nil
            return
        }

        if
            defaults.string(forKey: Keys.legacyCopyQueueOwner) == nil,
            !globalCopyQueueSheetID.isEmpty
        {
            defaults.set(googleUserID, forKey: Keys.legacyCopyQueueOwner)
            persistActiveCopyQueueConfiguration()
            return
        }

        globalCopyQueueLink = ""
        globalCopyQueueSheetID = ""
        globalCopyQueueResourceKey = nil
        globalCopyQueueLastSyncedAt = nil
        globalCopyQueueIssue = nil
    }

    private func persistActiveCopyQueueConfiguration() {
        guard let googleUserID = activeCopyQueueGoogleUserID else { return }
        let connection = CopyQueueConnection(
            link: globalCopyQueueLink,
            sheetID: globalCopyQueueSheetID,
            resourceKey: globalCopyQueueResourceKey,
            lastSyncedAt: globalCopyQueueLastSyncedAt
        )
        guard let data = try? JSONEncoder().encode(connection) else { return }
        defaults.set(data, forKey: copyQueueConnectionKey(for: googleUserID))
        var userIDs = Set(defaults.stringArray(forKey: Keys.copyQueueConnectionUserIDs) ?? [])
        userIDs.insert(googleUserID)
        defaults.set(Array(userIDs), forKey: Keys.copyQueueConnectionUserIDs)
    }

    private func clearStoredCopyQueueConfigurations() {
        let userIDs = defaults.stringArray(forKey: Keys.copyQueueConnectionUserIDs) ?? []
        for userID in userIDs {
            defaults.removeObject(forKey: copyQueueConnectionKey(for: userID))
        }
        defaults.removeObject(forKey: Keys.copyQueueConnectionUserIDs)
        defaults.removeObject(forKey: Keys.legacyCopyQueueOwner)
        activeCopyQueueGoogleUserID = auth.userID
    }

    private func copyQueueConnectionKey(for googleUserID: String) -> String {
        "\(Keys.copyQueueConnectionPrefix)\(googleUserID)"
    }

    private func perform(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            guard !isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private enum Keys {
        static let rootLink = "rootLink"
        static let rootFolderID = "rootFolderID"
        static let rootResourceKey = "rootResourceKey"
        static let lastSyncAt = "lastSyncAt"
        static let analyticsSnapshot = "analyticsSnapshotV1"
        static let requestedResetVerified = "requestedResetVerifiedV2"
        static let suppressAutomaticRestore = "suppressAutomaticRestore"
        static let globalCopyQueueLink = "globalCopyQueueLink"
        static let globalCopyQueueSheetID = "globalCopyQueueSheetID"
        static let globalCopyQueueResourceKey = "globalCopyQueueResourceKey"
        static let globalCopyQueueLastSyncedAt = "globalCopyQueueLastSyncedAt"
        static let legacyCopyQueueOwner = "globalCopyQueueLegacyOwner"
        static let copyQueueConnectionPrefix = "globalCopyQueueConnection."
        static let copyQueueConnectionUserIDs = "globalCopyQueueConnectionUserIDs"
    }

    private struct CopyQueueConnection: Codable {
        let link: String
        let sheetID: String
        let resourceKey: String?
        let lastSyncedAt: Date?
    }
}

enum DriveAssociationError: LocalizedError {
    case missingNames
    case wrongGoogleAccount(String?)
    case videoMissing

    var errorDescription: String? {
        switch self {
        case .missingNames:
            "Enter both the account name and the tracked folder name."
        case let .wrongGoogleAccount(email):
            "Connect \(email ?? "the Google account for this folder") before previewing this video."
        case .videoMissing:
            "This video is no longer available in the tracked Google Drive folder."
        }
    }
}

enum DownloadIntegrityError: LocalizedError {
    case sizeMismatch
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .sizeMismatch:
            "The downloaded file size does not match the original Google Drive video. Please retry."
        case .checksumMismatch:
            "The downloaded file failed the original-file checksum check. Please retry."
        }
    }
}
