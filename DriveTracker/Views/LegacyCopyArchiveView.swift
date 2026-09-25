import SwiftData
import SwiftUI

struct LegacyCopyArchiveView: View {
    @Query(sort: \CopyEntry.sourceRow) private var entries: [CopyEntry]

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No archived clipboard text",
                    systemImage: "archivebox",
                    description: Text("Text from the retired Global Copy Queue will remain available here after migration.")
                )
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Archived row \(entry.sourceRow)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TrackerPalette.muted)
                        Text(entry.content)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .trackerScreen()
        .navigationTitle("Clipboard Archive")
        .navigationBarTitleDisplayMode(.inline)
    }
}
