import Foundation

enum PlaybackTime {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else {
            return "00:00"
        }
        let wholeSeconds = Int(seconds)
        return String(format: "%02ld:%02ld", wholeSeconds / 60, wholeSeconds % 60)
    }
}
