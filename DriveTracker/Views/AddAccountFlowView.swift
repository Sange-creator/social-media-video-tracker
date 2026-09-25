import SwiftData
import SwiftUI

/// Unified, robust flow for connecting Google Drive folders to TikTok accounts.
/// Uses a single NavigationStack to prevent sheet dismissal/cancellation race conditions.
struct AddAccountFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var auth: GoogleAuthService

    var initialFolder: DriveFolderChoice?
    var initialLink: String?
    var onDismiss: (() -> Void)?

    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            if let initial = initialFolder {
                AddAccountSetupStep(
                    folder: initial,
                    originalLink: initialLink,
                    onSuccess: {
                        dismissFlow()
                    }
                )
            } else {
                AddAccountFolderStep(
                    onSelectFolder: { selectedFolder in
                        navigationPath.append(selectedFolder)
                    },
                    onCancel: {
                        dismissFlow()
                    }
                )
                .navigationDestination(for: DriveFolderChoice.self) { folder in
                    AddAccountSetupStep(
                        folder: folder,
                        originalLink: initialLink,
                        onSuccess: {
                            dismissFlow()
                        }
                    )
                }
            }
        }
    }

    private func dismissFlow() {
        onDismiss?()
        dismiss()
    }
}

// MARK: - Step 1: Folder Selection View

