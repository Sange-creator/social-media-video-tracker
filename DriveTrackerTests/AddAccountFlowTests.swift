import Foundation
import SwiftData
import XCTest
@testable import DriveTracker

@MainActor
final class AddAccountFlowTests: XCTestCase {
    func testDriveFolderChoiceConformsToHashableAndIdentifiable() {
        let choice1 = DriveFolderChoice(id: "folder-123", name: "TikTok Viral", resourceKey: "key-abc")
        let choice2 = DriveFolderChoice(id: "folder-123", name: "TikTok Viral", resourceKey: "key-abc")
        let choice3 = DriveFolderChoice(id: "folder-456", name: "Reels", resourceKey: nil)

        XCTAssertEqual(choice1, choice2)
        XCTAssertNotEqual(choice1, choice3)
        XCTAssertEqual(choice1.id, "folder-123")
        XCTAssertEqual(choice1.name, "TikTok Viral")
        XCTAssertEqual(choice1.resourceKey, "key-abc")
    }

    func testAccountIconCatalogProducesConsistentStyles() {
        let style1 = AccountIconCatalog.style(forName: "Daily Motivation")
        let style2 = AccountIconCatalog.style(forName: "Daily Motivation")
        XCTAssertEqual(style1.symbol, style2.symbol)
        XCTAssertEqual(style1.colorHex, style2.colorHex)

        let emptyStyle = AccountIconCatalog.style(forName: "")
        XCTAssertFalse(emptyStyle.symbol.isEmpty)
        XCTAssertFalse(emptyStyle.colorHex.isEmpty)
    }

    func testAssociateFolderThrowsOnEmptyNames() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)

        let folder = DriveFolderChoice(id: "folder-xyz", name: "Test Folder", resourceKey: nil)

        // Attempting to associate with whitespace-only names should throw or report error
        await state.associateFolder(
            folder,
            link: nil,
            accountID: nil,
            accountName: "   ",
            folderName: "   ",
            dailyQuota: 3,
            iconSymbol: "sparkles",
            iconColorHex: "#4F46E5",
            context: context
        )

        XCTAssertNotNil(state.errorMessage)
    }

    private func makeTestContainer() throws -> ModelContainer {
        let schema = Schema([
            DriveSource.self,
            TikTokAccount.self,
            VideoAsset.self,
            DailyAssignment.self,
            StatusEvent.self,
            CopyEntry.self,
            CopyEvent.self
        ])
        let configuration = ModelConfiguration(
            "Test_AddAccount_\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
