import Foundation

struct VideoCaption: Equatable, Sendable {
    let title: String
    let hashtags: String
    var text: String { title + "\n\n" + hashtags }
}

enum VideoCaptionParser {
    enum Issue: LocalizedError {
        case ambiguousNumber, missing, duplicate, incomplete
        var errorDescription: String? {
            switch self {
            case .ambiguousNumber: "Use one video number in the filename, such as Video 001.mp4."
            case .missing: "No title and hashtags were found for this video number."
            case .duplicate: "This video number has multiple metadata entries. Correct the document before copying."
            case .incomplete: "This entry needs both a Title: line and a Hashtags: line."
            }
        }
    }

    static func number(in filename: String) throws -> Int {
        let stem = (filename as NSString).deletingPathExtension
        let regex = try NSRegularExpression(pattern: #"\d+"#)
        let matches = regex.matches(in: stem, range: NSRange(stem.startIndex..., in: stem))
        guard matches.count == 1, let range = Range(matches[0].range, in: stem),
              let number = Int(stem[range]) else { throw Issue.ambiguousNumber }
        return number
    }

    static func caption(for filename: String, document: String) throws -> VideoCaption {
        let number = try number(in: filename)
        let regex = try NSRegularExpression(pattern: #"(?im)^\s*Video\s*#?\s*(\d+)\s*[:\-]?\s*$"#)
        let matches = regex.matches(in: document, range: NSRange(document.startIndex..., in: document))
        var entries: [String] = []
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range(at: 1), in: document), Int(document[range]) == number else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : (document as NSString).length
            entries.append((document as NSString).substring(with: NSRange(location: start, length: end - start)))
        }
        guard !entries.isEmpty else { throw Issue.missing }
        guard entries.count == 1 else { throw Issue.duplicate }
        var title: [String] = [], tags: [String] = []
        var section = ""
        for line in entries[0].components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.lowercased().hasPrefix("title:") {
                section = "title"; title.append(String(clean.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            } else if clean.lowercased().hasPrefix("hashtags:") {
                section = "tags"; tags.append(String(clean.dropFirst(9)).trimmingCharacters(in: .whitespaces))
            } else if !clean.isEmpty {
                if section == "title" { title.append(clean) }
                else if section == "tags" { tags.append(clean) }
            }
        }
        let caption = VideoCaption(title: title.joined(separator: " ").trimmingCharacters(in: .whitespaces),
                                   hashtags: tags.joined(separator: " ").trimmingCharacters(in: .whitespaces))
        guard !caption.title.isEmpty, !caption.hashtags.isEmpty else { throw Issue.incomplete }
        return caption
    }
}

enum UploadPlatform: String, CaseIterable, Identifiable {
    case tiktok = "TikTok", facebook = "Facebook"
    var id: String { rawValue }
}

struct CaptionDocumentChoice: Codable, Identifiable {
    let id: String
    let name: String
}
