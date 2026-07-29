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
        let rootItem = try await api.item(id: root.folderID, resourceKey: root.resourceKey)
        guard rootItem.isFolder else { throw DriveLinkError.invalidFolderLink }

        let allVideos = try context.fetch(FetchDescriptor<VideoAsset>())
        let existingVideoByKey = Dictionary(
            uniqueKeysWithValues: allVideos.map { ($0.identityKey, $0) }
        )
        let scanTime = Date.now
        var seenVideoKeys = Set<String>()
        var newVideos = 0

        var visitedFolders = Set<String>()
        let locatedVideos = try await recursivelyListVideos(
            folderID: root.folderID,
            resourceKey: root.resourceKey,
            path: account.folderName,
            visitedFolders: &visitedFolders
        )

        for located in locatedVideos {
            let item = located.item
            let key = VideoAsset.makeIdentityKey(
                googleUserID: account.googleUserID,
                accountFolderID: root.folderID,
                driveFileID: item.effectiveID
            )
            guard seenVideoKeys.insert(key).inserted else { continue }
            if let video = existingVideoByKey[key] {
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
                video.canDownload = item.capabilities?.canDownload ?? true
                video.account = account
                video.updatedAt = scanTime
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
            }
        }

        for video in allVideos where
            video.account?.id == account.id &&
            !seenVideoKeys.contains(video.identityKey)
        {
            video.isMissingFromDrive = true
            video.updatedAt = scanTime
        }

        account.isMissingFromDrive = false
        account.updatedAt = scanTime
        try context.save()
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
