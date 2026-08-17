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
                    customTopHeader

                    HStack {
                        TrackerSectionLabel(
                            title: "Your accounts",
                            trailing: "\(activeCount) active / \(accounts.count) total"
                        )
                    }
                    .padding(.top, 4)
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
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
            .trackerScreen()
            .toolbar(.hidden, for: .navigationBar)
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

    private var customTopHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ACCOUNTS")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(TrackerPalette.textPrimary)

                Text("\(accounts.filter { $0.isConfigured }.count) Active Profiles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TrackerPalette.muted)
            }

            Spacer()

            Button {
                showFolderBrowser = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Add")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Color(hex: "#090A0F"))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(TrackerPalette.accent, in: Capsule())
            }
            .buttonStyle(TrackerPressButtonStyle())
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
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

    private var completedToday: Int {
        account.videos.filter { video in
            guard let uploadedAt = video.uploadedAt else { return false }
            return DayKey.isToday(uploadedAt)
        }.count
    }

    private var quotaProgress: Double {
        account.dailyQuota > 0 ? Double(completedToday) / Double(account.dailyQuota) : 0
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
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Text(account.folderName)
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.muted)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: stateColor.opacity(0.6), radius: 3)
                    Text(stateLabel)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(stateColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(stateColor.opacity(0.12), in: Capsule())

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TrackerPalette.muted)
            }

            // Quota progress bar
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Today's Pace")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(TrackerPalette.muted)
                    Spacer()
                    Text("\(completedToday) of \(account.dailyQuota) done")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(completedToday >= account.dailyQuota ? TrackerPalette.success : TrackerPalette.accent)
                }

                ProgressView(value: min(max(quotaProgress, 0), 1))
                    .tint(completedToday >= account.dailyQuota ? TrackerPalette.success : TrackerPalette.accent)
                    .background(TrackerPalette.raised, in: Capsule())
                    .frame(height: 5)
            }

            Divider().overlay(TrackerPalette.line)

            HStack {
                TrackerMetric(value: "\(account.dailyQuota)", label: "Daily quota")
                Spacer()
                TrackerMetric(value: "\(account.availableCount)", label: "Unused", tint: TrackerPalette.accent)
                Spacer()
                TrackerMetric(
                    value: "\(account.uploadedCount)",
                    label: "Completed",
                    tint: TrackerPalette.success
                )
            }
        }
        .trackerCard(padding: 16)
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
                Picker("Target time zone", selection: $draftTimeZoneID) {
                    Text("App default (\(state.reminderTimeZoneID.split(separator: "/").last ?? "ET"))").tag("")
                    ForEach(USReminderTimeZone.allCases) { zone in
                        Text("\(zone.title) (\(zone.shortTitle))").tag(zone.rawValue)
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
                state.deleteAccount(account, context: context)
                dismiss()
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
        account.displayName = draftHandle
        account.dailyQuota = draftQuota
        account.isPaused = draftPaused
        let style = AccountIconCatalog.style(forName: draftHandle, fallbackID: account.id)
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
