import AVFoundation
import Foundation
import Photos
import UIKit

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case albumCreationFailed
    case assetCreationFailed
    case assetExportFailed
    case storageFull
    case photoLibraryUnavailable
    case timeout
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Allow Photos access in iPhone Settings so downloaded videos can be saved."
        case .albumCreationFailed:
            "The account album could not be created in Apple Photos."
        case .assetCreationFailed:
            "Photos could not save the downloaded video. Check available device storage."
        case .assetExportFailed:
            "Photos could not prepare this video for Drive backup."
        case .storageFull:
            "Your iPhone storage is almost full. Free up space to save downloaded videos."
        case .photoLibraryUnavailable:
            "The Apple Photos library is temporarily unavailable."
        case .timeout:
            "Apple Photos timed out while saving the video. Please retry."
        case .unsupportedFormat:
            "The video format could not be prepared for Apple Photos."
        }
    }
}

private actor PhotoSaveSerializer {
    func run<T>(_ operation: () async throws -> T) async throws -> T {
        try await operation()
    }
}

nonisolated final class PhotoLibraryService: Sendable {
    private let serializer = PhotoSaveSerializer()

    func savedAssetExists(localIdentifier: String) -> Bool? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject != nil
    }

    func existingAssetIdentifiers(_ identifiers: [String]) -> Set<String>? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        guard !identifiers.isEmpty else { return [] }

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: nil
        )
        var existing = Set<String>()
        result.enumerateObjects { asset, _, _ in
            existing.insert(asset.localIdentifier)
        }
        return existing
    }

    func saveMedia(at fileURL: URL, isPhoto: Bool, accountName: String) async throws -> String? {
        if isPhoto {
            return try await savePhoto(at: fileURL, accountName: accountName)
        } else {
            return try await saveVideo(at: fileURL, accountName: accountName)
        }
    }

    func savePhoto(at fileURL: URL, accountName: String) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }

        return try await serializer.run {
            // Step 1: Create the photo asset in the photo library
            var placeholder: PHObjectPlaceholder?
            try await self.performChanges {
                guard let creation = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL) else {
                    return
                }
                placeholder = creation.placeholderForCreatedAsset
            }

            guard let localIdentifier = placeholder?.localIdentifier else {
                throw PhotoLibraryError.assetCreationFailed
            }

            // Step 2: Attempt to add to the account album as a non-fatal secondary step
            if status == .authorized {
                if let album = try? await self.findOrCreateAlbum(named: self.sanitizedAlbumName(accountName)) {
                    _ = try? await self.performChanges {
                        guard let albumRequest = PHAssetCollectionChangeRequest(for: album),
                              let asset = PHAsset.fetchAssets(
                                  withLocalIdentifiers: [localIdentifier],
                                  options: nil
                              ).firstObject
                        else {
                            return
                        }
                        albumRequest.addAssets([asset] as NSArray)
                    }
                }
            }

            return localIdentifier
        }
    }

    func saveVideo(at fileURL: URL, accountName: String) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }

        return try await serializer.run {
            let (compatibleURL, isTemporary) = try await self.ensureCompatibleVideoFile(at: fileURL)
            defer {
                if isTemporary {
                    try? FileManager.default.removeItem(at: compatibleURL)
                }
            }

            // Step 1: Create the video asset in the photo library
            var placeholder: PHObjectPlaceholder?
            try await self.performChanges {
                guard let creation = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: compatibleURL) else {
                    return
                }
                placeholder = creation.placeholderForCreatedAsset
            }

            guard let localIdentifier = placeholder?.localIdentifier else {
                throw PhotoLibraryError.assetCreationFailed
            }

            // Step 2: Attempt to add to the account album as a non-fatal secondary step
            if status == .authorized {
                if let album = try? await self.findOrCreateAlbum(named: self.sanitizedAlbumName(accountName)) {
                    _ = try? await self.performChanges {
                        guard let albumRequest = PHAssetCollectionChangeRequest(for: album),
                              let asset = PHAsset.fetchAssets(
                                  withLocalIdentifiers: [localIdentifier],
                                  options: nil
                              ).firstObject
                        else {
                            return
                        }
                        albumRequest.addAssets([asset] as NSArray)
                    }
                }
            }

            return localIdentifier
        }
    }

    /// Checks if the video at the given URL is compatible with the Photos album.
    /// If incompatible (e.g. non-standard container or codec), transcodes it using AVAssetExportSession.
    private func ensureCompatibleVideoFile(at url: URL) async throws -> (url: URL, isTemporary: Bool) {
        if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) {
            return (url, false)
        }

        let asset = AVURLAsset(url: url)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            return (url, false)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveTrackerTranscodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let outputURL = tempDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        await exportSession.export()
        if exportSession.status == .completed && FileManager.default.fileExists(atPath: outputURL.path) {
            return (outputURL, true)
        } else {
            return (url, false)
        }
    }

    /// Exports a saved Photos video to a temporary file for an explicit Drive
    /// backup. The caller owns and must remove the returned file.
    func exportVideo(localIdentifier: String) async throws -> URL {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject,
        let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .video }) ?? PHAssetResource.assetResources(for: asset).first
        else {
            throw PhotoLibraryError.assetExportFailed
        }

        let extensionName = (resource.originalFilename as NSString).pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(extensionName.isEmpty ? "mp4" : extensionName)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: nil
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return destination
    }

    private func findOrCreateAlbum(named name: String) async throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        if let existing = PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject {
            return existing
        }

        var placeholder: PHObjectPlaceholder?
        do {
            try await performChanges {
                placeholder = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: name)
                    .placeholderForCreatedAssetCollection
            }
            if let id = placeholder?.localIdentifier,
               let album = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [id],
                    options: nil
               ).firstObject {
                return album
            }
        } catch {
            // Album creation failure is non-fatal for video saving
        }
        return nil
    }

    private func performChanges(_ changes: @escaping () -> Void) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges(changes) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: PhotoLibraryError.assetCreationFailed)
                    }
                }
            }
        } catch {
            if let nsError = error as NSError?, nsError.domain == "PHPhotosErrorDomain" {
                switch nsError.code {
                case 3300, 3302, -1:
                    throw PhotoLibraryError.assetCreationFailed
                case 3301, 3311:
                    throw PhotoLibraryError.permissionDenied
                default:
                    throw PhotoLibraryError.assetCreationFailed
                }
            }
            throw error
        }
    }

    private func sanitizedAlbumName(_ accountName: String) -> String {
        let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Drive Tracker – ") || trimmed.hasPrefix("Drive Tracker - ") {
            return trimmed
        }
        return "Drive Tracker – \(trimmed)"
    }
}
