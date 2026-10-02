import SwiftData
import SwiftUI

struct AccountsView: View {
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]
    @State private var showAddAccountFlow = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(accounts.filter { $0.modelContext != nil && !$0.isDeleted }) { account in
                    NavigationLink {
                        AccountEditorView(account: account)
                    } label: {
                        HStack(spacing: 12) {
                            AccountIdentityIcon(symbol: account.iconSymbol, colorHex: account.iconColorHex, size: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.displayName).font(.headline)
                                Text("\(account.dailyQuota) videos daily · \(account.isPaused ? "Paused" : "Active")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }
                }
                if accounts.isEmpty {
                    ContentUnavailableView("No accounts yet", systemImage: "person.crop.circle.badge.plus",
                        description: Text("Connect a Drive folder to create an account."))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(TrackerPalette.canvas)
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add account", systemImage: "plus") { showAddAccountFlow = true }
                }
            }
        }
        .sheet(isPresented: $showAddAccountFlow) { AddAccountFlowView() }
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
    @State private var draftTimeZoneID: String = ""
    @State private var draftSlot1Hour: Int = 9
    @State private var draftSlot2Hour: Int = 13
    @State private var draftSlot3Hour: Int = 20
    @State private var draftRemindersEnabled: Bool = true
    @State private var draftAlbumName: String = ""
    @State private var draftSuggestionStrategy: String = "shuffle"
    @State private var draftAutoComplete: Bool = true
    @State private var draftStrictChecksum: Bool = true
    @State private var confirmDelete = false
    @State private var isDeleting = false

    private var trackedFolderPaths: [String] {
        guard !isDeleting else { return [] }
        return Array(Set(account.videos.map(\.folderPath).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        Form {
            if isDeleting {
                Section {
                    Text("Removing account…")
                        .foregroundStyle(TrackerPalette.muted)
                }
            } else {
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
                Picker("Target time zone", selection: $draftTimeZoneID) {
                    Text("App default (\(state.reminderTimeZoneID.split(separator: "/").last ?? "ET"))").tag("")
                    ForEach(CreatorReminderTimeZone.groupedByRegion) { group in
                        Section(header: Text("\(group.flag) \(group.name)")) {
                            ForEach(group.zones) { zone in
                                Text("\(zone.flag) \(zone.title) (\(zone.shortTitle))").tag(zone.rawValue)
                            }
                        }
                    }
                }

                Stepper(value: $draftSlot1Hour, in: 0 ... 23) {
                    LabeledContent("Posting slot 1") {
                        Text(formatHour(draftSlot1Hour))
                            .font(.body.monospacedDigit().weight(.bold))
                    }
                }

                Stepper(value: $draftSlot2Hour, in: 0 ... 23) {
                    LabeledContent("Posting slot 2") {
                        Text(formatHour(draftSlot2Hour))
                            .font(.body.monospacedDigit().weight(.bold))
                    }
                }

                Stepper(value: $draftSlot3Hour, in: 0 ... 23) {
                    LabeledContent("Posting slot 3") {
                        Text(formatHour(draftSlot3Hour))
                            .font(.body.monospacedDigit().weight(.bold))
                    }
                }

                Toggle("Account reminders", isOn: $draftRemindersEnabled)
                    .tint(TrackerPalette.accent)
            } header: {
                TrackerSectionLabel(title: "Time & Schedule settings")
            } footer: {
                Text("Controls the daily suggestion timeline and reminder windows for this specific account.")
            }

            Section {
                TextField("Custom Photos album name", text: $draftAlbumName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("Daily suggestion strategy", selection: $draftSuggestionStrategy) {
                    Text("Random shuffle").tag("shuffle")
                    Text("Newest uploads first").tag("newest")
                    Text("Oldest inventory first").tag("oldest")
                    Text("Alphabetical (A-Z)").tag("alphabetical")
                }

                Toggle("Auto-mark completed on download", isOn: $draftAutoComplete)
                    .tint(TrackerPalette.success)

                Toggle("Verify MD5 checksum", isOn: $draftStrictChecksum)
                    .tint(TrackerPalette.accent)
            } header: {
                TrackerSectionLabel(title: "Uploading & media settings")
            } footer: {
                Text("Configure how videos from this account are saved to Apple Photos and picked from Google Drive.")
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
        }
        .trackerListStyle()
        .navigationTitle(draftHandle.isEmpty ? account.displayName : draftHandle)
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
            draftTimeZoneID = account.targetTimeZoneID ?? ""
            draftSlot1Hour = account.preferredSlot1Hour
            draftSlot2Hour = account.preferredSlot2Hour
            draftSlot3Hour = account.preferredSlot3Hour
            draftRemindersEnabled = account.remindersEnabled
            draftAlbumName = account.customAlbumName ?? ""
            draftSuggestionStrategy = account.suggestionStrategy
            draftAutoComplete = account.autoCompleteOnDownload
            draftStrictChecksum = account.strictChecksum
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
                let targetID = account.id
                isDeleting = true
                dismiss()
                Task { @MainActor in
                    state.deleteAccount(accountID: targetID, context: context)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Google Drive files will not be changed.")
        }
    }

    private func formatHour(_ hour: Int) -> String {
        let period = hour >= 12 ? "PM" : "AM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return "\(displayHour):00 \(period)"
    }

    private func save() {
        let cleanName = draftHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        account.displayName = cleanName
        account.dailyQuota = draftQuota
        account.isPaused = draftPaused
        let style = AccountIconCatalog.style(forName: cleanName, fallbackID: account.id)
        account.iconSymbol = style.symbol
        account.iconColorHex = style.colorHex
        account.targetTimeZoneID = draftTimeZoneID.isEmpty ? nil : draftTimeZoneID
        account.preferredSlot1Hour = draftSlot1Hour
        account.preferredSlot2Hour = draftSlot2Hour
        account.preferredSlot3Hour = draftSlot3Hour
        account.remindersEnabled = draftRemindersEnabled
        account.customAlbumName = draftAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        account.suggestionStrategy = draftSuggestionStrategy
        account.autoCompleteOnDownload = draftAutoComplete
        account.strictChecksum = draftStrictChecksum

        state.accountChanged(account, context: context)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        state.toastMessage = "Saved \(cleanName)"
        dismiss()
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
