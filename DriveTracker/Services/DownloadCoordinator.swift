import Foundation

enum DownloadCoordinatorError: LocalizedError {
    case missingTemporaryFile
    case cancelled
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingTemporaryFile:
            "The completed download could not be found."
        case .cancelled:
            "The download was cancelled."
        case let .httpStatus(code):
            switch code {
            case 401:
                "Google Drive authorization expired. Reconnect your Google account and try again."
            case 403:
                "Google Drive does not permit downloading this video."
            case 404:
                "The video could not be found in Google Drive. Sync the folder and try again."
            default:
                "Google Drive could not download the video (error \(code))."
            }
        }
    }
}

@MainActor
final class DownloadCoordinator: NSObject, ObservableObject {
    struct ProgressState {
        let fraction: Double
        let bytesWritten: Int64
        let totalBytes: Int64
    }

    @Published private(set) var progressByIdentity: [String: ProgressState] = [:]

    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var identityByTask: [Int: String] = [:]
    private var sessionStorage: URLSession?
    private var recoveryHandler: ((String, URL) -> Void)?
    private let recoveredDownloadsKey = "recoveredBackgroundDownloads"
    private let minimumProgressUpdateInterval: TimeInterval = 0.25

    override init() {
        super.init()
        _ = session
    }

    private var session: URLSession {
        if let sessionStorage { return sessionStorage }
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.example.DriveTracker.video-downloads"
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionStorage = created
        return created
    }

    func download(request: URLRequest, identity: String) async throws -> URL {
        let task = session.downloadTask(with: request)
        task.taskDescription = identity
        identityByTask[task.taskIdentifier] = identity
        progressByIdentity[identity] = ProgressState(fraction: 0, bytesWritten: 0, totalBytes: 0)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[task.taskIdentifier] = continuation
                task.resume()
            }
        } onCancel: {
            Task { @MainActor in
                task.cancel()
            }
        }
    }

    func cancel(identity: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == identity }.forEach { $0.cancel() }
        }
    }

    func setRecoveryHandler(_ handler: @escaping (String, URL) -> Void) {
        recoveryHandler = handler
        deliverPersistedRecoveries()
    }

    private func complete(taskID: Int, identity taskDescription: String?, result: Result<URL, Error>) {
        let identity = identityByTask.removeValue(forKey: taskID) ?? taskDescription
        if let identity {
            progressByIdentity.removeValue(forKey: identity)
            lastProgressUpdateByIdentity.removeValue(forKey: identity)
        }
        if let continuation = continuations.removeValue(forKey: taskID) {
            continuation.resume(with: result)
            return
        }
        guard let identity, case let .success(url) = result else { return }
        if let recoveryHandler {
            recoveryHandler(identity, url)
        } else {
            var stored = UserDefaults.standard.dictionary(
                forKey: recoveredDownloadsKey
            ) as? [String: String] ?? [:]
            stored[identity] = url.path
            UserDefaults.standard.set(stored, forKey: recoveredDownloadsKey)
        }
    }

    private func deliverPersistedRecoveries() {
        guard let recoveryHandler else { return }
        let stored = UserDefaults.standard.dictionary(
            forKey: recoveredDownloadsKey
        ) as? [String: String] ?? [:]
        UserDefaults.standard.removeObject(forKey: recoveredDownloadsKey)
        for (identity, path) in stored {
            recoveryHandler(identity, URL(fileURLWithPath: path))
        }
    }
    private var lastProgressUpdateByIdentity: [String: Date] = [:]
}

extension DownloadCoordinator: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let identity = downloadTask.taskDescription else { return }
        let now = Date()
        Task { @MainActor in
            if let last = lastProgressUpdateByIdentity[identity],
               now.timeIntervalSince(last) < minimumProgressUpdateInterval,
               totalBytesWritten < totalBytesExpectedToWrite {
                return
            }
            lastProgressUpdateByIdentity[identity] = now
            let fraction = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : 0
            progressByIdentity[identity] = ProgressState(
                fraction: fraction,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200 ... 299).contains(response.statusCode) {
                throw DownloadCoordinatorError.httpStatus(response.statusCode)
            }
            let directory = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("CompletedDownloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suggestedName = downloadTask.response?.suggestedFilename ?? ""
            let suggestedExtension = (suggestedName as NSString).pathExtension
            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(suggestedExtension.isEmpty ? "mp4" : suggestedExtension)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in
                complete(
                    taskID: taskID,
                    identity: downloadTask.taskDescription,
                    result: .success(destination)
                )
            }
        } catch {
            Task { @MainActor in
                complete(
                    taskID: taskID,
                    identity: downloadTask.taskDescription,
                    result: .failure(error)
                )
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let mapped: Error = (error as NSError).code == NSURLErrorCancelled
            ? DownloadCoordinatorError.cancelled
            : error
        Task { @MainActor in
            complete(
                taskID: task.taskIdentifier,
                identity: task.taskDescription,
                result: .failure(mapped)
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            DriveTrackerAppDelegate.finishBackgroundSessionEvents()
        }
    }
}
