import Foundation
import UIKit

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

nonisolated final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate: [String: CFAbsoluteTime] = [:]

    nonisolated func shouldDispatch(identity: String, interval: TimeInterval, isComplete: Bool) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        if !isComplete, let last = lastUpdate[identity], (now - last) < interval {
            return false
        }
        lastUpdate[identity] = now
        return true
    }

    nonisolated func reset(identity: String) {
        lock.lock()
        lastUpdate.removeValue(forKey: identity)
        lock.unlock()
    }
}

nonisolated final class TaskMetadataRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedFileNameByTask: [Int: String] = [:]

    nonisolated func set(expectedFileName: String, for taskID: Int) {
        lock.lock()
        expectedFileNameByTask[taskID] = expectedFileName
        lock.unlock()
    }

    nonisolated func get(for taskID: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return expectedFileNameByTask[taskID]
    }

    nonisolated func remove(for taskID: Int) {
        lock.lock()
        expectedFileNameByTask.removeValue(forKey: taskID)
        lock.unlock()
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
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var activeDownloadCount = 0
    private var sessionStorage: URLSession?
    private var recoveryHandler: ((String, URL) -> Void)?
    private let recoveredDownloadsKey = "recoveredBackgroundDownloads"
    private nonisolated let minimumProgressUpdateInterval: TimeInterval = 0.25
    private nonisolated let throttle = ProgressThrottle()
    private nonisolated let taskMetadata = TaskMetadataRegistry()

    override init() {
        super.init()
    }

    private var session: URLSession {
        if let sessionStorage { return sessionStorage }
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let queue = OperationQueue()
        queue.name = "com.drivetracker.downloadCoordinatorQueue"
        queue.maxConcurrentOperationCount = 4
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        sessionStorage = created
        return created
    }

    func download(request: URLRequest, identity: String, expectedFileName: String? = nil) async throws -> URL {
        let task = session.downloadTask(with: request)
        task.taskDescription = identity
        identityByTask[task.taskIdentifier] = identity
        if let expectedFileName {
            taskMetadata.set(expectedFileName: expectedFileName, for: task.taskIdentifier)
        }
        progressByIdentity[identity] = ProgressState(fraction: 0, bytesWritten: 0, totalBytes: 0)
        incrementActiveDownloads()

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

    private func incrementActiveDownloads() {
        activeDownloadCount += 1
        if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoDownloads") { [weak self] in
                Task { @MainActor [weak self] in
                    self?.endBackgroundTask()
                }
            }
        }
    }

    private func decrementActiveDownloads() {
        activeDownloadCount = max(0, activeDownloadCount - 1)
        if activeDownloadCount == 0 {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func complete(taskID: Int, identity taskDescription: String?, result: Result<URL, Error>) {
        let identity = identityByTask.removeValue(forKey: taskID) ?? taskDescription
        taskMetadata.remove(for: taskID)
        decrementActiveDownloads()

        if let identity {
            progressByIdentity.removeValue(forKey: identity)
            throttle.reset(identity: identity)
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

    private func updateProgress(identity: String, state: ProgressState) {
        progressByIdentity[identity] = state
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
        let isComplete = totalBytesWritten >= totalBytesExpectedToWrite && totalBytesExpectedToWrite > 0
        guard throttle.shouldDispatch(identity: identity, interval: minimumProgressUpdateInterval, isComplete: isComplete) else {
            return
        }

        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let state = ProgressState(
            fraction: fraction,
            bytesWritten: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
        Task { @MainActor [weak self] in
            self?.updateProgress(identity: identity, state: state)
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

            // Determine safe video extension for Apple Photos
            let expectedFileName = taskMetadata.get(for: taskID)
            let expectedExtension = (expectedFileName as NSString?)?.pathExtension.lowercased() ?? ""
            let suggestedName = downloadTask.response?.suggestedFilename ?? ""
            let suggestedExtension = (suggestedName as NSString).pathExtension.lowercased()
            let mimeType = downloadTask.response?.mimeType?.lowercased() ?? ""

            let validVideoExtensions: Set<String> = ["mp4", "mov", "m4v", "m4a", "webm", "mkv", "avi", "3gp", "ts"]
            let validPhotoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"]
            let finalExtension: String
            if validVideoExtensions.contains(expectedExtension) || validPhotoExtensions.contains(expectedExtension) {
                finalExtension = expectedExtension
            } else if validVideoExtensions.contains(suggestedExtension) || validPhotoExtensions.contains(suggestedExtension) {
                finalExtension = suggestedExtension
            } else if mimeType.contains("quicktime") {
                finalExtension = "mov"
            } else if mimeType.contains("jpeg") || mimeType.contains("jpg") {
                finalExtension = "jpg"
            } else if mimeType.contains("png") {
                finalExtension = "png"
            } else if mimeType.contains("heic") {
                finalExtension = "heic"
            } else {
                finalExtension = "mp4"
            }

            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(finalExtension)
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
