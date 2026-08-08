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
                guard auth.isSignedIn else { return }
                await state.runForegroundDriveRefreshLoop(context: context)
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
                if let error = state.errorMessage {
                    ImportantMessageBanner(message: error)
                        .padding(.horizontal, 14)
                        .padding(.bottom, hasConfiguredAccount ? 70 : 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                } else if let message = state.toastMessage {
                    ToastMessageBanner(message: message)
                        .padding(.horizontal, 14)
                        .padding(.bottom, hasConfiguredAccount ? 70 : 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                } else if let message = state.statusMessage {
                    ToastMessageBanner(message: message)
                        .padding(.horizontal, 14)
                        .padding(.bottom, hasConfiguredAccount ? 70 : 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.22), value: state.errorMessage)
            .animation(.easeOut(duration: 0.22), value: state.toastMessage)
            .animation(.easeOut(duration: 0.22), value: state.statusMessage)
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
            .preferredColorScheme(.dark)
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
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(TrackerPalette.success)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(TrackerPalette.success.opacity(0.30), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }
}

private struct ImportantMessageBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(TrackerPalette.warning)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(TrackerPalette.warning.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
    }
}

private struct LaunchView: View {
    let title: String
    let detail: String

    var body: some View {
        ZStack {
            TrackerPalette.canvas.ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(TrackerPalette.accent)
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 31, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 68, height: 68)

                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(TrackerPalette.muted)
                ProgressView()
                    .tint(TrackerPalette.accent)
            }
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab: TrackerTab = .today

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tag(TrackerTab.today)
                .tabItem { Label("Today", systemImage: TrackerTab.today.symbol) }

            AnalyticsView()
                .tag(TrackerTab.analytics)
                .tabItem { Label("Analytics", systemImage: TrackerTab.analytics.symbol) }

            LibraryView()
                .tag(TrackerTab.library)
                .tabItem { Label("Library", systemImage: TrackerTab.library.symbol) }

            AccountsView()
                .tag(TrackerTab.accounts)
                .tabItem { Label("Accounts", systemImage: TrackerTab.accounts.symbol) }

            SettingsView()
                .tag(TrackerTab.settings)
                .tabItem { Label("Settings", systemImage: TrackerTab.settings.symbol) }
        }
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.regularMaterial, for: .tabBar)
    }
}

private enum TrackerTab: String, CaseIterable, Identifiable {
    case today
    case analytics
    case library
    case accounts
    case settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .today: "calendar"
        case .analytics: "chart.bar.xaxis"
        case .library: "rectangle.stack"
        case .accounts: "person.2"
        case .settings: "gearshape"
        }
    }
}
