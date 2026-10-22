import Foundation
import SwiftData

struct DriveDeltaResult {
    var changed = false
    var newMediaCount = 0
    var affectedAccountIDs: Set<UUID> = []
    var accountsToScan: Set<UUID> = []
}

/// Applies file events without listing every account folder. Cursor ownership
/// remains in DriveChangeTracker, which retries this idempotent batch on failure.
@MainActor
final class DriveDeltaService {
    private struct Owner {
        let accountID: UUID
        let path: String
    }
    private var folderOwners: [String: Owner] = [:]
    private let api: any DriveMetadataAPI

    init(api: any DriveMetadataAPI) { self.api = api }

    func record(_ result: DriveSyncResult, account: TikTokAccount) {
        for (folderID, path) in result.folderPaths {
            folderOwners[key(account.googleUserID, folderID)] = Owner(accountID: account.id, path: path)
        }
    }

    private func key(_ user: String, _ folder: String) -> String { "\(user)|\(folder)" }

    func apply(_ changes: [DriveChange], userID: String, accounts: [TikTokAccount],
               context: ModelContext) async throws -> DriveDeltaResult {
        let active = accounts.filter { $0.modelContext != nil && !$0.isDeleted && $0.googleUserID == userID }
        let byID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for account in active {
            folderOwners[key(userID, account.driveFolderID)] = Owner(accountID: account.id, path: account.folderName)
        }
        var prepared: [(DriveChange, Owner?)] = []
        // Resolve ancestry before mutating persistent records. Network errors
        // leave the cursor and the stored metadata intact for the next retry.
        for change in changes {
            try Task.checkCancellation()
            guard api.currentUserID == userID else { throw GoogleAuthError.notSignedIn }
            if change.file?.name == BackupService.fileName { continue }
            let fileID = change.fileId ?? change.file?.effectiveID ?? ""
            if change.removed == true || change.file?.trashed == true {
                prepared.append((change, folderOwners[key(userID, fileID)]))
                continue
            }
            guard let item = change.file else { continue }
            if item.isFolder {
                let previous = folderOwners[key(userID, item.effectiveID)]
                // A move/rename invalidates cached paths below the folder.
                if let previous {
                    folderOwners = folderOwners.filter { entry in
                        !(entry.key.hasPrefix("\(userID)|") && entry.value.accountID == previous.accountID &&
                          (entry.value.path == previous.path || entry.value.path.hasPrefix(previous.path + " / ")))
                    }
                }
                let owner = try await owner(of: item.parents ?? [], userID: userID, accounts: byID)
                prepared.append((change, previous ?? owner))
                if let owner, previous?.accountID != owner.accountID { prepared.append((change, owner)) }
            } else if item.isMedia {
                let owner = try await owner(of: item.parents ?? [], userID: userID, accounts: byID)
                prepared.append((change, owner))
            }
        }
        try Task.checkCancellation()
        guard api.currentUserID == userID else { throw GoogleAuthError.notSignedIn }
        // Records can be deleted while ancestry requests suspend. Fetch fresh
        // models only after those requests, and guard them again after yields.
        let media = try context.fetch(FetchDescriptor<VideoAsset>(predicate: #Predicate { $0.googleUserID == userID }))
        var byFileID = Dictionary(grouping: media.filter { !$0.isDeleted }, by: \.driveFileID)
        var result = DriveDeltaResult()
        for (index, entry) in prepared.enumerated() {
            try Task.checkCancellation()
            guard api.currentUserID == userID else { throw GoogleAuthError.notSignedIn }
            let (change, owner) = entry
            let fileID = change.fileId ?? change.file?.effectiveID ?? ""
            let existing = byFileID[change.file?.effectiveID ?? fileID] ?? []
            if change.removed == true || change.file?.trashed == true {
                for video in existing where video.modelContext != nil && !video.isDeleted && !video.isMissingFromDrive {
                    video.isMissingFromDrive = true; video.updatedAt = .now
                    result.changed = true
                    if let account = video.account { result.affectedAccountIDs.insert(account.id) }
                }
                if let owner, let account = byID[owner.accountID], account.modelContext != nil, !account.isDeleted {
                    for video in media where video.modelContext != nil && !video.isDeleted && video.accountFolderID == account.driveFolderID &&
                        (video.folderPath == owner.path || video.folderPath.hasPrefix(owner.path + " / ")) && !video.isMissingFromDrive {
                        video.isMissingFromDrive = true; video.updatedAt = .now; result.changed = true
                    }
                    if account.driveFolderID == fileID && !account.isMissingFromDrive {
                        account.isMissingFromDrive = true; result.changed = true
                    }
                    result.affectedAccountIDs.insert(account.id)
                }
                continue
            }
            guard let item = change.file else { continue }
            if item.isFolder {
                if let owner { result.accountsToScan.insert(owner.accountID); result.affectedAccountIDs.insert(owner.accountID) }
                continue
            }
            // A move out of a tracked account retains history and frees its slot.
            for video in existing where video.modelContext != nil && !video.isDeleted && video.account?.id != owner?.accountID && !video.isMissingFromDrive {
                video.isMissingFromDrive = true; video.updatedAt = .now; result.changed = true
                if let account = video.account { result.affectedAccountIDs.insert(account.id) }
            }
            guard let owner, let account = byID[owner.accountID], account.modelContext != nil, !account.isDeleted else { continue }
            result.affectedAccountIDs.insert(account.id)
            if let video = existing.first(where: { $0.modelContext != nil && !$0.isDeleted && $0.accountFolderID == account.driveFolderID }) {
                let descriptionChanged = video.workspaceMediaID == nil && video.uploadTextSyncState == .synced &&
                    item.description != nil && video.uploadText != item.description
                let changed = video.name != item.name || video.mimeType != item.effectiveMimeType ||
                    video.folderPath != owner.path || video.thumbnailLink != item.thumbnailLink ||
                    video.driveModifiedAt != item.modifiedDate || video.checksum != item.md5Checksum ||
                    video.size != item.sizeValue || video.resourceKey != item.effectiveResourceKey ||
                    video.canDownload != (item.capabilities?.canDownload ?? true) || video.isMissingFromDrive || descriptionChanged
                if changed {
                    video.name = item.name; video.mimeType = item.effectiveMimeType; video.folderPath = owner.path
                    video.thumbnailLink = item.thumbnailLink; video.driveModifiedAt = item.modifiedDate
                    video.checksum = item.md5Checksum; video.size = item.sizeValue
                    video.resourceKey = item.effectiveResourceKey; video.canDownload = item.capabilities?.canDownload ?? true
                    video.isMissingFromDrive = false; video.lastSeenAt = .now; video.updatedAt = .now
                    if descriptionChanged { video.uploadText = item.description ?? "" }
                    result.changed = true
                }
            } else {
                let video = VideoAsset(driveFileID: item.effectiveID, accountFolderID: account.driveFolderID,
                    googleUserID: userID, name: item.name, folderPath: owner.path, mimeType: item.effectiveMimeType,
                    resourceKey: item.effectiveResourceKey, size: item.sizeValue, checksum: item.md5Checksum,
                    driveModifiedAt: item.modifiedDate, thumbnailLink: item.thumbnailLink,
                    canDownload: item.capabilities?.canDownload ?? true, account: account)
                video.uploadText = item.description ?? ""
                context.insert(video); byFileID[item.effectiveID, default: []].append(video)
                result.changed = true; result.newMediaCount += 1
            }
            if index > 0, index.isMultiple(of: 20) { await Task.yield() }
        }
        if result.changed { try context.save() }
        return result
    }

    private func owner(of parents: [String], userID: String, accounts: [UUID: TikTokAccount],
                       visited: Set<String> = []) async throws -> Owner? {
        guard visited.count < 50 else { return nil }
        for folderID in parents where !visited.contains(folderID) {
            if let known = folderOwners[key(userID, folderID)], accounts[known.accountID] != nil { return known }
            if let account = accounts.values.first(where: { $0.modelContext != nil && !$0.isDeleted && $0.driveFolderID == folderID }) {
                return Owner(accountID: account.id, path: account.folderName)
            }
            var next = visited; next.insert(folderID)
            let folder: DriveItem
            do { folder = try await api.item(id: folderID, resourceKey: nil) }
            catch DriveAPIError.notFound { continue }
            catch DriveAPIError.forbidden { continue }
            catch DriveAPIError.http(let code, _) where code == 403 || code == 404 { continue }
            guard api.currentUserID == userID else { throw GoogleAuthError.notSignedIn }
            if let ancestor = try await owner(of: folder.parents ?? [], userID: userID, accounts: accounts, visited: next) {
                let found = Owner(accountID: ancestor.accountID, path: ancestor.path + " / " + folder.name)
                folderOwners[key(userID, folderID)] = found
                return found
            }
        }
        return nil
    }
}
