import CryptoKit
import Foundation
import ImageIO
import UIKit

@MainActor
protocol DriveThumbnailAPI {
    func thumbnailData(for item: VideoAsset) async throws -> Data
}

extension DriveAPIClient: DriveThumbnailAPI {}

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheDirectory: URL
    private struct Request {
        let id: UUID
        let task: Task<UIImage?, Never>
        var consumers: Set<UUID>
    }
    private var inFlightTasks: [String: Request] = [:]

    // Concurrency control: Limit concurrent thumbnail network/decode operations to 4
    private let maxConcurrentFetches = 4
    private var activeFetchCount = 0
    private var fetchWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(cacheDirectory: URL? = nil) {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 32 * 1_024 * 1_024 // Leave room for AVPlayer buffers.

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = cacheDirectory ?? caches.appendingPathComponent("DriveTrackerThumbnails", isDirectory: true)
        self.diskCacheDirectory = directory

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func cacheKey(for video: VideoAsset) -> String {
        "\(video.identityKey)|\(video.driveModifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func diskFileURL(for identityKey: String) -> URL {
        let hash = SHA256.hash(data: Data(identityKey.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return diskCacheDirectory.appendingPathComponent("\(hash).jpg")
    }

    /// In-memory lookup; callers do not read thumbnail files during layout.
    func memoryCachedImage(for identityKey: String) -> UIImage? {
        let key = identityKey as NSString
        return memoryCache.object(forKey: key)
    }

    /// Legacy cache lookup helper.
    func cachedImage(for identityKey: String) -> UIImage? {
        memoryCachedImage(for: identityKey)
    }

    /// Fetches or retrieves a decoded thumbnail with disk caching, concurrency throttling,
    /// in-flight deduplication, and background image decompression off the main thread.
    func thumbnailImage(
        for video: VideoAsset,
        api: (any DriveThumbnailAPI)?,
        currentUserID: String?
    ) async -> UIImage? {
        let identity = Self.cacheKey(for: video)
        let cacheKey = identity as NSString

        // 1. Check in-memory cache (instant synchronous lookup, guaranteed 0 disk I/O)
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        guard !Task.isCancelled else { return nil }
        let consumerID = UUID()
        if var existing = inFlightTasks[identity], !existing.task.isCancelled {
            existing.consumers.insert(consumerID)
            inFlightTasks[identity] = existing
            return await consume(existing, identity: identity, consumerID: consumerID)
        }

        let fileURL = diskFileURL(for: identity)
        let isMissing = video.isMissingFromDrive
        let matchesUser = (currentUserID == video.googleUserID)

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }

            guard await self.acquireFetchSlot() else { return nil }
            defer { self.releaseFetchSlot() }

            // Bound disk reads and decodes as well as network requests.
            // A. Check on-disk persistent cache asynchronously off the main thread
            let diskCached = await Task.detached(priority: .utility) { () -> (UIImage, Int)? in
                guard FileManager.default.fileExists(atPath: fileURL.path),
                      let data = try? Data(contentsOf: fileURL),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(
                          source,
                          0,
                          [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                              kCGImageSourceShouldCacheImmediately: true,
                              kCGImageSourceThumbnailMaxPixelSize: 320
                          ] as CFDictionary
                      )
                else { return nil }
                let image = UIImage(cgImage: cgImage)
                let cost = cgImage.bytesPerRow * cgImage.height
                return (image, cost)
            }.value

            guard !Task.isCancelled else { return nil }
            if let (image, cost) = diskCached {
                self.memoryCache.setObject(image, forKey: cacheKey, cost: cost)
                return image
            }

            guard let api, matchesUser, !isMissing else {
                return nil
            }

            // B. Fetch from Google Drive with concurrency gate & background decoding
            guard !Task.isCancelled,
                  let data = try? await api.thumbnailData(for: video)
            else {
                return nil
            }

            // Decode and downscale image off the main thread
            let decodedResult = await Task.detached(priority: .utility) { () -> (UIImage, Data)? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(
                          source,
                          0,
                          [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                              kCGImageSourceShouldCacheImmediately: true,
                              kCGImageSourceThumbnailMaxPixelSize: 320
                          ] as CFDictionary
                      )
                else {
                    return nil
                }
                let uiImage = UIImage(cgImage: cgImage)
                let jpegData = uiImage.jpegData(compressionQuality: 0.82) ?? data
                return (uiImage, jpegData)
            }.value

            guard !Task.isCancelled, let (decodedImage, jpegData) = decodedResult else { return nil }

            // Write to disk cache asynchronously
            Task.detached(priority: .background) {
                try? jpegData.write(to: fileURL, options: .atomic)
            }

            let imageCost = decodedImage.cgImage.map {
                $0.bytesPerRow * $0.height
            } ?? jpegData.count

            self.memoryCache.setObject(decodedImage, forKey: cacheKey, cost: imageCost)
            return decodedImage
        }

        let request = Request(id: UUID(), task: task, consumers: [consumerID])
        inFlightTasks[identity] = request
        return await consume(request, identity: identity, consumerID: consumerID)
    }

    private func consume(_ request: Request, identity: String, consumerID: UUID) async -> UIImage? {
        defer { releaseConsumer(identity: identity, requestID: request.id, consumerID: consumerID) }
        return await withTaskCancellationHandler {
            let image = await request.task.value
            return Task.isCancelled ? nil : image
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseConsumer(identity: identity, requestID: request.id, consumerID: consumerID)
            }
        }
    }

    private func releaseConsumer(identity: String, requestID: UUID, consumerID: UUID) {
        guard var request = inFlightTasks[identity], request.id == requestID,
              request.consumers.remove(consumerID) != nil else { return }
        if request.consumers.isEmpty {
            request.task.cancel()
            inFlightTasks.removeValue(forKey: identity)
        } else {
            inFlightTasks[identity] = request
        }
    }

    /// Concurrency slot management
    private func acquireFetchSlot() async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeFetchCount < maxConcurrentFetches {
            activeFetchCount += 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fetchWaiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let index = fetchWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = fetchWaiters.remove(at: index)
            waiter.continuation.resume(returning: false)
        }
    }

    private func releaseFetchSlot() {
        if !fetchWaiters.isEmpty {
            let next = fetchWaiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            activeFetchCount = max(0, activeFetchCount - 1)
        }
    }

    /// Prefetches thumbnails for upcoming videos in the background
    func prefetchThumbnails(
        for videos: [VideoAsset],
        api: (any DriveThumbnailAPI)?,
        currentUserID: String?
    ) {
        guard let api, let currentUserID else { return }
        let eligible = videos.filter {
            $0.googleUserID == currentUserID &&
            !$0.isMissingFromDrive &&
            memoryCachedImage(for: Self.cacheKey(for: $0)) == nil
        }
        guard !eligible.isEmpty else { return }

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            for video in eligible.prefix(6) {
                guard !Task.isCancelled else { break }
                _ = await self.thumbnailImage(for: video, api: api, currentUserID: currentUserID)
            }
        }
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        for request in inFlightTasks.values { request.task.cancel() }
        inFlightTasks.removeAll()
        try? FileManager.default.removeItem(at: diskCacheDirectory)
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }
}
