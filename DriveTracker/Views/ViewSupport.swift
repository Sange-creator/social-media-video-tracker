import SwiftUI
import UIKit

enum TrackerPalette {
    static let canvas = Color(red: 0.035, green: 0.043, blue: 0.055)
    static let surface = Color(red: 0.075, green: 0.09, blue: 0.11)
    static let raised = Color(red: 0.105, green: 0.125, blue: 0.15)
    static let line = Color.white.opacity(0.10)
    static let muted = Color(red: 0.55, green: 0.59, blue: 0.65)
    static let accent = Color(red: 0.27, green: 0.51, blue: 0.96)
    static let success = Color(red: 0.24, green: 0.75, blue: 0.49)
    static let warning = Color(red: 0.94, green: 0.62, blue: 0.24)
    static let danger = Color(red: 0.95, green: 0.34, blue: 0.35)
}

struct StatusPill: View {
    let status: VideoStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.tint)
                .frame(width: 6, height: 6)
            Text(status.title.capitalized)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(status.tint.opacity(0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(status.tint.opacity(0.26), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(title.capitalized).lineLimit(1)
            Image(systemName: selected ? "xmark" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(selected ? Color.white : TrackerPalette.muted)
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(selected ? TrackerPalette.accent : TrackerPalette.raised)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(selected ? TrackerPalette.accent : TrackerPalette.line, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct TrackerSectionLabel: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrackerPalette.muted)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(TrackerPalette.muted)
            }
        }
    }
}

struct TrackerMetric: View {
    let value: String
    let label: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TrackerPalette.muted)
        }
    }
}

struct TrackerActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case quiet
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .white
        case .quiet: TrackerPalette.muted
        }
    }

    private var background: Color {
        switch kind {
        case .primary: TrackerPalette.accent
        case .secondary: TrackerPalette.raised
        case .quiet: .clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary: TrackerPalette.accent
        case .secondary, .quiet: TrackerPalette.line
        }
    }
}

extension View {
    func trackerCard(padding cardPadding: CGFloat = 16) -> some View {
        padding(cardPadding)
            .background(TrackerPalette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(TrackerPalette.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    func trackerScreen() -> some View {
        background(TrackerPalette.canvas.ignoresSafeArea())
    }

    func trackerListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(TrackerPalette.canvas)
    }
}

extension VideoStatus {
    var tint: Color {
        switch self {
        case .available: TrackerPalette.muted
        case .assigned: TrackerPalette.warning
        case .downloaded: TrackerPalette.accent
        case .uploaded: TrackerPalette.success
        }
    }
}

struct AccountIdentityIcon: View {
    let symbol: String
    let colorHex: String
    var size: CGFloat = 48
    var badge: String?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(Color(hex: colorHex))
            .frame(width: size, height: size)
            .background(Color(hex: colorHex).opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                    .stroke(Color(hex: colorHex).opacity(0.42), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: max(8, size * 0.18), weight: .semibold, design: .monospaced))
                        .foregroundStyle(TrackerPalette.muted)
                        .frame(minWidth: size * 0.38, minHeight: size * 0.38)
                        .padding(.horizontal, 2)
                        .background(TrackerPalette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4).stroke(TrackerPalette.line, lineWidth: 1)
                        }
                        .offset(x: size * 0.10, y: size * 0.10)
                }
            }
    }
}

struct VideoThumbnailView: View {
    @EnvironmentObject private var state: AppState
    let video: VideoAsset
    var width: CGFloat = 108
    var height: CGFloat = 144

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(TrackerPalette.raised)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(TrackerPalette.muted)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(TrackerPalette.line, lineWidth: 1)
        }
        .task(id: video.thumbnailLink) {
            image = await state.thumbnailImage(for: video)
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

struct AccountIconPicker: View {
    @Binding var symbol: String
    @Binding var colorHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a symbol")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrackerPalette.muted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AccountIconCatalog.symbols, id: \.self) { option in
                        Button {
                            symbol = option
                        } label: {
                            Image(systemName: option)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(symbol == option ? .white : TrackerPalette.muted)
                                .frame(width: 42, height: 42)
                                .background(
                                    symbol == option
                                        ? Color(hex: colorHex)
                                        : TrackerPalette.raised
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            symbol == option ? .white.opacity(0.45) : TrackerPalette.line,
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("Choose a color")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TrackerPalette.muted)

            HStack(spacing: 12) {
                ForEach(AccountIconCatalog.colors, id: \.self) { option in
                    Button {
                        colorHex = option
                    } label: {
                        Circle()
                            .fill(Color(hex: option))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if colorHex == option {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle().stroke(.white.opacity(colorHex == option ? 0.75 : 0.12), lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

extension String {
    var humanized: String {
        replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
