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
            .task(id: hasConfiguredAccount) {
                guard hasConfiguredAccount else {
                    dashboardIsReady = false
                    return
                }

                // Render a lightweight progress screen before constructing the
                // dashboard. A cold debug build on the simulator can spend several
                // seconds preparing SwiftUI's view metadata for all four tabs.
                dashboardIsReady = false
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                dashboardIsReady = true
            }
            .alert(
                "Social Media Video Tracker",
                isPresented: Binding(
                    get: { state.statusMessage != nil || state.errorMessage != nil },
                    set: { if !$0 { state.dismissMessages() } }
                )
            ) {
                Button("OK") { state.dismissMessages() }
            } message: {
                Text(state.errorMessage ?? state.statusMessage ?? "")
            }
            .tint(TrackerPalette.accent)
            .preferredColorScheme(.dark)
    }

    // Keeping the large onboarding and dashboard trees behind a small
    // type-erased boundary prevents a cold debug launch from eagerly preparing
    // metadata for every screen before the first frame is displayed.
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
        if !dashboardIsReady {
            return AnyView(
                LaunchView(
                    title: "Preparing today",
                    detail: "Loading accounts and assignments…"
                )
            )
        }
        return AnyView(MainTabView())
    }

    private var hasConfiguredAccount: Bool {
        accounts.contains { $0.isConfigured }
    }
}

private struct LaunchView: View {
    let title: String
    let detail: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TrackerPalette.raised, TrackerPalette.canvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

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
                    .font(.title.bold())
                    .tracking(-0.5)
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
        selectedContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(TrackerTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            VStack(spacing: 5) {
                                Rectangle()
                                    .fill(selectedTab == tab ? TrackerPalette.accent : .clear)
                                    .frame(height: 2)
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 18, weight: .semibold))
                                Text(tab.title.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.7)
                            }
                            .foregroundStyle(
                                selectedTab == tab ? TrackerPalette.accent : TrackerPalette.muted
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.title)
                        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
                .background(TrackerPalette.surface)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(TrackerPalette.line)
                        .frame(height: 1)
                }
            }
    }

    private var selectedContent: AnyView {
        switch selectedTab {
        case .today:
            AnyView(TodayView())
        case .library:
            AnyView(LibraryView())
        case .accounts:
            AnyView(AccountsView())
        case .settings:
            AnyView(SettingsView())
        }
    }
}

private enum TrackerTab: String, CaseIterable, Identifiable {
    case today
    case library
    case accounts
    case settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .today: "calendar"
        case .library: "rectangle.stack"
        case .accounts: "person.2"
        case .settings: "gearshape"
        }
    }
}
