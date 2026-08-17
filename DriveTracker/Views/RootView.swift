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
        ZStack(alignment: .bottom) {
            // Keep only the selected tab in the view tree. The previous
            // opacity-based stack rendered all five tabs at once, so every
            // scroll gesture also laid out Settings, Analytics, Library,
            // Accounts, and Today together.
            selectedTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom gradient veil anchored to absolute device bottom
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        TrackerPalette.canvas.opacity(0),
                        TrackerPalette.canvas
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 36)

                Rectangle()
                    .fill(TrackerPalette.canvas)
                    .frame(height: 54)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .compositingGroup()

            floatingDock
                .compositingGroup()
        }
        .ignoresSafeArea(.all, edges: .bottom)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case 0: TodayView()
        case 1: AnalyticsView()
        case 2: LibraryView()
        case 3: AccountsView()
        default: SettingsView()
        }
    }

    private var floatingDock: some View {
        HStack(spacing: 0) {
            dockItem(index: 0, title: "Today", icon: "calendar")
            dockItem(index: 1, title: "Analytics", icon: "chart.bar.xaxis")
            dockItem(index: 2, title: "Library", icon: "rectangle.stack")
            dockItem(index: 3, title: "Accounts", icon: "person.2")
            dockItem(index: 4, title: "Settings", icon: "gearshape")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            Color(hex: "#131622").opacity(0.98)
        )
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(Color(hex: "#222739"), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private func dockItem(index: Int, title: String, icon: String) -> some View {
        let isSelected = selectedTab == index
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedTab = index
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? TrackerPalette.accent : TrackerPalette.muted)

                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? TrackerPalette.accent : TrackerPalette.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                isSelected ? TrackerPalette.accent.opacity(0.12) : Color.clear,
                in: Capsule()
            )
        }
        .buttonStyle(TrackerPressButtonStyle())
    }
}