private struct AddAccountFolderStep: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var auth: GoogleAuthService

    let onSelectFolder: (DriveFolderChoice) -> Void
    let onCancel: () -> Void

    @State private var folders: [DriveFolderChoice] = []
    @State private var folderStack: [DriveFolderChoice] = []
    @State private var location: DriveFolderLocation = .myDrive
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var searchQuery = ""
    @State private var isSigningIn = false
    @State private var signInError: String?

    private var currentFolder: DriveFolderChoice? {
        folderStack.last
    }

    private var filteredFolders: [DriveFolderChoice] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return folders
        }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !auth.isSignedIn {
                googleSignInPrompt
            } else {
                folderBrowserContent
            }
        }
        .trackerScreen()
        .navigationTitle(currentFolder?.name ?? "Select Drive Folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                }
                .foregroundStyle(TrackerPalette.muted)
            }

            if !folderStack.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        navigateUp()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text(folderStack.count > 1 ? folderStack[folderStack.count - 2].name : "Back")
                                .lineLimit(1)
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(TrackerPalette.accent)
                    }
                }
            }
        }
        .task(id: auth.isSignedIn) {
            if auth.isSignedIn {
                await loadCurrentLevel()
            }
        }
    }

    // MARK: - Google Sign-In Prompt

    private var googleSignInPrompt: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(TrackerPalette.accent.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "folder.badge.person.crop")
                    .font(.system(size: 36))
                    .foregroundStyle(TrackerPalette.accent)
            }

            VStack(spacing: 8) {
                Text("Google Sign-In Required")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(TrackerPalette.textPrimary)

                Text("Sign in with Google to browse and choose your Drive folders for this account.")
                    .font(.footnote)
                    .foregroundStyle(TrackerPalette.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            if let signInError {
                Text(signInError)
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.danger)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
            }

            Button {
                isSigningIn = true
                signInError = nil
                Task {
                    do {
                        await state.signIn(context: context)
                        if !auth.isSignedIn {
                            signInError = "Sign-in was cancelled or could not be completed."
                        }
                    }
                    isSigningIn = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView()
                            .tint(Color(hex: "#090A0F"))
                    } else {
                        Image(systemName: "link")
                    }
                    Text(isSigningIn ? "Signing in…" : "Sign In with Google")
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(Color(hex: "#090A0F"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(TrackerPalette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(TrackerPressButtonStyle())
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .disabled(isSigningIn)

            Spacer()
        }
    }

    // MARK: - Main Browser Content

    private var folderBrowserContent: some View {
        VStack(spacing: 12) {
            // Location segmented picker
            Picker("Location", selection: $location) {
                ForEach(DriveFolderLocation.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .onChange(of: location) { _, _ in
                folderStack.removeAll()
                searchQuery = ""
                Task { await loadCurrentLevel() }
            }

            // Search filter bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)

                TextField("Filter folders…", text: $searchQuery)
                    .font(.subheadline)
                    .foregroundStyle(TrackerPalette.textPrimary)
                    .autocorrectionDisabled()

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(TrackerPalette.muted)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TrackerPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(TrackerPalette.line, lineWidth: 1)
            }
            .padding(.horizontal, 16)

            // Current folder selection banner (when inside a subfolder)
            if let currentFolder {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill.badge.plus")
                        .font(.title3)
                        .foregroundStyle(TrackerPalette.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current Folder")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(TrackerPalette.accent)
                        Text(currentFolder.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TrackerPalette.textPrimary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        onSelectFolder(currentFolder)
                    } label: {
                        Text("Use This Folder")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(hex: "#090A0F"))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(TrackerPalette.accent, in: Capsule())
                    }
                    .buttonStyle(TrackerPressButtonStyle())
                }
                .padding(12)
                .background(TrackerPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TrackerPalette.accent.opacity(0.3), lineWidth: 1)
                }
                .padding(.horizontal, 16)
            }

            // Folder list / status view
            if isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(TrackerPalette.accent)
                    Text("Loading folders from Google Drive…")
                        .font(.footnote)
                        .foregroundStyle(TrackerPalette.muted)
                }
                Spacer()
            } else if let loadError {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(TrackerPalette.warning)
                    Text("Unable to load folders")
                        .font(.headline)
                        .foregroundStyle(TrackerPalette.textPrimary)
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(TrackerPalette.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Try Again") {
                        Task { await loadCurrentLevel() }
                    }
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(TrackerPalette.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(TrackerPalette.accent.opacity(0.12), in: Capsule())
                }
                Spacer()
            } else if filteredFolders.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 36))
                        .foregroundStyle(TrackerPalette.muted)
                    Text(searchQuery.isEmpty ? "No folders found here" : "No folders match \"\(searchQuery)\"")
                        .font(.headline)
                        .foregroundStyle(TrackerPalette.textPrimary)
                    if let currentFolder {
                        Text("You can still choose \"\(currentFolder.name)\" using the button above.")
                            .font(.footnote)
                            .foregroundStyle(TrackerPalette.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
                Spacer()
            } else {
                List {
                    Section {
                        ForEach(filteredFolders) { folder in
                            FolderBrowserRow(
                                folder: folder,
                                onSelect: {
                                    onSelectFolder(folder)
                                },
                                onBrowse: {
                                    enterFolder(folder)
                                }
                            )
                        }
                    } header: {
                        Text(currentFolder == nil ? "Top-Level Folders" : "Subfolders")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(TrackerPalette.muted)
                    }
                }
                .trackerListStyle()
            }
        }
    }

    private func enterFolder(_ folder: DriveFolderChoice) {
        folderStack.append(folder)
        searchQuery = ""
        Task { await loadCurrentLevel() }
    }

    private func navigateUp() {
        guard !folderStack.isEmpty else { return }
        folderStack.removeLast()
        searchQuery = ""
        Task { await loadCurrentLevel() }
    }

    private func loadCurrentLevel() async {
        isLoading = true
        loadError = nil
        do {
            if let active = currentFolder {
                folders = try await state.driveFolders(in: active.id, resourceKey: active.resourceKey)
            } else {
                switch location {
                case .myDrive:
                    folders = try await state.driveFolders(in: "root", resourceKey: nil)
                case .shared:
                    folders = try await state.sharedDriveFolders()
                }
            }
        } catch {
            folders = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Folder Browser Row

private struct FolderBrowserRow: View {
    let folder: DriveFolderChoice
    let onSelect: () -> Void
    let onBrowse: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBrowse) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                        .foregroundStyle(TrackerPalette.accent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TrackerPalette.textPrimary)
                            .lineLimit(1)
                        Text("Tap to open subfolders")
                            .font(.caption2)
                            .foregroundStyle(TrackerPalette.muted)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TrackerPalette.muted)
                }
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 24)

            Button(action: onSelect) {
                Text("Select")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: "#090A0F"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(TrackerPalette.accent, in: Capsule())
            }
            .buttonStyle(TrackerPressButtonStyle())
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Step 2: Account Setup Step View

