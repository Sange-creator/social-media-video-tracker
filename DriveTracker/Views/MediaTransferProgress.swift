import SwiftUI

/// Observes transfer updates directly, including when the parent app state is unchanged.
struct MediaTransferProgress: View {
    let identity: String
    @ObservedObject var downloads: DownloadCoordinator

    var body: some View {
        VStack(spacing: 6) {
            if let progress = downloads.progressByIdentity[identity] {
                let written = ByteCountFormatter.string(fromByteCount: progress.bytesWritten, countStyle: .file)
                if progress.totalBytes > 0 {
                    let fraction = TodayDownloadProgress.clamped(progress.fraction)
                    let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                    Text("Downloading \(Int(fraction * 100))% • \(written) / \(total)")
                    ProgressView(value: fraction)
                } else {
                    Text("Downloading • \(written) received")
                    ProgressView()
                }
            } else {
                Text("Connecting to Drive…")
                ProgressView()
            }
        }
        .font(.caption.monospacedDigit().weight(.bold))
        .foregroundStyle(TrackerPalette.accent)
        .tint(TrackerPalette.accent)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
