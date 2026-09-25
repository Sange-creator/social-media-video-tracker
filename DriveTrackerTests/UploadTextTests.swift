import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class UploadTextTests: XCTestCase {
    func testUploadTextStaysAttachedToDriveIdentityAfterRename() throws {
        let video = VideoAsset(
            driveFileID: "stable-drive-id",
            accountFolderID: "root",
            googleUserID: "user",
            name: "before.mp4",
            mimeType: "video/mp4"
        )
        video.uploadText = "Title and caption\n\n#tag"
        video.name = "after.mp4"

        XCTAssertEqual(video.driveFileID, "stable-drive-id")
        XCTAssertEqual(video.uploadText, "Title and caption\n\n#tag")
    }

    func testUploadTextPreservesUnicodeAndLineBreaks() {
        let content = "नयाँ भिडियो 🎬\n\n#नेपाल #Creator"
        let video = VideoAsset(
            driveFileID: "video-2",
            accountFolderID: "root",
            googleUserID: "user",
            name: "clip.mov",
            mimeType: "video/quicktime"
        )
        video.uploadText = content
        XCTAssertEqual(video.uploadText, content)
    }
}
