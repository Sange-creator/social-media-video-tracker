import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class TodayFeedTests: XCTestCase {
    func testFeedKeepsCompletedHistoryAndScopesMediaToActiveAccounts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = TikTokAccount(googleUserID: "qa", driveFolderID: "folder", folderName: "Account", dailyQuota: 3)
        let paused = TikTokAccount(googleUserID: "qa", driveFolderID: "paused", folderName: "Paused", isPaused: true)
        context.insert(account); context.insert(paused)
        let done = VideoAsset(driveFileID: "done", accountFolderID: "folder", googleUserID: "qa", name: "Done.mp4", mimeType: "video/mp4", account: account)
        done.uploadedAt = .now; done.isMissingFromDrive = true
        let photo = VideoAsset(driveFileID: "photo", accountFolderID: "folder", googleUserID: "qa", name: "Photo.jpg", mimeType: "image/jpeg", account: account)
        photo.uploadedAt = .now
        let foreign = VideoAsset(driveFileID: "foreign", accountFolderID: "folder", googleUserID: "another-user", name: "Foreign.mp4", mimeType: "video/mp4")
        foreign.uploadedAt = .now
        for video in [done, photo, foreign] { context.insert(video) }
        try context.save()
        let groups = TodayFeedIndex.build(accounts: [account, paused], media: [done, photo, foreign])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].completed, 1)
        XCTAssertEqual(groups[0].photoCount, 1)
        XCTAssertEqual(groups[0].videos.map(\.driveFileID), ["done"])
    }

    func testLargeFeedConstruction() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var accounts: [TikTokAccount] = []
        var media: [VideoAsset] = []
        for index in 0..<40 {
            let account = TikTokAccount(googleUserID: "qa", driveFolderID: "folder-\(index)", folderName: "Account \(index)", dailyQuota: 3)
            context.insert(account); accounts.append(account)
            for item in 0..<50 {
                let video = VideoAsset(driveFileID: "\(index)-\(item)", accountFolderID: account.driveFolderID, googleUserID: "qa", name: "Episode \(item).mp4", mimeType: "video/mp4", account: account)
                context.insert(video); media.append(video)
                if item < 3 {
                    context.insert(DailyAssignment(localDayKey: DayKey.value(for: .now), slot: item + 1, account: account, video: video))
                }
            }
        }
        try context.save()
        measure {
            let groups = TodayFeedIndex.build(accounts: accounts, media: media)
            XCTAssertEqual(groups.count, 40)
            XCTAssertEqual(groups.reduce(0) { $0 + $1.videos.count }, 120)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = ModelContainerFactory.schema
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }
}
