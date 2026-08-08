import SwiftData
import SwiftUI

struct AccountsView: View {
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]
    @State private var showFolderBrowser = false
    @State private var pendingFolder: DriveFolderChoice?

    private var activeCount: Int {
        accounts.filter { $0.isConfigured && !$0.isPaused && !$0.isMissingFromDrive }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    HStack {
                        TrackerSectionLabel(
                            title: "Your accounts",
                            trailing: "\(activeCount) active / \(accounts.count) total"
                        )
                    }
                    .padding(.bottom, 4)

                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        NavigationLink {
                            AccountEditorView(account: account)
                        } label: {
                            AccountRow(account: account, sequence: index + 1)
                        }
                        .buttonStyle(TrackerPressButtonStyle())
                    }

                    if accounts.isEmpty {
                        ContentUnavailableView(
                            "No accounts yet",
                            systemImage: "person.crop.circle.badge.plus",
                            description: Text("Connect a Drive folder in Settings, then give the account a name and daily target.")
                        )
                        .foregroundStyle(TrackerPalette.muted)
                        .padding(.top, 44)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .trackerScreen()
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFolderBrowser = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add account")
                }
            }
            .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showFolderBrowser) {
            DriveFolderBrowserView { folder in
                pendingFolder = folder
            }
        }
        .sheet(item: $pendingFolder) { folder in
            FolderAssociationView(folder: folder, originalLink: nil)
        }
    }
}

private struct AccountRow: View {
    let account: TikTokAccount
    let sequence: Int

    private var stateLabel: String {
        if !account.isConfigured { return "Set up" }
        if account.isMissingFromDrive { return "Missing" }
        if account.isPaused { return "Paused" }
        return "Active"
    }

    private var stateColor: Color {
        if !account.isConfigured { return TrackerPalette.warning }
        if account.isMissingFromDrive { return TrackerPalette.danger }
        if account.isPaused { return TrackerPalette.warning }
        return TrackerPalette.success
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                AccountIdentityIcon(
                    symbol: account.iconSymbol,
                    colorHex: account.iconColorHex,
                    size: 48
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(account.isConfigured ? account.displayName : "Configure account")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(account.folderName)
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 6, height: 6)
                    Text(stateLabel)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(stateColor)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TrackerPalette.muted)
            }

            Divider().overlay(TrackerPalette.line)

            HStack {
                TrackerMetric(value: "\(account.dailyQuota)", label: "Daily quota")
                Spacer()
                TrackerMetric(value: "\(account.availableCount)", label: "Unused")
                Spacer()
                TrackerMetric(
                    value: "\(account.uploadedCount)",
                    label: "Completed",
                    tint: TrackerPalette.success
                )
            }
        }
        .trackerCard()
    }
}

