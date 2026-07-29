import CryptoKit
import Foundation
import SwiftData

struct CopyQueueRow: Equatable, Sendable {
    let sourceRow: Int
    let content: String
    let contentHash: String
}

struct CopyQueueSyncResult: Equatable, Sendable {
    let entriesFound: Int
    let newEntries: Int
    let changed: Bool
    let syncedAt: Date
}

enum CopyQueueError: LocalizedError, Equatable {
    case folderMissing
    case duplicateFolders
    case sheetMissing
    case duplicateSheets
    case invalidSheet
    case invalidCSV

    var errorDescription: String? {
        switch self {
        case .folderMissing:
            "Create one “Copy Paste” folder inside any connected Drive folder."
        case .duplicateFolders:
            "More than one “Copy Paste” folder was found. Keep only one global copy queue."
        case .sheetMissing:
            "Create one Google Sheet named “Queue” inside the “Copy Paste” folder."
        case .duplicateSheets:
            "More than one Google Sheet named “Queue” was found. Keep only one."
        case .invalidSheet:
            "The connected link must point to a Google Sheet that this Google account can open."
        case .invalidCSV:
            "The Queue sheet could not be read. Keep “Content” in row 1 and entries in column A."
        }
    }
}

enum CopyQueueCSVParser {
    static func rows(from data: Data) throws -> [CopyQueueRow] {
        guard let string = String(data: data, encoding: .utf8) else {
            throw CopyQueueError.invalidCSV
        }
        let leadingText = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard
            !leadingText.hasPrefix("<!doctype html"),
            !leadingText.hasPrefix("<html")
        else {
            throw CopyQueueError.invalidCSV
        }

        let table = try parse(string)
        guard !table.isEmpty else { return [] }

        var firstDataRow = 0
        if table.first?.first?
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Content") == .orderedSame
        {
            firstDataRow = 1
        }

        var newestByHash: [String: CopyQueueRow] = [:]
        for index in firstDataRow ..< table.count {
            guard var content = table[index].first else { continue }
            if index == 0 {
                content = content.replacingOccurrences(of: "\u{feff}", with: "")
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let hash = contentHash(content)
            let row = CopyQueueRow(
                sourceRow: index + 1,
                content: content,
                contentHash: hash
            )
            if row.sourceRow > (newestByHash[hash]?.sourceRow ?? 0) {
                newestByHash[hash] = row
            }
        }
        return newestByHash.values.sorted { $0.sourceRow < $1.sourceRow }
    }

    static func contentHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func parse(_ source: String) throws -> [[String]] {
        let characters = Array(source)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = 0

        func finishField() {
            row.append(field)
            field = ""
        }

        func finishRow() {
            finishField()
            rows.append(row)
            row = []
        }

        while index < characters.count {
            let character = characters[index]
            if isQuoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        isQuoted = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    isQuoted = true
                case ",":
                    finishField()
                case "\n":
                    finishRow()
                case "\r":
                    if index + 1 >= characters.count || characters[index + 1] != "\n" {
                        finishRow()
                    }
                default:
                    field.append(character)
                }
            }
            index += 1
        }

        guard !isQuoted else { throw CopyQueueError.invalidCSV }
        if !field.isEmpty || !row.isEmpty {
            finishRow()
        }
        return rows
    }
}

enum CopyQueueDiscovery {
    static func matchingCopyFolders(in items: [DriveItem]) -> [DriveItem] {
        items.filter {
            $0.isFolder &&
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Copy Paste") == .orderedSame
        }
    }

    static func copyFolder(in items: [DriveItem]) throws -> DriveItem {
        let matches = matchingCopyFolders(in: items)
        guard !matches.isEmpty else { throw CopyQueueError.folderMissing }
        guard matches.count == 1 else { throw CopyQueueError.duplicateFolders }
        return matches[0]
    }

    static func queueSheet(in items: [DriveItem]) throws -> DriveItem {
        let matches = items.filter {
            $0.isSpreadsheet &&
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Queue") == .orderedSame
        }
        guard !matches.isEmpty else { throw CopyQueueError.sheetMissing }
        guard matches.count == 1 else { throw CopyQueueError.duplicateSheets }
        return matches[0]
    }
}

@MainActor
final class CopyQueueService {
    private let api: DriveAPIClient

    init(api: DriveAPIClient) {
        self.api = api
    }

    func syncGlobal(
        accounts: [TikTokAccount],
        googleUserID: String,
        context: ModelContext
    ) async throws -> CopyQueueSyncResult {
        var locations: [(account: TikTokAccount, folder: DriveItem)] = []
        var visitedRootIDs = Set<String>()
        for account in accounts where
            account.googleUserID == googleUserID &&
            visitedRootIDs.insert(account.driveFolderID).inserted
        {
            let rootChildren = try await api.listChildren(
                of: account.driveFolderID,
                folderResourceKey: account.folderResourceKey
            )
            let folders = CopyQueueDiscovery.matchingCopyFolders(in: rootChildren)
            guard folders.count <= 1 else { throw CopyQueueError.duplicateFolders }
            if let folder = folders.first {
                locations.append((account, folder))
            }
        }
        guard !locations.isEmpty else { throw CopyQueueError.folderMissing }
        guard locations.count == 1 else { throw CopyQueueError.duplicateFolders }

        let hostAccount = locations[0].account
        let folder = locations[0].folder
        let folderChildren = try await api.listChildren(
            of: folder.effectiveID,
            folderResourceKey: folder.effectiveResourceKey
        )
        let sheet = try CopyQueueDiscovery.queueSheet(in: folderChildren)
        return try await importSheet(
            sheet,
            scopeID: hostAccount.driveFolderID,
            googleUserID: googleUserID,
            context: context
        )
    }

