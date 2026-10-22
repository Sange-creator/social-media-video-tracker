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

struct CopyQueueScreen: View {
    @State private var search = ""

    var body: some View {
        NavigationStack {
            CopyQueueContent(search: $search)
                .navigationTitle("Clipboard")
            .searchable(text: $search, prompt: "Search captions & hashtags…")
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
        let entries = filteredEntries
        List {
            overview

            if let issue = state.globalCopyQueueIssue {
                Label(
                    "Saved rows are available. Retrying automatically: \(issue)",
                    systemImage: "arrow.clockwise.icloud"
                )
                .font(.caption)
                .foregroundStyle(TrackerPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
            }

            HStack {
                TrackerSectionLabel(
                    title: "Copy queue",
                    trailing: "\(entries.count) entries"
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

            if entries.isEmpty {
                ContentUnavailableView(
                    filter == .uncopied ? "No uncopied text" : "No matching text",
                    systemImage: "text.badge.checkmark",
                    description: Text(emptyDescription)
                )
                .foregroundStyle(TrackerPalette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(entries) { entry in
                    CopyEntryCard(entry: entry)
                }
            }
        }
        .listStyle(.insetGrouped)
        .trackerListStyle()
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
        .padding(.vertical, 6)
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
            return left.sourceRow < right.sourceRow
        }
        if left.copiedAt != right.copiedAt {
            return (left.copiedAt ?? .distantPast) > (right.copiedAt ?? .distantPast)
        }
        return left.sourceRow < right.sourceRow
    }
}

struct CopyEntryCard: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var state: AppState
    let entry: CopyEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.caption)
                        .foregroundStyle(TrackerPalette.accent)
                    Text("Row \(entry.sourceRow) Clipboard")
                        .font(.headline)
                        .foregroundStyle(TrackerPalette.textPrimary)
                }

                Spacer()

                if let copiedAt = entry.copiedAt {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                        Text("Copied \(copiedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                    }
                    .foregroundStyle(TrackerPalette.success)
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(TrackerPalette.warning)
                            .frame(width: 6, height: 6)
                        Text("Ready to copy")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(TrackerPalette.warning)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(entry.content)
                        .font(.body)
                        .foregroundStyle(TrackerPalette.textPrimary)
                        .lineLimit(isExpanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TrackerPalette.muted)
                        .padding(.top, 3)
                }
                .padding(10)
                .background(TrackerPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse row \(entry.sourceRow)" : "Expand row \(entry.sourceRow)")

            HStack(spacing: 10) {
                Button {
                    state.copyToClipboard(entry, context: context)
                } label: {
                    Label(
                        entry.copiedAt == nil ? "Copy Row \(entry.sourceRow) to Clipboard" : "Copy Row \(entry.sourceRow) Again",
                        systemImage: entry.copiedAt == nil ? "doc.on.doc" : "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TrackerActionButtonStyle(kind: entry.copiedAt == nil ? .primary : .secondary))

                if entry.copiedAt != nil {
                    Button {
                        state.markCopyEntryUncopied(entry, context: context)
                    } label: {
                        Label("Uncopy", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TrackerActionButtonStyle(kind: .secondary))
                    .frame(width: 105)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
