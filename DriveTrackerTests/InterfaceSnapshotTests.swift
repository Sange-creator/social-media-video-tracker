import CryptoKit
import Combine
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import DriveTracker

@MainActor
final class InterfaceSnapshotTests: XCTestCase {
    func testLandscapeThumbnailsRespectNarrowGridWidth() {
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 240)).image { renderer in
            UIColor.orange.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 1200, height: 240))
        }
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 1200)).image { renderer in
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 240, height: 1200))
        }
        for image in [landscape, portrait] {
            for width in [CGFloat(90), 160, 340] {
                let controller = UIHostingController(rootView: ThumbnailArtwork(image: image).frame(height: 100))
                let size = controller.sizeThatFits(in: CGSize(width: width, height: 100))
                XCTAssertEqual(size.width, width, accuracy: 0.5)
                XCTAssertEqual(size.height, 100, accuracy: 0.5)
            }
        }
    }

    func testRepeatedTokenIdentityDoesNotPublishScreenInvalidations() {
        let auth = GoogleAuthService()
        auth.applyIdentity(isSignedIn: true, email: "qa@example.test", userID: "qa")
        var changes = 0
        let observation = auth.objectWillChange.sink { changes += 1 }
        for _ in 0..<100 {
            auth.applyIdentity(isSignedIn: true, email: "qa@example.test", userID: "qa")
        }
        XCTAssertEqual(changes, 0)
        auth.applyIdentity(isSignedIn: true, email: "other@example.test", userID: "other")
        XCTAssertGreaterThan(changes, 0)
        withExtendedLifetime(observation) {}
    }

    func testAdaptivePaletteResolvesOnBackgroundRenderExecutor() async throws {
        let resolved = await Task.detached {
            let color = TrackerPalette.adaptiveUIColor(light: 0xFFFFFF, dark: 0x101319)
            var components: [Double] = []
            for style in [UIUserInterfaceStyle.light, .dark] {
                let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                components.append(Double(red))
            }
            return components
        }.value
        XCTAssertEqual(resolved[0], 1, accuracy: 0.001)
        XCTAssertEqual(resolved[1], 16.0 / 255, accuracy: 0.001)
    }

    func testTodayLayoutsInLightDarkAndLargeText() async throws {
        let schema = ModelContainerFactory.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = TikTokAccount(googleUserID: "qa-user", driveFolderID: "qa-folder", folderName: "Daily Videos", displayName: "Daily Motivation", dailyQuota: 5)
        account.uploadPlatform = .tiktok
        context.insert(account)
        for index in 1...5 {
            let video = VideoAsset(driveFileID: "qa-\(index)", accountFolderID: "qa-folder", googleUserID: "qa-user",
                                   name: "Morning routine episode \(index).mp4", mimeType: "video/mp4", account: account)
            context.insert(video)
            let artwork = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 160)).image { renderer in
                UIColor.systemOrange.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
            }
            let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DriveTrackerThumbnails", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let hash = SHA256.hash(data: Data(ThumbnailService.cacheKey(for: video).utf8))
                .map { String(format: "%02x", $0) }.joined()
            try artwork.jpegData(compressionQuality: 0.8)?.write(to: cacheDirectory.appendingPathComponent("\(hash).jpg"))
            context.insert(DailyAssignment(localDayKey: DayKey.value(for: .now), slot: index, account: account, video: video))
        }
        try context.save()
        for video in account.videos {
            let loaded = await ThumbnailService.shared.thumbnailImage(for: video, api: nil, currentUserID: nil)
            XCTAssertNotNil(loaded, "Image-backed layout QA must load its fixture, not render a placeholder")
        }
        let state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for (name, scheme, size) in [("today-light", ColorScheme.light, DynamicTypeSize.large),
                                      ("today-dark", .dark, .large), ("today-large-text", .light, .accessibility2)] {
            let view = TodayView().modelContainer(container).environmentObject(state).environmentObject(state.auth)
                .preferredColorScheme(scheme).environment(\.dynamicTypeSize, size)
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered, "The \(name) interface must render")
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
        }
    }
    func testThemeAcrossTabsEditorsAndAccountDetails() async throws {
        let schema = ModelContainerFactory.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = TikTokAccount(googleUserID: "qa", driveFolderID: "folder", folderName: "Animated News", displayName: "Animated News")
        account.uploadPlatform = .tiktok
        context.insert(account)
        let video = VideoAsset(driveFileID: "qa-theme", accountFolderID: "folder", googleUserID: "qa", name: "Five mistakes episode 1.mp4", mimeType: "video/mp4", account: account)
        context.insert(video); try context.save()
        let state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let views: [(String, AnyView)] = [
            ("tabs", AnyView(MainTabView())),
            ("clipboard", AnyView(CopyQueueScreen())),
            ("library", AnyView(LibraryView())),
            ("accounts", AnyView(AccountsView())),
            ("analytics", AnyView(AnalyticsView())),
            ("settings", AnyView(SettingsView())),
            ("account-editor", AnyView(NavigationStack { AccountEditorView(account: account) })),
            ("account-library", AnyView(NavigationStack { AccountLibraryView(account: account) })),
            ("video-detail", AnyView(NavigationStack { VideoDetailView(video: video) })),
            ("today-detail", AnyView(NavigationStack { TodayAccountDetailView(account: account) })),
            ("setup", AnyView(OnboardingView())),
            ("add-account", AnyView(AddAccountFlowView()))
        ]
        for (name, screen) in views {
            let view = screen.modelContainer(container).environmentObject(state).environmentObject(state.auth)
                .preferredColorScheme(.dark)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = UIHostingController(rootView: view)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(200))
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered, "The \(name) screen must render")
            let attachment = XCTAttachment(image: image); attachment.name = "theme-" + name
            attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    func testTwentyAccountsSurviveRepeatedVerticalAndHorizontalScrolling() async throws {
        let schema = ModelContainerFactory.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        for index in 0..<20 {
            let account = TikTokAccount(googleUserID: "qa", driveFolderID: "folder-\(index)", folderName: "Creator \(index)", dailyQuota: 5, sortOrder: index)
            account.uploadPlatform = .tiktok
            context.insert(account)
            for slot in 1...5 {
                let video = VideoAsset(driveFileID: "\(index)-\(slot)", accountFolderID: account.driveFolderID, googleUserID: "qa", name: "Video \(slot).mp4", mimeType: "video/mp4", account: account)
                context.insert(video)
                context.insert(DailyAssignment(localDayKey: DayKey.value(for: .now), slot: slot, account: account, video: video))
            }
        }
        try context.save()
        let state = AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: TodayView().modelContainer(container).environmentObject(state).environmentObject(state.auth))
        window.makeKeyAndVisible(); defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
        }
        let vertical = try XCTUnwrap(scrollViews(window).max { $0.contentSize.height < $1.contentSize.height })
        XCTAssertGreaterThan(vertical.contentSize.height, vertical.bounds.height * 2)
        for step in 0..<24 {
            let end = max(0, vertical.contentSize.height - vertical.bounds.height)
            vertical.setContentOffset(CGPoint(x: 0, y: end * CGFloat(step % 13) / 12), animated: false)
            vertical.layoutIfNeeded()
            for horizontal in scrollViews(window) where horizontal.contentSize.width > horizontal.bounds.width && horizontal.contentSize.height <= horizontal.bounds.height + 1 {
                horizontal.setContentOffset(CGPoint(x: max(0, horizontal.contentSize.width - horizontal.bounds.width), y: 0), animated: false)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TikTokAccount>()), 20)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VideoAsset>()), 100)
    }

}
