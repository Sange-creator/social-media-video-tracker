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
                }
            }
            .animation(.easeOut(duration: 0.22), value: state.errorMessage)
            .task(id: state.errorMessage) {
                guard let message = state.errorMessage else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, state.errorMessage == message else { return }
                state.errorMessage = nil
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

private struct ImportantMessageBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(TrackerPalette.warning)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
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
        case .analytics:
            AnyView(AnalyticsView())
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
