import XCTest
import SwiftData
@testable import DriveTracker

@MainActor
final class VideoCaptionTests: XCTestCase {
    let document = """
    Video 001
    Title: First title
    Hashtags: #first #one

    Video 2
    Title: Second title
    Hashtags: #second
    """

    func testLeadingZeroMatchAndClipboardFormat() throws {
        XCTAssertEqual(try VideoCaptionParser.caption(for: "Video 01.mp4", document: document).text,
                       "First title\n\n#first #one")
        XCTAssertEqual(try VideoCaptionParser.caption(for: "002.mov", document: document).title, "Second title")
    }

    func testNeverMatchesPartialNumbersOrAmbiguousNames() {
        XCTAssertThrowsError(try VideoCaptionParser.caption(for: "Video 10.mp4", document: document))
        XCTAssertThrowsError(try VideoCaptionParser.caption(for: "Video 1 version 2.mp4", document: document))
        XCTAssertThrowsError(try VideoCaptionParser.caption(for: "untitled.mp4", document: document))
    }

    func testDuplicateAndIncompleteEntriesAreRejected() {
        XCTAssertThrowsError(try VideoCaptionParser.caption(for: "1.mp4", document: document + "\nVideo 01\nTitle: Duplicate\nHashtags: #bad"))
        XCTAssertThrowsError(try VideoCaptionParser.caption(for: "1.mp4", document: "Video 1\nTitle: No tags"))
    }

    func testMultilineMetadataAndWindowsLineEndings() throws {
        let text = "Video 1\r\nTitle: A long\r\ntitle\r\nHashtags: #one\r\n#two"
        XCTAssertEqual(try VideoCaptionParser.caption(for: "1.mp4", document: text).text, "A long title\n\n#one #two")
    }

    func testAccountPostingCalendarRespectsCityDayAndDST() {
        let account = TikTokAccount(googleUserID: "qa", driveFolderID: "root", folderName: "Account")
        account.targetTimeZoneID = "America/New_York"
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(DayKey.value(for: formatter.date(from: "2026-07-01T03:30:00Z")!, calendar: account.postingCalendar), "2026-06-30")
        XCTAssertEqual(account.postingCalendar.timeZone.secondsFromGMT(for: formatter.date(from: "2026-07-01T12:00:00Z")!), -14400)
        XCTAssertEqual(account.postingCalendar.timeZone.secondsFromGMT(for: formatter.date(from: "2026-01-01T12:00:00Z")!), -18000)
    }

    func testPlatformFeedsKeepAccountsSeparateAndUnassignedOutOfBothTabs() throws {
        let container = try ModelContainer(for: ModelContainerFactory.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var accounts: [TikTokAccount] = []
        for index in 0..<21 {
            let account = TikTokAccount(googleUserID: "qa", driveFolderID: "folder-\(index)", folderName: "Account \(index)")
            if index < 10 { account.uploadPlatform = .tiktok }
            else if index < 20 { account.uploadPlatform = .facebook }
            context.insert(account)
            accounts.append(account)
        }
        XCTAssertEqual(TodayFeedIndex.build(accounts: accounts, media: [], platform: .tiktok).count, 10)
        XCTAssertEqual(TodayFeedIndex.build(accounts: accounts, media: [], platform: .facebook).count, 10)
        accounts[0].uploadPlatform = .facebook
        XCTAssertEqual(TodayFeedIndex.build(accounts: accounts, media: [], platform: .tiktok).count, 9)
        XCTAssertEqual(TodayFeedIndex.build(accounts: accounts, media: [], platform: .facebook).count, 11)
        XCTAssertEqual(accounts.count, 21)
    }

    func testFolderSyncCachesOnlyItsDocumentAndSkipsUnchangedExport() async throws {
        let container = try ModelContainer(for: ModelContainerFactory.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let api = CaptionAPI()
        let service = DriveSyncService(api: api)
        let account = TikTokAccount(googleUserID: "qa", driveFolderID: "root", folderName: "Account")
        context.insert(account)
        _ = try await service.sync(root: DriveFolderReference(folderID: "root", resourceKey: nil), account: account, context: context)
        XCTAssertEqual(account.captionDocumentText, api.text)
        XCTAssertEqual(api.exports, 1)
        _ = try await service.sync(root: DriveFolderReference(folderID: "root", resourceKey: nil), account: account, context: context)
        XCTAssertEqual(api.exports, 1)
        api.documents = [api.doc("doc"), api.doc("other")]
        account.captionDocumentID = nil
        _ = try await service.sync(root: DriveFolderReference(folderID: "root", resourceKey: nil), account: account, context: context)
        XCTAssertNil(account.captionDocumentText)
        XCTAssertTrue(account.captionDocumentIssue?.contains("Multiple") == true)
    }
}

@MainActor
private final class CaptionAPI: DriveMetadataAPI {
    var currentUserID: String? = "qa"
    var exports = 0
    var text = "Video 1\nTitle: Correct account\nHashtags: #correct"
    lazy var documents = [doc("doc")]
    func doc(_ id: String) -> DriveItem {
        DriveItem(id: id, name: "Metadata", mimeType: "application/vnd.google-apps.document", size: nil, md5Checksum: nil,
                  modifiedTime: "2026-10-16T12:00:00.000Z", thumbnailLink: nil, resourceKey: nil, capabilities: nil, shortcutDetails: nil)
    }
    func item(id: String, resourceKey: String?) async throws -> DriveItem {
        DriveItem(id: id, name: "Account", mimeType: DriveItem.folderMimeType, size: nil, md5Checksum: nil,
                  modifiedTime: nil, thumbnailLink: nil, resourceKey: nil, capabilities: nil, shortcutDetails: nil)
    }
    func listChildren(of folderID: String, folderResourceKey: String?) async throws -> [DriveItem] { documents }
    func exportCaptionDocument(id: String, resourceKey: String?) async throws -> String { exports += 1; return text }
}
