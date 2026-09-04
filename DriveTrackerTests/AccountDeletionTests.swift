import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class AccountDeletionTests: XCTestCase {
    func testDeleteAccountCascadesCleanlyWithoutDanglingRecords() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let driveSource = DriveSource(
            googleUserID: "test-user-1",
            googleEmail: "user1@example.com",
            rootFolderID: "root-1",
            rootLink: "https://drive.google.com/drive/folders/root-1",
            displayName: "Source 1"
        )
        context.insert(driveSource)

        let account = TikTokAccount(
            googleUserID: "test-user-1",
            driveFolderID: "folder-1",
            folderName: "Account 1",
            dailyQuota: 3,
            sourceID: driveSource.id,
            googleEmail: driveSource.googleEmail
        )
        context.insert(account)

        let video1 = VideoAsset(
            driveFileID: "video-1",
            accountFolderID: account.driveFolderID,
            googleUserID: "test-user-1",
            name: "video1.mp4",
            mimeType: "video/mp4",
            account: account
        )
        let video2 = VideoAsset(
            driveFileID: "video-2",
            accountFolderID: account.driveFolderID,
            googleUserID: "test-user-1",
            name: "video2.mp4",
            mimeType: "video/mp4",
            account: account
        )
        context.insert(video1)
        context.insert(video2)

        let assignment1 = DailyAssignment(
            localDayKey: "2026-08-22",
            slot: 1,
            account: account,
            video: video1
        )
        context.insert(assignment1)

        let statusEvent1 = StatusEvent(
            kind: .assigned,
            accountName: account.displayName,
            driveFileID: video1.driveFileID,
            videoName: video1.name,
            video: video1
        )
        context.insert(statusEvent1)

        let copyEntry1 = CopyEntry(
            googleUserID: "test-user-1",
            accountFolderID: account.driveFolderID,
            sourceSheetID: "sheet-1",
            contentHash: CopyQueueCSVParser.contentHash("Caption 1 #test"),
            sourceRow: 1,
            content: "Caption 1 #test",
            account: account
        )
        context.insert(copyEntry1)

        let copyEvent1 = CopyEvent(
            kind: .copied,
            accountName: account.displayName,
            entryIdentityKey: copyEntry1.identityKey,
            contentPreview: copyEntry1.content,
            entry: copyEntry1
        )
        context.insert(copyEvent1)

        try context.save()

        // Verify initial setup
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TikTokAccount>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VideoAsset>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyAssignment>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StatusEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CopyEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CopyEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DriveSource>()), 1)

        // Perform safe deletion
        state.deleteAccount(accountID: account.id, context: context)

        // Verify that all child records and the account itself are cleanly removed
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TikTokAccount>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VideoAsset>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyAssignment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StatusEvent>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CopyEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CopyEvent>()), 0)
        // Orphaned source should also be removed
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DriveSource>()), 0)
    }

    func testDeleteAccountPreservesOtherAccounts() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let driveSource = DriveSource(
            googleUserID: "test-user-1",
            googleEmail: "user1@example.com",
            rootFolderID: "root-1",
            rootLink: "https://drive.google.com/drive/folders/root-1",
            displayName: "Shared Source"
        )
        context.insert(driveSource)

        let account1 = TikTokAccount(
            googleUserID: "test-user-1",
            driveFolderID: "folder-1",
            folderName: "Account 1",
            dailyQuota: 3,
            sourceID: driveSource.id,
            googleEmail: driveSource.googleEmail
        )
        let account2 = TikTokAccount(
            googleUserID: "test-user-1",
            driveFolderID: "folder-2",
            folderName: "Account 2",
            dailyQuota: 2,
            sourceID: driveSource.id,
            googleEmail: driveSource.googleEmail
        )
        context.insert(account1)
        context.insert(account2)

        let video1 = VideoAsset(
            driveFileID: "video-1",
            accountFolderID: account1.driveFolderID,
            googleUserID: "test-user-1",
            name: "video1.mp4",
            mimeType: "video/mp4",
            account: account1
        )
        let video2 = VideoAsset(
            driveFileID: "video-2",
            accountFolderID: account2.driveFolderID,
            googleUserID: "test-user-1",
            name: "video2.mp4",
            mimeType: "video/mp4",
            account: account2
        )
        context.insert(video1)
        context.insert(video2)
        try context.save()

        // Delete only account1
        state.deleteAccount(accountID: account1.id, context: context)

        // Account 2 and its videos and the shared source must remain
        let remainingAccounts = try context.fetch(FetchDescriptor<TikTokAccount>())
        let remainingVideos = try context.fetch(FetchDescriptor<VideoAsset>())
        let remainingSources = try context.fetch(FetchDescriptor<DriveSource>())

        XCTAssertEqual(remainingAccounts.count, 1)
        XCTAssertEqual(remainingAccounts.first?.id, account2.id)
        XCTAssertEqual(remainingVideos.count, 1)
        XCTAssertEqual(remainingVideos.first?.id, video2.id)
        XCTAssertEqual(remainingSources.count, 1)
    }

    func testModelContainerFactoryCreatesValidContainer() {
        let container = ModelContainerFactory.createContainer()
        XCTAssertNotNil(container.mainContext)
    }

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
            "Test_\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
