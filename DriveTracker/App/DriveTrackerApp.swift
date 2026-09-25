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

    private let container: ModelContainer = ModelContainerFactory.createContainer()

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
                    await state.sync(context: container.mainContext, announce: false)
                case .background:
                    await state.backupNow(context: container.mainContext)
                default:
                    break
                }
            }
        }
    }
}

enum ModelContainerFactory {
    static let schema = Schema([
        DriveSource.self,
        TikTokAccount.self,
        VideoAsset.self,
        DailyAssignment.self,
        StatusEvent.self,
        CopyEntry.self,
        CopyEvent.self
    ])

    static func createContainer() -> ModelContainer {
        let fileManager = FileManager.default
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }

        let configuration = ModelConfiguration(
            "DriveTracker",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        // Attempt 1: Persistent store with DriveTracker schema
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            print("[DriveTracker] Failed to create persistent ModelContainer: \(error)")
        }

        // Attempt 2: Fallback to default persistent store configuration
        if let defaultContainer = try? ModelContainer(for: schema) {
            return defaultContainer
        }

        // Attempt 3: In-memory fallback if disk storage is entirely unavailable
        let memoryConfig = ModelConfiguration(
            "DriveTracker_Memory",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true
        )
        if let memContainer = try? ModelContainer(for: schema, configurations: [memoryConfig]) {
            return memContainer
        }
        return try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }
}
