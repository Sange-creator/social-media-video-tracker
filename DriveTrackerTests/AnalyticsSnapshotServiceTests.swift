import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class AnalyticsSnapshotServiceTests: XCTestCase {
    func testSnapshotBuildsCountsWithoutBlockingMainContext() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = TikTokAccount(
            googleUserID: "user-1",
            driveFolderID: "folder-1",
            folderName: "Video Folder",
            displayName: "Main Account",
            dailyQuota: 3
        )
        let video = VideoAsset(
            driveFileID: "video-1",
            accountFolderID: "folder-1",
            googleUserID: "user-1",
            name: "clip.mp4",
            mimeType: "video/mp4",
            size: 1_024,
            account: account
        )
        video.downloadedAt = .now
        video.uploadedAt = .now
        let event = StatusEvent(
            kind: .downloadSucceeded,
            accountName: account.displayName,
            driveFileID: video.driveFileID,
            videoName: video.name,
            video: video
        )
        context.insert(account)
        context.insert(video)
        context.insert(event)
        try context.save()

        let snapshot = try await AnalyticsSnapshotService.makeSnapshot(
            container: container,
            googleUserID: "user-1"
        )

        XCTAssertEqual(snapshot.activeAccountCount, 1)
        XCTAssertEqual(snapshot.dailyTarget, 3)
        XCTAssertEqual(snapshot.todayCount, 1)
        XCTAssertEqual(snapshot.allTimeDownloaded, 1)
        XCTAssertEqual(snapshot.completedCount, 1)
        XCTAssertEqual(snapshot.inAppDownloadedCount, 1)
        XCTAssertEqual(snapshot.downloadActionCount, 1)
        XCTAssertEqual(snapshot.dayCounts.count, 14)
        XCTAssertEqual(snapshot.accounts.first?.total, 1)
        XCTAssertEqual(snapshot.recentDownloads.first?.name, "clip.mp4")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            DriveSource.self,
            TikTokAccount.self,
            VideoAsset.self,
            DailyAssignment.self,
            StatusEvent.self,
            CopyEntry.self,
            CopyEvent.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
        )
    }
}
