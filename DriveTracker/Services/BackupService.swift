import Foundation
import SwiftData

struct TrackerBackup: Codable {
    static let currentSchemaVersion = 6

    let schemaVersion: Int
    let revision: Int
    let createdAt: Date
    let rootLink: String
    let rootFolderID: String
    let rootResourceKey: String?
    let googleUserID: String
    let globalCopyQueueLink: String?
    let globalCopyQueueSheetID: String?
    let globalCopyQueueResourceKey: String?
    let sources: [SourceRecord]?
    let accounts: [AccountRecord]
    let videos: [VideoRecord]
    let assignments: [AssignmentRecord]
    let events: [EventRecord]
    let copyEntries: [CopyEntryRecord]?
    let copyEvents: [CopyEventRecord]?

    struct SourceRecord: Codable {
        let id: UUID
        let googleUserID: String
        let googleEmail: String
        let rootFolderID: String
        let rootResourceKey: String?
        let rootLink: String
        let displayName: String
        let isEnabled: Bool
        let createdAt: Date
        let lastSyncedAt: Date?
    }

    struct AccountRecord: Codable {
        let id: UUID
        let driveFolderID: String
        let folderResourceKey: String?
        let folderName: String
        let displayName: String
        let dailyQuota: Int
        let isPaused: Bool
        let sortOrder: Int
        let createdAt: Date
        let updatedAt: Date
        let isMissingFromDrive: Bool
        let sourceID: UUID?
        let googleEmail: String?
        let isConfigured: Bool?
        let iconSymbol: String?
        let iconColorHex: String?
        let copyQueueFolderID: String?
        let copyQueueSheetID: String?
        let copyQueueSheetResourceKey: String?
        let copyQueueLastSyncedAt: Date?
        let copyQueueIssue: String?
    }

    struct VideoRecord: Codable {
        let identityKey: String
        let accountID: UUID
        let driveFileID: String
        let accountFolderID: String
        let resourceKey: String?
        let name: String
        let folderPath: String?
        let mimeType: String
        let size: Int64?
        let checksum: String?
        let driveModifiedAt: Date?
        let thumbnailLink: String?
        let lastSeenAt: Date
        let isMissingFromDrive: Bool
        let canDownload: Bool
        let downloadedAt: Date?
        let uploadedAt: Date?
        let photoLocalIdentifier: String?
        let isMissingFromPhotos: Bool?
        let createdAt: Date
        let updatedAt: Date
    }

    struct AssignmentRecord: Codable {
        let id: UUID
        let accountID: UUID
        let videoIdentityKey: String
        let localDayKey: String
        let slot: Int
        let assignedAt: Date
        let isActive: Bool
        let completedAt: Date?
        let updatedAt: Date
    }

    struct EventRecord: Codable {
        let id: UUID
        let videoIdentityKey: String
        let kindRawValue: String
        let timestamp: Date
        let detail: String?
        let accountName: String
        let driveFileID: String
        let videoName: String
    }

    struct CopyEntryRecord: Codable {
        let identityKey: String
        let accountID: UUID?
        let googleUserID: String
        let accountFolderID: String
        let sourceSheetID: String
        let contentHash: String
        let sourceRow: Int
        let content: String
        let driveModifiedAt: Date?
        let lastSeenAt: Date
        let isMissingFromDrive: Bool
        let copiedAt: Date?
        let copyCount: Int
        let createdAt: Date
        let updatedAt: Date
    }

    struct CopyEventRecord: Codable {
        let id: UUID
        let entryIdentityKey: String
        let kindRawValue: String
        let timestamp: Date
        let detail: String?
        let accountName: String
        let contentPreview: String
    }
}

enum BackupError: LocalizedError {
    case unsupportedSchema
    case wrongGoogleAccount

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            "The Drive backup was created by a newer version of Drive Tracker."
        case .wrongGoogleAccount:
            "The Drive backup belongs to a different Google account."
        }
    }
}

@MainActor
final class BackupService {
    static let fileName = "drive_tracker_backup_v1.json"

    private let api: DriveAPIClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let defaults: UserDefaults

