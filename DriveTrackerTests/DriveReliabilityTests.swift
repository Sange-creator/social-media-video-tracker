import AVFoundation
import Foundation
import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class DriveReliabilityTests: XCTestCase {
    func testBaselineCursorIsCapturedBeforeScan() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let tracker = DriveChangeTracker(defaults: defaults)
        var order: [String] = []
        await tracker.check(key: "cursor", startToken: {
            order.append("token")
            return "before-upload"
        }, changes: { _ in XCTFail("Baseline must scan first"); return ([], "") }, reconcile: {
            order.append("scan")
            return true
        }, isCurrentUser: { true })
        XCTAssertEqual(order, ["token", "scan"])
        XCTAssertEqual(defaults.string(forKey: "cursor"), "before-upload")
    }

    func testFailedScanRetainsChangesForRetry() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("old", forKey: "cursor")
        let tracker = DriveChangeTracker(defaults: defaults)
        await tracker.check(key: "cursor", startToken: { "must-not-reset" }, changes: { token in
            XCTAssertEqual(token, "old")
            return ([DriveChange(fileId: "new-video", removed: false, file: nil)], "new")
        }, reconcile: { false }, isCurrentUser: { true })
        XCTAssertEqual(defaults.string(forKey: "cursor"), "old")
    }

    func testEmptyChangePageAdvancesWithoutScan() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("old", forKey: "cursor")
        let tracker = DriveChangeTracker(defaults: defaults)
        await tracker.check(key: "cursor", startToken: { "" }, changes: { _ in ([], "new") },
                            reconcile: { XCTFail("Empty pages do not need a full scan"); return false },
                            isCurrentUser: { true })
        XCTAssertEqual(defaults.string(forKey: "cursor"), "new")
    }

    func testNetworkFailureDoesNotResetCursor() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("old", forKey: "cursor")
        await DriveChangeTracker(defaults: defaults).check(
            key: "cursor", startToken: { XCTFail("Do not reset on network error"); return "" },
            changes: { _ in throw URLError(.notConnectedToInternet) },
            reconcile: { XCTFail("Do not full scan while offline"); return false }, isCurrentUser: { true }
        )
        XCTAssertEqual(defaults.string(forKey: "cursor"), "old")
    }

    func testAccountSwitchDoesNotCommitCursor() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("old", forKey: "cursor")
        await DriveChangeTracker(defaults: defaults).check(
            key: "cursor", startToken: { "" }, changes: { _ in ([], "new") },
            reconcile: { true }, isCurrentUser: { false }
        )
        XCTAssertEqual(defaults.string(forKey: "cursor"), "old")
    }

    func testExpiredCursorIsResetButPermissionFailureIsRetained() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let tracker = DriveChangeTracker(defaults: defaults)
        defaults.set("old", forKey: "cursor")
        await tracker.check(key: "cursor", startToken: { "" },
                            changes: { _ in throw DriveAPIError.http(403, "Forbidden") },
                            reconcile: { false }, isCurrentUser: { true })
        XCTAssertEqual(defaults.string(forKey: "cursor"), "old")
        await tracker.check(key: "cursor", startToken: { "" },
                            changes: { _ in throw DriveAPIError.http(410, "Expired") },
                            reconcile: { false }, isCurrentUser: { true })
        XCTAssertNil(defaults.string(forKey: "cursor"))
    }

    func testPlaybackTimeRejectsInvalidMediaTimes() {
        for seconds in [Double.nan, Double.infinity, -Double.infinity, -1, Double(Int.max)] {
            XCTAssertEqual(PlaybackTime.format(seconds), "00:00")
        }
        XCTAssertEqual(PlaybackTime.format(65.9), "01:05")
        XCTAssertEqual(PlaybackTime.format(3600), "60:00")
    }

    func testLargeFolderReconciliationPreservesHistoryAndAvoidsUnchangedWrites() async throws {
        let schema = ModelContainerFactory.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = TikTokAccount(googleUserID: "user", driveFolderID: "folder", folderName: "Account", dailyQuota: 3)
        context.insert(account)
        let api = FakeDriveMetadataAPI()
        api.children["folder"] = (0..<2000).map { makeItem(id: "file-\($0)", name: "video-\($0).mp4", mime: "video/mp4") }
        let service = DriveSyncService(api: api)
        let first = try await service.sync(root: DriveFolderReference(folderID: "folder", resourceKey: nil), account: account, context: context)
        XCTAssertEqual(first.newVideos, 2000)
        let completed = try XCTUnwrap(account.videos.first { $0.driveFileID == "file-0" })
        completed.uploadedAt = .now
        try context.save()
        let second = try await service.sync(root: DriveFolderReference(folderID: "folder", resourceKey: nil), account: account, context: context)
        XCTAssertEqual(second.newVideos, 0)
        XCTAssertFalse(context.hasChanges)
        XCTAssertNotNil(completed.uploadedAt)
        api.children["folder"] = [makeItem(id: "file-0", name: "renamed.mp4", mime: "video/mp4", description: "Caption\n#tag")]
        _ = try await service.sync(root: DriveFolderReference(folderID: "folder", resourceKey: nil), account: account, context: context)
        XCTAssertEqual(completed.name, "renamed.mp4")
        XCTAssertEqual(completed.uploadText, "Caption\n#tag")
        XCTAssertNotNil(completed.uploadedAt)
        XCTAssertEqual(account.videos.filter(\.isMissingFromDrive).count, 1999)
    }

    func testConcurrentScansShareOneDriveListing() async throws {
        let schema = ModelContainerFactory.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = TikTokAccount(googleUserID: "user", driveFolderID: "folder", folderName: "Account", dailyQuota: 3)
        context.insert(account)
        let api = FakeDriveMetadataAPI()
        api.children["folder"] = [makeItem(id: "file", name: "video.mp4", mime: "video/mp4")]
        let service = DriveSyncService(api: api)
        let root = DriveFolderReference(folderID: "folder", resourceKey: nil)
        let first = Task { @MainActor in try await service.sync(root: root, account: account, context: context) }
        let second = Task { @MainActor in try await service.sync(root: root, account: account, context: context) }
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(api.listCalls, 1)
        XCTAssertEqual(account.videos.count, 1)
    }

    func testStreamingPreviewCreatesRemoteAssetWithoutDownloadingOriginal() async throws {
        let api = DriveAPIClient(auth: PreviewAuthorization())
        let video = VideoAsset(driveFileID: "preview-file", accountFolderID: "folder", googleUserID: "user", name: "large.mp4", mimeType: "video/mp4")
        let item = try await api.streamingPlayerItem(for: video)
        let asset = try XCTUnwrap(item.asset as? AVURLAsset)
        XCTAssertEqual(asset.url.scheme, "https")
        XCTAssertEqual(asset.url.host, "www.googleapis.com")
        XCTAssertTrue(asset.url.path.contains("preview-file"))
        XCTAssertTrue(asset.url.query?.contains("alt=media") == true)
    }

    func testPlaybackFailureHopsToUIExecutor() async {
        let failure = expectation(description: "Player failure delivered to UI")
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-review-video.mp4"))
        let observation = PlaybackObservation.failure(of: item) {
            XCTAssertTrue(Thread.isMainThread)
            failure.fulfill()
        }
        let player = AVPlayer(playerItem: item)
        player.play()
        await fulfillment(of: [failure], timeout: 10)
        observation.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func makeItem(id: String, name: String, mime: String, description: String? = nil) -> DriveItem {
        DriveItem(id: id, name: name, mimeType: mime, size: "1024", md5Checksum: nil, modifiedTime: nil,
                  thumbnailLink: nil, resourceKey: nil, description: description, capabilities: nil, shortcutDetails: nil)
    }
}

@MainActor
private final class FakeDriveMetadataAPI: DriveMetadataAPI {
    var currentUserID: String? = "user"
    var children: [String: [DriveItem]] = [:]
    var listCalls = 0
    func item(id: String, resourceKey: String?) async throws -> DriveItem {
        DriveItem(id: id, name: "Account", mimeType: DriveItem.folderMimeType, size: nil, md5Checksum: nil,
                  modifiedTime: nil, thumbnailLink: nil, resourceKey: nil, capabilities: nil, shortcutDetails: nil)
    }
    func listChildren(of folderID: String, folderResourceKey: String?) async throws -> [DriveItem] {
        listCalls += 1
        await Task.yield()
        return children[folderID] ?? []
    }
}

@MainActor
private final class PreviewAuthorization: DriveAuthorization {
    let userID: String? = "user"
    func accessToken() async throws -> String { "qa-token" }
}
