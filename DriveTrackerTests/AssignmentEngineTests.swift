import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class AssignmentEngineTests: XCTestCase {
    private lazy var container: ModelContainer = {
        let schema = Schema([
            TikTokAccount.self,
            VideoAsset.self,
            DailyAssignment.self,
            StatusEvent.self
        ])
        return try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
        )
    }()
    private lazy var context = container.mainContext
    private let engine = AssignmentEngine()

    func testInitialQuotaCreatesThreeUniqueAssignments() throws {
        let account = makeAccount(videoCount: 10, quota: 3)

        let summary = try engine.ensureAssignments(
            for: account,
            context: context,
            shuffledBy: { $0.sorted { $0.name < $1.name } }
        )

        XCTAssertEqual(summary, AssignmentSummary(added: 3, outstanding: 3, shortage: 0))
        XCTAssertEqual(account.videos.filter { $0.status == .assigned }.count, 3)
        XCTAssertEqual(Set(account.videos.compactMap(\.activeAssignment?.video?.driveFileID)).count, 3)
    }

    func testEnsureIsIdempotentDuringSameDay() throws {
        let account = makeAccount(videoCount: 10, quota: 3)
        _ = try engine.ensureAssignments(for: account, context: context)

        let second = try engine.ensureAssignments(for: account, context: context)

        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(account.videos.filter { $0.status == .assigned }.count, 3)
    }

    func testUploadedTodayDoesNotCauseFourthSuggestion() throws {
        let account = makeAccount(videoCount: 10, quota: 3)
        _ = try engine.ensureAssignments(for: account, context: context)
        let first = try XCTUnwrap(account.videos.first { $0.status == .assigned })

        try engine.markDownloaded(first, photoIdentifier: "photo-1", context: context)
        try engine.markUploaded(first, context: context)
        let sameDay = try engine.ensureAssignments(for: account, context: context)

        XCTAssertEqual(first.status, .uploaded)
        XCTAssertEqual(sameDay.added, 0)
        XCTAssertEqual(account.videos.filter { $0.status == .assigned }.count, 2)
    }

    func testNextDayCarriesOverAndTopsUp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = Date(timeIntervalSince1970: 1_800_000_000)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let account = makeAccount(videoCount: 10, quota: 3)
        _ = try engine.ensureAssignments(for: account, on: firstDay, context: context)
        let first = try XCTUnwrap(account.videos.first { $0.status == .assigned })
        try engine.markDownloaded(first, photoIdentifier: nil, at: firstDay, context: context)
        try engine.markUploaded(first, at: firstDay, context: context)

        let next = try engine.ensureAssignments(
            for: account,
            on: nextDay,
            context: context,
            shuffledBy: { $0.sorted { $0.name < $1.name } }
        )

        XCTAssertEqual(next.added, 1)
        XCTAssertEqual(next.outstanding, 3)
    }

    func testDownloadedVideoCannotBeReplaced() throws {
        let account = makeAccount(videoCount: 5, quota: 3)
        _ = try engine.ensureAssignments(for: account, context: context)
        let video = try XCTUnwrap(account.videos.first { $0.status == .assigned })
        let assignment = try XCTUnwrap(video.activeAssignment)
        try engine.markDownloaded(video, photoIdentifier: "photo-1", context: context)

        XCTAssertFalse(try engine.replace(assignment, context: context))
        XCTAssertEqual(video.status, .downloaded)
    }

    func testUploadRequiresCompletedDownload() throws {
        let account = makeAccount(videoCount: 3, quota: 3)
        _ = try engine.ensureAssignments(for: account, context: context)
        let video = try XCTUnwrap(account.videos.first)

        try engine.markUploaded(video, context: context)

        XCTAssertNil(video.uploadedAt)
        XCTAssertNotEqual(video.status, .uploaded)
    }

    func testReportsShortageWithoutRepeatingVideos() throws {
        let account = makeAccount(videoCount: 2, quota: 3)

        let summary = try engine.ensureAssignments(for: account, context: context)

        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.shortage, 1)
        XCTAssertEqual(account.videos.filter { $0.status == .assigned }.count, 2)
    }

    func testTenAccountsGenerateThirtyUniqueAssignments() throws {
        var assignedIdentities = Set<String>()
        for accountIndex in 1 ... 10 {
            let account = TikTokAccount(
                googleUserID: "test-user",
                driveFolderID: "folder-\(accountIndex)",
                folderName: "Account \(accountIndex)",
                dailyQuota: 3
            )
            context.insert(account)
            for videoIndex in 1 ... 100 {
                context.insert(
                    VideoAsset(
                        driveFileID: "file-\(accountIndex)-\(videoIndex)",
                        accountFolderID: account.driveFolderID,
                        googleUserID: "test-user",
                        name: "video-\(videoIndex).mp4",
                        mimeType: "video/mp4",
                        account: account
                    )
                )
            }
            try context.save()
            let summary = try engine.ensureAssignments(for: account, context: context)
            XCTAssertEqual(summary.added, 3)
            assignedIdentities.formUnion(
                account.videos.filter { $0.status == .assigned }.map(\.identityKey)
            )
        }

        XCTAssertEqual(assignedIdentities.count, 30)
    }

    func testDownloadedVideoIsNeverSuggestedForNewQueue() throws {
        let account = makeAccount(videoCount: 3, quota: 1)
        let downloaded = account.videos.sorted { $0.name < $1.name }[0]
        downloaded.downloadedAt = .now
        try context.save()

        let summary = try engine.ensureAssignments(
            for: account,
            context: context,
            shuffledBy: { $0.sorted { $0.name < $1.name } }
        )

        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(downloaded.status, .downloaded)
        XCTAssertNil(downloaded.activeAssignment)
    }

    func testManualSelectionReplacesUntouchedSuggestion() throws {
        let account = makeAccount(videoCount: 4, quota: 1)
        _ = try engine.ensureAssignments(
            for: account,
            context: context,
            shuffledBy: { $0.sorted { $0.name < $1.name } }
        )
        let original = try XCTUnwrap(account.videos.first { $0.status == .assigned })
        let manual = try XCTUnwrap(account.videos.first { $0.status == .available })

        let assignment = try engine.selectManually(manual, context: context)

        XCTAssertNotNil(assignment)
        XCTAssertEqual(manual.status, .assigned)
        XCTAssertEqual(original.status, .available)
        XCTAssertEqual(account.outstandingCount, 1)
    }

    func testImmediateManualDownloadDoesNotReplaceDailySuggestion() throws {
        let account = makeAccount(videoCount: 4, quota: 1)
        _ = try engine.ensureAssignments(
            for: account,
            context: context,
            shuffledBy: { $0.sorted { $0.name < $1.name } }
        )
        let original = try XCTUnwrap(account.videos.first { $0.status == .assigned })
        let manual = try XCTUnwrap(account.videos.first { $0.status == .available })

        let assignment = try engine.selectManually(
            manual,
            replaceExistingSuggestion: false,
            context: context
        )

        XCTAssertNotNil(assignment)
        XCTAssertEqual(original.status, .assigned)
        XCTAssertEqual(manual.status, .assigned)
        XCTAssertEqual(account.outstandingCount, 2)
    }

    func testUnconfiguredFolderDoesNotCreateSuggestions() throws {
        let account = makeAccount(videoCount: 4, quota: 3)
        account.isConfigured = false

        let summary = try engine.ensureAssignments(for: account, context: context)

        XCTAssertEqual(summary.added, 0)
        XCTAssertTrue(account.videos.allSatisfy { $0.status == .available })
    }

    func testLowerQuotaReturnsUntouchedSuggestionsToAvailablePool() throws {
        let account = makeAccount(videoCount: 8, quota: 4)
        _ = try engine.ensureAssignments(for: account, context: context)
        XCTAssertEqual(account.outstandingCount, 4)

        account.dailyQuota = 2
        let summary = try engine.ensureAssignments(for: account, context: context)

        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.outstanding, 2)
        XCTAssertEqual(account.videos.filter { $0.status == .assigned }.count, 2)
        XCTAssertEqual(account.videos.filter { $0.status == .available }.count, 6)
    }

    private func makeAccount(videoCount: Int, quota: Int) -> TikTokAccount {
        let account = TikTokAccount(
            googleUserID: "test-user",
            driveFolderID: UUID().uuidString,
            folderName: "Test account",
            dailyQuota: quota
        )
        context.insert(account)
        for index in 1 ... videoCount {
            context.insert(
                VideoAsset(
                    driveFileID: "drive-file-\(index)",
                    accountFolderID: account.driveFolderID,
                    googleUserID: "test-user",
                    name: "video-\(index).mp4",
                    mimeType: "video/mp4",
                    account: account
                )
            )
        }
        try! context.save()
        return account
    }
}
