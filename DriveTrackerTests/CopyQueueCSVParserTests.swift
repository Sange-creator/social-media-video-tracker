import XCTest
@testable import DriveTracker

@MainActor
final class CopyQueueCSVParserTests: XCTestCase {
    func testParsesHeaderUnicodeQuotesCommasAndMultilineContent() throws {
        let csv = """
        Content,Ignored
        "First title, with comma
        #one #two",x
        "Emoji 😀 and ""quoted"" words",y
        """

        let rows = try CopyQueueCSVParser.rows(from: Data(csv.utf8))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].sourceRow, 2)
        XCTAssertEqual(rows[0].content, "First title, with comma\n#one #two")
        XCTAssertEqual(rows[1].content, "Emoji 😀 and \"quoted\" words")
    }

    func testIgnoresBlankRowsAndKeepsNewestIdenticalContent() throws {
        let csv = """
        Content
        Same title #tag

        Different title
        Same title #tag
        """

        let rows = try CopyQueueCSVParser.rows(from: Data(csv.utf8))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(
            rows.first { $0.content == "Same title #tag" }?.sourceRow,
            5
        )
    }

    func testContentHashIsStableAndChangesAfterEdit() {
        XCTAssertEqual(
            CopyQueueCSVParser.contentHash("Title #tag"),
            CopyQueueCSVParser.contentHash("Title #tag")
        )
        XCTAssertNotEqual(
            CopyQueueCSVParser.contentHash("Title #tag"),
            CopyQueueCSVParser.contentHash("Edited title #tag")
        )
    }

    func testAcceptsUTF8BOMBeforeOptionalContentHeader() throws {
        let csv = "\u{feff}Content\nNewest title #tag"

        let rows = try CopyQueueCSVParser.rows(from: Data(csv.utf8))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sourceRow, 2)
        XCTAssertEqual(rows[0].content, "Newest title #tag")
    }

    func testRejectsHTMLAndMalformedQuotedCSV() {
        XCTAssertThrowsError(
            try CopyQueueCSVParser.rows(from: Data("<!doctype html><html></html>".utf8))
        ) {
            XCTAssertEqual($0 as? CopyQueueError, .invalidCSV)
        }
        XCTAssertThrowsError(
            try CopyQueueCSVParser.rows(from: Data("Content\n\"unfinished".utf8))
        ) {
            XCTAssertEqual($0 as? CopyQueueError, .invalidCSV)
        }
    }

    func testDiscoversFolderAndSheetCaseInsensitively() throws {
        let folder = driveItem(
            id: "copy-folder",
            name: "copy paste",
            mimeType: DriveItem.folderMimeType
        )
        let sheet = driveItem(
            id: "queue-sheet",
            name: "QUEUE",
            mimeType: DriveItem.spreadsheetMimeType
        )

        XCTAssertEqual(
            try CopyQueueDiscovery.copyFolder(in: [folder]).id,
            "copy-folder"
        )
        XCTAssertEqual(
            try CopyQueueDiscovery.queueSheet(in: [sheet]).id,
            "queue-sheet"
        )
    }

    func testDiscoveryRejectsMissingAndDuplicateConfiguration() {
        XCTAssertThrowsError(try CopyQueueDiscovery.copyFolder(in: [])) {
            XCTAssertEqual($0 as? CopyQueueError, .folderMissing)
        }
        let first = driveItem(
            id: "one",
            name: "Copy Paste",
            mimeType: DriveItem.folderMimeType
        )
        let second = driveItem(
            id: "two",
            name: "COPY PASTE",
            mimeType: DriveItem.folderMimeType
        )
        XCTAssertThrowsError(
            try CopyQueueDiscovery.copyFolder(in: [first, second])
        ) {
            XCTAssertEqual($0 as? CopyQueueError, .duplicateFolders)
        }
    }

    private func driveItem(
        id: String,
        name: String,
        mimeType: String
    ) -> DriveItem {
        DriveItem(
            id: id,
            name: name,
            mimeType: mimeType,
            size: nil,
            md5Checksum: nil,
            modifiedTime: nil,
            thumbnailLink: nil,
            resourceKey: nil,
            capabilities: nil,
            shortcutDetails: nil
        )
    }
}