struct AccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @Bindable var account: TikTokAccount
    var isSetupFlow = false
    @State private var draftHandle = ""
    @State private var draftQuota = 3
    @State private var draftPaused = false
    @State private var draftIconSymbol = "sparkles"
    @State private var draftIconColor = "#4F46E5"
    @State private var confirmDelete = false

    private var trackedFolderPaths: [String] {
        Array(Set(account.videos.map(\.folderPath).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AccountIdentityIcon(
                        symbol: draftIconSymbol,
                        colorHex: draftIconColor,
                        size: 58
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draftHandle.isEmpty ? "New account" : draftHandle)
                            .font(.headline.weight(.bold))
                        Label(account.folderName, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(TrackerPalette.muted)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 5)
            }

            Section {
                TextField("Account name or @handle", text: $draftHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.weight(.semibold))

                Stepper(value: $draftQuota, in: 1 ... 30) {
                    LabeledContent("Daily target") {
                        Text("\(draftQuota)")
                            .font(.body.monospacedDigit().weight(.bold))
                    }
                }

                Toggle("Pause account", isOn: $draftPaused)
                    .tint(TrackerPalette.warning)

                Text("The app will not activate this folder or create suggestions until you save an account name and daily target.")
                    .font(.footnote)
                    .foregroundStyle(TrackerPalette.muted)
            } header: {
                TrackerSectionLabel(title: "Managed account")
            }

            Section {
                LabeledContent("Folder", value: account.folderName)
                if let email = account.googleEmail {
                    LabeledContent("Google account", value: email)
                }
                LabeledContent("Folder ID") {
                    Text(account.driveFolderID)
                        .font(.caption.monospaced())
                        .foregroundStyle(TrackerPalette.muted)
                        .lineLimit(1)
                }
                if account.isMissingFromDrive {
                    Label(
                        "Folder not found during the last complete sync.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(TrackerPalette.danger)
                }
                LabeledContent("Folders containing videos", value: "\(trackedFolderPaths.count)")
                if trackedFolderPaths.count > 1 {
                    Text("This account includes \(trackedFolderPaths.count) folders. Every video keeps its own folder path.")
                        .font(.footnote)
                        .foregroundStyle(TrackerPalette.muted)
                }
                ForEach(trackedFolderPaths, id: \.self) { path in
                    NavigationLink {
                        AccountFolderVideosView(account: account, folderPath: path)
                    } label: {
                        Label(path, systemImage: "folder")
                            .font(.caption)
                    }
                }
            } header: {
                TrackerSectionLabel(title: "Google Drive source")
            }

            Section {
                LabeledContent("Unused", value: "\(account.availableCount)")
                LabeledContent("Active queue", value: "\(account.outstandingCount)")
                LabeledContent("Completed", value: "\(account.uploadedCount)")
                LabeledContent("Missing from Drive", value: "\(account.missingCount)")
                LabeledContent("Total files", value: "\(account.videos.count)")
            } header: {
                TrackerSectionLabel(title: "Account metrics")
            }

            Section {
                Button("Delete account from tracker", role: .destructive) {
                    confirmDelete = true
                }
                .font(.body.weight(.semibold))
            } footer: {
                Text("This removes the account, its suggestions, and local tracking history. It never deletes folders or videos from Google Drive.")
            }
        }
        .trackerListStyle()
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(draftHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            draftHandle = account.displayName
            draftQuota = account.dailyQuota
            draftPaused = account.isPaused
            draftIconSymbol = account.iconSymbol
            draftIconColor = account.iconColorHex
        }
        .onChange(of: draftHandle) { _, newValue in
            let style = AccountIconCatalog.style(forName: newValue, fallbackID: account.id)
            draftIconSymbol = style.symbol
            draftIconColor = style.colorHex
        }
        .confirmationDialog(
            "Delete \(account.displayName) from the tracker?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                state.deleteAccount(account, context: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Google Drive files will not be changed.")
        }
    }

    private func save() {
        account.displayName = draftHandle
        account.dailyQuota = draftQuota
        account.isPaused = draftPaused
        let style = AccountIconCatalog.style(forName: draftHandle, fallbackID: account.id)
        account.iconSymbol = style.symbol
        account.iconColorHex = style.colorHex
        state.accountChanged(account, context: context)
        if account.isConfigured, isSetupFlow {
            dismiss()
        }
    }
}

private struct AccountFolderVideosView: View {
    let account: TikTokAccount
    let folderPath: String

    private var videos: [VideoAsset] {
        account.videos
            .filter { $0.folderPath == folderPath }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Account", value: account.displayName)
                LabeledContent("Folder", value: folderPath)
                LabeledContent("Videos", value: "\(videos.count)")
            }

            Section("Videos in this folder") {
                ForEach(videos) { video in
                    NavigationLink {
                        VideoDetailView(video: video)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(video.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            HStack {
                                StatusPill(status: video.status)
                                if video.isMissingFromDrive {
                                    Text("Missing from Drive")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(TrackerPalette.danger)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .trackerListStyle()
        .navigationTitle((folderPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TrackerPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}
