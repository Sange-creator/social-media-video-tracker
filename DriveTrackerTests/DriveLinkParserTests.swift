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
}
