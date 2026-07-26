import SwiftData
import SwiftUI

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

    var body: some View {
        NavigationStack {
            Form {
                googleSection
                driveSection
                notificationSection
                backupSection
                privacySection
                dangerSection
            }
            .trackerListStyle()
            .navigationTitle("Settings")
            .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { folderLink = state.rootLink }
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

    private var googleSection: some View {
        Section {
            if auth.isSignedIn {
                HStack {
                    Circle()
                        .fill(TrackerPalette.success)
                        .frame(width: 7, height: 7)
                    LabeledContent("Connected", value: auth.email ?? "Google account")
                }
                Button("Disconnect Google", role: .destructive) {
                    confirmDisconnect = true
                }
                Button {
                    Task { await state.switchGoogleAccount(context: context) }
                } label: {
                    Label("Add or switch Google account", systemImage: "person.2")
                }
            } else {
                Button("Connect Google") {
                    Task { await state.signIn(context: context) }
                }
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
        } header: {
            TrackerSectionLabel(title: "Google connection")
        }
    }

    private var driveSection: some View {
        Section {
            Button {
                showFolderBrowser = true
            } label: {
                Label("Choose another Drive folder", systemImage: "folder.badge.plus")
            }
            .disabled(!auth.isSignedIn)

            TextField("Folder link", text: $folderLink, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.monospaced())
            Button(isResolvingLink ? "Checking folder…" : "Continue and choose account") {
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
            }
            .disabled(!auth.isSignedIn || folderLink.isEmpty || state.isWorking || isResolvingLink)

            ForEach(sources) { source in
                DriveSourceSettingsRow(source: source)
            }

            Button("Sync folders for the connected Google account") {
                Task { await state.sync(context: context) }
            }
            .disabled(!auth.isSignedIn || state.isWorking)

            if let lastSyncAt = state.lastSyncAt {
                LabeledContent("Last complete sync", value: lastSyncAt.formatted())
                    .font(.footnote)
            }
            Text("Only folders you explicitly connect are scanned. Each folder is attached to the account you choose; nested folders stay inside that account. The app checks again when it opens or returns to the foreground.")
                .font(.footnote)
                .foregroundStyle(TrackerPalette.muted)
        } header: {
            TrackerSectionLabel(title: "Drive source")
        }
    }

    private var backupSection: some View {
        Section {
            Button("Back up now") {
                Task { await state.backupNow(context: context) }
            }
            .disabled(!auth.isSignedIn || sources.isEmpty)

            if let lastBackupAt = state.lastBackupAt {
                LabeledContent("Last backup", value: lastBackupAt.formatted())
                    .font(.footnote)
            }
            Button("Delete hidden Drive backup", role: .destructive) {
                confirmDeleteBackup = true
            }
            .disabled(!auth.isSignedIn)
            Text("Only account, assignment, and status metadata is backed up. Videos and credentials are never included.")
                .font(.footnote)
                .foregroundStyle(TrackerPalette.muted)
        } header: {
            TrackerSectionLabel(title: "Recovery backup")
        }
    }

    private var notificationSection: some View {
        Section {
            Button("Enable download reminders") {
                Task {
                    let enabled = await state.enableDownloadNotifications(context: context)
                    state.statusMessage = enabled
                        ? "Download reminders enabled for the New York schedule."
                        : "Notifications are disabled. Allow them in iPhone Settings."
                }
            }
            Text("The tracker reminds you at the three New York windows. Videos for different accounts are staggered by 10, 15, 20, or 30 minutes. Nothing downloads automatically.")
                .font(.footnote)
                .foregroundStyle(TrackerPalette.muted)
        } header: {
            TrackerSectionLabel(title: "Download reminders")
        }
    }

    private var privacySection: some View {
        Section {
            NavigationLink("How your data is handled") {
                PrivacyView()
            }
            LabeledContent("Analytics", value: "None")
            LabeledContent("Advertising", value: "None")
            LabeledContent("External account login", value: "Not used")
        } header: {
            TrackerSectionLabel(title: "Privacy posture")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Delete local tracking data", role: .destructive) {
                confirmDeleteLocal = true
            }
        } header: {
            TrackerSectionLabel(title: "Data controls")
        } footer: {
            Text("Deleting the app also deletes its local database. Keep the hidden Drive backup for recovery.")
        }
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
        .padding(.vertical, 4)
    }
}

private struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Video status, daily assignments, account settings, and audit history are stored in the app’s private SwiftData container.")
            } header: {
                TrackerSectionLabel(title: "On this iPhone")
            }
            Section {
                Text("Social Media Video Tracker reads folder metadata and video files you can access. A small JSON recovery backup is stored in Google Drive’s hidden app-data folder.")
            } header: {
                TrackerSectionLabel(title: "Google Drive")
            }
            Section {
                Text("A downloaded video is added to an account-specific Photos album. The app records completion only after Photos confirms the save.")
                Text("Before saving, Social Media Video Tracker verifies the downloaded file size and Google Drive checksum when available. The Drive download is the original source file, with no app compression or quality conversion.")
            } header: {
                TrackerSectionLabel(title: "Photos")
            }
            Section {
                Text("A successful download and Photos save marks the item completed automatically. Suggested items are not marked completed.")
            } header: {
                TrackerSectionLabel(title: "Completion rule")
            }
        }
        .trackerListStyle()
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}
