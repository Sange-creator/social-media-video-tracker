import Foundation
import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class WorkspaceSyncTests: XCTestCase {
    func testDecodeWorkspaceSyncDelta() throws {
        let json = """
        {
            "cursor": "2026-09-25T14:00:00.000Z",
            "changes": [
                {
                    "id": "med-1",
                    "driveFileId": "drive-file-abc",
                    "uploadText": "Hook line and hashtags #viral #workspace",
                    "revision": 3
                }
            ],
            "assignments": [
                {
                    "id": "asg-1",
                    "account_id": "acc-1",
                    "media_id": "med-1",
                    "state": "completed",
                    "completed_at": "2026-09-25T14:15:00.000Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let delta = try JSONDecoder().decode(WorkspaceSyncDelta.self, from: json)
        XCTAssertEqual(delta.cursor, "2026-09-25T14:00:00.000Z")
        XCTAssertEqual(delta.changes.count, 1)
        XCTAssertEqual(delta.changes.first?.id, "med-1")
        XCTAssertEqual(delta.changes.first?.driveFileId, "drive-file-abc")
        XCTAssertEqual(delta.changes.first?.uploadText, "Hook line and hashtags #viral #workspace")
        XCTAssertEqual(delta.changes.first?.revision, 3)

        XCTAssertEqual(delta.assignments?.count, 1)
        XCTAssertEqual(delta.assignments?.first?.id, "asg-1")
        XCTAssertEqual(delta.assignments?.first?.mediaId, "med-1")
        XCTAssertEqual(delta.assignments?.first?.state, "completed")
    }

    func testOutboxItemSerialization() throws {
        let item = WorkspaceOutboxItem(
            id: UUID(),
            kind: .saveUploadText,
            mediaID: "media-uuid",
            text: "Updated caption",
            revision: 4,
            completed: nil,
            createdAt: Date()
        )

        let encoded = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([WorkspaceOutboxItem].self, from: encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, item.id)
        XCTAssertEqual(decoded.first?.kind, .saveUploadText)
        XCTAssertEqual(decoded.first?.mediaID, "media-uuid")
        XCTAssertEqual(decoded.first?.text, "Updated caption")
        XCTAssertEqual(decoded.first?.revision, 4)
    }

    func testUploadTextSyncStateTransitions() {
        let video = VideoAsset(
            driveFileID: "drive-99",
            accountFolderID: "folder-1",
            googleUserID: "user-1",
            name: "sample.mp4",
            mimeType: "video/mp4"
        )

        XCTAssertEqual(video.uploadTextSyncState, .synced)

        video.uploadTextSyncState = .saving
        XCTAssertEqual(video.uploadTextSyncStateRawValue, "saving")
        XCTAssertEqual(video.uploadTextSyncState, .saving)

        video.uploadTextSyncState = .conflict
        XCTAssertEqual(video.uploadTextSyncStateRawValue, "conflict")
        XCTAssertEqual(video.uploadTextSyncState, .conflict)

        video.uploadTextSyncState = .offline
        XCTAssertEqual(video.uploadTextSyncStateRawValue, "offline")
        XCTAssertEqual(video.uploadTextSyncState, .offline)
    }
}
