import AVFoundation
import Foundation
import UIKit

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
    let thumbnailLink: String?
    let resourceKey: String?
    let capabilities: DriveCapabilities?
    let shortcutDetails: DriveShortcutDetails?

    static let folderMimeType = "application/vnd.google-apps.folder"
    static let shortcutMimeType = "application/vnd.google-apps.shortcut"
    static let spreadsheetMimeType = "application/vnd.google-apps.spreadsheet"

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

    var isPhoto: Bool {
        if effectiveMimeType.hasPrefix("image/") {
            return true
        }
        let lower = name.lowercased()
        return lower.hasSuffix(".jpg") ||
            lower.hasSuffix(".jpeg") ||
            lower.hasSuffix(".png") ||
            lower.hasSuffix(".heic") ||
            lower.hasSuffix(".heif") ||
            lower.hasSuffix(".webp")
    }

    var isVideo: Bool {
        if effectiveMimeType.hasPrefix("video/") {
            return true
        }
        let lower = name.lowercased()
        return lower.hasSuffix(".mp4") ||
            lower.hasSuffix(".mov") ||
            lower.hasSuffix(".m4v") ||
            lower.hasSuffix(".avi") ||
            lower.hasSuffix(".mkv")
    }

    var isMedia: Bool {
        isVideo || isPhoto
    }

    var isSpreadsheet: Bool {
        effectiveMimeType == Self.spreadsheetMimeType
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

struct DriveChange: Decodable, Sendable {
    let fileId: String?
    let removed: Bool?
    let file: DriveItem?
}

struct DriveChangesResponse: Decodable, Sendable {
    let nextPageToken: String?
    let newStartPageToken: String?
    let changes: [DriveChange]
}

struct DriveStartPageTokenResponse: Decodable, Sendable {
    let startPageToken: String
}

enum DriveAPIError: LocalizedError {
    case invalidResponse
    case http(Int, String)
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case serverUnavailable(Int)
    case itemNotDownloadable
    case malformedURL
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Google Drive returned an invalid response."
        case .unauthorized:
            return "Google Drive authorization expired. Please reconnect your Google account."
        case .forbidden:
            return "You do not have permission to access this Google Drive item."
        case .notFound:
            return "The requested file or folder was not found in Google Drive."
        case .rateLimited:
            return "Google Drive is receiving too many requests. Please wait a moment."
        case let .serverUnavailable(code):
            return "Google Drive servers are temporarily unavailable (\(code)). Please try again shortly."
        case let .http(code, message):
            if code == 401 { return "Google Drive authorization expired. Please reconnect your Google account." }
            if code == 403 { return "Permission denied. Check your Google Drive folder access." }
            if code == 404 { return "The folder or video was not found in Google Drive." }
            if code == 429 { return "Google Drive rate limit reached. Please wait a few seconds." }
            if code >= 500 { return "Google Drive server error (\(code)). Please try again in a few moments." }
            return "Google Drive error \(code): \(message)"
        case .itemNotDownloadable:
            return "Google Drive does not permit downloading this video."
        case .malformedURL:
            return "The Google Drive request could not be created."
        case .networkUnavailable:
            return "Unable to connect to Google Drive. Check your internet connection."
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

    /// Creates an authenticated streaming item so playback can begin as soon
    /// as Google Drive returns the first media bytes.
    func streamingPlayerItem(for item: VideoAsset) async throws -> AVPlayerItem {
        let request = try await downloadRequest(for: item)
        guard let url = request.url else { throw DriveAPIError.malformedURL }
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:],
                AVURLAssetAllowsCellularAccessKey: true
            ]
        )
        return AVPlayerItem(asset: asset)
    }

    func thumbnailData(for item: VideoAsset) async throws -> Data {
        // Strategy 1: Attempt to load from item's stored thumbnailLink
        if let link = item.thumbnailLink {
            let scaledLink = link.replacingOccurrences(
                of: "=s\\d+($|-[^?]+)",
                with: "=s360$1",
                options: .regularExpression
            )
            if let url = URL(string: scaledLink) {
                // Google CDN (lh3.googleusercontent.com) often expects unauthenticated requests
                if let (data, response) = try? await session.data(from: url),
                   let http = response as? HTTPURLResponse,
                   (200 ... 299).contains(http.statusCode),
                   !data.isEmpty {
                    return data
                }
                // Fallback to authorized request if unauthenticated was rejected
                if let data = try? await data(for: authorizedRequest(url: url)), !data.isEmpty {
                    return data
                }
            }
        }

        // Strategy 2: Query Drive API for fresh thumbnail link if missing or expired
        if let freshLink = try? await fetchFreshThumbnailLink(for: item.driveFileID, resourceKey: item.resourceKey) {
            let scaledLink = freshLink.replacingOccurrences(
                of: "=s\\d+($|-[^?]+)",
                with: "=s360$1",
                options: .regularExpression
            )
            if let url = URL(string: scaledLink) {
                if let (data, response) = try? await session.data(from: url),
                   let http = response as? HTTPURLResponse,
                   (200 ... 299).contains(http.statusCode),
                   !data.isEmpty {
                    return data
                }
                if let data = try? await data(for: authorizedRequest(url: url)), !data.isEmpty {
                    return data
                }
            }
        }

        // Strategy 3: Try Google Drive thumbnail endpoint directly
        if let thumbURL = URL(string: "https://drive.google.com/thumbnail?id=\(item.driveFileID)&sz=w360") {
            if let data = try? await data(for: authorizedRequest(url: thumbURL)), !data.isEmpty {
                return data
            }
        }

        throw DriveAPIError.invalidResponse
    }

    func fetchFreshThumbnailLink(for driveFileID: String, resourceKey: String? = nil) async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(driveFileID)")
        components?.queryItems = [
            URLQueryItem(name: "fields", value: "thumbnailLink")
        ]
        guard let url = components?.url else { return nil }
        let req = try await authorizedRequest(
            url: url,
            resourceKeys: resourceHeader(id: driveFileID, key: resourceKey)
        )
        let rawData = try await data(for: req)
        struct FileThumbResponse: Decodable {
            let thumbnailLink: String?
        }
        return try? decoder.decode(FileThumbResponse.self, from: rawData).thumbnailLink
    }

    func exportSpreadsheetCSV(
        id: String,
        resourceKey: String? = nil
    ) async throws -> Data {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(id)/export"
        )
        components?.queryItems = [
            URLQueryItem(name: "mimeType", value: "text/csv")
        ]
        guard let url = components?.url else { throw DriveAPIError.malformedURL }
        return try await data(
            for: authorizedRequest(
                url: url,
                resourceKeys: resourceHeader(id: id, key: resourceKey)
            )
        )
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
        if let part1 = "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8) {
            body.append(part1)
        }
        body.append(metadata)
        if let part2 = "\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8) {
            body.append(part2)
        }
        body.append(data)
        if let part3 = "\r\n--\(boundary)--\r\n".data(using: .utf8) {
            body.append(part3)
        }

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

    /// Finds or creates a Drive folder below `parentID`, avoiding duplicate
    /// backup folders when the user taps backup again later.
    func findOrCreateFolder(named name: String, parentID: String = "root") async throws -> String {
        if let existing = try await listChildren(of: parentID).first(where: {
            $0.isFolder && $0.name == name
        }) {
            return existing.effectiveID
        }

        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files?supportsAllDrives=true&fields=id") else {
            throw DriveAPIError.malformedURL
        }
        var request = try await authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": DriveItem.folderMimeType,
            "parents": [parentID]
        ])
        let responseData = try await data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let id = object["id"] as? String else {
            throw DriveAPIError.invalidResponse
        }
        return id
    }

    /// Uploads a local video using Drive's resumable protocol so large files
    /// are streamed from disk rather than copied into a giant in-memory body.
    func uploadFile(
        at fileURL: URL,
        name: String,
        mimeType: String,
        parentID: String
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let existingID = try await listChildren(of: parentID)
            .first(where: { !$0.isFolder && $0.name == name })?.effectiveID
        let endpoint = existingID.map {
            "https://www.googleapis.com/upload/drive/v3/files/\($0)?uploadType=resumable&supportsAllDrives=true"
        } ?? "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true"
        guard let startURL = URL(string: endpoint) else {
            throw DriveAPIError.malformedURL
        }
        var startRequest = try await authorizedRequest(url: startURL)
        startRequest.httpMethod = existingID == nil ? "POST" : "PATCH"
        startRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        startRequest.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        startRequest.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        startRequest.httpBody = try JSONSerialization.data(withJSONObject: existingID == nil
            ? ["name": name, "parents": [parentID]]
            : [:])
        let (_, startResponse) = try await session.data(for: startRequest)
        guard let httpResponse = startResponse as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode),
              let uploadURLString = httpResponse.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: uploadURLString) else {
            throw DriveAPIError.invalidResponse
        }

        var uploadRequest = try await authorizedRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        let (_, uploadResponse) = try await session.upload(for: uploadRequest, fromFile: fileURL)
        guard let uploadHTTPResponse = uploadResponse as? HTTPURLResponse,
              (200 ... 299).contains(uploadHTTPResponse.statusCode) else {
            throw DriveAPIError.invalidResponse
        }
    }

    func startPageToken() async throws -> String {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/changes/startPageToken")
        components?.queryItems = [
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components?.url else { throw DriveAPIError.malformedURL }
        let request = try await authorizedRequest(url: url)
        let data = try await data(for: request)
        return try decoder.decode(DriveStartPageTokenResponse.self, from: data).startPageToken
    }

    func listChanges(pageToken: String) async throws -> (changes: [DriveChange], nextToken: String) {
        var allChanges: [DriveChange] = []
        var currentToken = pageToken
        var finalToken = pageToken

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/changes")
            components?.queryItems = [
                URLQueryItem(name: "pageToken", value: currentToken),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fields)))")
            ]
            guard let url = components?.url else { throw DriveAPIError.malformedURL }
            let request = try await authorizedRequest(url: url)
            let data = try await data(for: request)
            let response = try decoder.decode(DriveChangesResponse.self, from: data)
            allChanges.append(contentsOf: response.changes)
            if let next = response.nextPageToken {
                currentToken = next
            } else {
                if let newStart = response.newStartPageToken {
                    finalToken = newStart
                }
                break
            }
        } while true

        return (allChanges, finalToken)
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
        var lastError: Error?
        for attempt in 0 ..< 3 {
            if attempt > 0 {
                let delay = Double(attempt) * 0.75
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { throw CancellationError() }
            }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw DriveAPIError.invalidResponse
                }
                if (200 ... 299).contains(http.statusCode) {
                    if data.isEmpty && !allowsEmpty {
                        throw DriveAPIError.invalidResponse
                    }
                    return data
                }
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                if http.statusCode == 429 || (500 ... 599).contains(http.statusCode) {
                    lastError = DriveAPIError.http(http.statusCode, message)
                    continue
                }
                throw DriveAPIError.http(http.statusCode, message)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                if error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                    lastError = DriveAPIError.networkUnavailable
                } else {
                    lastError = error
                }
            } catch {
                throw error
            }
        }
        throw lastError ?? DriveAPIError.invalidResponse
    }

    private func resourceHeader(id: String, key: String?) -> String? {
        key.map { "\(id)/\($0)" }
    }

    private func escapeQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "\\'")
    }

    private static let fields =
        "id,name,mimeType,size,md5Checksum,modifiedTime,thumbnailLink,resourceKey," +
        "capabilities(canDownload),shortcutDetails(targetId,targetMimeType,targetResourceKey)"
}
