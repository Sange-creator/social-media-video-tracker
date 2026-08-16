import Foundation
import SwiftData

struct DriveSyncResult: Equatable {
    let accountsFound: Int
    let videosFound: Int
    let newVideos: Int
}

@MainActor
final class DriveSyncService {
    private let api: DriveAPIClient

    init(api: DriveAPIClient) {
        self.api = api
    }

    func sync(
        root: DriveFolderReference,
        account: TikTokAccount,
        context: ModelContext
    ) async throws -> DriveSyncResult {
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
            uniqueKeysWithValues: accountVideos.map { ($0.identityKey, $0) }
        )
        let scanTime = Date.now
        var seenVideoKeys = Set<String>()
        var newVideos = 0
        var hasPersistentChanges = false

        var visitedFolders = Set<String>()
        // Keep a visited set because shared Drive folder structures can expose
        // the same folder more than once; recursion must never loop forever.
        let locatedVideos = try await recursivelyListVideos(
            folderID: root.folderID,
            resourceKey: root.resourceKey,
            path: account.folderName,
            visitedFolders: &visitedFolders
        )

        for (index, located) in locatedVideos.enumerated() {
            try Task.checkCancellation()
            // Large folders should never monopolize the main actor while the
            // user is scrolling or changing tabs.
            if index > 0, index.isMultiple(of: 40) {
                await Task.yield()
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
                let refreshLastSeen =
                    scanTime.timeIntervalSince(video.lastSeenAt) >= 86_400

                if metadataChanged || refreshLastSeen {
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
                context.insert(video)
                newVideos += 1
                hasPersistentChanges = true
            }
        }

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
        if hasPersistentChanges {
            try context.save()
        }
        return DriveSyncResult(
            accountsFound: 1,
            videosFound: locatedVideos.count,
            newVideos: newVideos
        )
    }

    private struct LocatedVideo {
        let item: DriveItem
        let folderPath: String
    }

    private func recursivelyListVideos(
        folderID: String,
        resourceKey: String?,
        path: String,
        visitedFolders: inout Set<String>
    ) async throws -> [LocatedVideo] {
        guard visitedFolders.insert(folderID).inserted else { return [] }
        let children = try await api.listChildren(of: folderID, folderResourceKey: resourceKey)
        var videos = children.filter(\.isVideo).map {
            LocatedVideo(item: $0, folderPath: path)
        }
        for folder in children where folder.isFolder {
            videos.append(
                contentsOf: try await recursivelyListVideos(
                    folderID: folder.effectiveID,
                    resourceKey: folder.effectiveResourceKey,
                    path: "\(path) / \(folder.name)",
                    visitedFolders: &visitedFolders
                )
            )
        }
        return videos
    }
}
