import XCTest
@testable import DriveTracker

@MainActor
final class CopyQueueCSVParserTests: XCTestCase {
    func testParsesHeaderUnicodeQuotesCommasAndMultilineContent() throws {
        let csv = """
        "First title, with comma
        #one #two",x
        "Emoji 😀 and ""quoted"" words",y
        """

        let rows = try CopyQueueCSVParser.rows(from: Data(csv.utf8))

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].sourceRow, 1)
        XCTAssertEqual(rows[0].content, "First title, with comma\n#one #two\n\nx")
        XCTAssertEqual(rows[1].sourceRow, 2)
        XCTAssertEqual(rows[1].content, "Emoji 😀 and \"quoted\" words\n\ny")
    }

    func testIgnoresBlankRowsAndKeepsAllContentInRowOrder() throws {
        let csv = """
        First title #tag1

        Second title #tag2
        Third title #tag3
        """

        let rows = try CopyQueueCSVParser.rows(from: Data(csv.utf8))

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].sourceRow, 1)
        XCTAssertEqual(rows[1].sourceRow, 3)
        XCTAssertEqual(rows[2].sourceRow, 4)
    }

    func testPreservesMultilineBlockAsSingleRowClipboardWithBlankRow1() throws {
        let csv = """


        "Kids Today vs. 90s UK Kids 🇬🇧 | The Brutal Sunday Dread & VHS Shop Rules | NostalgiaUK Did your weekend end with the heavy dread of staring at an ironed school shirt? 🥺 From Saturday morning cereal on th...
        Hit FOLLOW to keep the VHS rolling with NostalgiaUK... the tape's not done yet! 📼🇬🇧 #NostalgiaUK #90schildhood #BritishNostalgia #90sKidsUK #ChildhoodMemories"
        """

        let rows = try CopyQueueCSVParser.rows(from: Data(csv.utf8))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sourceRow, 3)
        XCTAssertTrue(rows[0].content.contains("Kids Today vs. 90s UK Kids"))
        XCTAssertTrue(rows[0].content.contains("#ChildhoodMemories"))
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

    func testAcceptsUTF8BOMBeforeContentAndPreservesRow1() throws {
        let csv = "\u{feff}Newest title #tag"

        let rows = try CopyQueueCSVParser.rows(from: Data(csv.utf8))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sourceRow, 1)
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
