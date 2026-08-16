import SwiftData
import SwiftUI
import UIKit

enum CopyQueueFilter: String, CaseIterable, Identifiable {
    case uncopied
    case copied
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncopied: "Uncopied"
        case .copied: "Copied"
        case .all: "All"
        }
    }
}

struct CopyQueueContent: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @Query private var allEntries: [CopyEntry]
    @Binding var search: String
    @State private var filter: CopyQueueFilter = .uncopied

    private var activeEntries: [CopyEntry] {
        allEntries.filter {
            !$0.isMissingFromDrive &&
            $0.googleUserID == state.auth.userID
        }
    }

    private var filteredEntries: [CopyEntry] {
        activeEntries
            .filter { entry in
                let matchesFilter: Bool
                switch filter {
                case .uncopied: matchesFilter = entry.copiedAt == nil
                case .copied: matchesFilter = entry.copiedAt != nil
                case .all: matchesFilter = true
                }
                let matchesSearch = search.isEmpty ||
                    entry.content.localizedCaseInsensitiveContains(search)
                return matchesFilter && matchesSearch
            }
            .sorted(by: Self.sortEntries)
    }

    private var copiedToday: Int {
        activeEntries.filter {
            guard let copiedAt = $0.copiedAt else { return false }
            return Calendar.autoupdatingCurrent.isDateInToday(copiedAt)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            overview

            if let issue = state.globalCopyQueueIssue {
                CopyQueueSetupCard(message: issue)
            }

            HStack {
                TrackerSectionLabel(
                    title: "Copy queue",
                    trailing: "\(filteredEntries.count) entries"
                )
                Spacer()
                if let date = state.globalCopyQueueLastSyncedAt {
                    Text("Updated \(date, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(TrackerPalette.muted)
                }
            }

            Picker("Queue filter", selection: $filter) {
                ForEach(CopyQueueFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    filter == .uncopied ? "No uncopied text" : "No matching text",
                    systemImage: "text.badge.checkmark",
                    description: Text(emptyDescription)
                )
                .foregroundStyle(TrackerPalette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(filteredEntries) { entry in
                    CopyEntryCard(entry: entry)
                }
            }
        }
        .task {
            await state.syncGlobalCopyQueue(
                context: context,
                announceErrors: false
            )
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await state.syncGlobalCopyQueue(
                    context: context,
                    announceErrors: false
                )
            }
        }
    }

    private var overview: some View {
        HStack {
            TrackerMetric(
                value: "\(activeEntries.filter { $0.copiedAt == nil }.count)",
                label: "Uncopied",
                tint: TrackerPalette.warning
            )
            Spacer()
            TrackerMetric(
                value: "\(copiedToday)",
                label: "Copied today",
                tint: TrackerPalette.accent
            )
            Spacer()
            TrackerMetric(
                value: "\(activeEntries.filter { $0.copiedAt != nil }.count)",
                label: "Copied total",
                tint: TrackerPalette.success
            )
        }
        .trackerCard()
    }

    private var emptyDescription: String {
        if state.globalCopyQueueIssue != nil {
            return "Finish the Drive setup shown above, then refresh."
        }
        if activeEntries.isEmpty {
            return "Paste new content into the next empty row of the Queue sheet."
        }
        return "Change the filter or search."
    }

    static func sortEntries(_ left: CopyEntry, _ right: CopyEntry) -> Bool {
        if (left.copiedAt == nil) != (right.copiedAt == nil) {
            return left.copiedAt == nil
        }
        if left.copiedAt == nil {
            return left.sourceRow > right.sourceRow
        }
        if left.copiedAt != right.copiedAt {
            return (left.copiedAt ?? .distantPast) > (right.copiedAt ?? .distantPast)
        }
        return left.sourceRow > right.sourceRow
    }
}

struct CopyEntryCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let entry: CopyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(
                    entry.copiedAt == nil ? "Ready to copy" : "Copied",
                    systemImage: entry.copiedAt == nil
                        ? "doc.on.clipboard"
                        : "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    entry.copiedAt == nil ? TrackerPalette.warning : TrackerPalette.success
                )
                Spacer()
                Text("Row \(entry.sourceRow)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TrackerPalette.muted)
            }

            Text(entry.content)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let copiedAt = entry.copiedAt {
                Text("Copied \(copiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
            }

            HStack(spacing: 10) {
                Button {
                    state.copyToClipboard(entry, context: context)
                } label: {
                    Label(
                        entry.copiedAt == nil ? "Copy" : "Copy Again",
                        systemImage: "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))

                if entry.copiedAt != nil {
                    Button {
                        state.markCopyEntryUncopied(entry, context: context)
                    } label: {
                        Label("Uncopy", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
                }
            }
        }
        .trackerCard()
    }
}

struct CopyQueueSetupCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("One-time Drive setup", systemImage: "folder.badge.gearshape")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TrackerPalette.warning)
            Text(message)
                .font(.subheadline.weight(.semibold))
            Text("On Today, paste the direct Google Sheet link and connect it once. Put Content in A1, then paste each new title and hashtag block into the next empty row in column A.")
                .font(.caption)
                .foregroundStyle(TrackerPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .trackerCard()
    }
}

