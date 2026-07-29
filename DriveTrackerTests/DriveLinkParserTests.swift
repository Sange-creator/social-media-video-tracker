import XCTest
@testable import DriveTracker

@MainActor
final class DriveLinkParserTests: XCTestCase {
    private let parser = DriveLinkParser()

    func testParsesModernFolderLinkAndResourceKey() throws {
        let reference = try parser.parse(
            "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMn?resourcekey=0-exampleKey"
        )

        XCTAssertEqual(reference.folderID, "1AbCdEfGhIjKlMn")
        XCTAssertEqual(reference.resourceKey, "0-exampleKey")
    }

    func testParsesLegacyOpenLink() throws {
        let reference = try parser.parse(
            "https://drive.google.com/open?id=1AbCdEfGhIjKlMn"
        )

        XCTAssertEqual(reference.folderID, "1AbCdEfGhIjKlMn")
        XCTAssertNil(reference.resourceKey)
    }

    func testParsesPlainFolderID() throws {
        let reference = try parser.parse("1AbCdEfGhIjKlMn_123")
        XCTAssertEqual(reference.folderID, "1AbCdEfGhIjKlMn_123")
    }

    func testRejectsNonDriveURL() {
        XCTAssertThrowsError(try parser.parse("https://example.com/folders/not-drive"))
    }

    func testRejectsBlankInput() {
        XCTAssertThrowsError(try parser.parse("  "))
    }

    func testParsesGoogleSheetLink() throws {
        let reference = try GoogleSheetLinkParser().parse(
            "https://docs.google.com/spreadsheets/d/1SheetAbCdEfGhIjKlMn/edit#gid=0"
        )

        XCTAssertEqual(reference.fileID, "1SheetAbCdEfGhIjKlMn")
        XCTAssertNil(reference.resourceKey)
    }

    func testParsesGoogleDriveFileLinkAndResourceKey() throws {
        let reference = try GoogleSheetLinkParser().parse(
            "https://drive.google.com/file/d/1SheetAbCdEfGhIjKlMn/view?resourcekey=queue-key"
        )

        XCTAssertEqual(reference.fileID, "1SheetAbCdEfGhIjKlMn")
        XCTAssertEqual(reference.resourceKey, "queue-key")
    }

    func testRejectsNonGoogleSheetHost() {
        XCTAssertThrowsError(
            try GoogleSheetLinkParser().parse(
                "https://example.com/spreadsheets/d/1SheetAbCdEfGhIjKlMn"
            )
        )
    }
}
