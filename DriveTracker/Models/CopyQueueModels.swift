import Foundation
import SwiftData

enum CopyEventKind: String, Codable, CaseIterable {
    case copied
    case recopied
    case markedUncopied
    case contentChanged
    case removedFromDrive

    var title: String {
        switch self {
        case .copied: "Copied"
        case .recopied: "Copied Again"
        case .markedUncopied: "Marked Uncopied"
        case .contentChanged: "New Content"
        case .removedFromDrive: "Removed from Drive"
        }
    }
}

@Model
final class CopyEntry {
    @Attribute(.unique) var identityKey: String
    var googleUserID: String
    var accountFolderID: String
    var sourceSheetID: String
    var contentHash: String
    var sourceRow: Int
    var content: String
    var driveModifiedAt: Date?
    var lastSeenAt: Date
    var isMissingFromDrive: Bool
    var copiedAt: Date?
    var copyCount: Int
    var createdAt: Date
    var updatedAt: Date

    var account: TikTokAccount?

    @Relationship(deleteRule: .cascade, inverse: \CopyEvent.entry)
    var events: [CopyEvent]

    init(
        googleUserID: String,
        accountFolderID: String,
        sourceSheetID: String,
        contentHash: String,
        sourceRow: Int,
        content: String,
        driveModifiedAt: Date? = nil,
        account: TikTokAccount? = nil
    ) {
        self.identityKey = Self.makeIdentityKey(
            googleUserID: googleUserID,
            accountFolderID: accountFolderID,
            sourceSheetID: sourceSheetID,
            contentHash: contentHash
        )
        self.googleUserID = googleUserID
        self.accountFolderID = accountFolderID
        self.sourceSheetID = sourceSheetID
        self.contentHash = contentHash
        self.sourceRow = sourceRow
        self.content = content
        self.driveModifiedAt = driveModifiedAt
        self.lastSeenAt = .now
        self.isMissingFromDrive = false
        self.copiedAt = nil
        self.copyCount = 0
        self.createdAt = .now
        self.updatedAt = .now
        self.account = account
        self.events = []
    }

    static func makeIdentityKey(
        googleUserID: String,
        accountFolderID: String,
        sourceSheetID: String,
        contentHash: String
    ) -> String {
        "\(googleUserID)|\(accountFolderID)|\(sourceSheetID)|\(contentHash)"
    }
}

@Model
final class CopyEvent {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var timestamp: Date
    var detail: String?
    var accountName: String
    var entryIdentityKey: String
    var contentPreview: String

    var entry: CopyEntry?

    init(
        id: UUID = UUID(),
        kind: CopyEventKind,
        timestamp: Date = .now,
        detail: String? = nil,
        accountName: String,
        entryIdentityKey: String,
        contentPreview: String,
        entry: CopyEntry? = nil
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.timestamp = timestamp
        self.detail = detail
        self.accountName = accountName
        self.entryIdentityKey = entryIdentityKey
        self.contentPreview = String(contentPreview.prefix(180))
        self.entry = entry
    }

    var kind: CopyEventKind {
        CopyEventKind(rawValue: kindRawValue) ?? .copied
    }
}
