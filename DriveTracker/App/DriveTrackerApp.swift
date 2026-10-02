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
                RootView(state: state)
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
                    await state.syncDuringOffTime(context: container.mainContext)
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-navigation-smoke-test") {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            let context = container.mainContext
            let account = TikTokAccount(googleUserID: "navigation-test", driveFolderID: "test-folder", folderName: "Navigation Test", dailyQuota: 3)
            context.insert(account)
            for index in 1...6 {
                let video = VideoAsset(driveFileID: "test-\(index)", accountFolderID: account.driveFolderID, googleUserID: account.googleUserID,
                                       name: "Video \(index).mp4", mimeType: "video/mp4", account: account)
                context.insert(video)
                if index <= 3 {
                    context.insert(DailyAssignment(localDayKey: DayKey.value(for: .now), slot: index, account: account, video: video))
                }
            }
            try context.save()
            return container
        }
        #endif
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
