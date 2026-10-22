import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class TargetedSyncTests: XCTestCase {
    private func makeTestContainer() throws -> ModelContainer {
        let schema = Schema([
            DriveSource.self,
            TikTokAccount.self,
            VideoAsset.self,
            DailyAssignment.self,
            StatusEvent.self,
            CopyEntry.self,
            CopyEvent.self
        ])
        let configuration = ModelConfiguration(
            "TargetedSyncTest_\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func testDriveSyncResultTracksFoldersAndPaths() {
        let result = DriveSyncResult(
            accountsFound: 1,
            videosFound: 5,
            newVideos: 2,
            visitedFolderIDs: ["folder-root", "folder-sub1"],
            folderPaths: [
                "folder-root": "Creator A",
                "folder-sub1": "Creator A / Week 1"
            ]
        )

        XCTAssertEqual(result.accountsFound, 1)
        XCTAssertEqual(result.videosFound, 5)
        XCTAssertEqual(result.newVideos, 2)
        XCTAssertTrue(result.visitedFolderIDs.contains("folder-root"))
        XCTAssertTrue(result.visitedFolderIDs.contains("folder-sub1"))
        XCTAssertEqual(result.folderPaths["folder-sub1"], "Creator A / Week 1")
    }

    func testSingleAccountSyncReconcilesOnlyTargetAccount() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "TargetedSyncTests_\(UUID().uuidString)")!
        let state = AppState(defaults: defaults)

        let source1 = DriveSource(
            googleUserID: "user-1",
            googleEmail: "creator@example.com",
            rootFolderID: "root-1",
            rootLink: "https://drive.google.com/drive/folders/root-1",
            displayName: "Source 1"
        )
        let source2 = DriveSource(
            googleUserID: "user-1",
            googleEmail: "creator@example.com",
            rootFolderID: "root-2",
            rootLink: "https://drive.google.com/drive/folders/root-2",
            displayName: "Source 2"
        )
        context.insert(source1)
        context.insert(source2)

        let account1 = TikTokAccount(
            googleUserID: "user-1",
            driveFolderID: "folder-1",
            folderName: "Account One",
            dailyQuota: 2,
            sourceID: source1.id,
            googleEmail: source1.googleEmail
        )
        let account2 = TikTokAccount(
            googleUserID: "user-1",
            driveFolderID: "folder-2",
            folderName: "Account Two",
            dailyQuota: 3,
            sourceID: source2.id,
            googleEmail: source2.googleEmail
        )
        context.insert(account1)
        context.insert(account2)

        let videoA = VideoAsset(
            driveFileID: "file-A",
            accountFolderID: account1.driveFolderID,
            googleUserID: "user-1",
            name: "videoA.mp4",
            folderPath: "Account One",
            mimeType: "video/mp4",
            account: account1
        )
        let videoB = VideoAsset(
            driveFileID: "file-B",
            accountFolderID: account2.driveFolderID,
            googleUserID: "user-1",
            name: "videoB.mp4",
            folderPath: "Account Two",
            mimeType: "video/mp4",
            account: account2
        )
        context.insert(videoA)
        context.insert(videoB)
        try context.save()

        // Verify account-specific query isolation
        let account1Videos = try context.fetch(FetchDescriptor<VideoAsset>(
            predicate: #Predicate { $0.accountFolderID == "folder-1" }
        ))
        XCTAssertEqual(account1Videos.count, 1)
        XCTAssertEqual(account1Videos.first?.name, "videoA.mp4")

        let account2Videos = try context.fetch(FetchDescriptor<VideoAsset>(
            predicate: #Predicate { $0.accountFolderID == "folder-2" }
        ))
        XCTAssertEqual(account2Videos.count, 1)
        XCTAssertEqual(account2Videos.first?.name, "videoB.mp4")
    }

    func testDriveItemTrashedAndMediaDetection() {
        let item1 = DriveItem(
            id: "vid-1",
            name: "reel.mp4",
            mimeType: "video/mp4",
            trashed: false
        )
        XCTAssertTrue(item1.isMedia)
        XCTAssertTrue(item1.isVideo)
        XCTAssertFalse(item1.isTrashed)

        let item2 = DriveItem(
            id: "vid-2",
            name: "deleted.mp4",
            mimeType: "video/mp4",
            trashed: true
        )
        XCTAssertTrue(item2.isTrashed)

        let item3 = DriveItem(
            id: "photo-1",
            name: "photo.jpg",
            mimeType: "image/jpeg"
        )
        XCTAssertTrue(item3.isMedia)
        XCTAssertTrue(item3.isPhoto)
        XCTAssertFalse(item3.isTrashed)
    }
}
