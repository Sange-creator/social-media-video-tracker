import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class DriveDeltaTests: XCTestCase {
    private var retainedContainers: [ModelContainer] = []
    func testUploadAndMetadataChangeDoNotListAnyFoldersOrDuplicateFiles() async throws {
        let (context, accounts, api, service) = try fixture()
        let file = item("new", parent: "a")
        let changes = [DriveChange(fileId: "new", removed: false, file: file), DriveChange(fileId: "new", removed: false, file: file)]
        let first = try await service.apply(changes, userID: "qa", accounts: accounts, context: context)
        XCTAssertEqual(first.newMediaCount, 1)
        XCTAssertEqual(first.affectedAccountIDs, [accounts[0].id])
        XCTAssertEqual(first.accountsToScan, [])
        XCTAssertEqual(api.listCalls, 0)
        XCTAssertEqual(api.itemCalls, 0)
        let second = try await service.apply(changes, userID: "qa", accounts: accounts, context: context)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VideoAsset>()).count, 1)
    }

    func testNestedUploadAndMovePreserveCompletedHistory() async throws {
        let (context, accounts, api, service) = try fixture()
        api.items["nested"] = item("nested", parent: "a", mime: DriveItem.folderMimeType)
        _ = try await service.apply([DriveChange(fileId: "v", removed: false, file: item("v", parent: "nested"))], userID: "qa", accounts: accounts, context: context)
        let video = try XCTUnwrap(context.fetch(FetchDescriptor<VideoAsset>()).first)
        video.uploadedAt = .now
        try context.save()
        _ = try await service.apply([DriveChange(fileId: "v", removed: false, file: item("v", parent: "b"))], userID: "qa", accounts: accounts, context: context)
        let all = try context.fetch(FetchDescriptor<VideoAsset>())
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(video.isMissingFromDrive)
        XCTAssertNotNil(video.uploadedAt)
        XCTAssertEqual(all.first(where: { $0.accountFolderID == "b" })?.isMissingFromDrive, false)
        XCTAssertEqual(api.listCalls, 0)
    }

    func testFolderRemovalMarksDescendantsWithoutDeletingHistory() async throws {
        let (context, accounts, _, service) = try fixture()
        service.record(DriveSyncResult(accountsFound: 1, videosFound: 1, newVideos: 0,
            folderPaths: ["nested": "Account a / Nested"]), account: accounts[0])
        let video = VideoAsset(driveFileID: "v", accountFolderID: "a", googleUserID: "qa", name: "v.mp4", folderPath: "Account a / Nested", mimeType: "video/mp4", account: accounts[0])
        video.uploadedAt = .now; context.insert(video); try context.save()
        let result = try await service.apply([DriveChange(fileId: "nested", removed: true, file: nil)], userID: "qa", accounts: accounts, context: context)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(video.isMissingFromDrive)
        XCTAssertNotNil(video.uploadedAt)
    }

    func testFailedAncestryLookupLeavesStoreUntouchedAndCursorUncommitted() async throws {
        let (context, accounts, api, service) = try fixture()
        api.fail = true
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("before", forKey: "cursor")
        let tracker = DriveChangeTracker(defaults: defaults)
        let change = DriveChange(fileId: "v", removed: false, file: item("v", parent: "unknown"))
        let succeeded = await tracker.check(key: "cursor", startToken: { "baseline" }, changes: { _ in ([change], "after") },
            reconcile: { XCTFail("Ordinary events must not crawl all accounts"); return false }, isCurrentUser: { true }, apply: { changes in
                do { _ = try await service.apply(changes, userID: "qa", accounts: accounts, context: context); return true }
                catch { return false }
            })
        XCTAssertFalse(succeeded)
        XCTAssertEqual(defaults.string(forKey: "cursor"), "before")
        XCTAssertEqual(try context.fetch(FetchDescriptor<VideoAsset>()).count, 0)
    }

    private func fixture() throws -> (ModelContext, [TikTokAccount], DeltaMetadataAPI, DriveDeltaService) {
        let schema = ModelContainerFactory.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        retainedContainers.append(container)
        let context = container.mainContext
        let accounts = ["a", "b"].map { TikTokAccount(googleUserID: "qa", driveFolderID: $0, folderName: "Account \($0)") }
        accounts.forEach { context.insert($0) }; try context.save()
        let api = DeltaMetadataAPI()
        return (context, accounts, api, DriveDeltaService(api: api))
    }

    private func item(_ id: String, parent: String, mime: String = "video/mp4") -> DriveItem {
        DriveItem(id: id, name: id, mimeType: mime, parents: [parent], size: nil, md5Checksum: nil,
                  modifiedTime: nil, thumbnailLink: nil, resourceKey: nil, capabilities: nil, shortcutDetails: nil)
    }
}

@MainActor
private final class DeltaMetadataAPI: DriveMetadataAPI {
    var currentUserID: String? = "qa"
    var items: [String: DriveItem] = [:]
    var listCalls = 0
    var itemCalls = 0
    var fail = false
    func item(id: String, resourceKey: String?) async throws -> DriveItem {
        itemCalls += 1
        if fail { throw URLError(.notConnectedToInternet) }
        guard let item = items[id] else { throw DriveAPIError.notFound }
        return item
    }
    func listChildren(of folderID: String, folderResourceKey: String?) async throws -> [DriveItem] {
        listCalls += 1
        return []
    }
}
