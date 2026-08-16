import Foundation
import Photos

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case albumCreationFailed
    case assetCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Allow Photos access in Settings so the downloaded video can be saved."
        case .albumCreationFailed:
            "The account album could not be created."
        case .assetCreationFailed:
            "Photos could not save the downloaded video."
        }
    }
}

@MainActor
final class PhotoLibraryService {
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

    func saveVideo(at fileURL: URL, accountName: String) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.permissionDenied
        }

        let album = try await findOrCreateAlbum(named: sanitizedAlbumName(accountName))
        var localIdentifier: String?
        try await performChanges {
            guard let creation = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL) else {
                return
            }
            localIdentifier = creation.placeholderForCreatedAsset?.localIdentifier
            if let placeholder = creation.placeholderForCreatedAsset,
               let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                albumRequest.addAssets([placeholder] as NSArray)
            }
        }
        guard localIdentifier != nil else { throw PhotoLibraryError.assetCreationFailed }
        return localIdentifier
    }

    private func findOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        if let existing = PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject {
            return existing
        }

        var placeholder: PHObjectPlaceholder?
        try await performChanges {
            placeholder = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: name)
                .placeholderForCreatedAssetCollection
        }
        guard
            let id = placeholder?.localIdentifier,
            let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id],
                options: nil
            ).firstObject
        else {
            throw PhotoLibraryError.albumCreationFailed
        }
        return album
    }

    private func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
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
    }

    private func sanitizedAlbumName(_ accountName: String) -> String {
        let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Drive Tracker – ") || trimmed.hasPrefix("Drive Tracker - ") {
            return trimmed
        }
        return "Drive Tracker – \(trimmed)"
    }
}
