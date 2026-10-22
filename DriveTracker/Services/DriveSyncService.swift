import Foundation
import SwiftData

struct DriveSyncResult: Equatable {
    let accountsFound: Int
    let videosFound: Int
    let newVideos: Int
    var folderIDs: Set<String> = []
    var visitedFolderIDs: Set<String> = []
    var folderPaths: [String: String] = [:]
}

@MainActor
protocol DriveMetadataAPI {
    var currentUserID: String? { get }
    func item(id: String, resourceKey: String?) async throws -> DriveItem
    func listChildren(of folderID: String, folderResourceKey: String?) async throws -> [DriveItem]
    func exportCaptionDocument(id: String, resourceKey: String?) async throws -> String
}

extension DriveMetadataAPI {
    func exportCaptionDocument(id: String, resourceKey: String?) async throws -> String {
        throw DriveAPIError.invalidResponse
    }
}
extension DriveAPIClient: DriveMetadataAPI {}

@MainActor
final class DriveSyncService {
    private let api: any DriveMetadataAPI
    private var scanTasks: [String: Task<DriveSyncResult, Error>] = [:]

    init(api: any DriveMetadataAPI) {
        self.api = api
    }

    func sync(
        root: DriveFolderReference,
        account: TikTokAccount,
        context: ModelContext
    ) async throws -> DriveSyncResult {
        let key = "\(account.googleUserID)|\(root.folderID)"
        let task: Task<DriveSyncResult, Error>
        if let existing = scanTasks[key] {
            task = existing
        } else {
            task = Task { @MainActor in
                defer { self.scanTasks.removeValue(forKey: key) }
                return try await self.reconcile(root: root, account: account, context: context)
            }
            scanTasks[key] = task
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }

    private func reconcile(root: DriveFolderReference, account: TikTokAccount, context: ModelContext) async throws -> DriveSyncResult {
        try Task.checkCancellation()
        // Drive is queried first, then reconciled against the account's existing
        // records. This makes missing files detectable without deleting local
        // history or resetting an in-progress assignment.
        let rootItem = try await api.item(id: root.folderID, resourceKey: root.resourceKey)
        guard rootItem.isFolder else { throw DriveLinkError.invalidFolderLink }

        let googleUserID = account.googleUserID
        let accountFolderID = root.folderID
        let accountVideos = try context.fetch(
            FetchDescriptor<VideoAsset>(
                predicate: #Predicate<VideoAsset> { video in
                    video.googleUserID == googleUserID &&
                    video.accountFolderID == accountFolderID
                }
            )
        )
        let existingVideoByKey = Dictionary(
            accountVideos.map { ($0.identityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let scanTime = Date.now
        var seenVideoKeys = Set<String>()
        var newVideos = 0
        var hasPersistentChanges = false

        var visitedFolders = Set<String>()
        var documents: [DriveItem] = []
        var folderPaths: [String: String] = [:]
        // Keep a visited set because shared Drive folder structures can expose
        // the same folder more than once; recursion must never loop forever.
        let locatedVideos = try await recursivelyListVideos(
            folderID: root.folderID,
            resourceKey: root.resourceKey,
            path: account.folderName,
            visitedFolders: &visitedFolders, documents: &documents, folderPaths: &folderPaths
        )

        try Task.checkCancellation()
        guard api.currentUserID == googleUserID, account.modelContext != nil,
              account.googleUserID == googleUserID, account.driveFolderID == root.folderID else {
            throw GoogleAuthError.notSignedIn
        }

        for (index, located) in locatedVideos.enumerated() {
            try Task.checkCancellation()
            // Large folders should never monopolize the main actor while the
            // user is scrolling or changing tabs.
            if index > 0, index.isMultiple(of: 20) {
                await Task.yield()
                try Task.checkCancellation()
                guard api.currentUserID == googleUserID, account.modelContext != nil,
                      account.googleUserID == googleUserID, account.driveFolderID == root.folderID else {
                    throw GoogleAuthError.notSignedIn
                }
            }
            let item = located.item
            let key = VideoAsset.makeIdentityKey(
                googleUserID: account.googleUserID,
                accountFolderID: root.folderID,
                driveFileID: item.effectiveID
            )
            guard seenVideoKeys.insert(key).inserted else { continue }
            if let video = existingVideoByKey[key] {
                let canDownload = item.capabilities?.canDownload ?? true
                let metadataChanged =
                    video.name != item.name ||
                    video.folderPath != located.folderPath ||
                    video.mimeType != item.effectiveMimeType ||
                    video.resourceKey != item.effectiveResourceKey ||
                    video.size != item.sizeValue ||
                    video.checksum != item.md5Checksum ||
                    video.driveModifiedAt != item.modifiedDate ||
                    video.thumbnailLink != item.thumbnailLink ||
                    video.isMissingFromDrive ||
                    video.canDownload != canDownload ||
                    video.account?.id != account.id
                let descriptionChanged = video.workspaceMediaID == nil &&
                    video.uploadTextSyncState == .synced &&
                    item.description != nil && video.uploadText != item.description
                if descriptionChanged { video.uploadText = item.description ?? "" }
                let refreshLastSeen =
                    scanTime.timeIntervalSince(video.lastSeenAt) >= 86_400

                if metadataChanged || descriptionChanged || refreshLastSeen {
                    video.name = item.name
                    video.folderPath = located.folderPath
                    video.mimeType = item.effectiveMimeType
                    video.resourceKey = item.effectiveResourceKey
                    video.size = item.sizeValue
                    video.checksum = item.md5Checksum
                    video.driveModifiedAt = item.modifiedDate
                    video.thumbnailLink = item.thumbnailLink
                    video.lastSeenAt = scanTime
                    video.isMissingFromDrive = false
                    video.canDownload = canDownload
                    video.account = account
                    if metadataChanged {
                        video.updatedAt = scanTime
                    }
                    hasPersistentChanges = true
                }
            } else {
                let video = VideoAsset(
                    driveFileID: item.effectiveID,
                    accountFolderID: root.folderID,
                    googleUserID: account.googleUserID,
                    name: item.name,
                    folderPath: located.folderPath,
                    mimeType: item.effectiveMimeType,
                    resourceKey: item.effectiveResourceKey,
                    size: item.sizeValue,
                    checksum: item.md5Checksum,
                    driveModifiedAt: item.modifiedDate,
                    thumbnailLink: item.thumbnailLink,
                    canDownload: item.capabilities?.canDownload ?? true,
                    account: account
                )
                video.uploadText = item.description ?? ""
                context.insert(video)
                newVideos += 1
                hasPersistentChanges = true
            }
        }

        await syncCaptions(documents: documents, account: account)
        try Task.checkCancellation()
        guard api.currentUserID == googleUserID else { throw GoogleAuthError.notSignedIn }

        // Anything previously known but absent from this complete scan is
        // marked missing. We retain it so old status events and assignments remain
        // inspectable and can recover if the file returns to Drive.
        for video in accountVideos where
            !seenVideoKeys.contains(video.identityKey) && !video.isMissingFromDrive
        {
            video.isMissingFromDrive = true
            video.updatedAt = scanTime
            hasPersistentChanges = true
        }

        if account.isMissingFromDrive {
            account.isMissingFromDrive = false
            account.updatedAt = scanTime
            hasPersistentChanges = true
        }
        // An unchanged scan should not write the whole context and invalidate
        // every SwiftData-backed screen. This was the largest recurring hitch.
        if hasPersistentChanges || context.hasChanges {
            try context.save()
        }
        return DriveSyncResult(
            accountsFound: 1,
            videosFound: locatedVideos.count,
            newVideos: newVideos,
            folderIDs: visitedFolders,
            visitedFolderIDs: visitedFolders,
            folderPaths: folderPaths
        )
    }

    private func syncCaptions(documents: [DriveItem], account: TikTokAccount) async {
        let byID: [String: DriveItem] = Dictionary(documents.map { ($0.effectiveID, $0) }, uniquingKeysWith: { first, _ in first })
        let unique: [DriveItem] = byID.values.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.effectiveID < rhs.effectiveID }
            return lhs.name < rhs.name
        }
        let candidates = unique.map { CaptionDocumentChoice(id: $0.effectiveID, name: $0.name) }
        let choicesJSON = (try? JSONEncoder().encode(candidates)).flatMap { String(data: $0, encoding: .utf8) }
        if account.captionDocumentChoices != choicesJSON { account.captionDocumentChoices = choicesJSON }
        let selected: DriveItem?
        if let id = account.captionDocumentID {
            selected = unique.first { $0.effectiveID == id }
        } else {
            selected = unique.count == 1 ? unique.first : nil
        }
        guard let selected else {
            let issue = unique.count > 1
                ? "Multiple documents found. Choose the metadata document in account settings."
                : "No metadata document found. Add a Google Docs document to this account folder."
            if account.captionDocumentIssue != issue { account.captionDocumentIssue = issue }
            if account.captionDocumentText != nil { account.captionDocumentText = nil }
            return
        }
        guard account.captionDocumentText == nil || account.captionDocumentID != selected.effectiveID ||
              selected.modifiedDate == nil || account.captionDocumentModifiedAt != selected.modifiedDate else {
            if account.captionDocumentIssue != nil { account.captionDocumentIssue = nil }
            return
        }
        do {
            let text = try await api.exportCaptionDocument(id: selected.effectiveID, resourceKey: selected.effectiveResourceKey)
            try Task.checkCancellation()
            guard account.modelContext != nil, !account.isDeleted, api.currentUserID == account.googleUserID else { return }
            account.captionDocumentID = selected.effectiveID
            account.captionDocumentName = selected.name
            account.captionDocumentText = text
            account.captionDocumentModifiedAt = selected.modifiedDate
            account.captionDocumentSyncedAt = .now
            account.captionDocumentIssue = nil
        } catch {
            account.captionDocumentIssue = "Metadata refresh failed. Sync this folder to retry."
        }
    }

    private struct LocatedVideo {
        let item: DriveItem
        let folderPath: String
    }

    private func recursivelyListVideos(
        folderID: String,
        resourceKey: String?,
        path: String,
        visitedFolders: inout Set<String>,
        documents: inout [DriveItem],
        folderPaths: inout [String: String]
    ) async throws -> [LocatedVideo] {
        guard visitedFolders.insert(folderID).inserted else { return [] }
        folderPaths[folderID] = path
        let children = try await api.listChildren(of: folderID, folderResourceKey: resourceKey)
        documents.append(contentsOf: children.filter { $0.effectiveMimeType == "application/vnd.google-apps.document" })
        var videos = children.filter(\.isMedia).map {
            LocatedVideo(item: $0, folderPath: path)
        }
        for folder in children where folder.isFolder {
            videos.append(
                contentsOf: try await recursivelyListVideos(
                    folderID: folder.effectiveID,
                    resourceKey: folder.effectiveResourceKey,
                    path: "\(path) / \(folder.name)",
                    visitedFolders: &visitedFolders, documents: &documents, folderPaths: &folderPaths
                )
            )
        }
        return videos
    }
}
