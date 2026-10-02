import AVFoundation
import Foundation

// AVFoundation may deliver KVO on its own queue. The provider callback must
// not inherit MainActor; only the UI handler hops to that executor.
nonisolated enum PlaybackObservation {
    static func failure(
        of item: AVPlayerItem,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> NSKeyValueObservation {
        item.observe(\.status, options: [.initial, .new]) { observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor in handler() }
        }
    }
}
