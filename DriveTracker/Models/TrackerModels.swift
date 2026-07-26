import Foundation
import SwiftData

enum VideoStatus: String, Codable, CaseIterable, Identifiable {
    case available
    case assigned
    case downloaded
    case uploaded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .available: "Available"
        case .assigned: "Suggested"
        case .downloaded: "Downloaded"
        case .uploaded: "Completed"
        }
    }

    var symbol: String {
        switch self {
        case .available: "circle"
        case .assigned: "calendar.badge.clock"
        case .downloaded: "arrow.down.circle.fill"
        case .uploaded: "checkmark.circle.fill"
        }
    }
}

enum StatusEventKind: String, Codable {
    case assigned
    case manuallySelected
    case replaced
    case downloadStarted
    case downloadSucceeded
    case downloadFailed
    case uploadConfirmed
    case uploadUndone
    case reset

    var title: String {
        switch self {
        case .assigned: "Suggested"
        case .manuallySelected: "Added to Today"
        case .replaced: "Suggestion Replaced"
        case .downloadStarted: "Download Started"
        case .downloadSucceeded: "Downloaded"
        case .downloadFailed: "Download Failed"
        case .uploadConfirmed: "Completed"
        case .uploadUndone: "Completion Undone"
        case .reset: "Status Reset"
        }
    }
}

@Model
final class DriveSource {
    @Attribute(.unique) var id: UUID
    var googleUserID: String
    var googleEmail: String
    var rootFolderID: String
    var rootResourceKey: String?
    var rootLink: String
    var displayName: String
    var isEnabled: Bool
    var createdAt: Date
    var lastSyncedAt: Date?

    init(
        id: UUID = UUID(),
        googleUserID: String,
        googleEmail: String,
        rootFolderID: String,
        rootResourceKey: String? = nil,
        rootLink: String,
        displayName: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.googleUserID = googleUserID
        self.googleEmail = googleEmail
        self.rootFolderID = rootFolderID
        self.rootResourceKey = rootResourceKey
        self.rootLink = rootLink
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.createdAt = .now
        self.lastSyncedAt = nil
    }
}

@Model
final class TikTokAccount {
    @Attribute(.unique) var id: UUID
    var googleUserID: String
    var driveFolderID: String
    var folderResourceKey: String?
    var folderName: String
    var displayName: String
    var dailyQuota: Int
    var isPaused: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var isMissingFromDrive: Bool
    var sourceID: UUID?
    var googleEmail: String?
    var isConfigured: Bool = true
    var iconSymbol: String = "folder.fill"
    var iconColorHex: String = "#4F46E5"

    @Relationship(deleteRule: .cascade, inverse: \VideoAsset.account)
    var videos: [VideoAsset]

    @Relationship(deleteRule: .cascade, inverse: \DailyAssignment.account)
    var assignments: [DailyAssignment]

    init(
        id: UUID = UUID(),
        googleUserID: String,
        driveFolderID: String,
        folderResourceKey: String? = nil,
        folderName: String,
        displayName: String? = nil,
        dailyQuota: Int = 3,
        isPaused: Bool = false,
        sortOrder: Int = 0,
        sourceID: UUID? = nil,
        googleEmail: String? = nil,
        isConfigured: Bool = true,
        iconSymbol: String? = nil,
        iconColorHex: String? = nil
    ) {
        let defaultIcon = AccountIconCatalog.style(for: id)
        self.id = id
        self.googleUserID = googleUserID
        self.driveFolderID = driveFolderID
        self.folderResourceKey = folderResourceKey
        self.folderName = folderName
        self.displayName = displayName ?? folderName
        self.dailyQuota = max(1, dailyQuota)
        self.isPaused = isPaused
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.updatedAt = .now
        self.isMissingFromDrive = false
        self.sourceID = sourceID
        self.googleEmail = googleEmail
        self.isConfigured = isConfigured
        self.iconSymbol = iconSymbol ?? defaultIcon.symbol
        self.iconColorHex = iconColorHex ?? defaultIcon.colorHex
        self.videos = []
        self.assignments = []
    }

    var outstandingCount: Int {
        videos.filter { $0.status == .assigned || $0.status == .downloaded }.count
    }

    var uploadedCount: Int {
        videos.filter { $0.status == .uploaded }.count
    }

    var availableCount: Int {
        videos.filter { $0.status == .available && !$0.isMissingFromDrive && $0.canDownload }.count
    }

    var missingCount: Int {
        videos.filter(\.isMissingFromDrive).count
    }
}

enum AccountIconCatalog {
    struct Style: Equatable, Sendable {
        let symbol: String
        let colorHex: String
    }

    nonisolated static let symbols = [
        "sparkles", "bolt.fill", "flame.fill", "star.fill",
        "crown.fill", "diamond.fill", "leaf.fill", "moon.stars.fill",
        "sun.max.fill", "heart.fill", "camera.fill", "play.rectangle.fill"
    ]

