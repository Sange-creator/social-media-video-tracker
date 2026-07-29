import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class BackupServiceTests: XCTestCase {
    func testBackupRestorePreservesStatusAndRelationships() throws {
        let source = try makeContainer()
        let sourceContext = source.mainContext
        let driveSource = DriveSource(
            googleUserID: "backup-user",
            googleEmail: "backup@example.com",
            rootFolderID: "root-folder-id",
            rootLink: "https://drive.google.com/drive/folders/root-folder-id",
            displayName: "Content Root"
        )
        sourceContext.insert(driveSource)
        let account = TikTokAccount(
            googleUserID: "backup-user",
            driveFolderID: "backup-folder",
            folderName: "@backup",
            dailyQuota: 3,
            sourceID: driveSource.id,
            googleEmail: driveSource.googleEmail
        )
        sourceContext.insert(account)
        let video = VideoAsset(
            driveFileID: "backup-video",
            accountFolderID: account.driveFolderID,
            googleUserID: "backup-user",
            name: "backup.mp4",
            mimeType: "video/mp4",
            account: account
        )
        sourceContext.insert(video)
        try sourceContext.save()

        let engine = AssignmentEngine()
        _ = try engine.ensureAssignments(for: account, context: sourceContext)
        try engine.markDownloaded(video, photoIdentifier: "local-photo", context: sourceContext)
        try engine.markUploaded(video, context: sourceContext)
        let copyEntry = CopyEntry(
            googleUserID: "backup-user",
            accountFolderID: account.driveFolderID,
            sourceSheetID: "queue-sheet",
            contentHash: CopyQueueCSVParser.contentHash("A title #backup"),
            sourceRow: 2,
            content: "A title #backup",
            account: account
        )
        copyEntry.copiedAt = .now
        copyEntry.copyCount = 1
        sourceContext.insert(copyEntry)
        sourceContext.insert(
            CopyEvent(
                kind: .copied,
                accountName: account.displayName,
                entryIdentityKey: copyEntry.identityKey,
                contentPreview: copyEntry.content,
                entry: copyEntry
            )
        )
        try sourceContext.save()

        let service = BackupService(
            api: DriveAPIClient(auth: GoogleAuthService()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let backup = try service.makeBackup(
            revision: 7,
            context: sourceContext,
            rootLink: "https://drive.google.com/drive/folders/root-folder-id",
            rootFolderID: "root-folder-id",
            rootResourceKey: nil,
            googleUserID: "backup-user",
            globalCopyQueueLink: "https://docs.google.com/spreadsheets/d/queue-sheet/edit",
            globalCopyQueueSheetID: "queue-sheet",
            globalCopyQueueResourceKey: "queue-resource-key"
        )

        let target = try makeContainer()
        try service.restore(backup, context: target.mainContext)
        let restoredAccounts = try target.mainContext.fetch(FetchDescriptor<TikTokAccount>())
        let restoredVideos = try target.mainContext.fetch(FetchDescriptor<VideoAsset>())
        let restoredEvents = try target.mainContext.fetch(FetchDescriptor<StatusEvent>())
        let restoredSources = try target.mainContext.fetch(FetchDescriptor<DriveSource>())
        let restoredCopyEntries = try target.mainContext.fetch(FetchDescriptor<CopyEntry>())
        let restoredCopyEvents = try target.mainContext.fetch(FetchDescriptor<CopyEvent>())

        XCTAssertEqual(restoredSources.count, 1)
        XCTAssertEqual(restoredSources[0].displayName, "Content Root")
        XCTAssertEqual(restoredAccounts.count, 1)
        XCTAssertEqual(restoredAccounts[0].sourceID, restoredSources[0].id)
        XCTAssertEqual(restoredVideos.count, 1)
        XCTAssertEqual(restoredVideos[0].status, .uploaded)
        XCTAssertEqual(restoredVideos[0].account?.displayName, "@backup")
        XCTAssertEqual(restoredVideos[0].photoLocalIdentifier, "local-photo")
        XCTAssertTrue(restoredEvents.contains { $0.kind == .downloadSucceeded })
        XCTAssertTrue(restoredEvents.contains { $0.kind == .uploadConfirmed })
        XCTAssertEqual(restoredCopyEntries.count, 1)
        XCTAssertEqual(restoredCopyEntries[0].content, "A title #backup")
        XCTAssertEqual(restoredCopyEntries[0].copyCount, 1)
        XCTAssertEqual(restoredCopyEvents.first?.kind, .copied)
        XCTAssertEqual(backup.globalCopyQueueSheetID, "queue-sheet")
        XCTAssertEqual(backup.globalCopyQueueResourceKey, "queue-resource-key")
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
