import Foundation

/// Commit a change cursor only after all corresponding metadata is saved.
/// Missing/expired cursors are established without scanning on app open.
/// Initial folder imports are handled when connecting; catch-up scans run in
/// off time. Failed reconciliation retains the existing cursor for retry.
@MainActor
final class DriveChangeTracker {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    @discardableResult
    func check(
        key: String,
        startToken: () async throws -> String,
        changes: (String) async throws -> (changes: [DriveChange], nextToken: String),
        reconcile: ([DriveChange]) async -> Bool,
        isCurrentUser: () -> Bool
    ) async -> Bool {
        do {
            guard let token = defaults.string(forKey: key), !token.isEmpty else {
                let baseline = try await startToken()
                guard !Task.isCancelled, isCurrentUser() else { return false }
                defaults.set(baseline, forKey: key)
                return true
            }
            let page = try await changes(token)
            guard !Task.isCancelled, isCurrentUser() else { return false }
            if !page.changes.isEmpty {
                guard await reconcile(page.changes), !Task.isCancelled, isCurrentUser() else { return false }
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