    func syncGlobal(
        sheetID: String,
        resourceKey: String?,
        googleUserID: String,
        context: ModelContext
    ) async throws -> CopyQueueSyncResult {
        let sheet = try await api.item(id: sheetID, resourceKey: resourceKey)
        guard sheet.isSpreadsheet else { throw CopyQueueError.invalidSheet }
        return try await importSheet(
            sheet,
            scopeID: "global",
            googleUserID: googleUserID,
            context: context
        )
    }

    private func importSheet(
        _ sheet: DriveItem,
        scopeID: String,
        googleUserID: String,
        context: ModelContext
    ) async throws -> CopyQueueSyncResult {
        let data = try await api.exportSpreadsheetCSV(
            id: sheet.effectiveID,
            resourceKey: sheet.effectiveResourceKey
        )
        let rows = try CopyQueueCSVParser.rows(from: data)
        let scanTime = Date.now
        let existing = try context.fetch(FetchDescriptor<CopyEntry>())
            .filter { $0.googleUserID == googleUserID }
        let existingByKey = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.identityKey, $0) }
        )
        let existingByContent = Dictionary(
            grouping: existing,
            by: {
                Self.semanticKey(
                    sheetID: $0.sourceSheetID,
                    contentHash: $0.contentHash
                )
            }
        )
        var seenKeys = Set<String>()
        var newEntries = 0
        var changed = false

        for row in rows {
            let key = CopyEntry.makeIdentityKey(
                googleUserID: googleUserID,
                accountFolderID: scopeID,
                sourceSheetID: sheet.effectiveID,
                contentHash: row.contentHash
            )
            let semanticKey = Self.semanticKey(
                sheetID: sheet.effectiveID,
                contentHash: row.contentHash
            )
            let semanticMatch = existingByContent[semanticKey]?
                .sorted(by: Self.preferredExistingEntry)
                .first
            if let entry = existingByKey[key] ?? semanticMatch {
                seenKeys.insert(entry.identityKey)
                let metadataChanged =
                    entry.accountFolderID != scopeID ||
                    entry.sourceRow != row.sourceRow ||
                    entry.content != row.content ||
                    entry.driveModifiedAt != sheet.modifiedDate ||
                    entry.isMissingFromDrive ||
                    entry.account != nil
                let refreshLastSeen =
                    scanTime.timeIntervalSince(entry.lastSeenAt) >= 86_400

                if metadataChanged || refreshLastSeen {
                    entry.accountFolderID = scopeID
                    entry.sourceRow = row.sourceRow
                    entry.content = row.content
                    entry.driveModifiedAt = sheet.modifiedDate
                    entry.lastSeenAt = scanTime
                    entry.isMissingFromDrive = false
                    entry.account = nil
                    if metadataChanged {
                        entry.updatedAt = scanTime
                    }
                    changed = true
                }
            } else {
                let entry = CopyEntry(
                    googleUserID: googleUserID,
                    accountFolderID: scopeID,
                    sourceSheetID: sheet.effectiveID,
                    contentHash: row.contentHash,
                    sourceRow: row.sourceRow,
                    content: row.content,
                    driveModifiedAt: sheet.modifiedDate,
                    account: nil
                )
                context.insert(entry)
                seenKeys.insert(entry.identityKey)
                context.insert(
                    CopyEvent(
                        kind: .contentChanged,
                        detail: "Imported from Queue row \(row.sourceRow)",
                        accountName: "Global Copy Queue",
                        entryIdentityKey: entry.identityKey,
                        contentPreview: entry.content,
                        entry: entry
                    )
                )
                newEntries += 1
                changed = true
            }
        }

        for entry in existing where !seenKeys.contains(entry.identityKey) {
            if !entry.isMissingFromDrive {
                entry.isMissingFromDrive = true
                entry.updatedAt = scanTime
                context.insert(
                    CopyEvent(
                        kind: .removedFromDrive,
                        detail: "No longer present in the Queue sheet",
                        accountName: "Global Copy Queue",
                        entryIdentityKey: entry.identityKey,
                        contentPreview: entry.content,
                        entry: entry
                    )
                )
                changed = true
            }
        }

        if changed {
            try context.save()
        }
        return CopyQueueSyncResult(
            entriesFound: rows.count,
            newEntries: newEntries,
            changed: changed,
            syncedAt: scanTime
        )
    }

    private static func semanticKey(sheetID: String, contentHash: String) -> String {
        "\(sheetID)|\(contentHash)"
    }

    private static func preferredExistingEntry(_ left: CopyEntry, _ right: CopyEntry) -> Bool {
        if (left.copiedAt != nil) != (right.copiedAt != nil) {
            return left.copiedAt != nil
        }
        if left.copyCount != right.copyCount {
            return left.copyCount > right.copyCount
        }
        return left.updatedAt > right.updatedAt
    }
}
