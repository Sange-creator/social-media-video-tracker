import Foundation

/// Commit a change cursor only after all corresponding metadata is saved.
/// A baseline token is captured BEFORE scanning so uploads during the scan
/// remain in the next change page. Failed scans retain their cursor for retry.
@MainActor
final class DriveChangeTracker {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    @discardableResult
    func check(
        key: String,
        startToken: () async throws -> String,
        changes: (String) async throws -> (changes: [DriveChange], nextToken: String),
        reconcile: () async -> Bool,
        isCurrentUser: () -> Bool,
        apply: (([DriveChange]) async -> Bool)? = nil
    ) async -> Bool {
        do {
            guard let token = defaults.string(forKey: key), !token.isEmpty else {
                let baseline = try await startToken()
                guard await reconcile(), !Task.isCancelled, isCurrentUser() else { return false }
                defaults.set(baseline, forKey: key)
                return true
            }
            let page = try await changes(token)
            guard !Task.isCancelled, isCurrentUser() else { return false }
            if !page.changes.isEmpty {
                let succeeded = if let apply { await apply(page.changes) } else { await reconcile() }
                guard succeeded, !Task.isCancelled, isCurrentUser() else { return false }
            }
            defaults.set(page.nextToken, forKey: key)
            return true
        } catch DriveAPIError.http(410, _) {
            // Only an expired cursor requires a new baseline. Network errors
            // must not discard changes that still need to be applied.
            defaults.removeObject(forKey: key)
        } catch {
            // Retain the cursor and retry on the next foreground check.
        }
        return false
    }
}