private struct AddAccountSetupStep: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @Query(sort: \TikTokAccount.sortOrder) private var accounts: [TikTokAccount]

    let folder: DriveFolderChoice
    let originalLink: String?
    let onSuccess: () -> Void

    @State private var selectedAccountID: UUID?
    @State private var accountName: String = ""
    @State private var folderName: String = ""
    @State private var dailyQuota: Int = 3
    @State private var draftIconSymbol: String = "sparkles"
    @State private var draftIconColor: String = "#4F46E5"
    @State private var draftTimeZoneID: String = ""
    @State private var draftSuggestionStrategy: String = "shuffle"
    @State private var draftAlbumName: String = ""
    @State private var isConnecting = false
    @State private var localError: String?

    private var selectedAccount: TikTokAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    var body: some View {
        Form {
            if let localError {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(TrackerPalette.danger)
                        Text(localError)
                            .font(.footnote)
                            .foregroundStyle(TrackerPalette.danger)
                    }
                }
            }

            Section {
                HStack(spacing: 14) {
                    AccountIdentityIcon(
                        symbol: draftIconSymbol,
                        colorHex: draftIconColor,
                        size: 58
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountName.isEmpty ? folder.name : accountName)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(TrackerPalette.textPrimary)
                            .lineLimit(1)
                        Label(folder.name, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(TrackerPalette.muted)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
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
                TrackerSectionLabel(title: "Account Details")
            } footer: {
                Text("If you choose an existing account, this folder replaces that account's Drive folder while keeping history.")
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

                Picker("Daily suggestion strategy", selection: $draftSuggestionStrategy) {
                    Text("Random shuffle").tag("shuffle")
                    Text("Newest uploads first").tag("newest")
                    Text("Oldest inventory first").tag("oldest")
                    Text("Alphabetical (A-Z)").tag("alphabetical")
                }

                TextField("Custom Photos album name (optional)", text: $draftAlbumName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                TrackerSectionLabel(title: "Schedule & Export")
            }

            Section {
                TextField("Folder name shown in the app", text: $folderName)
                LabeledContent("Drive Folder", value: folder.name)
                Text("ID: \(folder.id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(TrackerPalette.muted)
            } header: {
                TrackerSectionLabel(title: "Drive Folder Connection")
            } footer: {
                Text("Only this selected folder and its subfolders will be scanned and tracked.")
            }
        }
        .trackerListStyle()
        .navigationTitle("Configure Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    connectAccount()
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting {
                            ProgressView()
                                .tint(TrackerPalette.accent)
                                .scaleEffect(0.8)
                        }
                        Text(isConnecting ? "Connecting…" : "Connect")
                            .fontWeight(.bold)
                    }
                }
                .disabled(
                    accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    isConnecting || state.isWorking
                )
            }
        }
        .onAppear {
            if accountName.isEmpty {
                accountName = folder.name
            }
            if folderName.isEmpty {
                folderName = folder.name
            }
            let style = AccountIconCatalog.style(forName: accountName, fallbackID: selectedAccountID ?? UUID())
            draftIconSymbol = style.symbol
            draftIconColor = style.colorHex
        }
        .onChange(of: selectedAccountID) { _, _ in
            if let selectedAccount {
                accountName = selectedAccount.displayName
                folderName = selectedAccount.folderName.isEmpty ? folder.name : selectedAccount.folderName
                dailyQuota = selectedAccount.dailyQuota
                draftIconSymbol = selectedAccount.iconSymbol
                draftIconColor = selectedAccount.iconColorHex
                draftTimeZoneID = selectedAccount.targetTimeZoneID ?? ""
                draftSuggestionStrategy = selectedAccount.suggestionStrategy
                draftAlbumName = selectedAccount.customAlbumName ?? ""
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

    private func connectAccount() {
        guard !isConnecting else { return }
        isConnecting = true
        localError = nil

        let cleanAccountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFolderName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanAccountName.isEmpty, !cleanFolderName.isEmpty else {
            localError = "Please enter an account name and folder name."
            isConnecting = false
            return
        }

        Task {
            state.errorMessage = nil
            await state.associateFolder(
                folder,
                link: originalLink,
                accountID: selectedAccountID,
                accountName: cleanAccountName,
                folderName: cleanFolderName,
                dailyQuota: dailyQuota,
                iconSymbol: draftIconSymbol,
                iconColorHex: draftIconColor,
                targetTimeZoneID: draftTimeZoneID.isEmpty ? nil : draftTimeZoneID,
                suggestionStrategy: draftSuggestionStrategy,
                customAlbumName: draftAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftAlbumName.trimmingCharacters(in: .whitespacesAndNewlines),
                context: context
            )

            isConnecting = false

            if let error = state.errorMessage {
                localError = error
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                state.toastMessage = "Connected \(cleanAccountName) successfully!"
                onSuccess()
                // Trigger immediate sync in background
                Task {
                    await state.sync(context: context)
                }
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
