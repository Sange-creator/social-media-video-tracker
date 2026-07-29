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
            Form {
                googleSection
                driveSection
                copyQueueSection
                notificationSection
                backupSection
                privacySection
                dangerSection
            }
            .trackerListStyle()
            .navigationTitle("Settings")
            .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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

    private var copyQueueSection: some View {
        Section {
            TextField(
                "Google Sheet link",
                text: $queueLinkDraft,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .font(.footnote.monospaced())
            .lineLimit(2 ... 5)
            .submitLabel(.done)
            .focused($isQueueLinkFocused)
            .onSubmit { isQueueLinkFocused = false }

            HStack(spacing: 10) {
                Button {
                    pasteQueueLink()
                } label: {
                    Label("Paste Link", systemImage: "doc.on.clipboard")
                }

                Spacer(minLength: 8)

                Button {
                    selectAllQueueLink()
                } label: {
                    Label("Select All", systemImage: "selection.pin.in.out")
                }
                .disabled(queueLinkDraft.isEmpty)
            }
            .buttonStyle(.borderless)

            Button {
                saveQueueLink()
            } label: {
                HStack {
                    if isConnectingQueue {
                        ProgressView()
                    } else {
                        Image(systemName: "link")
                    }
                    Text(
                        isConnectingQueue
                            ? "Checking Google Sheet…"
                            : state.hasGlobalCopyQueueSheet
                                ? "Save and reconnect Sheet"
                                : "Connect Google Sheet"
                    )
                }
            }
            .disabled(
                !auth.isSignedIn ||
                isConnectingQueue ||
                queueLinkDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )

            if state.hasGlobalCopyQueueSheet, !hasUnsavedQueueLink {
                Label("Global queue connected", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TrackerPalette.success)
            } else if hasUnsavedQueueLink {
                Label("Link changed — save to connect it", systemImage: "pencil.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TrackerPalette.warning)
            }

            if let lastSynced = state.globalCopyQueueLastSyncedAt {
                LabeledContent("Last queue sync", value: lastSynced.formatted())
                    .font(.footnote)
            }

            Text("You can replace this URL at any time. The app validates the new Sheet before switching, so an invalid link does not erase the current queue history. Put one complete title-and-hashtag block in each cell in column A; the “Content” header in A1 is optional.")
                .font(.footnote)
                .foregroundStyle(TrackerPalette.muted)
        } header: {
            TrackerSectionLabel(title: "Global copy queue")
        }
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

    private func selectAllQueueLink() {
        isQueueLinkFocused = true
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(
                #selector(UIResponder.selectAll(_:)),
                to: nil,
                from: nil,
                for: nil
            )
        }
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
            .disabled(!auth.isSignedIn || (sources.isEmpty && !state.hasGlobalCopyQueueSheet))

            if let lastBackupAt = state.lastBackupAt {
                LabeledContent("Last backup", value: lastBackupAt.formatted())
                    .font(.footnote)
            }
            Button("Delete hidden Drive backup", role: .destructive) {
                confirmDeleteBackup = true
            }
            .disabled(!auth.isSignedIn)
            Text("Account settings, video status, copy-queue text, and copy history are backed up. Videos and credentials are never included.")
                .font(.footnote)
                .foregroundStyle(TrackerPalette.muted)
        } header: {
            TrackerSectionLabel(title: "Recovery backup")
        }
    }

    private var notificationSection: some View {
        Section {
            Picker(
                "United States time zone",
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

            Button("Enable download reminders") {
                Task {
                    let enabled = await state.enableDownloadNotifications(context: context)
                    if !enabled {
                        state.errorMessage = "Notifications are disabled. Allow them in iPhone Settings."
                    }
                }
            }
            Text("The schedule changes immediately when you select a time zone. Reminders begin at 3:00 AM, 9:00 AM, 3:00 PM, and 9:00 PM in that zone. Accounts are staggered by five minutes.")
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
            LabeledContent("Analytics", value: "On-device only")
            LabeledContent("Advertising", value: "None")
            LabeledContent("Google authentication", value: "System sign-in")
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
                Text("Video status, daily assignments, account settings, copy-queue text, and audit history are stored in the app’s private SwiftData container.")
            } header: {
                TrackerSectionLabel(title: "On this iPhone")
            }
            Section {
                Text("Social Media Video Tracker reads selected folder metadata, video files, and the Copy Paste/Queue Sheet. The hidden JSON recovery backup includes tracker metadata and cached copy-queue text, but never video files or credentials.")
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
