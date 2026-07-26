import Foundation

struct DriveFolderReference: Equatable, Sendable {
    let folderID: String
    let resourceKey: String?
}

enum DriveLinkError: LocalizedError, Equatable {
    case empty
    case invalidFolderLink

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a Google Drive folder link or folder ID."
        case .invalidFolderLink:
            "This does not look like a Google Drive folder link."
        }
    }
}

struct DriveLinkParser {
    func parse(_ input: String) throws -> DriveFolderReference {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DriveLinkError.empty }

        if isLikelyID(value) {
            return DriveFolderReference(folderID: value, resourceKey: nil)
        }

        guard
            let components = URLComponents(string: value),
            let host = components.host?.lowercased(),
            host == "drive.google.com" || host.hasSuffix(".drive.google.com")
        else {
            throw DriveLinkError.invalidFolderLink
        }

        let parts = components.path.split(separator: "/").map(String.init)
        var folderID: String?
        if let folderIndex = parts.firstIndex(of: "folders"), parts.indices.contains(folderIndex + 1) {
            folderID = parts[folderIndex + 1]
        } else if let id = components.queryItems?.first(where: { $0.name == "id" })?.value {
            folderID = id
        }

        guard let folderID, isLikelyID(folderID) else {
            throw DriveLinkError.invalidFolderLink
        }

        let resourceKey = components.queryItems?
            .first(where: { $0.name.lowercased() == "resourcekey" })?
            .value
        return DriveFolderReference(folderID: folderID, resourceKey: resourceKey)
    }

    private func isLikelyID(_ value: String) -> Bool {
        value.count >= 10 &&
        value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}