    nonisolated static let colors = [
        "#4F46E5", "#2563EB", "#0891B2", "#059669",
        "#D97706", "#EA580C", "#E11D48", "#9333EA"
    ]

    nonisolated static func style(for id: UUID) -> Style {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let symbolIndex = Int(bytes[0]) % symbols.count
        let colorIndex = Int(bytes[1]) % colors.count
        return Style(symbol: symbols[symbolIndex], colorHex: colors[colorIndex])
    }

    nonisolated static func style(for position: Int) -> Style {
        Style(
            symbol: symbols[position % symbols.count],
            colorHex: colors[position % colors.count]
        )
    }
}

@Model
final class VideoAsset {
    @Attribute(.unique) var identityKey: String
    var driveFileID: String
    var accountFolderID: String
    var googleUserID: String
    var resourceKey: String?
    var name: String
    /// Human-readable path beneath the folder attached to the managed account.
    /// Root-level files use the tracked folder's display name.
    var folderPath: String = ""
    var mimeType: String
    var size: Int64?
    var checksum: String?
    var driveModifiedAt: Date?
    var lastSeenAt: Date
    var isMissingFromDrive: Bool
    var canDownload: Bool
    var downloadedAt: Date?
    var uploadedAt: Date?
    var photoLocalIdentifier: String?
    var isMissingFromPhotos: Bool = false
    var createdAt: Date
    var updatedAt: Date

    var account: TikTokAccount?

    @Relationship(deleteRule: .cascade, inverse: \DailyAssignment.video)
    var assignments: [DailyAssignment]

    @Relationship(deleteRule: .cascade, inverse: \StatusEvent.video)
    var events: [StatusEvent]

    init(
        driveFileID: String,
        accountFolderID: String,
        googleUserID: String,
        name: String,
        folderPath: String = "",
        mimeType: String,
        resourceKey: String? = nil,
        size: Int64? = nil,
        checksum: String? = nil,
        driveModifiedAt: Date? = nil,
        canDownload: Bool = true,
        account: TikTokAccount? = nil
    ) {
        self.identityKey = Self.makeIdentityKey(
            googleUserID: googleUserID,
            accountFolderID: accountFolderID,
            driveFileID: driveFileID
        )
        self.driveFileID = driveFileID
        self.accountFolderID = accountFolderID
        self.googleUserID = googleUserID
        self.resourceKey = resourceKey
        self.name = name
        self.folderPath = folderPath
        self.mimeType = mimeType
        self.size = size
        self.checksum = checksum
        self.driveModifiedAt = driveModifiedAt
        self.lastSeenAt = .now
        self.isMissingFromDrive = false
        self.canDownload = canDownload
        self.downloadedAt = nil
        self.uploadedAt = nil
        self.photoLocalIdentifier = nil
        self.isMissingFromPhotos = false
        self.createdAt = .now
        self.updatedAt = .now
        self.account = account
        self.assignments = []
        self.events = []
    }

    static func makeIdentityKey(googleUserID: String, accountFolderID: String, driveFileID: String) -> String {
        "\(googleUserID)|\(accountFolderID)|\(driveFileID)"
    }

    var activeAssignment: DailyAssignment? {
        assignments
            .filter(\.isActive)
            .sorted { $0.assignedAt > $1.assignedAt }
            .first
    }

    var status: VideoStatus {
        if uploadedAt != nil { return .uploaded }
        if downloadedAt != nil { return .downloaded }
        if activeAssignment != nil { return .assigned }
        return .available
    }
}

@Model
final class DailyAssignment {
    @Attribute(.unique) var id: UUID
    var localDayKey: String
    var slot: Int
    var assignedAt: Date
    var isActive: Bool
    var completedAt: Date?
    var updatedAt: Date
    var account: TikTokAccount?
    var video: VideoAsset?

    init(
        id: UUID = UUID(),
        localDayKey: String,
        slot: Int,
        assignedAt: Date = .now,
        account: TikTokAccount,
        video: VideoAsset
    ) {
        self.id = id
        self.localDayKey = localDayKey
        self.slot = slot
        self.assignedAt = assignedAt
        self.isActive = true
        self.completedAt = nil
        self.updatedAt = assignedAt
        self.account = account
        self.video = video
    }
}

@Model
final class StatusEvent {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var timestamp: Date
    var detail: String?
    var accountName: String
    var driveFileID: String
    var videoName: String
    var video: VideoAsset?

    init(
        id: UUID = UUID(),
        kind: StatusEventKind,
        timestamp: Date = .now,
        detail: String? = nil,
        accountName: String,
        driveFileID: String,
        videoName: String,
        video: VideoAsset? = nil
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.timestamp = timestamp
        self.detail = detail
        self.accountName = accountName
        self.driveFileID = driveFileID
        self.videoName = videoName
        self.video = video
    }

    var kind: StatusEventKind {
        StatusEventKind(rawValue: kindRawValue) ?? .reset
    }
}

enum DayKey {
    static func value(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
