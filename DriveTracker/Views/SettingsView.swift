import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var auth: GoogleAuthService
    @Query(sort: \DriveSource.createdAt) private var sources: [DriveSource]
    @State private var folderLink = ""
    @State private var confirmDeleteLocal = false
    @State private var confirmDeleteBackup = false
    @State private var confirmDisconnect = false
    @State private var showFolderBrowser = false
    @State private var pendingFolder: DriveFolderChoice?
    @State private var pendingFolderLink: String?
    @State private var isResolvingLink = false
    @State private var isConnectingQueue = false
    @State private var queueLinkDraft = ""
    @FocusState private var isQueueLinkFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    customTopHeader
                    googleSection
                    driveSection
                    copyQueueSection
                    notificationSection
                    backupSection
                    privacySection
                    dangerSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
            .trackerScreen()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                folderLink = state.rootLink
                queueLinkDraft = state.globalCopyQueueLink
            }
            .onChange(of: state.globalCopyQueueLink) { _, newValue in
                if !isQueueLinkFocused, !isConnectingQueue {
                    queueLinkDraft = newValue
                }
            }
            .onDisappear { dismissQueueKeyboard() }
        }
        .confirmationDialog("Delete all local tracking data?", isPresented: $confirmDeleteLocal) {
            Button("Delete local data", role: .destructive) {
                state.deleteLocalData(context: context)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The hidden Drive backup is not deleted.")
        }
        .confirmationDialog("Delete the hidden Drive backup?", isPresented: $confirmDeleteBackup) {
            Button("Delete Drive backup", role: .destructive) {
                Task { await state.deleteRemoteBackup() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Disconnect Google?", isPresented: $confirmDisconnect) {
            Button("Disconnect and revoke access", role: .destructive) {
                Task {
                    do {
                        try await auth.disconnect()
                    } catch {
                        state.errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local tracking history remains on this iPhone.")
        }
        .sheet(isPresented: $showFolderBrowser) {
            DriveFolderBrowserView { folder in
                pendingFolderLink = nil
                pendingFolder = folder
            }
        }
        .sheet(item: $pendingFolder) { folder in
            FolderAssociationView(folder: folder, originalLink: pendingFolderLink)
        }
    }

    private var customTopHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SETTINGS")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(TrackerPalette.textPrimary)

                Text("Connected Accounts & Storage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TrackerPalette.muted)
            }

            Spacer()

            if auth.isSignedIn {
                HStack(spacing: 5) {
                    Circle()
                        .fill(TrackerPalette.success)
                        .frame(width: 6, height: 6)
                        .shadow(color: TrackerPalette.success.opacity(0.8), radius: 3)
                    Text("ONLINE")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(TrackerPalette.success)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(TrackerPalette.success.opacity(0.12), in: Capsule())
                .overlay {
                    Capsule().stroke(TrackerPalette.success.opacity(0.3), lineWidth: 1)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var googleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Google Connection",
                trailing: auth.isSignedIn ? "Active Session" : "Required"
            )

            if auth.isSignedIn {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(TrackerPalette.accent.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(TrackerPalette.accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(auth.email ?? "Google Account")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(TrackerPalette.textPrimary)
                        Text("Google Drive & Sheets Authorized")
                            .font(.caption2)
                            .foregroundStyle(TrackerPalette.muted)
                    }

                    Spacer()
                }
                .padding(12)
                .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        Task { await state.switchGoogleAccount(context: context) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.2.fill")
                            Text("Switch Account")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(TrackerPalette.line, lineWidth: 1)
                        }
                    }
                    .buttonStyle(TrackerPressButtonStyle())

                    Button {
                        confirmDisconnect = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Disconnect")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TrackerPalette.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(TrackerPalette.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                }
            } else {
                Button {
                    Task { await state.signIn(context: context) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                        Text("Sign In with Google")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(hex: "#090A0F"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(TrackerPalette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(TrackerPressButtonStyle())
                .disabled(!auth.isConfigured)
            }

            if !auth.isConfigured {
                Label(
                    "OAuth client ID is not configured in Info.plist.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(TrackerPalette.warning)
            }
        }
        .trackerCard(padding: 16)
    }

    private var driveSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Drive Sources",
                trailing: "\(sources.filter(\.isEnabled).count) connected"
            )

            HStack(spacing: 10) {
                Button {
                    showFolderBrowser = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text("Browse Drive")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: "#090A0F"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(TrackerPalette.accent, in: Capsule())
                }
                .buttonStyle(TrackerPressButtonStyle())
                .disabled(!auth.isSignedIn)

                Spacer()

                Button {
                    Task { await state.sync(context: context) }
                } label: {
                    HStack(spacing: 5) {
                        if state.isWorking {
                            ProgressView()
                                .tint(TrackerPalette.accent)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text("Sync All")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrackerPalette.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(TrackerPalette.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(TrackerPressButtonStyle())
                .disabled(!auth.isSignedIn || state.isWorking)
            }

            // Link Input Field
            VStack(alignment: .leading, spacing: 8) {
                Text("Or Paste Folder URL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TrackerPalette.muted)

                HStack(spacing: 8) {
                    TextField("https://drive.google.com/drive/folders/...", text: $folderLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .padding(10)
                        .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(TrackerPalette.line, lineWidth: 1)
                        }

                    Button {
                        if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                            folderLink = pasted
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(TrackerPalette.accent)
                            .padding(10)
                            .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                Button {
                    Task {
                        isResolvingLink = true
                        defer { isResolvingLink = false }
                        do {
                            pendingFolder = try await state.folderChoice(from: folderLink)
                            pendingFolderLink = folderLink
                        } catch {
                            state.errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        if isResolvingLink {
                            ProgressView()
                                .tint(TrackerPalette.accent)
                        }
                        Text(isResolvingLink ? "Checking Folder..." : "Connect Pasted Folder")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TrackerPalette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(TrackerPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(TrackerPressButtonStyle())
                .disabled(!auth.isSignedIn || folderLink.isEmpty || state.isWorking || isResolvingLink)
            }

            if !sources.isEmpty {
                Divider().overlay(TrackerPalette.line)

                ForEach(sources) { source in
                    DriveSourceSettingsRow(source: source)
                }
            }

            if let lastSyncAt = state.lastSyncAt {
                HStack {
                    Text("Last complete sync:")
                        .font(.caption2)
                        .foregroundStyle(TrackerPalette.muted)
                    Spacer()
                    Text(lastSyncAt.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(TrackerPalette.muted)
                }
            }
        }
        .trackerCard(padding: 16)
    }

    private var copyQueueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Global Copy Queue",
                trailing: state.hasGlobalCopyQueueSheet ? "Connected" : "Not Linked"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Google Sheet URL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TrackerPalette.muted)

                TextField("https://docs.google.com/spreadsheets/d/...", text: $queueLinkDraft, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.footnote.monospaced())
                    .lineLimit(2 ... 4)
                    .padding(10)
                    .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(TrackerPalette.line, lineWidth: 1)
                    }
                    .focused($isQueueLinkFocused)

                HStack(spacing: 10) {
                    Button {
                        pasteQueueLink()
                    } label: {
                        Label("Paste Link", systemImage: "doc.on.clipboard")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TrackerPalette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(TrackerPalette.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(TrackerPressButtonStyle())

                    Spacer()

                    Button {
                        saveQueueLink()
                    } label: {
                        HStack(spacing: 5) {
                            if isConnectingQueue {
                                ProgressView()
                                    .tint(Color(hex: "#090A0F"))
                                    .scaleEffect(0.7)
                            }
                            Text(isConnectingQueue ? "Connecting..." : state.hasGlobalCopyQueueSheet ? "Save Changes" : "Connect Sheet")
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(hex: "#090A0F"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(TrackerPalette.accent, in: Capsule())
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                    .disabled(!auth.isSignedIn || isConnectingQueue || queueLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if state.hasGlobalCopyQueueSheet && !hasUnsavedQueueLink {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TrackerPalette.success)
                    Text("Google Sheet successfully synced with 1-tap queue.")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(TrackerPalette.success)
                }
            }

            Text("Put one complete title and hashtag block in each row of column A. The app automatically fetches new captions during every Drive sync.")
                .font(.caption2)
                .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard(padding: 16)
    }

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Schedule & Reminders",
                trailing: "US Timezones"
            )

            HStack {
                Text("Default US Time Zone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TrackerPalette.textPrimary)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { state.reminderTimeZoneID },
                        set: { state.setReminderTimeZone($0, context: context) }
                    )
                ) {
                    ForEach(USReminderTimeZone.allCases) { zone in
                        Text("\(zone.title) (\(zone.shortTitle))")
                            .tag(zone.rawValue)
                    }
                }
                .labelsHidden()
            }

            Divider().overlay(TrackerPalette.line)

            Button {
                Task {
                    let enabled = await state.enableDownloadNotifications(context: context)
                    if !enabled {
                        state.errorMessage = "Notifications are disabled. Allow them in iPhone Settings."
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(TrackerPalette.accent)
                    Text("Enable Download Push Reminders")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(TrackerPalette.muted)
                }
                .padding(12)
                .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(TrackerPressButtonStyle())

            Text("Reminders trigger at 3:00 AM, 9:00 AM, 3:00 PM, and 9:00 PM in the selected time zone, staggered per account.")
                .font(.caption2)
                .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard(padding: 16)
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Cloud Backup",
                trailing: state.lastBackupAt != nil ? "Protected" : "Pending"
            )

            HStack {
                Button {
                    Task { await state.backupNow(context: context) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.and.arrow.up.fill")
                        Text("Back Up Now")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: "#090A0F"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(TrackerPalette.accent, in: Capsule())
                }
                .buttonStyle(TrackerPressButtonStyle())
                .disabled(!auth.isSignedIn || (sources.isEmpty && !state.hasGlobalCopyQueueSheet))

                Spacer()

                if let lastBackupAt = state.lastBackupAt {
                    Text("Last: \(lastBackupAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(TrackerPalette.muted)
                }
            }

            Text("Backs up account settings, daily progress, custom time slots, and copy queue history to hidden Drive storage.")
                .font(.caption2)
                .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard(padding: 16)
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrackerSectionLabel(title: "Privacy & Integrity")

            NavigationLink {
                PrivacyView()
            } label: {
                HStack {
                    Image(systemName: "hand.raised.shield.fill")
                        .foregroundStyle(TrackerPalette.accent)
                    Text("How Your Data is Handled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(TrackerPalette.muted)
                }
                .padding(12)
                .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(TrackerPressButtonStyle())

            HStack {
                Text("Analytics & Tracking")
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
                Spacer()
                Text("On-device only")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrackerPalette.textPrimary)
            }

            HStack {
                Text("Authentication")
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
                Spacer()
                Text("Direct Google OAuth")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TrackerPalette.textPrimary)
            }
        }
        .trackerCard(padding: 16)
    }

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrackerSectionLabel(
                title: "Data Controls",
                trailing: "Danger Zone"
            )

            Button {
                confirmDeleteLocal = true
            } label: {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("Delete Local Tracking Database")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(TrackerPalette.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(TrackerPalette.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(TrackerPressButtonStyle())

            Text("Deletes local history on this iPhone. Your files on Google Drive will never be modified or deleted.")
                .font(.caption2)
                .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard(padding: 16)
    }

    private func saveQueueLink() {
        guard !isConnectingQueue else { return }
        dismissQueueKeyboard()
        isConnectingQueue = true
        Task {
            let connected = await state.connectGlobalCopyQueue(
                link: queueLinkDraft,
                context: context
            )
            if connected {
                queueLinkDraft = state.globalCopyQueueLink
            }
            isConnectingQueue = false
            dismissQueueKeyboard()
        }
    }

    private func pasteQueueLink() {
        guard let pastedLink = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !pastedLink.isEmpty
        else {
            state.errorMessage = "Copy a Google Sheet link first, then tap Paste Link."
            return
        }

        queueLinkDraft = pastedLink
        dismissQueueKeyboard()
    }

    private var hasUnsavedQueueLink: Bool {
        queueLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines) !=
            state.globalCopyQueueLink
    }

    private func dismissQueueKeyboard() {
        isQueueLinkFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private struct DriveSourceSettingsRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var source: DriveSource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Text(source.googleEmail)
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                }
                Spacer()
                Toggle("", isOn: $source.isEnabled)
                    .labelsHidden()
                    .onChange(of: source.isEnabled) { _, _ in
                        try? context.save()
                    }
            }
            Text(source.rootFolderID)
                .font(.caption2.monospaced())
                .foregroundStyle(TrackerPalette.muted)
                .lineLimit(1)
            if let lastSyncedAt = source.lastSyncedAt {
                Text("Last synced \(lastSyncedAt.formatted())")
                    .font(.caption2)
                    .foregroundStyle(TrackerPalette.muted)
            }
        }
        .padding(10)
        .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PrivacyView: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    TrackerSectionLabel(title: "On this iPhone")
                    Text("Video status, daily assignments, account settings, copy-queue text, and audit history are stored in the app’s private SwiftData container.")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                }
                .trackerCard(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    TrackerSectionLabel(title: "Google Drive")
                    Text("Social Media Video Tracker reads selected folder metadata, video files, and the Copy Paste/Queue Sheet. The hidden JSON recovery backup includes tracker metadata and cached copy-queue text, but never video files or credentials.")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                }
                .trackerCard(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    TrackerSectionLabel(title: "Apple Photos")
                    Text("A downloaded video is added to an account-specific Photos album. The app records completion only after Photos confirms the save.")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                    Text("Before saving, Social Media Video Tracker verifies the downloaded file size and Google Drive checksum when available. The Drive download is the original source file, with no app compression or quality conversion.")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                }
                .trackerCard(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    TrackerSectionLabel(title: "Completion rule")
                    Text("A successful download and Photos save marks the item completed automatically. Suggested items are not marked completed until verified.")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                }
                .trackerCard(padding: 16)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
        .trackerScreen()
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}
