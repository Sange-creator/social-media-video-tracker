import SwiftData
import UIKit
import XCTest
@testable import DriveTracker

@MainActor
final class ThumbnailCancellationTests: XCTestCase {
    func testOffscreenConsumerCancelsRequestAndCanRetry() async throws {
        let service = ThumbnailService(cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let api = SlowThumbnailAPI()
        let video = makeVideo()
        let request = Task { await service.thumbnailImage(for: video, api: api, currentUserID: "qa") }
        while api.starts == 0 { await Task.yield() }
        request.cancel()
        let cancelledImage = await request.value
        XCTAssertNil(cancelledImage)
        XCTAssertEqual(api.cancellations, 1)
        let image = await service.thumbnailImage(for: video, api: api, currentUserID: "qa")
        XCTAssertNotNil(image)
        XCTAssertEqual(api.starts, 2)
        service.clearCache()
    }

    func testCancelingOneConsumerPreservesSharedRequest() async throws {
        let service = ThumbnailService(cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let api = SlowThumbnailAPI()
        let video = makeVideo()
        let first = Task { await service.thumbnailImage(for: video, api: api, currentUserID: "qa") }
        while api.starts == 0 { await Task.yield() }
        let second = Task { await service.thumbnailImage(for: video, api: api, currentUserID: "qa") }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let image = await second.value
        XCTAssertNotNil(image)
        let firstImage = await first.value
        XCTAssertNil(firstImage)
        XCTAssertEqual(api.starts, 1)
        XCTAssertEqual(api.cancellations, 0)
        service.clearCache()
    }

    private func makeVideo() -> VideoAsset {
        VideoAsset(driveFileID: UUID().uuidString, accountFolderID: "folder", googleUserID: "qa", name: "Sample.mp4", mimeType: "video/mp4")
    }
}

@MainActor
private final class SlowThumbnailAPI: DriveThumbnailAPI {
    var starts = 0
    var cancellations = 0
    func thumbnailData(for item: VideoAsset) async throws -> Data {
        starts += 1
        do { try await Task.sleep(for: .milliseconds(200)) }
        catch { cancellations += 1; throw error }
        return UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { renderer in
            UIColor.orange.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.jpegData(compressionQuality: 0.8)!
    }
}
