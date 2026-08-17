import Foundation
import ImageIO
import UIKit

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 250
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    /// Fast-path synchronous cache lookup. Returns immediately on the main thread
    /// so cells render cached thumbnails on the very first frame without delay.
    func cachedImage(for identityKey: String) -> UIImage? {
        cache.object(forKey: identityKey as NSString)
    }

    /// Fetches or retrieves a decoded thumbnail with in-flight deduplication
    /// and background image decompression off the main thread.
    func thumbnailImage(
        for video: VideoAsset,
        api: DriveAPIClient?,
        currentUserID: String?
    ) async -> UIImage? {
        let identity = video.identityKey
        let cacheKey = identity as NSString

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        if let existingTask = inFlightTasks[identity] {
            return await existingTask.value
        }

        guard let api,
              currentUserID == video.googleUserID,
              !video.isMissingFromDrive,
              video.thumbnailLink != nil
        else {
            return nil
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            guard let data = try? await api.thumbnailData(for: video) else {
                return nil
            }

            // Bounded image decompression is performed off the main actor.
            let decodedImage = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 640
                        ] as CFDictionary
                      )
                else {
                    return nil
                }
                return UIImage(cgImage: cgImage)
            }.value

            guard let decodedImage else { return nil }
            let imageCost = decodedImage.cgImage.map {
                $0.bytesPerRow * $0.height
            } ?? data.count

            self.cache.setObject(decodedImage, forKey: cacheKey, cost: imageCost)
            return decodedImage
        }

        inFlightTasks[identity] = task
        let image = await task.value
        inFlightTasks.removeValue(forKey: identity)
        return image
    }

    func clearCache() {
        cache.removeAllObjects()
        inFlightTasks.removeAll()
    }
}
