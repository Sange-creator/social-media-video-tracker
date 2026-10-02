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

    @State private var containerLoad = Result { try ModelContainerFactory.createContainer() }

    var body: some Scene {
        WindowGroup {
            switch containerLoad {
            case .success(let container):
                RootView()
                    .environmentObject(state)
                    .environmentObject(state.auth)
                    .modelContainer(container)
                    .onOpenURL { url in
                        _ = state.auth.handle(url: url)
                    }
            case .failure(let error):
                ContentUnavailableView {
                    Label("Tracker storage unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Your saved tracker could not be opened. Existing data has been kept. \(error.localizedDescription)")
                } actions: {
                    Button("Try Again") {
                        containerLoad = Result { try ModelContainerFactory.createContainer() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task {
                switch newPhase {
                case .active:
                    break // RootView starts the foreground change monitor.
                case .background:
                    guard case .success(let container) = containerLoad else { return }
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

    static func createContainer() throws -> ModelContainer {
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

        // Never switch to a different store or an ephemeral database after a
        // disk/migration failure: that makes preserved history look erased and
        // lets new downloads disappear on the next launch.
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