struct GlobalCopyQueueCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    @Query private var allEntries: [CopyEntry]
    @State private var showQueue = false
    @State private var search = ""
    @State private var isEditingLink = false
    @State private var isConnecting = false
    @State private var queueLinkDraft = ""
    @FocusState private var isQueueLinkFocused: Bool

    private var nextEntry: CopyEntry? {
        activeEntries
            .filter { $0.copiedAt == nil }
            .max { $0.sourceRow < $1.sourceRow }
    }

    private var activeEntries: [CopyEntry] {
        allEntries.filter {
            !$0.isMissingFromDrive &&
            $0.googleUserID == state.auth.userID
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            TrackerSectionLabel(
                title: "Global copy queue",
                trailing: "\(activeEntries.filter { $0.copiedAt == nil }.count) uncopied"
            )

            if !state.hasGlobalCopyQueueSheet && !isEditingLink {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.badge.plus")
                        .font(.title3)
                        .foregroundStyle(TrackerPalette.accent)
                        .frame(width: 36, height: 36)
                        .background(TrackerPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect 1-Tap Captions Sheet")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TrackerPalette.textPrimary)
                        Text("Auto-fill titles & tags across all accounts")
                            .font(.caption2)
                            .foregroundStyle(TrackerPalette.muted)
                    }

                    Spacer()

                    Button("Link") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditingLink = true
                        }
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: "#090A0F"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(TrackerPalette.accent)
                    .clipShape(Capsule())
                    .buttonStyle(TrackerPressButtonStyle())
                }
            } else if !state.hasGlobalCopyQueueSheet || isEditingLink {
                queueLinkSetup
            } else if let nextEntry {
                Text(nextEntry.content)
                    .font(.subheadline)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    state.copyToClipboard(nextEntry, context: context)
                } label: {
                    Label("Copy title and hashtags", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .primary))

                if let issue = state.globalCopyQueueIssue {
                    Label(
                        "Showing the saved queue because the latest refresh failed: \(issue)",
                        systemImage: "icloud.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else if let issue = state.globalCopyQueueIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
                Button("Change Google Sheet") {
                    isEditingLink = true
                }
                .font(.caption.weight(.semibold))
            } else {
                Text("No uncopied text is waiting in the Queue sheet.")
                    .font(.caption)
                    .foregroundStyle(TrackerPalette.muted)
            }

            if state.hasGlobalCopyQueueSheet {
                Button {
                    showQueue = true
                } label: {
                    Label("Open full copy queue", systemImage: "list.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
            }
        }
        .trackerCard()
        .onAppear {
            queueLinkDraft = state.globalCopyQueueLink
        }
        .onDisappear {
            dismissQueueKeyboard()
        }
        .onChange(of: state.globalCopyQueueLink) { _, newValue in
            if !isEditingLink {
                queueLinkDraft = newValue
            }
        }
        .task {
            if state.hasGlobalCopyQueueSheet {
                await state.syncGlobalCopyQueue(
                    context: context,
                    announceErrors: false
                )
            }
        }
        .sheet(isPresented: $showQueue) {
            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        CopyQueueContent(search: $search)
                    }
                    .padding(16)
                    .padding(.bottom, 80)
                }
                .trackerScreen()
                .navigationTitle("Global Copy Queue")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Search titles or hashtags")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showQueue = false }
                    }
                }
                .refreshable {
                    await state.syncGlobalCopyQueue(context: context)
                }
            }
        }
    }

    private var queueLinkSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste the link to your global Queue Google Sheet. It can live anywhere in Drive that the connected Google account can access.")
                .font(.caption)
                .foregroundStyle(TrackerPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "https://docs.google.com/spreadsheets/d/…",
                text: $queueLinkDraft
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(TrackerPalette.raised)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(TrackerPalette.line, lineWidth: 1)
            }
            .focused($isQueueLinkFocused)
            .onSubmit {
                connectQueue()
            }

            HStack {
                Button {
                    pasteQueueLink()
                } label: {
                    Label("Paste Link", systemImage: "doc.on.clipboard")
                }

                Spacer()

                Button {
                    selectAllQueueLink()
                } label: {
                    Label("Select All", systemImage: "selection.pin.in.out")
                }
                .disabled(queueLinkDraft.isEmpty)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(TrackerPressButtonStyle())

            Button {
                connectQueue()
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "link")
                    }
                    Text(isConnecting ? "Connecting…" : "Connect Global Queue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TrackerActionButtonStyle(kind: .primary))
            .disabled(
                isConnecting ||
                queueLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            if state.hasGlobalCopyQueueSheet, isEditingLink {
                Button("Cancel") {
                    queueLinkDraft = state.globalCopyQueueLink
                    isEditingLink = false
                    dismissQueueKeyboard()
                }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func connectQueue() {
        guard !isConnecting else { return }
        dismissQueueKeyboard()
        isConnecting = true
        Task {
            let connected = await state.connectGlobalCopyQueue(
                link: queueLinkDraft,
                context: context
            )
            if connected {
                queueLinkDraft = state.globalCopyQueueLink
                isEditingLink = false
            }
            isConnecting = false
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
