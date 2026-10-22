import SwiftData
import SwiftUI
import XCTest
@testable import DriveTracker

@MainActor
final class HomeOrderingTests: XCTestCase {
    func testMoveBottomAccountToTopPersistsWithoutChangingVideoSlots() throws {
        let schema = ModelContainerFactory.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let accounts = (0..<20).map { index in
            TikTokAccount(googleUserID: "qa", driveFolderID: "\(index)", folderName: "Creator \(index)", isPaused: index == 1, sortOrder: index)
        }
        accounts.forEach { context.insert($0) }
        let video = VideoAsset(driveFileID: "v", accountFolderID: "19", googleUserID: "qa", name: "Episode.mp4", mimeType: "video/mp4", account: accounts[19])
        context.insert(video)
        let assignment = DailyAssignment(localDayKey: DayKey.value(for: .now), slot: 3, account: accounts[19], video: video)
        context.insert(assignment)
        try context.save()
        let visible = accounts.filter { !$0.isPaused }
        try HomeAccountOrdering.move(accounts: accounts, visibleIDs: visible.map(\.id), from: IndexSet(integer: visible.count - 1), to: 0, context: context)
        let fetched = try context.fetch(FetchDescriptor<TikTokAccount>(sortBy: [SortDescriptor(\.sortOrder)]))
        XCTAssertEqual(fetched.first?.id, accounts[19].id)
        XCTAssertEqual(fetched[1].id, accounts[1].id, "Hidden accounts retain their position")
        XCTAssertEqual(assignment.slot, 3)
        XCTAssertEqual(Set(fetched.map(\.sortOrder)).count, 20)
    }

    func testThreePreviewCardsFitNarrowPhonesAndEditHandles() {
        for available in [CGFloat(255), 305, 329, 380] {
            let width = TodayCarouselLayout.cardWidth(available: available, accessibility: false)
            XCTAssertLessThanOrEqual(width * 3 + 16, available + 0.5)
            XCTAssertGreaterThanOrEqual(width, 76)
        }
        XCTAssertGreaterThanOrEqual(TodayCarouselLayout.cardWidth(available: 305, accessibility: true), 180)
    }
}
