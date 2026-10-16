import SwiftUI
import SwiftData

struct UploadStreamSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]
    @State private var selections: [UUID: String] = [:]
    @State private var issue: String?

    private var configured: [TikTokAccount] { accounts.filter { $0.isConfigured } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose where each account belongs. Your videos, history and download progress stay with the account.")
                }
                Section("Accounts") {
                    ForEach(configured) { account in
                        Picker(account.displayName, selection: Binding(
                            get: { selections[account.id] ?? account.uploadPlatformRawValue ?? "" },
                            set: { selections[account.id] = $0 }
                        )) {
                            Text("Unassigned").tag("")
                            ForEach(UploadPlatform.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    }
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }
            .navigationTitle("Assign upload streams")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        for account in configured {
                            if let value = selections[account.id] {
                                account.uploadPlatformRawValue = value.isEmpty ? nil : value
                                account.updatedAt = .now
                            }
                        }
                        do {
                            try state.uploadStreamsChanged(context: context)
                            dismiss()
                        } catch { issue = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct UploadStreamScheduleView: View {
    let platform: UploadPlatform
    let accounts: [TikTokAccount]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @State private var zone = "America/New_York"
    @State private var hour1 = 9
    @State private var hour2 = 13
    @State private var hour3 = 20
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Apply a posting timezone and three daily slots to all \(accounts.count) \(platform.rawValue) accounts. You can adjust individual accounts later in Accounts.")
                }
                Section("Posting city / timezone") {
                    Picker("Timezone", selection: $zone) {
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { id in
                            Text(id.replacingOccurrences(of: "_", with: " ")).tag(id)
                        }
                    }
                    Text("Daylight saving changes are handled automatically.").font(.caption)
                }
                Section("Posting hours in selected timezone") {
                    Stepper("Slot 1: \(hour1):00", value: $hour1, in: 0...23)
                    Stepper("Slot 2: \(hour2):00", value: $hour2, in: 0...23)
                    Stepper("Slot 3: \(hour3):00", value: $hour3, in: 0...23)
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }
            .navigationTitle("\(platform.rawValue) schedule")
            .onAppear {
                if let account = accounts.first {
                    zone = account.targetTimeZoneID ?? state.reminderTimeZoneID
                    hour1 = account.preferredSlot1Hour; hour2 = account.preferredSlot2Hour; hour3 = account.preferredSlot3Hour
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        for account in accounts {
                            account.targetTimeZoneID = zone
                            account.preferredSlot1Hour = hour1; account.preferredSlot2Hour = hour2; account.preferredSlot3Hour = hour3
                            account.updatedAt = .now
                        }
                        do {
                            try state.uploadStreamsChanged(context: context)
                            dismiss()
                        } catch { issue = error.localizedDescription }
                    }.disabled(accounts.isEmpty)
                }
            }
        }
    }
}

struct AccountCaptionSettings: View {
    @Bindable var account: TikTokAccount
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    private var choices: [CaptionDocumentChoice] {
        guard let data = account.captionDocumentChoices?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CaptionDocumentChoice].self, from: data)) ?? []
    }
    var body: some View {
        Section("Titles & hashtags document") {
            if !choices.isEmpty {
                Picker("Source document", selection: Binding(
                    get: { account.captionDocumentID ?? "" },
                    set: { value in
                        account.captionDocumentID = value.isEmpty ? nil : value
                        account.captionDocumentText = nil
                        account.captionDocumentModifiedAt = nil
                        account.captionDocumentIssue = "Sync this folder to load the selected document."
                    }
                )) {
                    Text("Automatic (one document)").tag("")
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
            }
            Button("Refresh this folder", systemImage: "arrow.clockwise") {
                Task { await state.sync(context: context, folderIDs: [account.driveFolderID]) }
            }.disabled(state.isSyncing)
            if let name = account.captionDocumentName { LabeledContent("Cached source", value: name) }
            if let issue = account.captionDocumentIssue { Text(issue).foregroundStyle(.secondary) }
            Text("Use a Google Docs file inside this account folder. Format each entry as:\nVideo 001\nTitle: Your title\nHashtags: #tag #another\n\nName videos with one number, such as Video 001.mp4. Then sync this folder.")
                .font(.caption).textSelection(.enabled)
        }
    }
}
