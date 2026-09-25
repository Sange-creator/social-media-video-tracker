import CryptoKit
import Foundation
import ImageIO
import UIKit

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheDirectory: URL
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    // Concurrency control: Limit concurrent thumbnail network/decode operations to 4
    private let maxConcurrentFetches = 4
    private var activeFetchCount = 0
    private var fetchWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    private init() {
        memoryCache.countLimit = 400
        memoryCache.totalCostLimit = 128 * 1_024 * 1_024 // 128 MB in-memory limit

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("DriveTrackerThumbnails", isDirectory: true)
        self.diskCacheDirectory = directory

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func diskFileURL(for identityKey: String) -> URL {
        let hash = SHA256.hash(data: Data(identityKey.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return diskCacheDirectory.appendingPathComponent("\(hash).jpg")
    }

    /// Instant synchronous O(1) in-memory cache lookup. Guaranteed 0 disk I/O for 60/120fps scrolling.
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
        api: DriveAPIClient?,
        currentUserID: String?
    ) async -> UIImage? {
        let identity = video.identityKey
        let cacheKey = identity as NSString

        // 1. Check in-memory cache (instant synchronous lookup, guaranteed 0 disk I/O)
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        // 2. Deduplicate in-flight loading tasks for this identity
        if let existingTask = inFlightTasks[identity] {
            return await existingTask.value
        }

        let fileURL = diskFileURL(for: identity)
        let isMissing = video.isMissingFromDrive
        let matchesUser = (currentUserID == video.googleUserID)

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }

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
                              kCGImageSourceThumbnailMaxPixelSize: 320
                          ] as CFDictionary
                      )
                else { return nil }
                let image = UIImage(cgImage: cgImage)
                let cost = cgImage.bytesPerRow * cgImage.height
                return (image, cost)
            }.value

            if let (image, cost) = diskCached {
                self.memoryCache.setObject(image, forKey: cacheKey, cost: cost)
                return image
            }

            guard let api, matchesUser, !isMissing else {
                return nil
            }

            // B. Fetch from Google Drive with concurrency gate & background decoding
            await self.acquireFetchSlot()
            defer {
                self.releaseFetchSlot()
            }

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
                              kCGImageSourceThumbnailMaxPixelSize: 320
                          ] as CFDictionary
                      )
                else {
                    if let direct = UIImage(data: data) {
                        return (direct, data)
                    }
                    return nil
                }
                let uiImage = UIImage(cgImage: cgImage)
                let jpegData = uiImage.jpegData(compressionQuality: 0.82) ?? data
                return (uiImage, jpegData)
            }.value

            guard let (decodedImage, jpegData) = decodedResult else { return nil }

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

        inFlightTasks[identity] = task
        defer { inFlightTasks.removeValue(forKey: identity) }
        let image = await task.value
        return image
    }

    /// Concurrency slot management
    private func acquireFetchSlot() async {
        if activeFetchCount < maxConcurrentFetches {
            activeFetchCount += 1
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
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
            waiter.continuation.resume()
        }
    }

    private func releaseFetchSlot() {
        if !fetchWaiters.isEmpty {
            let next = fetchWaiters.removeFirst()
            next.continuation.resume()
        } else {
            activeFetchCount = max(0, activeFetchCount - 1)
        }
    }

    /// Prefetches thumbnails for upcoming videos in the background
    func prefetchThumbnails(
        for videos: [VideoAsset],
        api: DriveAPIClient?,
        currentUserID: String?
    ) {
        guard let api, let currentUserID else { return }
        let eligible = videos.filter {
            $0.googleUserID == currentUserID &&
            !$0.isMissingFromDrive &&
            memoryCachedImage(for: $0.identityKey) == nil
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
        inFlightTasks.removeAll()
        try? FileManager.default.removeItem(at: diskCacheDirectory)
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }
}
