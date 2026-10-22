import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    let state: AppState
    @EnvironmentObject private var auth: GoogleAuthService
    @Query private var accounts: [TikTokAccount]

    var body: some View {
        rootContent
            .task {
                await state.start(context: context)
            }
            .task(id: "\(scenePhase)-\(auth.userID ?? "signed-out")-\(auth.isRestoring)") {
                guard scenePhase == .active, auth.isSignedIn, !auth.isRestoring else {
                    state.stopDriveChangeMonitor()
                    return
                }
                state.startDriveChangeMonitor(context: context)
            }
            .overlay(alignment: .bottom) {
                RootStatusOverlay(hasConfiguredAccount: hasConfiguredAccount)
                    .allowsHitTesting(false)
            }
            .tint(TrackerPalette.accent)
    }

    @ViewBuilder
    private var rootContent: some View {
        if auth.isRestoring {
            LaunchView(title: "Social Media Video Tracker", detail: "Restoring your tracker…")
        } else if !hasConfiguredAccount {
            OnboardingView()
        } else {
            MainTabView()
        }
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
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 0) {
                sectionButton("Today", symbol: "calendar", tab: 0)
                sectionButton("Clipboard", symbol: "doc.on.clipboard.fill", tab: 1)
                sectionButton("Library", symbol: "rectangle.stack", tab: 2)
                sectionButton("Accounts", symbol: "person.2", tab: 3)
                Menu {
                    Button("Analytics", systemImage: "chart.bar.xaxis") { selectedTab = 4 }
                    Button("Settings", systemImage: "gearshape") { selectedTab = 5 }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "ellipsis").font(.system(size: 20))
                        Text(selectedTab == 4 ? "Analytics" : selectedTab == 5 ? "Settings" : "More").font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("More sections")
                .foregroundStyle(selectedTab >= 4 ? TrackerPalette.accent : TrackerPalette.muted)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .background(TrackerPalette.surface)
        }
    }

    private func sectionButton(_ title: String, symbol: String, tab: Int) -> some View {
        Button { selectedTab = tab } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .foregroundStyle(selectedTab == tab ? TrackerPalette.accent : TrackerPalette.muted)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
        .accessibilityIdentifier("section-\(tab)")
    }
}

private struct RootStatusOverlay: View {
    let hasConfiguredAccount: Bool
    @EnvironmentObject private var state: AppState
    var body: some View {
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
    }
}
