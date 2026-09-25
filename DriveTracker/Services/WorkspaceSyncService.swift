import Foundation

nonisolated struct WorkspaceMediaRecord: Decodable, Sendable {
    let id: String
    let driveFileId: String
    let uploadText: String
    let revision: Int
}

nonisolated struct WorkspaceAssignmentRecord: Decodable, Sendable {
    let id: String
    let accountId: String?
    let mediaId: String?
    let state: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case accountId = "account_id"
        case mediaId = "media_id"
        case state
        case completedAt = "completed_at"
    }
}

nonisolated struct WorkspaceSyncDelta: Decodable, Sendable {
    let cursor: String
    let changes: [WorkspaceMediaRecord]
    let assignments: [WorkspaceAssignmentRecord]?
}

nonisolated struct WorkspaceOutboxItem: Codable, Sendable, Identifiable {
    enum ActionKind: String, Codable, Sendable {
        case saveUploadText
        case completeAssignment
    }

    let id: UUID
    let kind: ActionKind
    let mediaID: String
    let text: String?
    let revision: Int?
    let completed: Bool?
    let createdAt: Date
}

private nonisolated struct SupabaseTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case expiresIn = "expires_in" }
}

actor WorkspaceSyncService {
    private let session: URLSession
    private let apiBaseURL: URL?
    private let supabaseURL: URL?
    private let supabaseAnonKey: String?
    private var bearerToken: String?
    private var tokenExpiresAt: Date = .distantPast

    init(bundle: Bundle = .main, session: URLSession = .shared) {
        self.session = session
        let apiString = bundle.object(forInfoDictionaryKey: "WorkspaceAPIBaseURL") as? String
        let supabaseString = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String
        let anon = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String
        self.apiBaseURL = apiString.flatMap { $0.hasPrefix("https://") && !$0.contains("YOUR_") ? URL(string: $0) : nil }
        self.supabaseURL = supabaseString.flatMap { $0.hasPrefix("https://") && !$0.contains("YOUR_") ? URL(string: $0) : nil }
        self.supabaseAnonKey = (anon?.contains("YOUR_") == false) ? anon : nil
    }

    var isConfigured: Bool { apiBaseURL != nil && supabaseURL != nil && supabaseAnonKey != nil }

    func media(auth: GoogleAuthService) async throws -> [WorkspaceMediaRecord] {
        let request = try await authorizedRequest(path: "/api/v1/media", method: "GET", auth: auth)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode([WorkspaceMediaRecord].self, from: data)
    }

    func syncDeltas(since: String?, auth: GoogleAuthService) async throws -> WorkspaceSyncDelta {
        var path = "/api/v1/sync"
        if let since, !since.isEmpty {
            path += "?since=\(since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? since)"
        }
        let request = try await authorizedRequest(path: path, method: "GET", auth: auth)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(WorkspaceSyncDelta.self, from: data)
    }

    func saveUploadText(_ text: String, mediaID: String, revision: Int, auth: GoogleAuthService) async throws -> WorkspaceMediaRecord {
        var request = try await authorizedRequest(path: "/api/v1/media/\(mediaID)/upload-text", method: "PUT", auth: auth)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "expectedRevision": revision])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(WorkspaceMediaRecord.self, from: data)
    }

    func completeAssignment(mediaID: String, completed: Bool, auth: GoogleAuthService) async throws {
        var request = try await authorizedRequest(path: "/api/v1/assignments", method: "POST", auth: auth)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mediaId": mediaID, "completed": completed])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    func drainOutbox(items: [WorkspaceOutboxItem], auth: GoogleAuthService) async -> [UUID] {
        var successfulIDs: [UUID] = []
        for item in items {
            do {
                switch item.kind {
                case .saveUploadText:
                    if let text = item.text, let rev = item.revision {
                        _ = try await saveUploadText(text, mediaID: item.mediaID, revision: rev, auth: auth)
                    }
                case .completeAssignment:
                    try await completeAssignment(mediaID: item.mediaID, completed: item.completed ?? true, auth: auth)
                }
                successfulIDs.append(item.id)
            } catch {
                // If conflict or fatal, or still offline, stop draining
                break
            }
        }
        return successfulIDs
    }

    private func authorizedRequest(path: String, method: String, auth: GoogleAuthService) async throws -> URLRequest {
        guard let base = apiBaseURL, isConfigured else { throw URLError(.unsupportedURL) }
        let token = try await workspaceToken(auth: auth)
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func workspaceToken(auth: GoogleAuthService) async throws -> String {
        if let bearerToken, tokenExpiresAt.timeIntervalSinceNow > 60 { return bearerToken }
        guard let supabaseURL, let supabaseAnonKey else { throw URLError(.unsupportedURL) }
        let googleIDToken = try await auth.idToken()
        var request = URLRequest(url: supabaseURL.appending(path: "/auth/v1/token").appending(queryItems: [URLQueryItem(name: "grant_type", value: "id_token")]))
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["provider": "google", "id_token": googleIDToken])
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let token = try JSONDecoder().decode(SupabaseTokenResponse.self, from: data)
        bearerToken = token.accessToken
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        return token.accessToken
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Workspace request failed"
            throw NSError(domain: "WorkspaceSync", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