    init(api: DriveAPIClient, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func save(
        context: ModelContext,
        rootLink: String,
        rootFolderID: String,
        rootResourceKey: String?,
        googleUserID: String,
        globalCopyQueueLink: String = "",
        globalCopyQueueSheetID: String = "",
        globalCopyQueueResourceKey: String? = nil
    ) async throws {
        guard !rootFolderID.isEmpty || !globalCopyQueueSheetID.isEmpty else { return }
        let currentRevision = defaults.integer(forKey: "backupRevision") + 1
        let backup = try makeBackup(
            revision: currentRevision,
            context: context,
            rootLink: rootLink,
            rootFolderID: rootFolderID,
            rootResourceKey: rootResourceKey,
            googleUserID: googleUserID,
            globalCopyQueueLink: globalCopyQueueLink,
            globalCopyQueueSheetID: globalCopyQueueSheetID,
            globalCopyQueueResourceKey: globalCopyQueueResourceKey
        )
        let data = try encoder.encode(backup)
        if let existing = try await api.listAppDataFile(named: Self.fileName) {
            try await api.updateAppData(id: existing.id, data: data)
        } else {
            try await api.createAppData(name: Self.fileName, data: data)
        }
        defaults.set(currentRevision, forKey: "backupRevision")
        defaults.set(false, forKey: "backupDirty")
        defaults.set(Date.now, forKey: "lastBackupAt")
    }

    func restoreIfLocalStoreIsEmpty(
        context: ModelContext,
        expectedGoogleUserID: String
    ) async throws -> TrackerBackup? {
        let localAccounts = try context.fetch(FetchDescriptor<TikTokAccount>())
        let localSources = try context.fetch(FetchDescriptor<DriveSource>())
        let localVideos = try context.fetch(FetchDescriptor<VideoAsset>())
        let localCopyEntries = try context.fetch(FetchDescriptor<CopyEntry>())
        let hasLocalDataForUser =
            localAccounts.contains { $0.googleUserID == expectedGoogleUserID } ||
            localSources.contains { $0.googleUserID == expectedGoogleUserID } ||
            localVideos.contains { $0.googleUserID == expectedGoogleUserID } ||
            localCopyEntries.contains { $0.googleUserID == expectedGoogleUserID }
        guard !hasLocalDataForUser else {
            return nil
        }
        guard let file = try await api.listAppDataFile(named: Self.fileName) else {
            return nil
        }
        let data = try await api.downloadAppData(id: file.id)
        let backup = try decoder.decode(TrackerBackup.self, from: data)
        guard backup.schemaVersion <= TrackerBackup.currentSchemaVersion else {
            throw BackupError.unsupportedSchema
        }
        guard backup.googleUserID == expectedGoogleUserID else {
            throw BackupError.wrongGoogleAccount
        }
        try restore(backup, context: context)
        defaults.set(backup.revision, forKey: "backupRevision")
        defaults.set(Date.now, forKey: "lastBackupAt")
        return backup
    }

    func restoreFromDriveBackup(
        context: ModelContext,
        expectedGoogleUserID: String
    ) async throws -> TrackerBackup? {
        guard let file = try await api.listAppDataFile(named: Self.fileName) else {
            return nil
        }
        let data = try await api.downloadAppData(id: file.id)
        let backup = try decoder.decode(TrackerBackup.self, from: data)
        guard backup.schemaVersion <= TrackerBackup.currentSchemaVersion else {
            throw BackupError.unsupportedSchema
        }
        guard backup.googleUserID == expectedGoogleUserID else {
            throw BackupError.wrongGoogleAccount
        }
        try restore(backup, context: context)
        defaults.set(backup.revision, forKey: "backupRevision")
        defaults.set(Date.now, forKey: "lastBackupAt")
        return backup
    }

    func deleteRemoteBackup() async throws {
        guard let file = try await api.listAppDataFile(named: Self.fileName) else { return }
        try await api.deleteFile(id: file.id)
        defaults.removeObject(forKey: "backupRevision")
        defaults.removeObject(forKey: "lastBackupAt")
        defaults.set(false, forKey: "backupDirty")
    }

    func markDirty() {
        defaults.set(true, forKey: "backupDirty")
    }

    var lastBackupAt: Date? {
        defaults.object(forKey: "lastBackupAt") as? Date
    }

    func makeBackup(
        revision: Int,
        context: ModelContext,
        rootLink: String,
        rootFolderID: String,
        rootResourceKey: String?,
        googleUserID: String,
        globalCopyQueueLink: String = "",
        globalCopyQueueSheetID: String = "",
        globalCopyQueueResourceKey: String? = nil
    ) throws -> TrackerBackup {
        let accounts = try context.fetch(FetchDescriptor<TikTokAccount>())
            .filter { $0.googleUserID == googleUserID }
        let sources = try context.fetch(FetchDescriptor<DriveSource>())
            .filter { $0.googleUserID == googleUserID }
        let accountIDs = Set(accounts.map(\.id))
        let videos = try context.fetch(FetchDescriptor<VideoAsset>())
            .filter { accountIDs.contains($0.account?.id ?? UUID()) }
        let videoKeys = Set(videos.map(\.identityKey))
        let assignments = try context.fetch(FetchDescriptor<DailyAssignment>())
            .filter { videoKeys.contains($0.video?.identityKey ?? "") }
        let events = try context.fetch(FetchDescriptor<StatusEvent>())
            .filter { videoKeys.contains($0.video?.identityKey ?? "") }
        let copyEntries = try context.fetch(FetchDescriptor<CopyEntry>())
            .filter { $0.googleUserID == googleUserID }
        let copyEntryKeys = Set(copyEntries.map(\.identityKey))
        let copyEvents = try context.fetch(FetchDescriptor<CopyEvent>())
            .filter { copyEntryKeys.contains($0.entry?.identityKey ?? "") }

        return TrackerBackup(
            schemaVersion: TrackerBackup.currentSchemaVersion,
            revision: revision,
            createdAt: .now,
            rootLink: rootLink,
            rootFolderID: rootFolderID,
            rootResourceKey: rootResourceKey,
            googleUserID: googleUserID,
            globalCopyQueueLink: globalCopyQueueLink,
            globalCopyQueueSheetID: globalCopyQueueSheetID,
            globalCopyQueueResourceKey: globalCopyQueueResourceKey,
            sources: sources.map {
                .init(
                    id: $0.id,
                    googleUserID: $0.googleUserID,
                    googleEmail: $0.googleEmail,
                    rootFolderID: $0.rootFolderID,
                    rootResourceKey: $0.rootResourceKey,
                    rootLink: $0.rootLink,
                    displayName: $0.displayName,
                    isEnabled: $0.isEnabled,
                    createdAt: $0.createdAt,
                    lastSyncedAt: $0.lastSyncedAt
                )
            },
            accounts: accounts.map {
                .init(
                    id: $0.id,
                    driveFolderID: $0.driveFolderID,
                    folderResourceKey: $0.folderResourceKey,
                    folderName: $0.folderName,
                    displayName: $0.displayName,
                    dailyQuota: $0.dailyQuota,
                    isPaused: $0.isPaused,
                    sortOrder: $0.sortOrder,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    isMissingFromDrive: $0.isMissingFromDrive,
                    sourceID: $0.sourceID,
                    googleEmail: $0.googleEmail,
                    isConfigured: $0.isConfigured,
                    iconSymbol: $0.iconSymbol,
                    iconColorHex: $0.iconColorHex,
                    copyQueueFolderID: $0.copyQueueFolderID,
                    copyQueueSheetID: $0.copyQueueSheetID,
                    copyQueueSheetResourceKey: $0.copyQueueSheetResourceKey,
                    copyQueueLastSyncedAt: $0.copyQueueLastSyncedAt,
                    copyQueueIssue: $0.copyQueueIssue
                )
            },
            videos: videos.compactMap { video in
                guard let accountID = video.account?.id else { return nil }
                return .init(
                    identityKey: video.identityKey,
                    accountID: accountID,
                    driveFileID: video.driveFileID,
                    accountFolderID: video.accountFolderID,
                    resourceKey: video.resourceKey,
                    name: video.name,
                    folderPath: video.folderPath,
                    mimeType: video.mimeType,
                    size: video.size,
                    checksum: video.checksum,
                    driveModifiedAt: video.driveModifiedAt,
                    thumbnailLink: video.thumbnailLink,
                    lastSeenAt: video.lastSeenAt,
                    isMissingFromDrive: video.isMissingFromDrive,
                    canDownload: video.canDownload,
                    downloadedAt: video.downloadedAt,
                    uploadedAt: video.uploadedAt,
                    photoLocalIdentifier: video.photoLocalIdentifier,
                    isMissingFromPhotos: video.isMissingFromPhotos,
                    createdAt: video.createdAt,
                    updatedAt: video.updatedAt
                )
            },
            assignments: assignments.compactMap { assignment in
                guard
                    let accountID = assignment.account?.id,
                    let videoKey = assignment.video?.identityKey
                else { return nil }
                return .init(
                    id: assignment.id,
                    accountID: accountID,
                    videoIdentityKey: videoKey,
                    localDayKey: assignment.localDayKey,
                    slot: assignment.slot,
                    assignedAt: assignment.assignedAt,
                    isActive: assignment.isActive,
                    completedAt: assignment.completedAt,
                    updatedAt: assignment.updatedAt
                )
            },
            events: events.compactMap { event in
                guard let videoKey = event.video?.identityKey else { return nil }
                return .init(
                    id: event.id,
                    videoIdentityKey: videoKey,
                    kindRawValue: event.kindRawValue,
                    timestamp: event.timestamp,
                    detail: event.detail,
                    accountName: event.accountName,
                    driveFileID: event.driveFileID,
                    videoName: event.videoName
                )
            },
            copyEntries: copyEntries.map { entry in
                return .init(
                    identityKey: entry.identityKey,
                    accountID: entry.account?.id,
                    googleUserID: entry.googleUserID,
                    accountFolderID: entry.accountFolderID,
                    sourceSheetID: entry.sourceSheetID,
                    contentHash: entry.contentHash,
                    sourceRow: entry.sourceRow,
                    content: entry.content,
                    driveModifiedAt: entry.driveModifiedAt,
                    lastSeenAt: entry.lastSeenAt,
                    isMissingFromDrive: entry.isMissingFromDrive,
                    copiedAt: entry.copiedAt,
                    copyCount: entry.copyCount,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt
                )
            },
            copyEvents: copyEvents.compactMap { event in
                guard let entryKey = event.entry?.identityKey else { return nil }
                return .init(
                    id: event.id,
                    entryIdentityKey: entryKey,
                    kindRawValue: event.kindRawValue,
                    timestamp: event.timestamp,
                    detail: event.detail,
                    accountName: event.accountName,
                    contentPreview: event.contentPreview
                )
            }
        )
    }

    func restore(_ backup: TrackerBackup, context: ModelContext) throws {
        for record in backup.sources ?? [] {
            let source = DriveSource(
                id: record.id,
                googleUserID: record.googleUserID,
                googleEmail: record.googleEmail,
                rootFolderID: record.rootFolderID,
                rootResourceKey: record.rootResourceKey,
                rootLink: record.rootLink,
                displayName: record.displayName,
                isEnabled: record.isEnabled
            )
            source.createdAt = record.createdAt
            source.lastSyncedAt = record.lastSyncedAt
            context.insert(source)
        }

        var accountByID: [UUID: TikTokAccount] = [:]
        for record in backup.accounts {
            let account = TikTokAccount(
                id: record.id,
                googleUserID: backup.googleUserID,
                driveFolderID: record.driveFolderID,
                folderResourceKey: record.folderResourceKey,
                folderName: record.folderName,
                displayName: record.displayName,
                dailyQuota: record.dailyQuota,
                isPaused: record.isPaused,
                sortOrder: record.sortOrder,
                sourceID: record.sourceID,
                googleEmail: record.googleEmail,
                isConfigured: record.isConfigured ?? true,
                iconSymbol: record.iconSymbol,
                iconColorHex: record.iconColorHex
            )
            account.createdAt = record.createdAt
            account.updatedAt = record.updatedAt
            account.isMissingFromDrive = record.isMissingFromDrive
            account.copyQueueFolderID = record.copyQueueFolderID
            account.copyQueueSheetID = record.copyQueueSheetID
            account.copyQueueSheetResourceKey = record.copyQueueSheetResourceKey
            account.copyQueueLastSyncedAt = record.copyQueueLastSyncedAt
            account.copyQueueIssue = record.copyQueueIssue
            context.insert(account)
            accountByID[record.id] = account
        }

        var videoByKey: [String: VideoAsset] = [:]
        for record in backup.videos {
            guard let account = accountByID[record.accountID] else { continue }
            let video = VideoAsset(
                driveFileID: record.driveFileID,
                accountFolderID: record.accountFolderID,
                googleUserID: backup.googleUserID,
                name: record.name,
                folderPath: record.folderPath ?? account.folderName,
                mimeType: record.mimeType,
                resourceKey: record.resourceKey,
                size: record.size,
                checksum: record.checksum,
                driveModifiedAt: record.driveModifiedAt,
                thumbnailLink: record.thumbnailLink,
                canDownload: record.canDownload,
                account: account
            )
            video.lastSeenAt = record.lastSeenAt
            video.isMissingFromDrive = record.isMissingFromDrive
            video.downloadedAt = record.downloadedAt
            video.uploadedAt = record.uploadedAt
            video.photoLocalIdentifier = record.photoLocalIdentifier
            video.isMissingFromPhotos = record.isMissingFromPhotos ?? false
            video.createdAt = record.createdAt
            video.updatedAt = record.updatedAt
            context.insert(video)
            videoByKey[record.identityKey] = video
        }

        for record in backup.assignments {
            guard
                let account = accountByID[record.accountID],
                let video = videoByKey[record.videoIdentityKey]
            else { continue }
            let assignment = DailyAssignment(
                id: record.id,
                localDayKey: record.localDayKey,
                slot: record.slot,
                assignedAt: record.assignedAt,
                account: account,
                video: video
            )
            assignment.isActive = record.isActive
            assignment.completedAt = record.completedAt
            assignment.updatedAt = record.updatedAt
            context.insert(assignment)
        }

        for record in backup.events {
            guard let video = videoByKey[record.videoIdentityKey] else { continue }
            let event = StatusEvent(
                id: record.id,
                kind: StatusEventKind(rawValue: record.kindRawValue) ?? .reset,
                timestamp: record.timestamp,
                detail: record.detail,
                accountName: record.accountName,
                driveFileID: record.driveFileID,
                videoName: record.videoName,
                video: video
            )
            context.insert(event)
        }

        var copyEntryByKey: [String: CopyEntry] = [:]
        for record in backup.copyEntries ?? [] {
            let account = record.accountID.flatMap { accountByID[$0] }
            let entry = CopyEntry(
                googleUserID: record.googleUserID,
                accountFolderID: record.accountFolderID,
                sourceSheetID: record.sourceSheetID,
                contentHash: record.contentHash,
                sourceRow: record.sourceRow,
                content: record.content,
                driveModifiedAt: record.driveModifiedAt,
                account: account
            )
            entry.lastSeenAt = record.lastSeenAt
            entry.isMissingFromDrive = record.isMissingFromDrive
            entry.copiedAt = record.copiedAt
            entry.copyCount = record.copyCount
            entry.createdAt = record.createdAt
            entry.updatedAt = record.updatedAt
            context.insert(entry)
            copyEntryByKey[record.identityKey] = entry
        }

        for record in backup.copyEvents ?? [] {
            guard let entry = copyEntryByKey[record.entryIdentityKey] else { continue }
            context.insert(
                CopyEvent(
                    id: record.id,
                    kind: CopyEventKind(rawValue: record.kindRawValue) ?? .copied,
                    timestamp: record.timestamp,
                    detail: record.detail,
                    accountName: record.accountName,
                    entryIdentityKey: entry.identityKey,
                    contentPreview: record.contentPreview,
                    entry: entry
                )
            )
        }
        try context.save()
    }
}
