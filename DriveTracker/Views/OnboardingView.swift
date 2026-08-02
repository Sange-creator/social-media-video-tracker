import SwiftData
import SwiftUI

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var auth: GoogleAuthService
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]
    @Query(sort: \DriveSource.createdAt) private var sources: [DriveSource]
    @State private var folderLink = ""
    @State private var showFolderBrowser = false
    @State private var pendingFolder: DriveFolderChoice?
    @State private var pendingFolderLink: String?
    @State private var isResolvingLink = false

    private var pendingAccounts: [TikTokAccount] {
        accounts.filter { !$0.isConfigured }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    masthead
                    setupProgress
                    rulesCard

                    if !auth.isConfigured {
                        configurationNotice
                    } else if !auth.isSignedIn {
                        connectGoogleCard
                    } else {
                        connectedGoogleCard
                        sourceSetup
                        accountSetup
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 48)
            }
            .trackerScreen()
            .toolbar(.hidden, for: .navigationBar)
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
        .onAppear {
            if folderLink.isEmpty { folderLink = state.rootLink }
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(TrackerPalette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Drive · Build \(appBuildNumber)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TrackerPalette.accent)
                    Text("Social Video Tracker")
                        .font(.headline.weight(.bold))
                }
            }

            Text("Connect. Map. Track.")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.8)

            Text("You choose each Drive folder and account. Suggested videos stay unchanged until you replace them, and a successful download automatically marks the item completed.")
                .font(.subheadline)
                .foregroundStyle(TrackerPalette.muted)
                .lineSpacing(3)
        }
    }

    private var appBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var setupProgress: some View {
        HStack(spacing: 8) {
            SetupBadge(number: 1, title: "Google", complete: auth.isSignedIn)
            SetupBadge(number: 2, title: "Folder", complete: !sources.isEmpty)
            SetupBadge(
                number: 3,
                title: "Accounts",
                complete: accounts.contains { $0.isConfigured }
            )
        }
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrackerSectionLabel(title: "How tracking works")
            RuleRow(
                icon: "sparkles",
                title: "Suggestions",
                detail: "Only unused videos are suggested. Completed files are never suggested again."
            )
            RuleRow(
                icon: "magnifyingglass",
                title: "Manual choice",
                detail: "Search the Library, select any unused file, and add it to today’s queue."
            )
            RuleRow(
                icon: "icloud.slash",
                title: "Deleted files",
                detail: "Drive deletions become Missing. Photos deletions can be verified later. Tracking history is never erased automatically."
            )
        }
        .trackerCard()
    }

    private var configurationNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("GOOGLE LOGIN SETUP INCOMPLETE", systemImage: "key.horizontal.fill")
                .font(.caption.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(TrackerPalette.warning)
            Text("This build still needs its Google iOS OAuth client ID. Until that is installed, a real Google login cannot open.")
                .font(.subheadline)
            Text("No sample accounts or mock videos are used. Finish Google Cloud setup, then install the configured build.")
                .font(.footnote)
                .foregroundStyle(TrackerPalette.muted)
        }
        .trackerCard()
    }

    private var connectGoogleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(title: "Step 1 · Google account")
            Text("Sign in with the Gmail account that can view the Drive folders. Social Media Video Tracker requests read-only file access and hidden backup storage.")
                .font(.subheadline)
                .foregroundStyle(TrackerPalette.muted)

            Button {
                Task { await state.signIn(context: context) }
            } label: {
                Label("CONNECT GOOGLE", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .primary))
            .disabled(state.isWorking)
        }
        .trackerCard()
    }

    private var connectedGoogleCard: some View {
        HStack(spacing: 11) {
            Circle().fill(TrackerPalette.success).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("GOOGLE CONNECTED")
                    .font(.caption2.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(TrackerPalette.success)
                Text(auth.email ?? "Google account")
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Button("Switch") {
                Task { await state.switchGoogleAccount(context: context) }
            }
            .font(.caption.weight(.bold))
        }
        .trackerCard()
    }

    private var sourceSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            TrackerSectionLabel(
                title: "Step 2 · Drive sources",
                trailing: "\(sources.count) connected"
            )

            Text("Choose only the folder you want to track. The app will ask which account it belongs to; it never imports every folder in your Drive.")
                .font(.subheadline)
                .foregroundStyle(TrackerPalette.muted)

            Button {
                showFolderBrowser = true
            } label: {
                Label("BROWSE DRIVE & SHARED FOLDERS", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .primary))

            TextField("Or paste a Drive folder link", text: $folderLink, axis: .vertical)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2 ... 3)
                .font(.subheadline.monospaced())
                .padding(12)
                .background(TrackerPalette.canvas)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(TrackerPalette.line, lineWidth: 1)
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
                Label(
                    isResolvingLink ? "CHECKING FOLDER…" : "CONTINUE AND CHOOSE ACCOUNT",
                    systemImage: "link.badge.plus"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            .disabled(
                folderLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                state.isWorking || isResolvingLink
            )

            ForEach(sources) { source in
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(TrackerPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(source.googleEmail)
                            .font(.caption)
                            .foregroundStyle(TrackerPalette.muted)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TrackerPalette.success)
                }
                .padding(.top, 4)
            }
        }
        .trackerCard()
    }

    @ViewBuilder
    private var accountSetup: some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                TrackerSectionLabel(
                    title: "Step 3 · Map accounts",
                    trailing: "\(pendingAccounts.count) remaining"
                )
                Text("Each account is created only after you choose its exact Drive folder, name the account, and set its daily target.")
                    .font(.subheadline)
                    .foregroundStyle(TrackerPalette.muted)

                ForEach(accounts) { account in
                    NavigationLink {
                        AccountEditorView(account: account, isSetupFlow: true)
                    } label: {
                        HStack(spacing: 11) {
                            AccountIdentityIcon(
                                symbol: account.iconSymbol,
                                colorHex: account.iconColorHex,
                                size: 44
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.folderName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text(account.isConfigured ? account.displayName : "Needs account setup")
                                    .font(.caption)
                                    .foregroundStyle(TrackerPalette.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(TrackerPalette.muted)
                        }
                        .padding(12)
                        .background(TrackerPalette.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .trackerCard()
        }
    }

}

private struct SetupBadge: View {
    let number: Int
    let title: String
    let complete: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
        }
        .foregroundStyle(complete ? TrackerPalette.success : TrackerPalette.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(TrackerPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct RuleRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(TrackerPalette.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DriveFolderBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @State private var folders: [DriveFolderChoice] = []
    @State private var path: [DriveFolderChoice] = []
    @State private var location: DriveFolderLocation = .myDrive
    @State private var isLoading = true
    @State private var loadError: String?
    let onSelect: (DriveFolderChoice) -> Void

    init(onSelect: @escaping (DriveFolderChoice) -> Void) {
        self.onSelect = onSelect
    }

    private var currentFolder: DriveFolderChoice? { path.last }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Location", selection: $location) {
                        ForEach(DriveFolderLocation.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Shared folders appear only when the connected Gmail has access.")
                }

                if let currentFolder {
                    Section {
                        Button {
                            dismiss()
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(250))
                                onSelect(currentFolder)
                            }
                        } label: {
                            Label(
                                "Choose this folder",
                                systemImage: "checkmark.circle.fill"
                            )
                        }
                        .disabled(state.isWorking)
                    } footer: {
                        Text("Only this folder and its nested folders will be tracked. You will choose the account on the next screen.")
                    }
                } else {
                    Section {
                        Label(
                            "Open a specific folder before continuing",
                            systemImage: "hand.tap"
                        )
                        .foregroundStyle(TrackerPalette.muted)
                    } footer: {
                        Text("The app does not allow selecting all of My Drive.")
                    }
                }

                Section("Folders") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading folders…")
                        }
                    } else if let loadError {
                        Text(loadError).foregroundStyle(TrackerPalette.danger)
                    } else if folders.isEmpty {
                        Text("No subfolders here.")
                            .foregroundStyle(TrackerPalette.muted)
                    } else {
                        ForEach(folders) { folder in
                            Button {
                                path.append(folder)
                                Task {
                                    await loadChildren(
                                        folderID: folder.id,
                                        resourceKey: folder.resourceKey
                                    )
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(TrackerPalette.accent)
                                    Text(folder.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(TrackerPalette.muted)
                                }
                            }
                        }
                    }
                }
            }
            .trackerListStyle()
            .navigationTitle(currentFolder?.name ?? location.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if path.isEmpty {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button {
                            path.removeLast()
                            let parent = path.last
                            Task {
                                if let parent {
                                    await loadChildren(
                                        folderID: parent.id,
                                        resourceKey: parent.resourceKey
                                    )
                                } else {
                                    await loadRoot()
                                }
                            }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
            }
            .task { await loadRoot() }
            .onChange(of: location) { _, _ in
                path = []
                Task { await loadRoot() }
            }
        }
    }

    private func loadRoot() async {
        isLoading = true
        loadError = nil
        do {
            switch location {
            case .myDrive:
                folders = try await state.driveFolders(in: "root", resourceKey: nil)
            case .shared:
                folders = try await state.sharedDriveFolders()
            }
        } catch {
            folders = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadChildren(folderID: String, resourceKey: String?) async {
        isLoading = true
        loadError = nil
        do {
            folders = try await state.driveFolders(in: folderID, resourceKey: resourceKey)
        } catch {
            folders = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

struct FolderAssociationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]

    let folder: DriveFolderChoice
    let originalLink: String?

    @State private var selectedAccountID: UUID?
    @State private var accountName = ""
    @State private var folderName = ""
    @State private var dailyQuota = 3
    @State private var draftIconSymbol = "sparkles"
    @State private var draftIconColor = "#4F46E5"

    private var selectedAccount: TikTokAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AccountIdentityIcon(
                            symbol: draftIconSymbol,
                            colorHex: draftIconColor,
                            size: 58
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Set up this account")
                                .font(.headline.weight(.bold))
                            Text("Choose its name, folder label, and daily number of suggestions.")
                                .font(.caption)
                                .foregroundStyle(TrackerPalette.muted)
                        }
                    }
                    .padding(.vertical, 5)
                }

                Section {
                    Picker("Associate with", selection: $selectedAccountID) {
                        Text("Create a new account").tag(nil as UUID?)
                        ForEach(accounts) { account in
                            Text(account.displayName).tag(account.id as UUID?)
                        }
                    }

                    TextField("Account name or @handle", text: $accountName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Stepper(value: $dailyQuota, in: 1 ... 30) {
                        LabeledContent("Videos per day", value: "\(dailyQuota)")
                    }
                } header: {
                    Text("Managed account")
                } footer: {
                    Text("If you choose an existing account, this folder replaces that account’s current Drive folder. Previous tracking history is retained.")
                }

                Section {
                    TextField("Folder name shown in the app", text: $folderName)
                    LabeledContent("Selected Drive folder", value: folder.name)
                    Text(folder.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(TrackerPalette.muted)
                } header: {
                    Text("Tracked folder")
                } footer: {
                    Text("This folder may contain two, ten, or more nested folders. They all remain inside this one account, and every video will show its full folder path.")
                }

                Section {
                    Label("Only this selected folder is scanned", systemImage: "checkmark.shield.fill")
                    Label("Other Google Drive folders are ignored", systemImage: "folder.badge.minus")
                    Label("\(dailyQuota) unused videos will be suggested each day", systemImage: "sparkles")
                } header: {
                    Text("What will happen")
                }
            }
            .trackerListStyle()
            .navigationTitle("Connect Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        Task {
                            state.errorMessage = nil
                            await state.associateFolder(
                                folder,
                                link: originalLink,
                                accountID: selectedAccountID,
                                accountName: accountName,
                                folderName: folderName,
                                dailyQuota: dailyQuota,
                                iconSymbol: draftIconSymbol,
                                iconColorHex: draftIconColor,
                                context: context
                            )
                            if state.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(
                        accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        state.isWorking
                    )
                }
            }
            .onAppear {
                folderName = folder.name
                let style = AccountIconCatalog.style(for: accounts.count)
                draftIconSymbol = style.symbol
                draftIconColor = style.colorHex
            }
            .onChange(of: selectedAccountID) { _, _ in
                if let selectedAccount {
                    accountName = selectedAccount.displayName
                    dailyQuota = selectedAccount.dailyQuota
                    draftIconSymbol = selectedAccount.iconSymbol
                    draftIconColor = selectedAccount.iconColorHex
                } else {
                    let style = AccountIconCatalog.style(for: accounts.count)
                    draftIconSymbol = style.symbol
                    draftIconColor = style.colorHex
                }
            }
            .onChange(of: accountName) { _, newValue in
                guard selectedAccountID == nil else { return }
                let style = AccountIconCatalog.style(forName: newValue)
                draftIconSymbol = style.symbol
                draftIconColor = style.colorHex
            }
        }
    }
}

private enum DriveFolderLocation: String, CaseIterable, Identifiable {
    case myDrive
    case shared

    var id: String { rawValue }
    var title: String {
        switch self {
        case .myDrive: "My Drive"
        case .shared: "Shared with me"
        }
    }
}
