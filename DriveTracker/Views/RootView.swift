import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var auth: GoogleAuthService
    @Query private var accounts: [TikTokAccount]
    @State private var dashboardIsReady = false

    var body: some View {
        rootContent
            .task {
                await state.start(context: context)
            }
            .task(id: auth.isSignedIn) {
                guard auth.isSignedIn else {
                    state.stopDriveChangeMonitor()
                    return
                }
                state.startDriveChangeMonitor(context: context)
            }
            .task(id: hasConfiguredAccount) {
                guard hasConfiguredAccount else {
                    dashboardIsReady = false
                    return
                }

                dashboardIsReady = false
                await Task.yield()
                guard !Task.isCancelled else { return }
                dashboardIsReady = true
            }
            .overlay(alignment: .bottom) {
                Group {
                    if let error = state.errorMessage {
                        ImportantMessageBanner(message: error)
                    } else if let message = state.toastMessage {
                        ToastMessageBanner(message: message)
                    } else if let message = state.statusMessage {
                        ToastMessageBanner(message: message)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, hasConfiguredAccount ? 72 : 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.errorMessage)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.toastMessage)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.statusMessage)
                .allowsHitTesting(false)
            }
            .task(id: state.errorMessage) {
                guard let message = state.errorMessage else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, state.errorMessage == message else { return }
                state.errorMessage = nil
            }
            .task(id: state.toastMessage) {
                guard let message = state.toastMessage else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, state.toastMessage == message else { return }
                state.toastMessage = nil
            }
            .task(id: state.statusMessage) {
                guard let message = state.statusMessage else { return }
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, state.statusMessage == message else { return }
                state.statusMessage = nil
            }
            .tint(TrackerPalette.accent)
    }

    private var rootContent: AnyView {
        if auth.isRestoring {
            return AnyView(
                LaunchView(
                    title: "Social Media Video Tracker",
                    detail: "Restoring your tracker…"
                )
            )
        }
        if !hasConfiguredAccount {
            return AnyView(OnboardingView())
        }
        return AnyView(MainTabView())
    }

    private var hasConfiguredAccount: Bool {
        accounts.contains { $0.isConfigured }
    }
}

private struct ToastMessageBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(TrackerPalette.success)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(TrackerPalette.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TrackerPalette.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TrackerPalette.success.opacity(0.35), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.40), radius: 16, y: 6)
    }
}

private struct ImportantMessageBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(TrackerPalette.warning)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(TrackerPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(TrackerPalette.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TrackerPalette.warning.opacity(0.40), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.40), radius: 16, y: 6)
    }
}

private struct LaunchView: View {
    let title: String
    let detail: String

    var body: some View {
        ZStack {
            TrackerPalette.canvas.ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [TrackerPalette.accent, TrackerPalette.success],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: TrackerPalette.accent.opacity(0.35), radius: 16, y: 6)

                    Image("BrandMark")
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .frame(width: 72, height: 72)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(TrackerPalette.muted)
                }

                ProgressView()
                    .tint(TrackerPalette.accent)
                    .controlSize(.regular)
            }
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView().tabItem { Label("Today", systemImage: "calendar") }.tag(0)
            CopyQueueScreen().tabItem { Label("Clipboard", systemImage: "doc.on.clipboard.fill") }.tag(1)
            LibraryView().tabItem { Label("Library", systemImage: "rectangle.stack") }.tag(2)
            AccountsView().tabItem { Label("Accounts", systemImage: "person.2") }.tag(3)
            AnalyticsView().tabItem { Label("Analytics", systemImage: "chart.bar.xaxis") }.tag(4)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(5)
        }
        .toolbarBackground(TrackerPalette.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
