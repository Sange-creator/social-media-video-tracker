import CryptoKit
import Foundation
import ImageIO
import UIKit

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let memoryCache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]
    private let diskCacheDirectory: URL

    // Concurrency control: Limit concurrent thumbnail network/decode operations to 4
    private let maxConcurrentFetches = 4
    private var activeFetchCount = 0
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Instant synchronous O(1) in-memory cache lookup. Guaranteed 0 disk I/O for 60fps scrolling.
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

        // 1. Check in-memory cache (instant)
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        // 2. Check on-disk persistent cache asynchronously off the main actor
        let fileURL = diskFileURL(for: identity)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let diskCached = await Task.detached(priority: .userInitiated) { () -> (UIImage, Int)? in
                guard let data = try? Data(contentsOf: fileURL),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(
                          source,
                          0,
                          [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                              kCGImageSourceThumbnailMaxPixelSize: 480
                          ] as CFDictionary
                      )
                else { return nil }
                let image = UIImage(cgImage: cgImage)
                let cost = cgImage.bytesPerRow * cgImage.height
                return (image, cost)
            }.value

            if let (image, cost) = diskCached {
                memoryCache.setObject(image, forKey: cacheKey, cost: cost)
                return image
            }
        }

        // 3. Check for an already in-flight task for this video
        if let existingTask = inFlightTasks[identity] {
            return await existingTask.value
        }

        guard let api,
              currentUserID == video.googleUserID,
              !video.isMissingFromDrive
        else {
            return nil
        }

        // 4. Fetch from Google Drive with concurrency gate & background decoding
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquireFetchSlot()
            defer {
                Task { @MainActor [weak self] in
                    self?.releaseFetchSlot()
                }
            }

            guard !Task.isCancelled,
                  let data = try? await api.thumbnailData(for: video)
            else {
                return nil
            }

            // Decode and downscale image off the main actor
            let decodedResult = await Task.detached(priority: .userInitiated) { () -> (UIImage, Data)? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(
                          source,
                          0,
                          [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                              kCGImageSourceThumbnailMaxPixelSize: 480
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
            let targetDiskURL = self.diskFileURL(for: identity)
            Task.detached(priority: .background) {
                try? jpegData.write(to: targetDiskURL, options: .atomic)
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
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fetchWaiters.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseFetchSlot()
            }
        }
    }

    private func releaseFetchSlot() {
        if !fetchWaiters.isEmpty {
            let next = fetchWaiters.removeFirst()
            next.resume()
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
