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
    @Published var lastSyncAt: Date?
    @Published var downloadIdentity: String?
    @Published private(set) var reminderTimeZoneID: String

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
    private let photoLibrary = PhotoLibraryService()
    private let assignmentEngine = AssignmentEngine()
    private let backupService: BackupService
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private var backupTask: Task<Void, Never>?
    private var hasStarted = false
    private var lastAutomaticSyncAttempt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let auth = GoogleAuthService()
        let api = DriveAPIClient(auth: auth)
        self.auth = auth
        self.api = api
        self.syncService = DriveSyncService(api: api)
        self.downloads = DownloadCoordinator()
        let notifications = DownloadNotificationService(defaults: defaults)
        self.notifications = notifications
        self.reminderTimeZoneID = notifications.timeZoneID
        self.backupService = BackupService(api: api, defaults: defaults)
        self.rootLink = defaults.string(forKey: Keys.rootLink) ?? ""
        self.rootFolderID = defaults.string(forKey: Keys.rootFolderID) ?? ""
        self.rootResourceKey = defaults.string(forKey: Keys.rootResourceKey)
        self.lastSyncAt = defaults.object(forKey: Keys.lastSyncAt) as? Date
    }

    var hasRootFolder: Bool { !rootFolderID.isEmpty }
    var lastBackupAt: Date? { backupService.lastBackupAt }

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
        verifyKnownPhotoCopies(context: context)
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
                statusMessage = "Tracking history restored from Drive."
            }
            let hasSources = try context.fetchCount(FetchDescriptor<DriveSource>()) > 0
            if hasSources {
                await sync(context: context, announce: false)
            } else {
                try ensureToday(context: context)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn(context: ModelContext) async {
        await perform {
            try await auth.signIn()
            guard let userID = auth.userID else { throw GoogleAuthError.missingUserID }
            if !defaults.bool(forKey: Keys.suppressAutomaticRestore),
               let backup = try await backupService.restoreIfLocalStoreIsEmpty(
                context: context,
                expectedGoogleUserID: userID
            ) {
                rootLink = backup.rootLink
                rootFolderID = backup.rootFolderID
                rootResourceKey = backup.rootResourceKey
                statusMessage = "Tracking history restored from Drive."
                try ensureToday(context: context)
            }
        }
    }

    func switchGoogleAccount(hint: String? = nil, context: ModelContext) async {
        await perform {
            try await auth.switchAccount(hint: hint)
            guard let userID = auth.userID else { throw GoogleAuthError.missingUserID }
            if !defaults.bool(forKey: Keys.suppressAutomaticRestore),
               let backup = try await backupService.restoreIfLocalStoreIsEmpty(
                context: context,
                expectedGoogleUserID: userID
            ) {
                rootLink = backup.rootLink
                rootFolderID = backup.rootFolderID
                rootResourceKey = backup.rootResourceKey
                try ensureToday(context: context)
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
           Date.now.timeIntervalSince(lastAutomaticSyncAttempt) < 30 {
            return
        }
        guard
            let sourceCount = try? context.fetchCount(FetchDescriptor<DriveSource>()),
            sourceCount > 0
        else { return }
        lastAutomaticSyncAttempt = .now
        await sync(context: context, announce: false)
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
            statusMessage = "(changed) suggestion\(changed == 1 ? "" : "s") shuffled for (account.displayName)."
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

    func download(_ video: VideoAsset, context: ModelContext) async {
        downloadIdentity = video.identityKey
        do {
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
            statusMessage = "\(video.name) was downloaded and marked completed."
            scheduleBackup(context: context)
            await scheduleDownloadNotifications(context: context)
        } catch {
            try? assignmentEngine.markDownloadFailed(video, error: error, context: context)
            errorMessage = error.localizedDescription
        }
        downloadIdentity = nil
    }

    func redownload(_ video: VideoAsset, context: ModelContext) async {
        downloadIdentity = video.identityKey
        do {
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
            statusMessage = "\(video.name) was downloaded again."
            scheduleBackup(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
        downloadIdentity = nil
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
            statusMessage = "(video.name) was marked completed."
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
            if try context.fetchCount(FetchDescriptor<DriveSource>()) == 0 {
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
        let cacheKey = video.identityKey as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        guard
            auth.userID == video.googleUserID,
            !video.isMissingFromDrive,
            video.thumbnailLink != nil,
            let data = try? await api.thumbnailData(for: video),
            let image = UIImage(data: data)
        else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: cacheKey, cost: data.count)
        return image
    }

    func backupNow(context: ModelContext) async {
        guard auth.isSignedIn, let userID = auth.userID else { return }
        do {
            try await backupService.save(
                context: context,
                rootLink: rootLink,
                rootFolderID: rootFolderID,
                rootResourceKey: rootResourceKey,
                googleUserID: userID
            )
            objectWillChange.send()
        } catch {
            backupService.markDirty()
        }
    }

    func scheduleBackup(context: ModelContext) {
        backupService.markDirty()
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.backupNow(context: context)
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
            for assignment in try context.fetch(FetchDescriptor<DailyAssignment>()) {
                context.delete(assignment)
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
        // A source created by older builds may still point at several
        // automatically generated accounts. Once the user explicitly maps the
        // folder, detach those legacy mappings so this source syncs only the
        // chosen account.
        for other in allAccounts where other.sourceID == source.id && other.id != account.id {
            other.sourceID = nil
            other.updatedAt = .now
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
            statusMessage = "The video was downloaded and marked completed."
            scheduleBackup(context: context)
        } catch {
            errorMessage = "Background download recovery failed: \(error.localizedDescription)"
        }
    }

    private func verifyKnownPhotoCopies(context: ModelContext) {
        guard let videos = try? context.fetch(FetchDescriptor<VideoAsset>()) else { return }
        var changed = false
        for video in videos where video.downloadedAt != nil {
            guard
                let identifier = video.photoLocalIdentifier,
                let exists = photoLibrary.savedAssetExists(localIdentifier: identifier)
            else {
                continue
            }
            let missing = !exists
            if video.isMissingFromPhotos != missing {
                video.isMissingFromPhotos = missing
                video.updatedAt = .now
                changed = true
            }
        }
        if changed { try? context.save() }
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
        static let requestedResetVerified = "requestedResetVerifiedV2"
        static let suppressAutomaticRestore = "suppressAutomaticRestore"
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
