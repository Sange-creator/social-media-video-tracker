import Foundation

/// Commit a change cursor only after all corresponding metadata is saved.
/// A baseline token is captured BEFORE scanning so uploads during the scan
/// remain in the next change page. Failed scans retain their cursor for retry.
@MainActor
final class DriveChangeTracker {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func check(
        key: String,
        startToken: () async throws -> String,
        changes: (String) async throws -> (changes: [DriveChange], nextToken: String),
        reconcile: () async -> Bool,
        isCurrentUser: () -> Bool
    ) async {
        do {
            guard let token = defaults.string(forKey: key), !token.isEmpty else {
                let baseline = try await startToken()
                guard await reconcile(), !Task.isCancelled, isCurrentUser() else { return }
                defaults.set(baseline, forKey: key)
                return
            }
            let page = try await changes(token)
            guard !Task.isCancelled, isCurrentUser() else { return }
            if !page.changes.isEmpty {
                guard await reconcile(), !Task.isCancelled, isCurrentUser() else { return }
            }
            defaults.set(page.nextToken, forKey: key)
        } catch DriveAPIError.http(410, _) {
            // Only an expired cursor requires a new baseline. Network errors
            // must not discard changes that still need to be applied.
            defaults.removeObject(forKey: key)
        } catch {
            // Retain the cursor and retry on the next foreground check.
        }
    }
}
