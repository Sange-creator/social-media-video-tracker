import Foundation

struct DriveCapabilities: Decodable, Sendable {
    let canDownload: Bool?
}

struct DriveShortcutDetails: Decodable, Sendable {
    let targetId: String?
    let targetMimeType: String?
    let targetResourceKey: String?
}

struct DriveItem: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let md5Checksum: String?
    let modifiedTime: String?
    let resourceKey: String?
    let capabilities: DriveCapabilities?
    let shortcutDetails: DriveShortcutDetails?

    static let folderMimeType = "application/vnd.google-apps.folder"
    static let shortcutMimeType = "application/vnd.google-apps.shortcut"

    var effectiveID: String {
        shortcutDetails?.targetId ?? id
    }

    var effectiveMimeType: String {
        shortcutDetails?.targetMimeType ?? mimeType
    }

    var effectiveResourceKey: String? {
        shortcutDetails?.targetResourceKey ?? resourceKey
    }

    var isFolder: Bool {
        effectiveMimeType == Self.folderMimeType
    }

    var isVideo: Bool {
        effectiveMimeType.hasPrefix("video/")
    }

    var sizeValue: Int64? {
        size.flatMap(Int64.init)
    }

    var modifiedDate: Date? {
        guard let modifiedTime else { return nil }
        return DriveAPIClient.dateFormatter.date(from: modifiedTime)
    }
}

struct DriveListResponse: Decodable, Sendable {
    let nextPageToken: String?
    let files: [DriveItem]
}

enum DriveAPIError: LocalizedError {
    case invalidResponse
    case http(Int, String)
    case itemNotDownloadable
    case malformedURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Google Drive returned an invalid response."
        case let .http(code, message):
            "Google Drive error \(code): \(message)"
        case .itemNotDownloadable:
            "Google Drive does not permit downloading this video."
        case .malformedURL:
            "The Google Drive request could not be created."
        }
    }
}

@MainActor
final class DriveAPIClient {
    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let auth: GoogleAuthService
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(auth: GoogleAuthService, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func item(id: String, resourceKey: String? = nil) async throws -> DriveItem {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "fields", value: Self.fields),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components?.url else { throw DriveAPIError.malformedURL }
        var request = try await authorizedRequest(url: url, resourceKeys: resourceHeader(id: id, key: resourceKey))
        request.httpMethod = "GET"
        let data = try await data(for: request)
        return try decoder.decode(DriveItem.self, from: data)
    }

    func listChildren(
        of folderID: String,
        folderResourceKey: String? = nil
    ) async throws -> [DriveItem] {
        var allItems: [DriveItem] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")
            var queryItems = [
                URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fields))"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "supportsAllDrives", value: "true")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw DriveAPIError.malformedURL }
            let request = try await authorizedRequest(
                url: url,
                resourceKeys: resourceHeader(id: folderID, key: folderResourceKey)
            )
            let data = try await data(for: request)
            let page = try decoder.decode(DriveListResponse.self, from: data)
            allItems.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil

        return allItems
    }

    func listSharedFolders() async throws -> [DriveItem] {
        var allItems: [DriveItem] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")
            var queryItems = [
                URLQueryItem(
                    name: "q",
                    value: "sharedWithMe = true and mimeType = '\(DriveItem.folderMimeType)' and trashed = false"
                ),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fields))"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "orderBy", value: "name"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "supportsAllDrives", value: "true")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw DriveAPIError.malformedURL }
            let data = try await data(for: authorizedRequest(url: url))
            let page = try decoder.decode(DriveListResponse.self, from: data)
            allItems.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil

        return allItems
    }

    func downloadRequest(for item: VideoAsset) async throws -> URLRequest {
        guard item.canDownload else { throw DriveAPIError.itemNotDownloadable }
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(item.driveFileID)"
        )
        components?.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components?.url else { throw DriveAPIError.malformedURL }
        return try await authorizedRequest(
            url: url,
            resourceKeys: resourceHeader(id: item.driveFileID, key: item.resourceKey)
        )
    }

    /// Downloads a foreground-only temporary copy for playback. This does not
    /// change tracker state or save the video to Photos.
    func previewFile(for item: VideoAsset) async throws -> URL {
        let request = try await downloadRequest(for: item)
        let (temporaryURL, response) = try await session.download(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200 ... 299).contains(http.statusCode)
        else {
            throw DriveAPIError.invalidResponse
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveTrackerPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceExtension = (item.name as NSString).pathExtension
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceExtension.isEmpty ? "mp4" : sourceExtension)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func listAppDataFile(named name: String) async throws -> DriveItem? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")
        components?.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name = '\(escapeQuery(name))' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(\(Self.fields))"),
            URLQueryItem(name: "pageSize", value: "10")
        ]
        guard let url = components?.url else { throw DriveAPIError.malformedURL }
        let request = try await authorizedRequest(url: url)
        let data = try await data(for: request)
        return try decoder.decode(DriveListResponse.self, from: data).files.first
    }

    func downloadAppData(id: String) async throws -> Data {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media") else {
            throw DriveAPIError.malformedURL
        }
        return try await data(for: authorizedRequest(url: url))
    }

    func createAppData(name: String, data: Data) async throws {
        let boundary = "DriveTracker-\(UUID().uuidString)"
        guard let url = URL(
            string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id"
        ) else {
            throw DriveAPIError.malformedURL
        }
        let metadata = try JSONSerialization.data(
            withJSONObject: ["name": name, "parents": ["appDataFolder"]]
        )
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadata)
        body.append("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = try await authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await self.data(for: request)
    }

    func updateAppData(id: String, data: Data) async throws {
        guard let url = URL(
            string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media"
        ) else {
            throw DriveAPIError.malformedURL
        }
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await self.data(for: request)
    }

    func deleteFile(id: String) async throws {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)") else {
            throw DriveAPIError.malformedURL
        }
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await data(for: request, allowsEmpty: true)
    }

    private func authorizedRequest(url: URL, resourceKeys: String? = nil) async throws -> URLRequest {
        let token = try await auth.accessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let resourceKeys {
            request.setValue(resourceKeys, forHTTPHeaderField: "X-Goog-Drive-Resource-Keys")
        }
        return request
    }

    private func data(for request: URLRequest, allowsEmpty: Bool = false) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DriveAPIError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DriveAPIError.http(http.statusCode, message)
        }
        if data.isEmpty && !allowsEmpty {
            throw DriveAPIError.invalidResponse
        }
        return data
    }

    private func resourceHeader(id: String, key: String?) -> String? {
        key.map { "\(id)/\($0)" }
    }

    private func escapeQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "\\'")
    }

    private static let fields =
        "id,name,mimeType,size,md5Checksum,modifiedTime,resourceKey," +
        "capabilities(canDownload),shortcutDetails(targetId,targetMimeType,targetResourceKey)"
}
