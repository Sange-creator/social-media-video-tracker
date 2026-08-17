import SwiftData
import SwiftUI
import UIKit

final class DriveTrackerAppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) private static var backgroundCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Self.backgroundCompletionHandler = completionHandler
    }

    static func finishBackgroundSessionEvents() {
        let completion = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        completion?()
    }
}

@main
struct DriveTrackerApp: App {
    @UIApplicationDelegateAdaptor(DriveTrackerAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = AppState()

    private let container: ModelContainer = {
        let schema = Schema([
            DriveSource.self,
            TikTokAccount.self,
            VideoAsset.self,
            DailyAssignment.self,
            StatusEvent.self,
            CopyEntry.self,
            CopyEvent.self
        ])
        let configuration = ModelConfiguration(
            "DriveTracker",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create the tracker database: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.auth)
                .onOpenURL { url in
                    _ = state.auth.handle(url: url)
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, newPhase in
            Task {
                switch newPhase {
                case .active:
                    await state.checkForDriveChanges(context: container.mainContext)
                case .background:
                    await state.backupNow(context: container.mainContext)
                default:
                    break
                }
            }
        }
    }
}
